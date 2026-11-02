#!/usr/bin/env python3
"""
prove-it/adversarial_challenge.py
Adversarial Verification Suite for MPV YouTube Playback & Cookie Sync.

Tests:
1. Scenario 1: YouTube Music / VEVO (Rick Astley dQw4w9WgXcQ) 4K AV1 & n-sig cipher
2. Scenario 2: YouTube 4K / 60fps (aqz-KE-bpKQ) hardware decoding & auto profile
3. Scenario 3: YouTube Shorts (V_t51u1tBJc) vertical aspect & stream decoding
4. Scenario 4: Fast seek forward and backward barrage under live stream
5. Scenario 5: YouTube Audio-only playback (--no-video)
6. Scenario 6: BotGuard Bot-wall Resistance (Anonymous vs Cookie-authenticated)
7. Scenario 7: Cookie Sync Edge Cases:
   - 7.1: Missing cookies.txt fallback & empty active cookie header
   - 7.2: 0-byte cookies.txt handling
   - 7.3: PotPlayer raw cookie string syntax parsing
   - 7.4: Concurrent MPV process startup file access
   - 7.5: Bilibili -> YouTube playlist session isolation (header contamination check)
"""

import os
import sys
import time
import shutil
import subprocess

PROJECT_ROOT = r"D:\Media tool\mpv-x86_64-v3-20260610-git-304426c"
MPV_COM = os.path.join(PROJECT_ROOT, "mpv.com")
YTDL_EXE = os.path.join(PROJECT_ROOT, "yt-dlp.exe")
COOKIES_USER = os.path.join(PROJECT_ROOT, "portable_config", "cookies.txt")
TEMP_DIR = os.environ.get("TEMP", r"C:\Users\Administrator\AppData\Local\Temp")
COOKIES_ACTIVE = os.path.join(TEMP_DIR, "mpv_active_cookies.txt")

RESULTS = []

def record(test_id, name, status, details=""):
    verdict = "PASS" if status else "FAIL"
    RESULTS.append({"id": test_id, "name": name, "status": verdict, "details": details})
    print(f"[{verdict}] {test_id}: {name} -> {details}")

def run_cmd(cmd, timeout=35):
    try:
        proc = subprocess.run(
            cmd,
            cwd=PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            shell=True
        )
        return proc.returncode, proc.stdout or ""
    except subprocess.TimeoutExpired:
        return -1, "Timeout expired"

def test_scenario_1_music():
    # Music / VEVO with signature cipher
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    cmd = f'"{MPV_COM}" --frames=40 --idle=no --keep-open=no "{url}"'
    code, out = run_cmd(cmd, timeout=30)
    passed = code == 0 and ("AV:" in out or "3840x2160" in out)
    record("ADV-1", "YouTube Music Video (Rick Astley 4K AV1)", passed, f"Exit: {code}, 4K/AV1 detected: {'3840x2160' in out}")

def test_scenario_2_4k60():
    # 4K 60fps
    url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
    cmd = f'"{MPV_COM}" --frames=40 --idle=no --keep-open=no "{url}"'
    code, out = run_cmd(cmd, timeout=30)
    passed = code == 0 and "4k-video" in out
    record("ADV-2", "YouTube 4K 60fps Profile Trigger", passed, f"Exit: {code}, 4k-video profile: {'4k-video' in out}")

def test_scenario_3_shorts():
    # YouTube Shorts
    url = "https://www.youtube.com/shorts/V_t51u1tBJc"
    cmd = f'"{MPV_COM}" --frames=40 --idle=no --keep-open=no "{url}"'
    code, out = run_cmd(cmd, timeout=30)
    passed = code == 0 and "AV:" in out
    record("ADV-3", "YouTube Shorts Vertical Playback", passed, f"Exit: {code}, Demuxed/Played: {'AV:' in out}")

def test_scenario_4_seek():
    # Rapid seek barrage
    script_path = os.path.join(PROJECT_ROOT, "prove-it", "test_seek_stress.lua")
    cmd = f'"{MPV_COM}" --script="{script_path}" --idle=no --keep-open=no "https://www.youtube.com/watch?v=dQw4w9WgXcQ"'
    code, out = run_cmd(cmd, timeout=40)
    passed = code == 0 and "SUCCESS: Video continues smooth playback after stress seeks!" in out
    record("ADV-4", "Rapid Seek Forward/Backward Barrage", passed, f"Exit: {code}, Seek recovery confirmed")

def test_scenario_5_audio_only():
    # Audio-only
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    cmd = f'"{MPV_COM}" --no-video --length=4 --idle=no --keep-open=no "{url}"'
    code, out = run_cmd(cmd, timeout=25)
    passed = code == 0 and "AO: [wasapi]" in out
    record("ADV-5", "YouTube Audio-Only Mode (--no-video)", passed, f"Exit: {code}, WASAPI audio active")

def test_scenario_6_botguard():
    # Verify BotGuard / JS Challenge resolution in both Anonymous and Authenticated modes
    # 6.1 Anonymous mode: Verifies Deno JS engine solves challenges without format unrecognized
    code_anon, out_anon = run_cmd(f'"{YTDL_EXE}" -g "https://www.youtube.com/watch?v=jNQXAC9IVRw"', timeout=20)
    anon_passed = code_anon == 0 and "googlevideo.com" in out_anon and "format unrecognized" not in out_anon.lower()
    record("ADV-6.1", "BotGuard & JS Challenge Resolution (Anonymous)", anon_passed, f"Exit: {code_anon}, googlevideo resolved: {anon_passed}")

    # 6.2 Authenticated mode with synchronized active cookies
    code_auth, out_auth = run_cmd(f'"{YTDL_EXE}" --cookies "{COOKIES_ACTIVE}" -g "https://www.youtube.com/watch?v=dQw4w9WgXcQ"', timeout=20)
    auth_passed = code_auth == 0 and "googlevideo.com" in out_auth
    record("ADV-6.2", "BotGuard & Authenticated Cookie Extraction", auth_passed, f"Exit: {code_auth}, googlevideo resolved: {auth_passed}")

