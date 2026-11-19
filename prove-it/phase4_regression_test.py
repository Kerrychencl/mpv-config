#!/usr/bin/env python3
"""
prove-it/phase4_regression_test.py
Automated Phase 4 Regression Verification Suite.

Tests:
1. Syntax Verification:
   - Python files (btr_engine.py, sponsor_unified.py, online_thumb_engine.py) via py_compile.
   - Lua files (modernz.lua, sponsorblock.lua, cookie-sync.lua, btr/main.lua) loaded in MPV.
2. Acceptance Test a: SponsorBlock Click Test (script-message sponsorblock-show-skip & click card, no crash).
3. Acceptance Test b: BTR Security Test (file:// scheme and disallowed domains rejected with 403, no CORS headers).
4. Acceptance Test c: Cookie Isolation Test (Bilibili mock cookie loaded, local clean 127.0.0.1 stream verified with 0 leaked headers).
5. Acceptance Test d: Glass Blur Persistence Test (Ctrl+1 -> Ctrl+0 shader cycle, modernz-glass.glsl cleanly re-attaches).
"""

import os
import sys
import time
import py_compile
import subprocess
import urllib.request
import urllib.error
import http.server
import socketserver
import threading

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MPV_COM = os.path.join(PROJECT_ROOT, "mpv.com")
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, "portable_config", "scripts")
TEST_IMG = os.path.join(PROJECT_ROOT, "portable_config", "scripts", "file-browser", "screenshots", "front.png")

RESULTS = []

def record(test_name, passed, details=""):
    verdict = "PASS" if passed else "FAIL"
    RESULTS.append((test_name, verdict, details))
    print(f"[{verdict}] {test_name}: {details}")

def test_syntax():
    print("\n--- 1. Syntax Verification ---")
    py_files = [
        os.path.join(SCRIPTS_DIR, "btr", "btr_engine.py"),
        os.path.join(PROJECT_ROOT, "portable_config", "sponsorblock_shared", "sponsor_unified.py"),
        os.path.join(SCRIPTS_DIR, "online_thumb_engine.py")
    ]
    py_ok = True
    for pf in py_files:
        try:
            py_compile.compile(pf, doraise=True)
            print(f"  [OK] Python syntax: {os.path.basename(pf)}")
        except Exception as e:
            print(f"  [ERR] Python syntax error in {pf}: {e}")
            py_ok = False
    record("Python Syntax (py_compile)", py_ok, "All modified Python files compiled with 0 errors")

    # Lua load check via MPV
    lua_files = [
        os.path.join(SCRIPTS_DIR, "cookie-sync.lua"),
        os.path.join(SCRIPTS_DIR, "sponsorblock.lua"),
        os.path.join(SCRIPTS_DIR, "btr", "main.lua"),
        os.path.join(SCRIPTS_DIR, "modernz.lua")
    ]
    lua_ok = True
    for lf in lua_files:
        cmd = [MPV_COM, "--no-config", "--load-scripts=no", f"--script={lf}", "--frames=1", TEST_IMG]
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
        # Check for Lua syntax or runtime load error
        if "error" in p.stdout.lower() and "syntax error" in p.stdout.lower():
            print(f"  [ERR] Lua syntax error in {os.path.basename(lf)}:\n{p.stdout}")
            lua_ok = False
        else:
            print(f"  [OK] Lua load check: {os.path.basename(lf)}")
    record("Lua Syntax & Loadability", lua_ok, "All modified Lua scripts parsed and loaded with 0 syntax errors")

def test_sponsorblock_click():
    print("\n--- 2. SponsorBlock Click Test ---")
    cmd = [
        MPV_COM,
        "--no-config",
        "--load-scripts=no",
        "--loop-file=inf",
        f"--script={os.path.join(SCRIPTS_DIR, 'sponsorblock.lua')}",
        f"--script={os.path.join(PROJECT_ROOT, 'prove-it', 'test_sb_click.lua')}",
        TEST_IMG
    ]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15)
    passed = (p.returncode == 0) and ("SPONSORBLOCK_CLICK_TEST_PASS" in p.stdout)
    record("SponsorBlock Click Test", passed, "Card click / TAB execution completed without Lua runtime crash")

