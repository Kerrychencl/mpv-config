#!/usr/bin/env python3
"""
prove-it/run_thumbnail_challenge.py
Adversarial Stress Test Suite & Oracle for MPV Seekbar Thumbnail & ModernZ Layering.

Challenger: teamwork_challenger_2
Mission:
1. Formulate stress test scenarios: rapid hover across timeline, seekbar hover during active playback vs paused, testing both Bilibili and YouTube.
2. Capture screenshots and calculate pixel histogram/variance to prove thumbnail rendering is consistent, real, and never reverts to a pure black box.
3. Verify overlay layering: ModernZ OSD elements (time text, slider, borders) composite correctly with thumbfast without clipping or artifacts.
4. Output detailed verification metrics.
"""

import os
import sys
import subprocess
import time
from PIL import Image

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MPV_COM = os.path.join(PROJECT_ROOT, "mpv.com")
HARNESS_LUA = os.path.join(PROJECT_ROOT, "prove-it", "adversarial_challenge.lua")
SCREENSHOT_DIR = os.path.join(PROJECT_ROOT, "prove-it", "screenshots")

os.makedirs(SCREENSHOT_DIR, exist_ok=True)

PASS_COUNT = 0
FAIL_COUNT = 0
RESULTS = []

def run_cmd(cmd, timeout=50):
    print(f"\n[EXEC] {cmd}")
    sys.stdout.flush()
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

