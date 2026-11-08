#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
online_thumb_engine.py
High-speed seekbar sprite-sheet thumbnail extractor for Bilibili (videoshot) & YouTube (storyboard).
Downloads and pre-slices the entire video's preview thumbnails into a raw BGRA pack (.pack + .idx)
so MPV seekbar scrubbing on Bilibili & YouTube has 0ms local-memory latency.
"""

import sys
import os
import re
import json
import math
import time
import subprocess
import urllib.request
import urllib.parse
import http.cookiejar
from io import BytesIO
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    from PIL import Image
except ImportError:
    Image = None

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)


def build_opener(cookie_file=None, referer=None):
    cj = http.cookiejar.MozillaCookieJar()
    if cookie_file and os.path.isfile(cookie_file):
        try:
            cj.load(cookie_file, ignore_discard=True, ignore_expires=True)
        except Exception:
            pass
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    headers = [("User-Agent", USER_AGENT)]
    if referer:
        headers.append(("Referer", referer))
    opener.addheaders = headers
    return opener


def fetch_bytes(opener, url, timeout=8, retries=2):
    if url.startswith("//"):
        url = "https:" + url
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url)
            with opener.open(req, timeout=timeout) as resp:
                return resp.read()
        except Exception:
            if attempt < retries:
                time.sleep(0.2 * (attempt + 1))
            else:
                raise


def fetch_json(opener, url, timeout=8):
    raw = fetch_bytes(opener, url, timeout=timeout)
    return json.loads(raw.decode("utf-8", errors="replace"))


def load_cached_ytdl_json(ytdl_json_file):
    if not ytdl_json_file or not os.path.isfile(ytdl_json_file):
        return None
    try:
        with open(ytdl_json_file, "r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
        try:
            os.remove(ytdl_json_file)
        except Exception:
            pass
        return data
    except Exception:
        return None


def image_cell_to_bgra(sheet_img, box, target_w, target_h):
    cell = sheet_img.crop(box)
    if cell.mode != "RGB":
        cell = cell.convert("RGB")
    cw, ch = cell.size
    if cw <= 0 or ch <= 0:
        return b"\x00" * (target_w * target_h * 4)

    if (cw, ch) != (target_w, target_h):
        scale = min(target_w / cw, target_h / ch)
        nw = max(1, int(round(cw * scale)))
        nh = max(1, int(round(ch * scale)))
        resample = getattr(Image, "Resampling", Image).BILINEAR
        resized = cell.resize((nw, nh), resample)
        if (nw, nh) != (target_w, target_h):
            canvas = Image.new("RGB", (target_w, target_h), (0, 0, 0))
            canvas.paste(resized, ((target_w - nw) // 2, (target_h - nh) // 2))
            cell = canvas
        else:
            cell = resized

    r, g, b = cell.split()
    a = Image.new("L", (target_w, target_h), 255)
    bgra = Image.merge("RGBA", (b, g, r, a))
    return bgra.tobytes()


def write_pack(out_prefix, times, frames):
    if not times or not frames or len(times) != len(frames):
        return False
    tmp_pack = out_prefix + ".pack.tmp"
    tmp_idx = out_prefix + ".idx.tmp"
    final_pack = out_prefix + ".pack"
    final_idx = out_prefix + ".idx"

    with open(tmp_pack, "wb") as fp:
        for fr in frames:
            fp.write(fr)

    with open(tmp_idx, "w", encoding="utf-8") as fi:
        for t in times:
            fi.write(f"{t:.3f}\n")

    try:
        if os.path.exists(final_pack):
            os.remove(final_pack)
        if os.path.exists(final_idx):
            os.remove(final_idx)
    except Exception:
        pass

    os.replace(tmp_pack, final_pack)
    os.replace(tmp_idx, final_idx)
    return True


# ==============================================================================
# 1. Bilibili Videoshot Extractor
# ==============================================================================
def extract_bilibili(url, target_w, target_h, out_prefix, cookie_file=None, cached_info=None):
    opener = build_opener(cookie_file, referer="https://www.bilibili.com/")

    if cached_info and isinstance(cached_info, dict):
        if cached_info.get("webpage_url") and "bilibili.com" in str(cached_info.get("webpage_url")):
            url = str(cached_info["webpage_url"])

    if "b23.tv/" in url:
        try:
            req = urllib.request.Request(url, method="HEAD")
            with opener.open(req, timeout=6) as resp:
                url = resp.geturl()
        except Exception:
            pass

    bvid_m = re.search(r"(BV[0-9A-Za-z]{10})", url)
    aid_m = re.search(r"av(\d+)", url, re.I)
    ep_m = re.search(r"ep(\d+)", url, re.I)
    page_m = re.search(r"[?&]p=(\d+)", url)
    page_num = int(page_m.group(1)) if page_m else 1

    bvid = bvid_m.group(1) if bvid_m else None
    aid = aid_m.group(1) if aid_m else None
    cid = None

    if cached_info and isinstance(cached_info, dict):
        cid_cand = cached_info.get("cid")
        if cid_cand:
            cid = cid_cand
        if not bvid:
            id_str = str(cached_info.get("id") or "")
            m_bv = re.match(r"^(BV[0-9A-Za-z]{10})", id_str)
            if m_bv:
                bvid = m_bv.group(1)

    if not cid or (not bvid and not aid):
        try:
            if bvid or aid:
                q = f"bvid={bvid}" if bvid else f"aid={aid}"
                view_data = fetch_json(opener, f"https://api.bilibili.com/x/web-interface/view?{q}")
                if view_data.get("code") == 0 and view_data.get("data"):
                    vdata = view_data["data"]
                    bvid = vdata.get("bvid") or bvid
                    aid = vdata.get("aid") or aid
                    cid = vdata.get("cid") or cid
                    pages = vdata.get("pages") or []
                    if page_num > 1 and page_num <= len(pages):
                        cid = pages[page_num - 1].get("cid") or cid
            elif ep_m:
                ep_id = ep_m.group(1)
                ep_data = fetch_json(opener, f"https://api.bilibili.com/pgc/view/web/season?ep_id={ep_id}")
                if ep_data.get("code") == 0 and ep_data.get("result"):
                    for ep in ep_data["result"].get("episodes", []):
                        if str(ep.get("id")) == str(ep_id):
                            bvid = ep.get("bvid")
                            aid = ep.get("aid")
                            cid = ep.get("cid")
                            break
        except Exception:
            pass

    params = ["index=1"]
    if bvid:
        params.append(f"bvid={bvid}")
    if aid:
        params.append(f"aid={aid}")
    if cid:
        params.append(f"cid={cid}")

    if len(params) == 1:
        return False

    vs_url = "https://api.bilibili.com/x/player/videoshot?" + "&".join(params)
    vs_json = fetch_json(opener, vs_url)
    if vs_json.get("code") != 0 or not vs_json.get("data"):
        return False

    data = vs_json["data"]
    img_urls = data.get("image") or []
    indices = data.get("index") or []
    if not img_urls:
        return False

    cols = int(data.get("img_x_len") or 10)
    rows = int(data.get("img_y_len") or 10)
    cell_w = int(data.get("img_x_size") or 160)
    cell_h = int(data.get("img_y_size") or 90)
    per_sheet = cols * rows

    sheets = {}
    with ThreadPoolExecutor(max_workers=min(8, len(img_urls))) as ex:
        futs = {ex.submit(fetch_bytes, opener, u, 8, 2): idx for idx, u in enumerate(img_urls)}
        for f in as_completed(futs):
            s_idx = futs[f]
            try:
                raw_bytes = f.result()
                sheets[s_idx] = Image.open(BytesIO(raw_bytes)).convert("RGB")
            except Exception:
                pass

    if not sheets:
        return False

    total_possible = len(img_urls) * per_sheet
    count = len(indices) if indices else total_possible
    count = min(count, total_possible)

    times = []
    frames = []
    last_valid_frame = None

    for i in range(count):
        s_idx = i // per_sheet
        t_val = float(indices[i]) if i < len(indices) else float(i * 2)

        if s_idx not in sheets:
            if last_valid_frame is not None:
                times.append(t_val)
                frames.append(last_valid_frame)
            continue

        sheet_img = sheets[s_idx]
        in_sheet = i % per_sheet
        r_idx = in_sheet // cols
        c_idx = in_sheet % cols
        x0 = c_idx * cell_w
        y0 = r_idx * cell_h
        if x0 + cell_w > sheet_img.width or y0 + cell_h > sheet_img.height:
            if last_valid_frame is not None:
                times.append(t_val)
                frames.append(last_valid_frame)
            continue

        bgra = image_cell_to_bgra(sheet_img, (x0, y0, x0 + cell_w, y0 + cell_h), target_w, target_h)
        last_valid_frame = bgra
        times.append(t_val)
        frames.append(bgra)

    return write_pack(out_prefix, times, frames)


# ==============================================================================
# 2. YouTube Storyboard Extractor (Optimized Level Selection + Safe Bounds)
# ==============================================================================
def choose_optimal_youtube_level(levels, target_w=200):
    candidates = []
    for idx, lvl in enumerate(levels):
        parts = lvl.split("#")
        if len(parts) < 8:
            continue
        cell_w = int(parts[0])
        cell_h = int(parts[1])
        total_count = int(parts[2])
        cols = int(parts[3])
        rows = int(parts[4])
        interval_ms = int(parts[5])
        per_sheet = cols * rows
        if per_sheet <= 0 or total_count <= 0:
            continue
        num_sheets = int(math.ceil(total_count / float(per_sheet)))
        candidates.append({
            "level_idx": idx,
            "cell_w": cell_w,
            "cell_h": cell_h,
            "total_count": total_count,
            "cols": cols,
            "rows": rows,
            "interval_ms": interval_ms,
            "name_pat": parts[6],
            "sigh": parts[7],
            "num_sheets": num_sheets,
        })
    if not candidates:
        return None

    # Priority ranking to prevent CDN rate limits / timeouts on long videos:
    # 1. Best balance: 120 <= cell_w <= 240 and safe sheet count <= 35
    preferred = [c for c in candidates if 120 <= c["cell_w"] <= 240 and c["num_sheets"] <= 35]
    if preferred:
        return preferred[-1]

    # 2. Compact level: 70 <= cell_w < 120 with safe sheet count <= 35
    compact = [c for c in candidates if 70 <= c["cell_w"] < 120 and c["num_sheets"] <= 35]
    if compact:
        return compact[-1]

    # 3. Fallback: minimize excessive sheet count
    candidates.sort(key=lambda c: (abs(c["num_sheets"] - 20), -c["cell_w"]))
    return candidates[0]


def parse_youtube_storyboard_spec(spec_str, duration=0, target_w=200):
    if not spec_str or "|" not in spec_str:
        return None
    parts = spec_str.split("|")
    base_url = parts[0]
    levels = parts[1:]
    if not levels:
        return None

    best = choose_optimal_youtube_level(levels, target_w)
    if not best:
        return None

    level_idx = best["level_idx"]
    cell_w = best["cell_w"]
    cell_h = best["cell_h"]
    total_count = best["total_count"]
    cols = best["cols"]
    rows = best["rows"]
    interval_ms = best["interval_ms"]
    name_pat = best["name_pat"]
    sigh = best["sigh"]
    num_sheets = best["num_sheets"]

    interval_sec = (interval_ms / 1000.0) if interval_ms > 0 else (
        (duration / float(total_count)) if duration > 0 else 2.0
    )

    if duration > 0 and interval_sec > 0:
        total_count = min(total_count, int(math.ceil(duration / interval_sec)))

    urls = []
    for m in range(num_sheets):
        u = base_url.replace("$L", str(level_idx))
        n_str = name_pat.replace("$M", str(m))
        u = u.replace("$N", n_str)
        sep = "&" if "?" in u else "?"
        u = f"{u}{sep}sigh={urllib.parse.quote(sigh)}"
        urls.append(u)

    return {
        "cell_w": cell_w,
        "cell_h": cell_h,
        "total_count": total_count,
        "cols": cols,
        "rows": rows,
        "interval_sec": interval_sec,
        "urls": urls,
    }


def parse_ytdl_storyboard_info(info, target_w=200):
    if not info or not isinstance(info, dict):
        return None
    formats = info.get("formats") or []
    fmts = [
        f for f in formats
        if f.get("fragments") and (
            (f.get("vcodec") == "none" and f.get("acodec") == "none" and f.get("columns") and f.get("rows"))
            or str(f.get("format_id", "")).startswith("sb")
            or f.get("format_note") == "storyboard"
        )
    ]
    if not fmts:
        return None

    candidates = []
    for f in fmts:
        w = int(f.get("width") or 0)
        h = int(f.get("height") or 0)
        cols = int(f.get("columns") or 5)
        rows = int(f.get("rows") or 5)
        frags = f.get("fragments") or []
        urls = [fr["url"] for fr in frags if fr.get("url")]
        if not urls:
            continue
        candidates.append({
            "fmt": f,
            "w": w,
            "h": h,
            "cols": cols,
            "rows": rows,
            "frags": frags,
            "urls": urls,
            "num_sheets": len(urls),
        })
    if not candidates:
        return None

    preferred = [c for c in candidates if 120 <= c["w"] <= 240 and c["num_sheets"] <= 35]
    if preferred:
        best_cand = preferred[-1]
    else:
        compact = [c for c in candidates if 70 <= c["w"] < 120 and c["num_sheets"] <= 35]
        if compact:
            best_cand = compact[-1]
        else:
            candidates.sort(key=lambda c: (abs(c["num_sheets"] - 20), -c["w"]))
            best_cand = candidates[0]

    best_sb = best_cand["fmt"]
    cols = best_cand["cols"]
    rows = best_cand["rows"]
    frags = best_cand["frags"]
    urls = best_cand["urls"]
    dur = float(info.get("duration") or 0)
    per_sheet = cols * rows

    if frags and frags[0].get("duration") and float(frags[0]["duration"]) > 0:
        interval_sec = float(frags[0]["duration"]) / float(per_sheet)
    elif dur > 0 and len(urls) > 0:
        interval_sec = dur / float(len(urls) * per_sheet)
    else:
        interval_sec = 2.0

    total_count = int(math.ceil(dur / interval_sec)) if (dur > 0 and interval_sec > 0) else (len(urls) * per_sheet)
    total_count = min(len(urls) * per_sheet, max(1, total_count))

    return {
        "cell_w": int(best_sb.get("width") or 0),
        "cell_h": int(best_sb.get("height") or 0),
        "total_count": total_count,
        "cols": cols,
        "rows": rows,
        "interval_sec": interval_sec,
        "urls": urls,
        "fragments": frags,
    }


def extract_youtube(url, target_w, target_h, out_prefix, cookie_file=None, ytdl_bin="yt-dlp", cached_info=None):
    opener = build_opener(cookie_file, referer="https://www.youtube.com/")
    sb_info = None

    # Fast Path 0: Use MPV's already-fetched ytdl_hook JSON (0ms overhead!)
    if cached_info:
        sb_info = parse_ytdl_storyboard_info(cached_info, target_w)

    # Fast Path 1: Fetch watch page directly and extract playerStoryboardSpecRenderer (~0.25s)
    if not sb_info:
        try:
            html = fetch_bytes(opener, url, timeout=6, retries=1).decode("utf-8", errors="replace")
            m_spec = re.search(r'"playerStoryboardSpecRenderer"\s*:\s*\{\s*"spec"\s*:\s*"([^"]+)"', html)
            m_dur = re.search(r'"lengthSeconds"\s*:\s*"(\d+)"', html)
            dur = float(m_dur.group(1)) if m_dur else 0.0
            if m_spec:
                raw_spec = m_spec.group(1).encode("utf-8").decode("unicode_escape")
                sb_info = parse_youtube_storyboard_spec(raw_spec, dur, target_w)
        except Exception:
            pass

    # Fast Path 2: Fallback to yt-dlp JSON storyboard formats if needed
    if not sb_info:
        try:
            cmd = [ytdl_bin, "--dump-single-json", "--no-warnings", "--no-playlist", "--skip-download"]
            if cookie_file and os.path.isfile(cookie_file):
                cmd.extend(["--cookies", cookie_file])
            cmd.append(url)
            creationflags = 0x08000000 if sys.platform.startswith("win") else 0
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15, creationflags=creationflags)
            if proc.returncode == 0 and proc.stdout:
                info = json.loads(proc.stdout.decode("utf-8", errors="replace"))
                sb_info = parse_ytdl_storyboard_info(info, target_w)
        except Exception:
            pass

    if not sb_info or not sb_info.get("urls"):
        return False

    urls = sb_info["urls"]
    cols = sb_info["cols"]
    rows = sb_info["rows"]
    per_sheet = cols * rows
    total_count = sb_info["total_count"]
    interval_sec = sb_info["interval_sec"]
    frags = sb_info.get("fragments")

    sheets = {}
    with ThreadPoolExecutor(max_workers=min(8, len(urls))) as ex:
        futs = {ex.submit(fetch_bytes, opener, u, 8, 2): idx for idx, u in enumerate(urls)}
        for f in as_completed(futs):
            s_idx = futs[f]
            try:
                raw_bytes = f.result()
                sheets[s_idx] = Image.open(BytesIO(raw_bytes)).convert("RGB")
            except Exception:
                pass

    if not sheets:
        return False

    first_sheet = sheets.get(0) or next(iter(sheets.values()))
    base_cell_w = first_sheet.width // cols if cols > 0 else 0
    base_cell_h = first_sheet.height // rows if rows > 0 else 0
    if base_cell_w <= 0 or base_cell_h <= 0:
        base_cell_w = sb_info.get("cell_w") or 160
        base_cell_h = sb_info.get("cell_h") or 90

    times = []
    frames = []
    cur_time = 0.0
    frame_idx = 0
    last_valid_frame = None

    for s_idx in range(len(urls)):
        frag_dur = float(frags[s_idx]["duration"]) if (frags and s_idx < len(frags) and frags[s_idx].get("duration")) else None
        cell_dt = (frag_dur / float(per_sheet)) if frag_dur else interval_sec

        if s_idx not in sheets:
            # Sheet failed or timed out: fill with previous frame instead of black hole
            for _ in range(per_sheet):
                if frame_idx >= total_count:
                    break
                if last_valid_frame is not None:
                    times.append(cur_time)
                    frames.append(last_valid_frame)
                cur_time += cell_dt
                frame_idx += 1
            continue

        sheet_img = sheets[s_idx]
        cell_w = base_cell_w
        cell_h = base_cell_h
        if cell_w <= 0 or cell_h <= 0:
            continue

        for r_idx in range(rows):
            for c_idx in range(cols):
                if frame_idx >= total_count:
                    break
                x0 = c_idx * cell_w
                y0 = r_idx * cell_h
                if x0 + cell_w <= sheet_img.width and y0 + cell_h <= sheet_img.height:
                    bgra = image_cell_to_bgra(sheet_img, (x0, y0, x0 + cell_w, y0 + cell_h), target_w, target_h)
                    last_valid_frame = bgra
                    times.append(cur_time)
                    frames.append(bgra)
                elif last_valid_frame is not None:
                    times.append(cur_time)
                    frames.append(last_valid_frame)
                cur_time += cell_dt
                frame_idx += 1

    return write_pack(out_prefix, times, frames)


def main():
    if Image is None or len(sys.argv) < 5:
        sys.exit(1)

    url = sys.argv[1]
    target_w = int(sys.argv[2])
    target_h = int(sys.argv[3])
    out_prefix = sys.argv[4]
    cookie_file = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
    ytdl_bin = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else "yt-dlp"
    ytdl_json_file = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None

    cached_info = load_cached_ytdl_json(ytdl_json_file)

    lower_url = url.lower()
    ok = False
    if "bilibili.com" in lower_url or "b23.tv" in lower_url:
        ok = extract_bilibili(url, target_w, target_h, out_prefix, cookie_file, cached_info)
    elif "youtube.com" in lower_url or "youtu.be" in lower_url:
        ok = extract_youtube(url, target_w, target_h, out_prefix, cookie_file, ytdl_bin, cached_info)

    sys.exit(0 if ok else 2)


if __name__ == "__main__":
    main()