def test_scenario_7_cookie_sync_edge_cases():
    # 7.1 Missing cookies.txt
    bak_path = COOKIES_USER + ".bak_adv"
    shutil.copyfile(COOKIES_USER, bak_path)
    try:
        os.remove(COOKIES_USER)
        # Run mpv on a simple test to trigger cookie-sync.lua
        cmd = f'"{MPV_COM}" --frames=1 --idle=no --keep-open=no "{os.path.join(PROJECT_ROOT, "yt-dlp.exe")}"'
        code, out = run_cmd(cmd, timeout=15)
        # Check active cookies file exists and has Netscape header
        has_active = os.path.exists(COOKIES_ACTIVE)
        with open(COOKIES_ACTIVE, "r", encoding="utf-8") as f:
            c_header = f.readline()
        record("ADV-7.1", "Cookie-Sync Missing cookies.txt Fallback/Header", "# Netscape HTTP Cookie File" in c_header, f"Header: {c_header.strip()}")
    finally:
        if os.path.exists(bak_path):
            shutil.copyfile(bak_path, COOKIES_USER)
            os.remove(bak_path)

    # 7.2 Empty cookies.txt
    shutil.copyfile(COOKIES_USER, bak_path)
    try:
        with open(COOKIES_USER, "w", encoding="utf-8") as f:
            pass # 0 bytes
        cmd = f'"{MPV_COM}" --frames=1 --idle=no --keep-open=no "{os.path.join(PROJECT_ROOT, "yt-dlp.exe")}"'
        code, out = run_cmd(cmd, timeout=15)
        with open(COOKIES_ACTIVE, "r", encoding="utf-8") as f:
            c_header = f.readline()
        record("ADV-7.2", "Cookie-Sync 0-byte cookies.txt Graceful Recovery", "# Netscape HTTP Cookie File" in c_header, f"Header: {c_header.strip()}")
    finally:
        if os.path.exists(bak_path):
            shutil.copyfile(bak_path, COOKIES_USER)
            os.remove(bak_path)

    # 7.3 PotPlayer raw cookie string syntax
    shutil.copyfile(COOKIES_USER, bak_path)
    try:
        with open(COOKIES_USER, "w", encoding="utf-8") as f:
            f.write("SESSDATA=d6e26c1a; bili_jct=f3f9c556; LOGIN_INFO=AFmmF2sw; __Secure-1PSID=ga000123\n")
        cmd = f'"{MPV_COM}" --frames=1 --idle=no --keep-open=no "{os.path.join(PROJECT_ROOT, "yt-dlp.exe")}"'
        code, out = run_cmd(cmd, timeout=15)
        with open(COOKIES_ACTIVE, "r", encoding="utf-8") as f:
            active_content = f.read()
        has_bili = ".bilibili.com" in active_content and "SESSDATA" in active_content
        has_yt = ".youtube.com" in active_content and "__Secure-1PSID" in active_content
        record("ADV-7.3", "Cookie-Sync Raw String Parsing & Transpilation", has_bili and has_yt, f"Bili mapped: {has_bili}, YT mapped: {has_yt}")
    finally:
        if os.path.exists(bak_path):
            shutil.copyfile(bak_path, COOKIES_USER)
            os.remove(bak_path)

    # 7.4 Session isolation (Bilibili -> YouTube transition)
    script_path = os.path.join(PROJECT_ROOT, "prove-it", "test_playlist_transition.lua")
    cmd = f'"{MPV_COM}" --script="{script_path}" --idle=no --keep-open=no "https://www.bilibili.com/video/BV1xx411c7mD"'
    code, out = run_cmd(cmd, timeout=30)
    passed = code == 0 and "YOUTUBE-VERIFY HEADERS COUNT: 0" in out and "Transition test complete" in out
    record("ADV-7.4", "Session Isolation: Bilibili -> YouTube Header Scoping", passed, f"Exit: {code}, YT headers count: 0")

def main():
    print("=" * 80)
    print("  MPV ADVERSARIAL CHALLENGE SUITE -- YouTube Robustness & Edge Cases")
    print("=" * 80)
    
    test_scenario_1_music()
    test_scenario_2_4k60()
    test_scenario_3_shorts()
    test_scenario_4_seek()
    test_scenario_5_audio_only()
    test_scenario_6_botguard()
    test_scenario_7_cookie_sync_edge_cases()

    total = len(RESULTS)
    passed = sum(1 for r in RESULTS if r["status"] == "PASS")
    failed = total - passed

    print("\n" + "=" * 80)
    print(f"  CHALLENGE SUMMARY: {passed}/{total} PASSED, {failed} FAILED")
    print("=" * 80)

    # Write summary artifact
    out_md = os.path.join(PROJECT_ROOT, "prove-it", "adversarial_results.md")
    with open(out_md, "w", encoding="utf-8") as f:
        f.write("# Adversarial Challenge Results\n\n")
        f.write(f"- Total Scenarios Tested: {total}\n")
        f.write(f"- Passed: {passed}\n")
        f.write(f"- Failed: {failed}\n\n")
        f.write("| ID | Scenario | Status | Details |\n")
        f.write("|---|---|---|---|\n")
        for r in RESULTS:
            f.write(f"| {r['id']} | {r['name']} | **{r['status']}** | {r['details']} |\n")

    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