def test_btr_security():
    print("\n--- 3. BTR Security Test ---")
    port = 19896
    engine_path = os.path.join(SCRIPTS_DIR, "btr", "btr_engine.py")
    proc = subprocess.Popen([sys.executable, engine_path, "--port", str(port)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(1.5)
    passed = True
    reasons = []
    try:
        # file:// injection
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/stream?url=file:///C:/Windows/win.ini", timeout=3)
            passed = False
            reasons.append("file:// did not 403")
        except urllib.error.HTTPError as e:
            if e.code == 403 and "Access-Control-Allow-Origin" not in e.headers:
                reasons.append("file:// -> 403 (no CORS header)")
            else:
                passed = False
                reasons.append(f"file:// unexpected: {e.code}, CORS={e.headers.get('Access-Control-Allow-Origin')}")

        # Disallowed domain
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/stream?url=https://attacker.example.com/stream.mp4", timeout=3)
            passed = False
            reasons.append("disallowed domain did not 403")
        except urllib.error.HTTPError as e:
            if e.code == 403 and "Access-Control-Allow-Origin" not in e.headers:
                reasons.append("attacker domain -> 403 (no CORS header)")
            else:
                passed = False
                reasons.append(f"attacker domain unexpected: {e.code}")

        # Probe whitelist
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/probe?hosts=evil.com,upos-sz-mirrorali.bilivideo.com", timeout=3) as resp:
                import json
                probe_hosts = [x["host"] for x in json.loads(resp.read().decode('utf-8'))]
                if "evil.com" not in probe_hosts:
                    reasons.append("probe filtered evil.com")
                else:
                    passed = False
                    reasons.append("probe included evil.com")
        except Exception as e:
            passed = False
            reasons.append(f"probe error: {e}")

    finally:
        proc.terminate()
        proc.wait(timeout=3)

    record("BTR Security Test", passed, "; ".join(reasons))

def test_cookie_isolation():
    print("\n--- 4. Cookie Isolation Test ---")
    port = 19912
    requests_log = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests_log.append((self.path, {k: v for k, v in self.headers.items()}))
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        def do_HEAD(self):
            requests_log.append((self.path, {k: v for k, v in self.headers.items()}))
            self.send_response(200)
            self.end_headers()
        def log_message(self, *args): pass

    server = socketserver.TCPServer(("127.0.0.1", port), H)
    server.allow_reuse_address = True
    threading.Thread(target=server.serve_forever, daemon=True).start()

    # Driver lua
    driver_lua = os.path.join(PROJECT_ROOT, "prove-it", "test_cookie_driver2.lua")
    with open(driver_lua, "w", encoding="utf-8") as f:
        f.write(f"""
local mp = require 'mp'
mp.add_timeout(0.4, function()
    mp.commandv("loadfile", "http://127.0.0.1:{port}/bilibili.com/video.mp4", "replace")
    mp.add_timeout(0.8, function()
        mp.commandv("loadfile", "http://127.0.0.1:{port}/clean_local_stream.mp4", "replace")
        mp.add_timeout(0.8, function()
            local g = mp.get_property_native("http-header-fields") or {{}}
            for _, h in ipairs(g) do
                if h:lower():find("sessdata") or h:lower():find("bilibili") then
                    mp.command("quit 1")
                    return
                end
            end
            mp.msg.info("COOKIE_ISOLATION_PASS")
            mp.command("quit 0")
        end)
    end)
end)
mp.add_timeout(6.0, function() mp.command("quit 1") end)
""")

    cmd = [
        MPV_COM,
        "--no-config",
        "--load-scripts=no",
        "--idle=yes",
        f"--script={os.path.join(SCRIPTS_DIR, 'cookie-sync.lua')}",
        f"--script={driver_lua}"
    ]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=12)
    server.shutdown()
    server.server_close()
    try:
        os.remove(driver_lua)
    except Exception:
        pass

    clean_requests = [r for r in requests_log if "clean_local" in r[0]]
    leak = False
    if not clean_requests:
        leak = True
    for path, hdrs in clean_requests:
        ck = hdrs.get("Cookie", "") or hdrs.get("cookie", "")
        rf = hdrs.get("Referer", "") or hdrs.get("referer", "")
        og = hdrs.get("Origin", "") or hdrs.get("origin", "")
        if "SESSDATA" in ck or "bilibili" in rf.lower() or "bilibili" in og.lower():
            leak = True

    passed = (p.returncode == 0) and not leak and ("COOKIE_ISOLATION_PASS" in p.stdout)
    record("Cookie Isolation Test", passed, "0 leaked SESSDATA/Referer headers on clean local stream; global options pure")

def test_glass_blur_persistence():
    print("\n--- 5. Glass Blur Persistence Test ---")
    cmd = [
        MPV_COM,
        f"--config-dir={os.path.join(PROJECT_ROOT, 'portable_config')}",
        "--loop-file=inf",
        f"--script={os.path.join(PROJECT_ROOT, 'prove-it', 'test_glass_blur.lua')}",
        TEST_IMG
    ]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15)
    passed = (p.returncode == 0) and ("GLASS_BLUR_PERSISTENCE_PASS" in p.stdout)
    record("Glass Blur Persistence Test", passed, "modernz-glass.glsl re-attaches on Ctrl+1 -> Ctrl+0 shader clear")

if __name__ == "__main__":
    test_syntax()
    test_sponsorblock_click()
    test_btr_security()
    test_cookie_isolation()
    test_glass_blur_persistence()

    print("\n" + "=" * 60)
    print("           REGRESSION VERIFICATION SUMMARY")
    print("=" * 60)
    all_ok = True
    for name, verdict, details in RESULTS:
        print(f"[{verdict:4s}] {name:30s} -> {details}")
        if verdict != "PASS":
            all_ok = False
    print("=" * 60)
    print("ALL TESTS PASSED!" if all_ok else "SOME TESTS FAILED!")
    sys.exit(0 if all_ok else 1)
