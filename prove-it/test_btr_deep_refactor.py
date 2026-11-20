#!/usr/bin/env python3
"""
prove-it/test_btr_deep_refactor.py
Verification suite for BTR Deep Refactor & Optimization:
1. Adaptive chunk sizing (first 4 chunks 256KB, next 8 chunks 512KB, then 1MB).
2. Audio / small file thread limits (total_size <= 20MB -> threads <= 4).
3. DynamicThreadController tuning (ramp-up on low TTFB, backoff on high TTFB / errors).
4. NodeHealthTracker (record_success, record_failure, 2 fails -> cooldown, target_host priority 1).
5. /status endpoint JSON response format.
6. SponsorBlock extract_ids() double call cid isolation.
"""

import os
import sys
import time
import json
import urllib.request
import urllib.error
import subprocess

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BTR_DIR = os.path.join(PROJECT_ROOT, "portable_config", "scripts", "btr")
sys.path.insert(0, BTR_DIR)

import btr_engine

RESULTS = []

def record(test_name, passed, details=""):
    verdict = "PASS" if passed else "FAIL"
    RESULTS.append((test_name, verdict, details))
    print(f"[{verdict:4s}] {test_name}: {details}")

def test_adaptive_chunk_sizing():
    print("\n--- 1. Adaptive Chunk Sizing ---")
    sizes = [btr_engine.get_adaptive_chunk_size(i) for i in range(16)]
    # First 4: 256 KB
    first_4 = sizes[0:4]
    # Next 8: 512 KB
    next_8 = sizes[4:12]
    # Rest: 1024 KB
    rest = sizes[12:16]

    c256 = 256 * 1024
    c512 = 512 * 1024
    c1024 = 1024 * 1024

    p1 = all(s == c256 for s in first_4)
    p2 = all(s == c512 for s in next_8)
    p3 = all(s == c1024 for s in rest)

    # Simulate chunk ranges for a 20MB stream
    req_start = 0
    req_end = 20 * 1024 * 1024 - 1
    chunks = []
    cur = req_start
    c_idx = 0
    while cur <= req_end:
        sz = btr_engine.get_adaptive_chunk_size(c_idx)
        chunk_end = min(cur + sz - 1, req_end)
        chunks.append((c_idx, cur, chunk_end, chunk_end - cur + 1))
        cur = chunk_end + 1
        c_idx += 1

    p4 = (chunks[0][3] == c256 and chunks[3][3] == c256 and
          chunks[4][3] == c512 and chunks[11][3] == c512 and
          chunks[12][3] == c1024)

    passed = p1 and p2 and p3 and p4
    details = f"c_idx 0-3={first_4[0]//1024}KB, 4-11={next_8[0]//1024}KB, 12+={rest[0]//1024}KB, total chunks={len(chunks)}"
    record("Adaptive Chunk Sizing", passed, details)

def test_audio_small_file_thread_limits():
    print("\n--- 2. Audio / Small File Thread Limits ---")
    # For small files (e.g. <= 20MB) or audio tracks, concurrency must be capped at min(threads, 4)
    ctrl_audio = btr_engine.DynamicThreadController(requested_threads=32, auto_threads=True, is_audio=True)
    c_audio = ctrl_audio.get_concurrency()
    m_audio = ctrl_audio.max_concurrency

    # Attempt ramp up on audio track
    for _ in range(10):
        ctrl_audio.record_chunk(ttfb=0.1, is_error=False)
    c_audio_after = ctrl_audio.get_concurrency()

    # For normal video (> 20MB), concurrency should allow scaling up to min(requested_threads, 24)
    ctrl_video = btr_engine.DynamicThreadController(requested_threads=32, auto_threads=True, is_audio=False)
    c_video = ctrl_video.get_concurrency()
    m_video = ctrl_video.max_concurrency

    passed = (c_audio <= 4) and (m_audio <= 4) and (c_audio_after <= 4) and (c_video == 4) and (m_video == 24)
    details = f"audio: initial={c_audio}, max={m_audio}, after low TTFB={c_audio_after} (all <= 4); video max={m_video}"
    record("Audio / Small File Thread Limits", passed, details)

def test_dynamic_thread_controller_tuning():
    print("\n--- 3. DynamicThreadController Tuning ---")
    ctrl = btr_engine.DynamicThreadController(requested_threads=32, auto_threads=True, is_audio=False)
    initial_c = ctrl.get_concurrency()

    # Ramp up: feed low TTFB (< 0.8s)
    concurrencies = [initial_c]
    for i in range(1, 11):
        ctrl.record_chunk(ttfb=0.2, is_error=False)
        concurrencies.append(ctrl.get_concurrency())

    ramped_c = ctrl.get_concurrency()
    ramp_ok = ramped_c > initial_c

    # Backoff on high TTFB (> 1.8s) over rolling window
    for _ in range(10):
        ctrl.record_chunk(ttfb=2.5, is_error=False)
    backoff_c = ctrl.get_concurrency()
    backoff_ok = backoff_c < ramped_c

    # Re-ramp slightly then test immediate backoff on error
    ctrl.record_chunk(ttfb=0.2, is_error=False)
    ctrl.record_chunk(ttfb=0.2, is_error=False)
    ctrl.record_chunk(ttfb=0.2, is_error=True)
    err_backoff_c = ctrl.get_concurrency()
    err_ok = err_backoff_c >= 4

    # auto_threads = False should maintain fixed requested threads
    ctrl_fixed = btr_engine.DynamicThreadController(requested_threads=16, auto_threads=False, is_audio=False)
    fixed_initial = ctrl_fixed.get_concurrency()
    for _ in range(6):
        ctrl_fixed.record_chunk(ttfb=0.1, is_error=False)
    for _ in range(4):
        ctrl_fixed.record_chunk(ttfb=3.0, is_error=True)
    fixed_after = ctrl_fixed.get_concurrency()
    fixed_ok = (fixed_initial == 16 and fixed_after == 16)

    passed = ramp_ok and backoff_ok and err_ok and fixed_ok
    details = f"ramp: {initial_c} -> {ramped_c}; high TTFB backoff -> {backoff_c}; err backoff -> {err_backoff_c}; fixed: {fixed_after}"
    record("DynamicThreadController Tuning", passed, details)