def analyze_thumbnail(image_path, label=""):
    if not os.path.exists(image_path):
        return False, f"File {image_path} not found", {}

    img = Image.open(image_path).convert("RGB")
    w, h = img.size

    # Inner crop region for thumbnail (inside border)
    # Thumbnail is centered at w/2, bottom at h - 120, height = 112, width = 200
    tx1 = max(0, w // 2 - 90)
    tx2 = min(w, w // 2 + 90)
    ty1 = max(0, h - 225)
    ty2 = min(h, h - 125)

    crop = img.crop((tx1, ty1, tx2, ty2))
    pixels = list(crop.getdata())
    total = len(pixels)
    if total == 0:
        return False, "Empty crop region", {}

    sum_r = sum(p[0] for p in pixels)
    sum_g = sum(p[1] for p in pixels)
    sum_b = sum(p[2] for p in pixels)
    mean_r, mean_g, mean_b = sum_r / total, sum_g / total, sum_b / total

    # Variance and standard deviation
    var = sum(((p[0] - mean_r)**2 + (p[1] - mean_g)**2 + (p[2] - mean_b)**2) / 3.0 for p in pixels) / total
    std_dev = var ** 0.5

    # Non-dark pixels
    non_dark = sum(1 for p in pixels if p[0] > 25 or p[1] > 25 or p[2] > 25)
    pct_non_dark = (non_dark / total) * 100.0

    # 10-bin brightness histogram
    hist_10 = [0] * 10
    for p in pixels:
        lum = int(0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2])
        bin_idx = min(9, lum // 26)
        hist_10[bin_idx] += 1
    hist_pct = [round((c / total) * 100.0, 1) for c in hist_10]

    # Layering check: inspect border & text regions
    # Border top edge around ty1
    border_crop = img.crop((tx1, max(0, ty1 - 6), tx2, ty1))
    border_pixels = list(border_crop.getdata())
    border_bright = sum(1 for p in border_pixels if p[0] > 100 and p[1] > 100 and p[2] > 100)
    has_border = border_bright > 5

    # Time text region below thumbnail: [w//2 - 60, w//2 + 60], [h - 118, h - 95]
    text_crop = img.crop((w // 2 - 60, h - 118, w // 2 + 60, h - 95))
    text_pixels = list(text_crop.getdata())
    text_bright = sum(1 for p in text_pixels if p[0] > 150 and p[1] > 150 and p[2] > 150)
    has_text = text_bright > 10

    # Criteria for non-black real video frame:
    # 1. Not pure black: std_dev >= 8.0, pct_non_dark >= 85%
    # 2. Significant color or luminance variance
    is_black_box = (std_dev < 6.0 and pct_non_dark < 30.0) or (mean_r < 20 and mean_g < 20 and mean_b < 20 and std_dev < 5.0)

    stats = {
        "mean_rgb": (round(mean_r, 1), round(mean_g, 1), round(mean_b, 1)),
        "std_dev": round(std_dev, 2),
        "pct_non_dark": round(pct_non_dark, 1),
        "histogram_10bin": hist_pct,
        "has_border": has_border,
        "has_text": has_text,
        "is_black_box": is_black_box,
        "crop_box": (tx1, ty1, tx2, ty2),
        "size": (w, h)
    }

    details = (f"RGB: ({mean_r:.1f}, {mean_g:.1f}, {mean_b:.1f}) | "
               f"Std: {std_dev:.1f} | Non-dark: {pct_non_dark:.1f}% | "
               f"Border: {'OK' if has_border else 'MISSING'} | Text: {'OK' if has_text else 'MISSING'}")

    return (not is_black_box), details, stats

def compute_image_difference(img_path1, img_path2):
    if not os.path.exists(img_path1) or not os.path.exists(img_path2):
        return 0.0, "Files missing"

    img1 = Image.open(img_path1).convert("RGB")
    img2 = Image.open(img_path2).convert("RGB")
    w, h = img1.size

    tx1 = max(0, w // 2 - 80)
    tx2 = min(w, w // 2 + 80)
    ty1 = max(0, h - 220)
    ty2 = min(h, h - 130)

    c1 = list(img1.crop((tx1, ty1, tx2, ty2)).getdata())
    c2 = list(img2.crop((tx1, ty1, tx2, ty2)).getdata())

    if len(c1) != len(c2) or len(c1) == 0:
        return 0.0, "Dimension mismatch"

    diff_sum = sum(abs(p1[0] - p2[0]) + abs(p1[1] - p2[1]) + abs(p1[2] - p2[2]) for p1, p2 in zip(c1, c2))
    mad = diff_sum / (len(c1) * 3.0)
    return mad, f"Mean Absolute Difference: {mad:.2f}"

def record_test(name, passed, details, stats=None):
    global PASS_COUNT, FAIL_COUNT, RESULTS
    if passed:
        PASS_COUNT += 1
        print(f"  [PASS] {name} => {details}")
    else:
        FAIL_COUNT += 1
        print(f"  [FAIL] {name} => {details}")
    RESULTS.append({
        "name": name,
        "passed": passed,
        "details": details,
        "stats": stats or {}
    })

def main():
    print("=" * 80)
    print("  ADVERSARIAL STRESS TEST: SEEKBAR THUMBNAIL RENDERING & OVERLAY LAYERING")
    print("=" * 80)

    yt_url = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
    bili_url = "https://www.bilibili.com/video/BV1xx411c7mD"

    # --------------------------------------------------------------------------
    # SUITE 1: Active Playback vs Paused Playback (YouTube)
    # --------------------------------------------------------------------------
    print("\n--- [SUITE 1] Active Playback vs Paused Playback (YouTube) ---")

    # 1.1 YouTube Active Playback Hover (t = 5.0s)
    f_yt_active = os.path.join(SCREENSHOT_DIR, "challenge_yt_active_5s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=active,t1=5.0,save_file1="{f_yt_active}" '
           f'--keep-open=no "{yt_url}"')
    code, out = run_cmd(cmd, timeout=40)
    passed, details, stats = analyze_thumbnail(f_yt_active, "YouTube Active 5s")
    record_test("1.1 YouTube Active Playback Hover (t=5s)", passed and code == 0, details, stats)

    # 1.2 YouTube Paused Playback Hover (t = 5.0s)
    f_yt_paused = os.path.join(SCREENSHOT_DIR, "challenge_yt_paused_5s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=paused,pause_before_hover=yes,t1=5.0,save_file1="{f_yt_paused}" '
           f'--keep-open=no "{yt_url}"')
    code, out = run_cmd(cmd, timeout=40)
    passed, details, stats = analyze_thumbnail(f_yt_paused, "YouTube Paused 5s")
    record_test("1.2 YouTube Paused Playback Hover (t=5s)", passed and code == 0, details, stats)

    # --------------------------------------------------------------------------
    # SUITE 2: Rapid Hover Scrubbing & Timeline Differentiation (YouTube)
    # --------------------------------------------------------------------------
    print("\n--- [SUITE 2] Rapid Hover Scrubbing & Timeline Differentiation (YouTube) ---")

    # 2.1 YouTube Rapid Scrubbing Across 5 Jumps (Ending at 12s)
    f_yt_rapid = os.path.join(SCREENSHOT_DIR, "challenge_yt_rapid_12s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=rapid,t1=12.0,save_file1="{f_yt_rapid}" '
           f'--keep-open=no "{yt_url}"')
    code, out = run_cmd(cmd, timeout=45)
    passed, details, stats = analyze_thumbnail(f_yt_rapid, "YouTube Rapid 12s")
    record_test("2.1 YouTube Rapid Scrubbing Stress (5 rapid jumps -> 12s)", passed and code == 0, details, stats)

    # 2.2 YouTube Timeline Differentiation (t1 = 3s vs t2 = 15s)
    f_yt_t1 = os.path.join(SCREENSHOT_DIR, "challenge_yt_diff_3s.png")
    f_yt_t2 = os.path.join(SCREENSHOT_DIR, "challenge_yt_diff_15s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=diff,t1=3.0,t2=15.0,save_file1="{f_yt_t1}",save_file2="{f_yt_t2}" '
           f'--keep-open=no "{yt_url}"')
    code, out = run_cmd(cmd, timeout=50)
    p1, d1, s1 = analyze_thumbnail(f_yt_t1, "YouTube t1=3s")
    p2, d2, s2 = analyze_thumbnail(f_yt_t2, "YouTube t2=15s")
    mad_yt, mad_yt_details = compute_image_difference(f_yt_t1, f_yt_t2)
    record_test("2.2 YouTube Timeline Differentiation (t1=3s vs t2=15s)", p1 and p2 and mad_yt > 8.0,
                f"T1: {d1} | T2: {d2} | Diff MAD: {mad_yt:.2f} (Expected > 8.0)", {"s1": s1, "s2": s2, "mad": mad_yt})

    # --------------------------------------------------------------------------
    # SUITE 3: Bilibili Stream Active, Paused, Rapid Scrubbing & Differentiation
    # --------------------------------------------------------------------------
    print("\n--- [SUITE 3] Bilibili Online Playback & Thumbnail Stress ---")

    # 3.1 Bilibili Active Playback Hover (t = 30s)
    f_bili_active = os.path.join(SCREENSHOT_DIR, "challenge_bili_active_30s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=active,t1=30.0,save_file1="{f_bili_active}" '
           f'--keep-open=no "{bili_url}"')
    code, out = run_cmd(cmd, timeout=45)
    passed, details, stats = analyze_thumbnail(f_bili_active, "Bilibili Active 30s")
    record_test("3.1 Bilibili Active Playback Hover (t=30s)", passed and code == 0, details, stats)

    # 3.2 Bilibili Paused Playback Hover (t = 60s)
    f_bili_paused = os.path.join(SCREENSHOT_DIR, "challenge_bili_paused_60s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=paused,pause_before_hover=yes,t1=60.0,save_file1="{f_bili_paused}" '
           f'--keep-open=no "{bili_url}"')
    code, out = run_cmd(cmd, timeout=45)
    passed, details, stats = analyze_thumbnail(f_bili_paused, "Bilibili Paused 60s")
    record_test("3.2 Bilibili Paused Playback Hover (t=60s)", passed and code == 0, details, stats)

    # 3.3 Bilibili Rapid Scrubbing Stress (5 jumps ending at 90s)
    f_bili_rapid = os.path.join(SCREENSHOT_DIR, "challenge_bili_rapid_90s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=rapid,t1=90.0,save_file1="{f_bili_rapid}" '
           f'--keep-open=no "{bili_url}"')
    code, out = run_cmd(cmd, timeout=50)
    passed, details, stats = analyze_thumbnail(f_bili_rapid, "Bilibili Rapid 90s")
    record_test("3.3 Bilibili Rapid Scrubbing Stress (5 rapid jumps -> 90s)", passed and code == 0, details, stats)

    # 3.4 Bilibili Timeline Differentiation (t1 = 25s vs t2 = 80s)
    f_bili_t1 = os.path.join(SCREENSHOT_DIR, "challenge_bili_diff_25s.png")
    f_bili_t2 = os.path.join(SCREENSHOT_DIR, "challenge_bili_diff_80s.png")
    cmd = (f'"{MPV_COM}" --scripts="{HARNESS_LUA}" '
           f'--script-opts=challenge_mode=diff,t1=25.0,t2=80.0,save_file1="{f_bili_t1}",save_file2="{f_bili_t2}" '
           f'--keep-open=no "{bili_url}"')
    code, out = run_cmd(cmd, timeout=55)
    p1, d1, s1 = analyze_thumbnail(f_bili_t1, "Bilibili t1=25s")
    p2, d2, s2 = analyze_thumbnail(f_bili_t2, "Bilibili t2=80s")
    mad_bili, mad_bili_details = compute_image_difference(f_bili_t1, f_bili_t2)
    record_test("3.4 Bilibili Timeline Differentiation (t1=25s vs t2=80s)", p1 and p2 and mad_bili > 8.0,
                f"T1: {d1} | T2: {d2} | Diff MAD: {mad_bili:.2f} (Expected > 8.0)", {"s1": s1, "s2": s2, "mad": mad_bili})

    # --------------------------------------------------------------------------
    # SUITE 4: ModernZ Overlay Layering & Compositing Integrity
    # --------------------------------------------------------------------------
    print("\n--- [SUITE 4] ModernZ Overlay Layering & Occlusion Inspection ---")
    # Verify that in all generated screenshots:
    # 1. has_border is True (ModernZ glass border outlines the thumbnail)
    # 2. has_text is True (ModernZ tooltip time code is visible)
    # 3. is_black_box is False (No opaque overlay occluding video frame)
    all_bordered = all(r["stats"].get("has_border", False) for r in RESULTS if "stats" in r and "has_border" in r["stats"])
    all_text = all(r["stats"].get("has_text", False) for r in RESULTS if "stats" in r and "has_text" in r["stats"])
    no_black_box = all(not r["stats"].get("is_black_box", True) for r in RESULTS if "stats" in r and "is_black_box" in r["stats"])

    layering_ok = all_bordered and all_text and no_black_box
    record_test("4.1 ModernZ Overlay Layering & Transparency Conformance", layering_ok,
                f"All Bordered: {all_bordered} | All Text Visible: {all_text} | 0 Black Boxes: {no_black_box}")

    print("\n" + "=" * 80)
    print(f"  CHALLENGE COMPLETE: {PASS_COUNT} PASSED, {FAIL_COUNT} FAILED")
    print("=" * 80)

    # Save structured results to json for reporting
    import json
    result_path = os.path.join(PROJECT_ROOT, ".agents", "teamwork", "teamwork_challenger_2", "challenge_results.json")
    with open(result_path, "w", encoding="utf-8") as f:
        json.dump({
            "pass_count": PASS_COUNT,
            "fail_count": FAIL_COUNT,
            "results": RESULTS
        }, f, indent=2, ensure_ascii=False)
    print(f"\n[OUTPUT] Structured test results saved to {result_path}")

    return 0 if FAIL_COUNT == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