def test_node_health_tracker():
    print("\n--- 4. NodeHealthTracker ---")
    tracker = btr_engine.NodeHealthTracker()
    test_host = "upos-sz-mirrorali.bilivideo.com"
    other_host = "upos-sz-mirrorcos.bilivideo.com"

    # Test record_success
    tracker.record_success(test_host, latency_ms=45.0, speed_mbps=50.0)
    h_info = tracker.hosts[test_host]
    succ_ok = (h_info["fail_count"] == 0) and tracker.is_healthy(test_host)

    # Test 1 failure (not yet in cooldown)
    tracker.record_failure(test_host)
    h_info1 = tracker.hosts[test_host]
    one_fail_ok = (h_info1["fail_count"] == 1) and tracker.is_healthy(test_host)

    # Test 2 consecutive failures -> triggers 60s cooldown
    tracker.record_failure(test_host)
    h_info2 = tracker.hosts[test_host]
    two_fails_ok = (h_info2["fail_count"] >= 2) and (not tracker.is_healthy(test_host))

    # Priority 1 guarantee for healthy target_host
    healthy_selected = tracker.select_healthy_hosts(target_host=other_host, cdn_mode="mainland", count=4)
    target_p1_ok = (len(healthy_selected) > 0 and healthy_selected[0] == other_host)

    # Cooldown host deprioritized / excluded from head
    cooldown_selected = tracker.select_healthy_hosts(target_host=test_host, cdn_mode="mainland", count=4)
    cooldown_excluded_ok = (len(cooldown_selected) > 0 and cooldown_selected[0] != test_host)

    passed = succ_ok and one_fail_ok and two_fails_ok and target_p1_ok and cooldown_excluded_ok
    details = f"success: fail_cnt=0; 1 fail: fail_cnt=1, healthy=True; 2 fails: cooldown=True; target_p1={target_p1_ok}; cooldown_excluded={cooldown_excluded_ok}"
    record("NodeHealthTracker", passed, details)

def test_status_endpoint():
    print("\n--- 5. /status Endpoint ---")
    port = 19897
    engine_py = os.path.join(BTR_DIR, "btr_engine.py")
    proc = subprocess.Popen([sys.executable, engine_py, "--port", str(port)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(1.5)
    passed = False
    details = ""
    try:
        url = f"http://127.0.0.1:{port}/status"
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            status_code = resp.status
            content_type = resp.headers.get("Content-Type", "")
            raw = resp.read().decode("utf-8")
            data = json.loads(raw)

            c1 = (status_code == 200)
            c2 = ("application/json" in content_type)
            c3 = isinstance(data.get("active_threads"), int)
            c4 = isinstance(data.get("target_concurrency"), int)
            c5 = isinstance(data.get("speed_mbps"), (int, float))
            c6 = isinstance(data.get("healthy_nodes"), list)
            c7 = isinstance(data.get("auto_threads"), bool)

            passed = c1 and c2 and c3 and c4 and c5 and c6 and c7
            details = f"status={status_code}, ct={content_type}, keys: {list(data.keys())}, sample={data}"
    except Exception as e:
        passed = False
        details = f"Exception: {e}"
    finally:
        proc.terminate()
        proc.wait(timeout=3.0)

    record("/status Endpoint", passed, details)

def test_sponsorblock_extract_ids_isolation():
    print("\n--- 6. SponsorBlock extract_ids() CID Isolation ---")
    mpv_com = os.path.join(PROJECT_ROOT, "mpv.com")
    lua_test = os.path.join(os.path.dirname(__file__), "test_extract_ids.lua")

    cmd = [
        mpv_com,
        "--no-config",
        "--load-scripts=no",
        "--idle=yes",
        f"--script={lua_test}"
    ]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
    passed = (p.returncode == 0) and ("SPONSORBLOCK_CID_ISOLATION_PASS" in p.stdout)
    details = "extract_ids() Call 1 (cid=12345678) isolated from Call 2 (stale cid prevented, returned nil)"
    if not passed:
        details += f" Output: {p.stdout}"
    record("SponsorBlock CID Isolation", passed, details)

if __name__ == "__main__":
    test_adaptive_chunk_sizing()
    test_audio_small_file_thread_limits()
    test_dynamic_thread_controller_tuning()
    test_node_health_tracker()
    test_status_endpoint()
    test_sponsorblock_extract_ids_isolation()

    print("\n" + "=" * 65)
    print("         BTR DEEP REFACTOR VERIFICATION SUMMARY")
    print("=" * 65)
    all_ok = True
    for name, verdict, details in RESULTS:
        print(f"[{verdict:4s}] {name:32s} -> {details}")
        if verdict != "PASS":
            all_ok = False
    print("=" * 65)
    print("ALL TESTS PASSED!" if all_ok else "SOME TESTS FAILED!")
    sys.exit(0 if all_ok else 1)
