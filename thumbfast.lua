-- thumbfast.lua
--
-- High-performance on-the-fly thumbnailer
--
-- Built for easy integration in third-party UIs.

--[[
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
]]

local options = {
    -- Socket path (leave empty for auto)
    socket = "",

    -- Thumbnail path (leave empty for auto)
    thumbnail = "",

    -- Maximum thumbnail generation size in pixels (scaled down to fit)
    -- Values are scaled when hidpi is enabled
    max_height = 200,
    max_width = 200,

    -- Scale factor for thumbnail display size (requires mpv 0.38+)
    -- Note that this is lower quality than increasing max_height and max_width
    scale_factor = 1,

    -- Apply tone-mapping, no to disable
    tone_mapping = "auto",

    -- Overlay id
    overlay_id = 42,

    -- Spawn thumbnailer on file load for faster initial thumbnails
    spawn_first = true,

    -- Close thumbnailer process after an inactivity period in seconds, 0 to disable
    quit_after_inactivity = 0,

    -- Enable on network playback
    network = false,

    -- Enable on audio playback
    audio = false,

    -- Enable hardware decoding
    hwdec = false,

    -- Windows only: use native Windows API to write to pipe (requires LuaJIT)
    direct_io = false,

    -- Custom path to the mpv executable
    mpv_path = "mpv",

    -- Exact seek mode:
    -- "auto": keyframe seek while moving, exact seek after stopping (default upstream behavior)
    -- "no": keyframe seek only, completely eliminates the secondary jump/twitch after stopping
    -- "yes": always exact seek (higher CPU/GPU overhead)
    exact_seek = "auto",

    -- Delay in seconds before triggering exact seek when exact_seek="auto" (default: 0.1)
    exact_seek_delay = 0.1
}

mp.utils = require "mp.utils"
mp.options = require "mp.options"
mp.options.read_options(options, "thumbfast")

local function get_exact_seek_mode()
    local mode = tostring(options.exact_seek):lower()
    if mode == "no" or mode == "false" or mode == "never" then
        return "no"
    elseif mode == "yes" or mode == "true" or mode == "always" then
        return "yes"
    else
        return "auto"
    end
end

local properties = {}
local pre_0_30_0 = mp.command_native_async == nil
local pre_0_33_0 = true
local support_media_control = mp.get_property_native("media-controls") ~= nil

function subprocess(args, async, callback)
    callback = callback or function() end

    if not pre_0_30_0 then
        -- FIXME: figure out which exact env var needs to be stripped. (PR: #144, Issue: #106 and #139)
        local env = os_name == "darwin" and "PATH="..os.getenv("PATH") or nil
        if async then
            return mp.command_native_async({name = "subprocess", playback_only = false, args = args, env = env}, callback)
        else
            return mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true, args = args, env = env})
        end
    else
        if async then
            return mp.utils.subprocess_detached({args = args}, callback)
        else
            return mp.utils.subprocess({args = args})
        end
    end
end

local winapi = {}
if options.direct_io then
    local ffi_loaded, ffi = pcall(require, "ffi")
    if ffi_loaded then
        winapi = {
            ffi = ffi,
            C = ffi.C,
            bit = require("bit"),
            socket_wc = "",

            -- WinAPI constants
            CP_UTF8 = 65001,
            GENERIC_WRITE = 0x40000000,
            OPEN_EXISTING = 3,
            FILE_FLAG_WRITE_THROUGH = 0x80000000,
            FILE_FLAG_NO_BUFFERING = 0x20000000,
            PIPE_NOWAIT = ffi.new("unsigned long[1]", 0x00000001),

            INVALID_HANDLE_VALUE = ffi.cast("void*", -1),

            -- don't care about how many bytes WriteFile wrote, so allocate something to store the result once
            _lpNumberOfBytesWritten = ffi.new("unsigned long[1]"),
        }
        -- cache flags used in run() to avoid bor() call
        winapi._createfile_pipe_flags = winapi.bit.bor(winapi.FILE_FLAG_WRITE_THROUGH, winapi.FILE_FLAG_NO_BUFFERING)

        ffi.cdef[[
            void* __stdcall CreateFileW(const wchar_t *lpFileName, unsigned long dwDesiredAccess, unsigned long dwShareMode, void *lpSecurityAttributes, unsigned long dwCreationDisposition, unsigned long dwFlagsAndAttributes, void *hTemplateFile);
            bool __stdcall WriteFile(void *hFile, const void *lpBuffer, unsigned long nNumberOfBytesToWrite, unsigned long *lpNumberOfBytesWritten, void *lpOverlapped);
            bool __stdcall CloseHandle(void *hObject);
            bool __stdcall SetNamedPipeHandleState(void *hNamedPipe, unsigned long *lpMode, unsigned long *lpMaxCollectionCount, unsigned long *lpCollectDataTimeout);
            int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
        ]]

        winapi.MultiByteToWideChar = function(MultiByteStr)
            if MultiByteStr then
                local utf16_len = winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, nil, 0)
                if utf16_len > 0 then
                    local utf16_str = winapi.ffi.new("wchar_t[?]", utf16_len)
                    if winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, utf16_str, utf16_len) > 0 then
                        return utf16_str
                    end
                end
            end
            return ""
        end

    else
        options.direct_io = false
    end
end

local file
local file_bytes = 0
local spawned = false
local disabled = false
local force_disabled = false
local spawn_waiting = false
local spawn_working = false
local script_written = false
local pending_loadfile = nil
local overlay_shown = false
local sprite_pack = nil
local sprite_fetching = false
local sprite_failed = false
local sprite_seq = 0
local cached_ytdl_stdout = nil
local cached_ytdl_webpage_url = nil

local dirty = false

local x, y
local last_x, last_y

local last_seek_time
local thumb_timestamp

local effective_w, effective_h = options.max_width, options.max_height
local real_w, real_h
local last_real_w, last_real_h

local script_name

local show_thumbnail = false

local filters_reset = {["lavfi-crop"]=true, ["crop"]=true}
local filters_runtime = {["hflip"]=true, ["vflip"]=true}
local filters_all = {["hflip"]=true, ["vflip"]=true, ["lavfi-crop"]=true, ["crop"]=true}

local tone_mappings = {["none"]=true, ["clip"]=true, ["linear"]=true, ["gamma"]=true, ["reinhard"]=true, ["hable"]=true, ["mobius"]=true}
local last_tone_mapping

local last_vf_reset = ""
local last_vf_runtime = ""

local last_rotate = 0

local par = ""
local last_par = ""

local last_crop = nil

local last_has_vid = 0
local has_vid = 0

local file_timer
local file_check_period = 1/60

local allow_fast_seek = get_exact_seek_mode() ~= "yes"

local client_script = [=[
#!/usr/bin/env bash
MPV_IPC_FD=0; MPV_IPC_PATH="%s"
trap "kill 0" EXIT
while [[ $# -ne 0 ]]; do case $1 in --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;; esac; shift; done
if echo "print-text thumbfast" >&"$MPV_IPC_FD"; then echo -n > "$MPV_IPC_PATH"; tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" & while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done; fi
]=]

local ONLINE_THUMB_PY = [===[
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


def fetch_bytes(opener, url, timeout=8):
    if url.startswith("//"):
        url = "https:" + url
    req = urllib.request.Request(url)
    with opener.open(req, timeout=timeout) as resp:
        return resp.read()


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
        futs = {ex.submit(fetch_bytes, opener, u, 8): idx for idx, u in enumerate(img_urls)}
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
    for i in range(count):
        s_idx = i // per_sheet
        if s_idx not in sheets:
            continue
        sheet_img = sheets[s_idx]
        in_sheet = i % per_sheet
        r_idx = in_sheet // cols
        c_idx = in_sheet % cols
        x0 = c_idx * cell_w
        y0 = r_idx * cell_h
        if x0 + cell_w > sheet_img.width or y0 + cell_h > sheet_img.height:
            continue
        t_val = float(indices[i]) if i < len(indices) else float(i * 2)
        bgra = image_cell_to_bgra(sheet_img, (x0, y0, x0 + cell_w, y0 + cell_h), target_w, target_h)
        times.append(t_val)
        frames.append(bgra)

    return write_pack(out_prefix, times, frames)


# ==============================================================================
# 2. YouTube Storyboard Extractor (MPV Cached JSON + Direct Spec + yt-dlp Fallback)
# ==============================================================================
def parse_ytdl_storyboard_info(info):
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
    fmts.sort(key=lambda f: (int(f.get("width") or 0) * int(f.get("height") or 0), len(f.get("fragments") or [])))
    best_sb = fmts[-1]
    cols = int(best_sb.get("columns") or 5)
    rows = int(best_sb.get("rows") or 5)
    frags = best_sb.get("fragments") or []
    urls = [fr["url"] for fr in frags if fr.get("url")]
    if not urls:
        return None
    dur = float(info.get("duration") or 0)
    total_count = len(urls) * cols * rows
    interval_sec = (dur / float(total_count)) if (dur > 0 and total_count > 0) else 2.0
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


def parse_youtube_storyboard_spec(spec_str, duration=0):
    if not spec_str or "|" not in spec_str:
        return None
    parts = spec_str.split("|")
    base_url = parts[0]
    levels = parts[1:]
    if not levels:
        return None

    level_idx = len(levels) - 1
    l_parts = levels[level_idx].split("#")
    if len(l_parts) < 8:
        return None

    cell_w = int(l_parts[0])
    cell_h = int(l_parts[1])
    total_count = int(l_parts[2])
    cols = int(l_parts[3])
    rows = int(l_parts[4])
    interval_ms = int(l_parts[5])
    name_pat = l_parts[6]
    sigh = l_parts[7]

    per_sheet = cols * rows
    if per_sheet <= 0 or total_count <= 0:
        return None

    num_sheets = int(math.ceil(total_count / float(per_sheet)))
    interval_sec = (interval_ms / 1000.0) if interval_ms > 0 else (
        (duration / float(total_count)) if duration > 0 else 2.0
    )

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


def extract_youtube(url, target_w, target_h, out_prefix, cookie_file=None, ytdl_bin="yt-dlp", cached_info=None):
    opener = build_opener(cookie_file, referer="https://www.youtube.com/")
    sb_info = None

    # Fast Path 0: Use MPV's already-fetched ytdl_hook JSON (0ms overhead!)
    if cached_info:
        sb_info = parse_ytdl_storyboard_info(cached_info)

    # Fast Path 1: Fetch watch page directly and extract playerStoryboardSpecRenderer (~0.25s)
    if not sb_info:
        try:
            html = fetch_bytes(opener, url, timeout=6).decode("utf-8", errors="replace")
            m_spec = re.search(r'"playerStoryboardSpecRenderer"\s*:\s*\{\s*"spec"\s*:\s*"([^"]+)"', html)
            m_dur = re.search(r'"lengthSeconds"\s*:\s*"(\d+)"', html)
            dur = float(m_dur.group(1)) if m_dur else 0.0
            if m_spec:
                raw_spec = m_spec.group(1).encode("utf-8").decode("unicode_escape")
                sb_info = parse_youtube_storyboard_spec(raw_spec, dur)
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
                sb_info = parse_ytdl_storyboard_info(info)
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
        futs = {ex.submit(fetch_bytes, opener, u, 8): idx for idx, u in enumerate(urls)}
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

    for s_idx in range(len(urls)):
        if s_idx not in sheets:
            if frags and s_idx < len(frags) and frags[s_idx].get("duration"):
                cur_time += float(frags[s_idx]["duration"])
            else:
                cur_time += per_sheet * interval_sec
            frame_idx += per_sheet
            continue

        sheet_img = sheets[s_idx]
        cell_w = base_cell_w
        cell_h = base_cell_h
        if cell_w <= 0 or cell_h <= 0:
            continue

        frag_dur = float(frags[s_idx]["duration"]) if (frags and s_idx < len(frags) and frags[s_idx].get("duration")) else None
        cell_dt = (frag_dur / float(per_sheet)) if frag_dur else interval_sec

        for r_idx in range(rows):
            for c_idx in range(cols):
                if frame_idx >= total_count:
                    break
                x0 = c_idx * cell_w
                y0 = r_idx * cell_h
                if x0 + cell_w <= sheet_img.width and y0 + cell_h <= sheet_img.height:
                    bgra = image_cell_to_bgra(sheet_img, (x0, y0, x0 + cell_w, y0 + cell_h), target_w, target_h)
                    times.append(cur_time)
                    frames.append(bgra)
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
]===]


local function get_os()
    local raw_os_name = ""

    if jit and jit.os and jit.arch then
        raw_os_name = jit.os
    else
        if package.config:sub(1,1) == "\\" then
            -- Windows
            local env_OS = os.getenv("OS")
            if env_OS then
                raw_os_name = env_OS
            end
        else
            raw_os_name = subprocess({"uname", "-s"}).stdout
        end
    end

    raw_os_name = (raw_os_name):lower()

    local os_patterns = {
        ["windows"] = "windows",
        ["linux"]   = "linux",

        ["osx"]     = "darwin",
        ["mac"]     = "darwin",
        ["darwin"]  = "darwin",

        ["^mingw"]  = "windows",
        ["^cygwin"] = "windows",

        ["bsd$"]    = "darwin",
        ["sunos"]   = "darwin"
    }

    -- Default to linux
    local str_os_name = "linux"

    for pattern, name in pairs(os_patterns) do
        if raw_os_name:match(pattern) then
            str_os_name = name
            break
        end
    end

    return str_os_name
end

local os_name = mp.get_property("platform") or get_os()

local path_separator = os_name == "windows" and "\\" or "/"

if options.socket == "" then
    if os_name == "windows" then
        options.socket = "thumbfast"
    else
        options.socket = "/tmp/thumbfast"
    end
end

if options.thumbnail == "" then
    if os_name == "windows" then
        options.thumbnail = os.getenv("TEMP").."\\thumbfast.out"
    else
        options.thumbnail = "/tmp/thumbfast.out"
    end
end

local unique = mp.utils.getpid()

local base_socket = options.socket .. unique
local base_thumbnail = options.thumbnail .. unique
local spawn_seq = 0

options.socket = base_socket
options.thumbnail = base_thumbnail

if options.direct_io then
    if os_name == "windows" then
        winapi.socket_wc = winapi.MultiByteToWideChar("\\\\.\\pipe\\" .. options.socket)
    end

    if winapi.socket_wc == "" then
        options.direct_io = false
    end
end

options.scale_factor = math.floor(options.scale_factor)

local mpv_path = options.mpv_path
local frontend_path

if mpv_path == "mpv" and os_name == "windows" then
    frontend_path = mp.get_property_native("user-data/frontend/process-path")
    mpv_path = frontend_path or mpv_path
end

if mpv_path == "mpv" and os_name == "darwin" and unique then
    -- TODO: look into ~~osxbundle/
    mpv_path = string.gsub(subprocess({"ps", "-o", "comm=", "-p", tostring(unique)}).stdout, "[\n\r]", "")
    if mpv_path ~= "mpv" then
        mpv_path = string.gsub(mpv_path, "/mpv%-bundle$", "/mpv")
        local mpv_bin = mp.utils.file_info("/usr/local/mpv")
        if mpv_bin and mpv_bin.is_file then
            mpv_path = "/usr/local/mpv"
        else
            local mpv_app = mp.utils.file_info("/Applications/mpv.app/Contents/MacOS/mpv")
            if mpv_app and mpv_app.is_file then
                mp.msg.warn("symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            else
                mp.msg.warn("drag to your Applications folder and symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`")
            end
        end
    end
end

local function vo_tone_mapping()
    local passes = mp.get_property_native("vo-passes")
    if passes and passes["fresh"] then
        for k, v in pairs(passes["fresh"]) do
            for k2, v2 in pairs(v) do
                if k2 == "desc" and v2 then
                    local tone_mapping = string.match(v2, "([0-9a-z.-]+) tone map")
                    if tone_mapping then
                        return tone_mapping
                    end
                end
            end
        end
    end
end

local function vf_string(filters, full)
    local vf = ""
    local vf_table = properties["vf"]

    if (properties["video-crop"] or "") ~= "" then
        vf = "lavfi-crop="..string.gsub(properties["video-crop"], "(%d*)x?(%d*)%+(%d+)%+(%d+)", "w=%1:h=%2:x=%3:y=%4")..","
        local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
        local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
        if width and height then
            vf = string.gsub(vf, "w=:h=:", "w="..width..":h="..height..":")
        end
    end

    if vf_table and #vf_table > 0 then
        for i = #vf_table, 1, -1 do
            if filters[vf_table[i].name] then
                local args = ""
                for key, value in pairs(vf_table[i].params) do
                    if args ~= "" then
                        args = args .. ":"
                    end
                    args = args .. key .. "=" .. value
                end
                vf = vf .. vf_table[i].name .. "=" .. args .. ","
            end
        end
    end

    if full and (options.tone_mapping ~= "no" and options.tone_mapping ~= false) then
        if properties["video-params"] and properties["video-params"]["primaries"] == "bt.2020" then
            local tone_mapping = options.tone_mapping
            if tone_mapping == "auto" then
                tone_mapping = last_tone_mapping or properties["tone-mapping"]
                if tone_mapping == "auto" and properties["current-vo"] == "gpu-next" then
                    tone_mapping = vo_tone_mapping()
                end
            end
            if not tone_mappings[tone_mapping] then
                tone_mapping = "hable"
            end
            last_tone_mapping = tone_mapping
            vf = vf .. "zscale=transfer=linear,format=gbrpf32le,tonemap="..tone_mapping..",zscale=transfer=bt709,"
        end
    end

    if full then
        vf = vf.."scale=w="..effective_w..":h="..effective_h..par..",pad=w="..effective_w..":h="..effective_h..":x=-1:y=-1,format=bgra"
    end

    return vf
end

local function calc_dimensions()
    local width = properties["video-out-params"] and properties["video-out-params"]["dw"]
    local height = properties["video-out-params"] and properties["video-out-params"]["dh"]
    if not width or not height then return end

    local scale = properties["display-hidpi-scale"] or 1

    if width / height > options.max_width / options.max_height then
        effective_w = math.floor(options.max_width * scale + 0.5)
        effective_h = math.floor(height / width * effective_w + 0.5)
    else
        effective_h = math.floor(options.max_height * scale + 0.5)
        effective_w = math.floor(width / height * effective_h + 0.5)
    end

    local v_par = properties["video-out-params"] and properties["video-out-params"]["par"] or 1
    if v_par == 1 then
        par = ":force_original_aspect_ratio=decrease"
    else
        par = ""
    end
end

local info_timer = nil

local function info(w, h)
    local rotate = properties["video-params"] and properties["video-params"]["rotate"]
    local image = properties["current-tracks/video"] and properties["current-tracks/video"]["image"]
    local albumart = image and properties["current-tracks/video"]["albumart"]

    disabled = (w or 0) == 0 or (h or 0) == 0 or
        has_vid == 0 or
        (properties["demuxer-via-network"] and not options.network) or
        (albumart and not options.audio) or
        (image and not albumart) or
        force_disabled

    if info_timer then
        info_timer:kill()
        info_timer = nil
    elseif has_vid == 0 or (rotate == nil and not disabled) then
        info_timer = mp.add_timeout(0.05, function() info(w, h) end)
    end

    local json, err = mp.utils.format_json({width=w * options.scale_factor, height=h * options.scale_factor, scale_factor=options.scale_factor, disabled=disabled, available=true, socket=options.socket, thumbnail=options.thumbnail, overlay_id=options.overlay_id})
    if pre_0_30_0 then
        mp.command_native({"script-message", "thumbfast-info", json})
    else
        mp.command_native_async({"script-message", "thumbfast-info", json}, function() end)
    end
end

local function remove_thumbnail_files()
    if file then
        pcall(function() file:close() end)
        file = nil
        file_bytes = 0
    end
    pcall(function()
        os.remove(options.thumbnail)
        os.remove(options.thumbnail..".bgra")
        os.remove(options.thumbnail..".tmp")
        os.remove(options.thumbnail..".pack")
        os.remove(options.thumbnail..".idx")
        os.remove(options.thumbnail..".pack.tmp")
        os.remove(options.thumbnail..".idx.tmp")
    end)
end

local function clean_edl_url(url)
    if not url then return nil end
    local clean = url:gsub(",length=%d+.*$", ""):gsub(",media_type=%a+.*$", "")
    return clean
end

local function optimize_btr_url(url)
    if not url then return url end
    if url:match("^https?://127%.0%.0%.1:%d+/stream") then
        if url:find("([?&])threads=%d+") then
            url = url:gsub("([?&])threads=%d+", "%1threads=1")
        else
            url = url .. (url:find("?", 1, true) and "&" or "?") .. "threads=1"
        end
        if not url:find("thumb=1", 1, true) then
            url = url .. "&thumb=1"
        end
    end
    return url
end

local function extract_direct_url(fn)
    if not fn or fn == "" then return fn end
    if fn:match("^https?://127%.0%.0%.1:%d+/stream") then
        return optimize_btr_url(fn)
    end
    if fn:match("^edl://") then
        if fn:find("!mp4_dash", 1, true) then
            return fn
        end
        local fallback_url = nil
        local pos = 1
        while pos <= #fn do
            local s, e, len_str = fn:find("%%(%d+)%%https?://", pos)
            if not s then break end
            local len = tonumber(len_str)
            local url_start = s + #len_str + 2
            if len and len > 0 and (url_start + len - 1) <= #fn then
                local candidate = fn:sub(url_start, url_start + len - 1)
                local seg_start = fn:sub(1, s - 1):match(".*!new_stream()") or 1
                local seg_header = fn:sub(seg_start, s - 1)
                local is_audio_only = seg_header:find("media_type=audio", 1, true) and not seg_header:find("media_type=video", 1, true)
                if not is_audio_only then
                    return optimize_btr_url(candidate)
                elseif not fallback_url then
                    fallback_url = candidate
                end
                pos = url_start + len
            else
                pos = e + 1
            end
        end
        if fallback_url then
            return optimize_btr_url(fallback_url)
        end
        local btr_match = fn:match("(https?://127%.0%.0%.1:%d+/stream[^\";\r\n]*)")
        if btr_match then
            return optimize_btr_url(clean_edl_url(btr_match))
        end
        local url3 = fn:match("(https?://[^;\r\n]+)")
        if url3 then
            return optimize_btr_url(clean_edl_url(url3))
        end
    end
    return fn
end

-- ==============================================================================
-- Online Sprite-Sheet / Storyboard RAM Pack Engine (Bilibili & YouTube)
-- ==============================================================================
local function get_online_page_url()
    local candidates = {
        mp.get_property("path"),
        properties["path"],
        cached_ytdl_webpage_url,
        mp.get_property("metadata/by-key/webpage_url"),
        mp.get_property("filtered-metadata/by-key/webpage_url"),
    }
    for _, raw in ipairs(candidates) do
        if raw and raw ~= "" then
            local u = raw:gsub("^ytdl://https?://", "https://"):gsub("^ytdl://", "https://")
            local lower = u:lower()
            if lower:find("^https?://") and (
                lower:find("bilibili%.com/video/") or
                lower:find("bilibili%.com/bangumi/play/") or
                lower:find("b23%.tv/") or
                lower:find("youtube%.com/watch") or
                lower:find("youtube%.com/shorts/") or
                lower:find("youtu%.be/")
            ) then
                return u
            end
        end
    end
    return nil
end

local function find_sprite_index(times, target)
    local n = #times
    if n == 0 then return nil end
    if target <= times[1] then return 1 end
    if target >= times[n] then return n end
    local lo, hi = 1, n
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if times[mid] == target then
            return mid
        elseif times[mid] < target then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    local idx = math.max(1, hi)
    if idx < n and math.abs(times[idx + 1] - target) < math.abs(times[idx] - target) then
        return idx + 1
    end
    return idx
end

local function write_sprite_frame_to_bgra(time)
    if not sprite_pack or not sprite_pack.frames or #sprite_pack.frames == 0 then
        return false
    end
    local idx = find_sprite_index(sprite_pack.times, time or 0)
    if not idx or not sprite_pack.frames[idx] then
        return false
    end
    if sprite_pack.last_idx ~= idx or not sprite_pack.bgra_written then
        local tmp_bgra = options.thumbnail .. ".sp.tmp"
        local dst_bgra = options.thumbnail .. ".bgra"
        local wrote = false
        local f = io.open(tmp_bgra, "wb")
        if f then
            f:write(sprite_pack.frames[idx])
            f:close()
            pcall(function() os.remove(dst_bgra) end)
            local ok, ren = pcall(function() return os.rename(tmp_bgra, dst_bgra) end)
            if ok and ren then
                wrote = true
            else
                pcall(function() os.remove(tmp_bgra) end)
            end
        end
        if not wrote then
            local f2 = io.open(dst_bgra, "wb")
            if not f2 then return false end
            f2:write(sprite_pack.frames[idx])
            f2:close()
        end
        sprite_pack.last_idx = idx
        sprite_pack.bgra_written = true
    end
    real_w, real_h = sprite_pack.w, sprite_pack.h
    return true
end

local function load_sprite_pack(prefix, w, h)
    local idx_path = prefix .. ".idx"
    local pack_path = prefix .. ".pack"
    local fi = io.open(idx_path, "r")
    local fp = io.open(pack_path, "rb")
    if not fi or not fp then
        if fi then fi:close() end
        if fp then fp:close() end
        return false
    end
    local times = {}
    for line in fi:lines() do
        local t = tonumber(line)
        if t then times[#times + 1] = t end
    end
    fi:close()

    local frame_bytes = w * h * 4
    local frames = {}
    if frame_bytes > 0 then
        for i = 1, #times do
            local data = fp:read(frame_bytes)
            if not data or #data < frame_bytes then break end
            frames[i] = data
        end
    end
    fp:close()
    pcall(function()
        os.remove(idx_path)
        os.remove(pack_path)
    end)

    if #frames == 0 then return false end
    sprite_pack = {
        w = w,
        h = h,
        times = times,
        frames = frames,
        last_idx = nil,
        bgra_written = false,
    }
    real_w, real_h = w, h
    if real_w ~= last_real_w or real_h ~= last_real_h then
        last_real_w, last_real_h = real_w, real_h
        info(real_w, real_h)
    end
    return true
end

local activity_timer
local draw
local run

local spawn
local request_seek

local function start_online_sprite_fetch()
    if disabled or sprite_fetching or sprite_pack or sprite_failed then return end
    local page_url = get_online_page_url()
    if not page_url then return end
    if not effective_w or not effective_h or effective_w <= 0 or effective_h <= 0 then return end

    -- For YouTube, wait briefly if ytdl_hook hasn't populated cached_ytdl_stdout yet, unless already loaded
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    local sep = os_name == "windows" and "\\" or "/"
    local py_script = temp_dir .. sep .. "thumbfast_online_engine.py"
    local pf = io.open(py_script, "wb")
    if not pf then return end
    pf:write(ONLINE_THUMB_PY)
    pf:close()

    local cookie_file = properties["cookies-file"] or mp.get_property("cookies-file") or ""
    if cookie_file == "" then
        local active_cookies = temp_dir .. sep .. "mpv_active_cookies.txt"
        local cf = io.open(active_cookies, "r")
        if cf then
            cf:close()
            cookie_file = active_cookies
        end
    end

    local ytdl_bin = "yt-dlp"
    if os_name == "windows" then
        local ok_p, cand = pcall(function() return mp.command_native({"expand-path", "~~/../yt-dlp.exe"}) end)
        if ok_p and cand and mp.utils.file_info(cand) then
            ytdl_bin = cand
        end
    end

    sprite_seq = sprite_seq + 1
    local cur_sprite_seq = sprite_seq
    local req_w, req_h = effective_w, effective_h
    local prefix = base_thumbnail .. "_sp_" .. cur_sprite_seq

    local ytdl_json_path = ""
    local ytdl_stdout = cached_ytdl_stdout
    if not ytdl_stdout then
        local ytdl_res = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
        if ytdl_res and type(ytdl_res) == "table" and ytdl_res.status == 0 and ytdl_res.stdout and ytdl_res.stdout ~= "" then
            ytdl_stdout = ytdl_res.stdout
        end
    end
    if ytdl_stdout and ytdl_stdout ~= "" then
        local jf_path = prefix .. ".ytdl.json"
        local jf = io.open(jf_path, "wb")
        if jf then
            jf:write(ytdl_stdout)
            jf:close()
            ytdl_json_path = jf_path
        end
    end

    sprite_fetching = true

    local py_bin = os_name == "windows" and "python" or "python3"
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {py_bin, py_script, page_url, tostring(req_w), tostring(req_h), prefix, cookie_file, ytdl_bin, ytdl_json_path}
    }, function(success, result)
        if ytdl_json_path ~= "" then
            pcall(function() os.remove(ytdl_json_path) end)
        end
        if cur_sprite_seq ~= sprite_seq then return end
        sprite_fetching = false
        local loaded = false
        if success and result and result.status == 0 then
            loaded = load_sprite_pack(prefix, req_w, req_h)
        end
        if loaded then
            mp.msg.info("thumbfast: loaded online sprite pack (" .. tostring(#sprite_pack.frames) .. " frames)")
            if spawned then
                run("quit")
                spawned = false
            end
            if show_thumbnail and last_seek_time then
                if write_sprite_frame_to_bgra(last_seek_time) then
                    draw(real_w, real_h, script_name)
                end
            end
        else
            sprite_failed = true
            mp.msg.verbose("thumbfast: online sprite pack unavailable, falling back to mpv subprocess")
            if not spawned and not disabled and (show_thumbnail or options.spawn_first or last_seek_time) then
                spawn(last_seek_time or mp.get_property_number("time-pos", 0))
                if show_thumbnail and last_seek_time then
                    request_seek()
                end
                if not file_timer:is_enabled() then file_timer:resume() end
            end
        end
    end)
end

spawn = function(time)
    if disabled or sprite_pack then return end

    local path = properties["path"]
    if path == nil then return end

    if not properties["video-out-params"] or not properties["video-out-params"]["dw"] or properties["video-out-params"]["dw"] == 0 then
        mp.msg.verbose("thumbfast: video-out-params not ready, deferring spawn")
        return
    end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    remove_thumbnail_files()

    spawn_seq = spawn_seq + 1
    options.socket = base_socket .. "_" .. spawn_seq
    options.thumbnail = base_thumbnail .. "_" .. spawn_seq

    if options.direct_io and os_name == "windows" then
        winapi.socket_wc = winapi.MultiByteToWideChar("\\\\.\\pipe\\" .. options.socket)
    end

    local open_filename = properties["stream-open-filename"] or mp.get_property("stream-open-filename")
    local ytdl = open_filename and properties["demuxer-via-network"] and path ~= open_filename
    if ytdl then
        path = extract_direct_url(open_filename)
    elseif path and (path:match("^edl://") or path:match("^https?://127%.0%.0%.1:%d+/stream")) then
        path = extract_direct_url(path)
    end

    local vid = properties["vid"]
    has_vid = vid or 0

    local args = {
        mpv_path, "--no-config", "--msg-level=all=no", "--idle", "--pause", "--keep-open=always", "--really-quiet", "--no-terminal",
        "--load-scripts=no", "--osc=no", "--ytdl=no", "--load-stats-overlay=no", "--load-osd-console=no", "--load-auto-profiles=no",
        "--edition="..(properties["edition"] or "auto"), "--vid="..(vid or "auto"), "--no-sub", "--no-audio",
        "--start="..time, allow_fast_seek and "--hr-seek=no" or "--hr-seek=yes",
        "--force-seekable=yes",
        "--ytdl-format=worst", "--demuxer-readahead-secs=0",
        properties["demuxer-via-network"] and "--demuxer-max-bytes=4MiB" or "--demuxer-max-bytes=128KiB",
        properties["demuxer-via-network"] and "--stream-buffer-size=128KiB" or "--stream-buffer-size=128KiB",
        "--network-timeout=10",
        "--demuxer-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5",
        "--vd-lavc-skiploopfilter=all", "--vd-lavc-software-fallback=1", "--vd-lavc-fast", "--vd-lavc-threads=2", "--hwdec="..(options.hwdec and "auto" or "no"),
        "--vf="..vf_string(filters_all, true),
        "--sws-scaler=fast-bilinear",
        "--video-rotate="..last_rotate,
        "--ovc=rawvideo", "--of=image2", "--ofopts=update=1", "--o="..options.thumbnail
    }

    if not pre_0_30_0 then
        table.insert(args, "--sws-allow-zimg=no")
    end

    if support_media_control then
        table.insert(args, "--media-controls=no")
    end

    if os_name == "darwin" and properties["macos-app-activation-policy"] then
        table.insert(args, "--macos-app-activation-policy=accessory")
    end

    if os_name == "windows" or pre_0_33_0 then
        table.insert(args, "--input-ipc-server="..options.socket)
    elseif not script_written then
        local client_script_path = options.socket..".run"
        local script = io.open(client_script_path, "w+")
        if script == nil then
            mp.msg.error("client script write failed")
            return
        else
            script_written = true
            script:write(string.format(client_script, options.socket))
            script:close()
            subprocess({"chmod", "+x", client_script_path}, true)
            table.insert(args, "--scripts="..client_script_path)
        end
    else
        local client_script_path = options.socket..".run"
        table.insert(args, "--scripts="..client_script_path)
    end

    local ua = properties["user-agent"]
    if ua and ua ~= "" then
        table.insert(args, "--user-agent=" .. ua)
    end
    local ref = properties["referrer"]
    if ref and ref ~= "" then
        table.insert(args, "--referrer=" .. ref)
    end

    local http_headers = properties["http-header-fields"]
    if http_headers and type(http_headers) == "table" then
        for _, h in ipairs(http_headers) do
            table.insert(args, "--http-header-fields-append=" .. h)
        end
    end

    if properties["cookies-file"] and properties["cookies-file"] ~= "" then
        table.insert(args, "--cookies-file=" .. properties["cookies-file"])
    else
        local temp_dir = os.getenv("TEMP") or "C:\\Users\\Administrator\\AppData\\Local\\Temp"
        local active_cookies = temp_dir .. "\\mpv_active_cookies.txt"
        local f = io.open(active_cookies, "r")
        if f then
            f:close()
            table.insert(args, "--cookies-file=" .. active_cookies)
        end
    end

    -- Bilibili anti-hotlinking defense: Ensure slave mpv carries Referer
    local full_path_info = ((path or "") .. " " .. (open_filename or "") .. " " .. (properties["path"] or "")):lower()
    local is_bilibili = full_path_info:find("bilibili%.com") or full_path_info:find("bilivideo%.com") or full_path_info:find("bilivideo%.cn") or full_path_info:find("akamaized%.net")
    if is_bilibili then
        local has_bili_ref = false
        if ref and ref:find("bilibili%.com") then has_bili_ref = true end
        if http_headers and type(http_headers) == "table" then
            for _, h in ipairs(http_headers) do
                if h:lower():match("^referer:") and h:find("bilibili%.com") then
                    has_bili_ref = true
                    break
                end
            end
        end
        if not has_bili_ref then
            table.insert(args, "--referrer=https://www.bilibili.com")
            table.insert(args, "--http-header-fields-append=referer: https://www.bilibili.com")
        end
    end

    local needs_ipc_load = (#path > 4000) or (path:match("^edl://") ~= nil)
    if not needs_ipc_load then
        table.insert(args, "--")
        table.insert(args, path)
        pending_loadfile = nil
    else
        pending_loadfile = { path = path, time = time }
    end

    spawned = true
    spawn_waiting = true

    local current_seq = spawn_seq
    subprocess(args, true,
        function(success, result)
            if current_seq ~= spawn_seq then
                return
            end
            if spawn_waiting and (success == false or (result.status ~= 0 and result.status ~= -2)) then
                spawned = false
                spawn_waiting = false
                options.tone_mapping = "no"
                mp.msg.error("mpv subprocess create failed")
                if not spawn_working then -- notify users of required configuration
                    if options.mpv_path == "mpv" then
                        if properties["current-vo"] == "libmpv" then
                            if options.mpv_path == mpv_path then -- attempt to locate ImPlay
                                mpv_path = "ImPlay"
                                spawn(time)
                            else -- ImPlay not in path
                                if os_name ~= "darwin" then
                                    force_disabled = true
                                    info(real_w or effective_w, real_h or effective_h)
                                end
                                mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                                mp.commandv("script-message-to", "implay", "show-message", "thumbfast initial setup", "Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                            end
                        else
                            mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                            if os_name == "windows" and frontend_path == nil then
                                mp.commandv("script-message-to", "mpvnet", "show-text", "thumbfast: ERROR! install standalone mpv, see README", 5000, 20)
                                mp.commandv("script-message", "mpv.net", "show-text", "thumbfast: ERROR! install standalone mpv, see README", 5000, 20)
                            end
                        end
                    else
                        mp.commandv("show-text", "thumbfast: ERROR! cannot create mpv subprocess", 5000)
                        -- found ImPlay but not defined in config
                        mp.commandv("script-message-to", "implay", "show-message", "thumbfast", "Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                    end
                end
            elseif success == true and (result.status == 0 or result.status == -2) then
                if not spawn_working and properties["current-vo"] == "libmpv" and options.mpv_path ~= mpv_path then
                    mp.commandv("script-message-to", "implay", "show-message", "thumbfast initial setup", "Set mpv_path=ImPlay in thumbfast config:\n" .. string.gsub(mp.command_native({"expand-path", "~~/script-opts/thumbfast.conf"}), "[/\\]", path_separator).."\nand restart ImPlay")
                end
                spawn_working = true
                spawn_waiting = false
            end
        end
    )
end

local function check_pending_loadfile()
    if not pending_loadfile then return end

    if options.direct_io then
        local hPipe = winapi.C.CreateFileW(winapi.socket_wc, winapi.GENERIC_WRITE, 0, nil, winapi.OPEN_EXISTING, winapi._createfile_pipe_flags, nil)
        if hPipe ~= winapi.INVALID_HANDLE_VALUE then
            local p = pending_loadfile
            local target_time = last_seek_time or p.time or 0
            local load_cmd = {
                command = {"loadfile", p.path, "replace", 0, "start=" .. tostring(target_time)}
            }
            local buf = mp.utils.format_json(load_cmd) .. "\n"
            winapi.C.SetNamedPipeHandleState(hPipe, winapi.PIPE_NOWAIT, nil, nil)
            local written = winapi.ffi.new("unsigned long[1]")
            local ok = winapi.C.WriteFile(hPipe, buf, #buf, written, nil)
            winapi.C.CloseHandle(hPipe)
            if ok and written[0] > 0 then
                pending_loadfile = nil
            end
        end
        return
    end

    if not file then
        if os_name == "windows" then
            file = io.open("\\\\.\\pipe\\"..options.socket, "r+b")
        else
            file = io.open(options.socket, "r+")
        end
    end

    if file then
        local p = pending_loadfile
        pending_loadfile = nil
        local target_time = last_seek_time or p.time or 0
        local load_cmd = {
            command = {"loadfile", p.path, "replace", 0, "start=" .. tostring(target_time)}
        }
        local json_str = mp.utils.format_json(load_cmd) .. "\n"
        file:write(json_str)
        file:flush()
        file_bytes = 0
    end
end

run = function(command)
    if not spawned then return end

    if pending_loadfile then
        check_pending_loadfile()
        if pending_loadfile then return end
    end

    if options.direct_io then
        local hPipe = winapi.C.CreateFileW(winapi.socket_wc, winapi.GENERIC_WRITE, 0, nil, winapi.OPEN_EXISTING, winapi._createfile_pipe_flags, nil)
        if hPipe ~= winapi.INVALID_HANDLE_VALUE then
            local buf = command .. "\n"
            winapi.C.SetNamedPipeHandleState(hPipe, winapi.PIPE_NOWAIT, nil, nil)
            winapi.C.WriteFile(hPipe, buf, #buf, winapi._lpNumberOfBytesWritten, nil)
            winapi.C.CloseHandle(hPipe)
        end

        return
    end

    local command_n = command.."\n"

    if os_name == "windows" then
        if file and file_bytes + #command_n >= 4096 then
            file:close()
            file = nil
            file_bytes = 0
        end
        if not file then
            file = io.open("\\\\.\\pipe\\"..options.socket, "r+b")
        end
    elseif pre_0_33_0 then
        subprocess({"/usr/bin/env", "sh", "-c", "echo '" .. command .. "' | socat - " .. options.socket})
        return
    elseif not file then
        file = io.open(options.socket, "r+")
    end
    if file then
        file_bytes = file:seek("end")
        file:write(command_n)
        file:flush()
    end
end

draw = function(w, h, script)
    if not w or not show_thumbnail then return end
    if x ~= nil then
        local scale_w, scale_h = options.scale_factor ~= 1 and (w * options.scale_factor) or nil, options.scale_factor ~= 1 and (h * options.scale_factor) or nil
        if not overlay_shown then
            overlay_shown = true
            mp.commandv("script-message", "thumbfast-rendered", options.thumbnail..".bgra", tostring(w), tostring(h), tostring(x), tostring(y))
        end
        if pre_0_30_0 then
            mp.command_native({"overlay-add", options.overlay_id, x, y, options.thumbnail..".bgra", 0, "bgra", w, h, (4*w), scale_w, scale_h})
        else
            mp.command_native_async({"overlay-add", options.overlay_id, x, y, options.thumbnail..".bgra", 0, "bgra", w, h, (4*w), scale_w, scale_h}, function() end)
        end
    elseif script then
        local json, err = mp.utils.format_json({width=w, height=h, scale_factor=options.scale_factor, x=x, y=y, socket=options.socket, thumbnail=options.thumbnail, overlay_id=options.overlay_id})
        mp.commandv("script-message-to", script, "thumbfast-render", json)
    end
end

local function real_res(req_w, req_h, filesize)
    local count = filesize / 4
    local diff = (req_w * req_h) - count

    if (properties["video-params"] and properties["video-params"]["rotate"] or 0) % 180 == 90 then
        req_w, req_h = req_h, req_w
    end

    if diff == 0 then
        return req_w, req_h
    else
        local threshold = 5 -- throw out results that change too much
        local long_side, short_side = req_w, req_h
        if req_h > req_w then
            long_side, short_side = req_h, req_w
        end
        for a = short_side, short_side - threshold, -1 do
            if count % a == 0 then
                local b = count / a
                if long_side - b < threshold then
                    if req_h < req_w then return b, a else return a, b end
                end
            end
        end
        return nil
    end
end

local function move_file(from, to)
    if os_name == "windows" then
        pcall(function() os.remove(to) end)
    end
    -- move the file because it can get overwritten while overlay-add is reading it, and crash the player
    local ok, err = pcall(function() return os.rename(from, to) end)
    return ok and err
end

local function seek(fast)
    if last_seek_time then
        mp.msg.verbose("thumbfast seek: " .. (fast and "keyframes" or "exact") .. " to " .. tostring(last_seek_time))
        run("async seek " .. last_seek_time .. (fast and " absolute+keyframes" or " absolute+exact"))
    end
end

local seek_period = 3/60
local seek_period_counter = 0
local seek_timer
seek_timer = mp.add_periodic_timer(seek_period, function()
    if seek_period_counter == 0 then
        seek(allow_fast_seek)
        seek_period_counter = 1
    else
        local delay_ticks = math.max(1, math.floor(((tonumber(options.exact_seek_delay) or 0.1) / seek_period) + 0.5))
        if seek_period_counter >= delay_ticks then
            seek_timer:kill()
            if allow_fast_seek and get_exact_seek_mode() ~= "no" then
                seek(false)
            elseif last_seek_time then
                seek(allow_fast_seek)
            end
        else
            seek_period_counter = seek_period_counter + 1
        end
    end
end)
seek_timer:kill()

request_seek = function()
    if seek_timer:is_enabled() then
        seek_period_counter = 0
    else
        seek_timer:resume()
        seek(allow_fast_seek)
        seek_period_counter = 1
    end
end

local function check_new_thumb()
    -- the slave might start writing to the file after checking existance and
    -- validity but before actually moving the file, so move to a temporary
    -- location before validity check to make sure everything stays consistant
    -- and valid thumbnails don't get overwritten by invalid ones
    local tmp = options.thumbnail..".tmp"
    local moved = move_file(options.thumbnail, tmp)
    if not moved then return false end
    local finfo = mp.utils.file_info(tmp)
    if not finfo then return false end
    spawn_waiting = false
    local w, h = real_res(effective_w, effective_h, finfo.size)
    if w then -- only accept valid thumbnails
        move_file(tmp, options.thumbnail..".bgra")

        thumb_timestamp = last_seek_time
        real_w, real_h = w, h
        if real_w and (real_w ~= last_real_w or real_h ~= last_real_h) then
            last_real_w, last_real_h = real_w, real_h
            info(real_w, real_h)
        end
        if not show_thumbnail then
            file_timer:kill()
        end
        return true
    end

    return false
end

file_timer = mp.add_periodic_timer(file_check_period, function()
    if pending_loadfile then
        check_pending_loadfile()
    end
    if check_new_thumb() then
        draw(real_w, real_h, script_name)
    end
end)
file_timer:kill()

local function clear()
    if not show_thumbnail and not last_seek_time and not last_x and not overlay_shown then
        return
    end
    file_timer:kill()
    seek_timer:kill()
    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end
    last_seek_time = nil
    thumb_timestamp = nil
    show_thumbnail = false
    last_x = nil
    last_y = nil
    if overlay_shown then
        overlay_shown = false
        mp.commandv("script-message", "thumbfast-rendered", "0")
    end
    if script_name then return end
    if pre_0_30_0 then
        mp.command_native({"overlay-remove", options.overlay_id})
    else
        mp.command_native_async({"overlay-remove", options.overlay_id}, function() end)
    end
end

local function quit()
    activity_timer:kill()
    if show_thumbnail then
        activity_timer:resume()
        return
    end
    pending_loadfile = nil
    run("quit")
    spawned = false
    real_w, real_h = nil, nil
    clear()
end

activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
activity_timer:kill()

local function thumb(time, r_x, r_y, script)
    if disabled then return end

    time = tonumber(time)
    if time == nil then return end

    if r_x == "" or r_y == "" then
        x, y = nil, nil
    else
        x, y = math.floor(r_x + 0.5), math.floor(r_y + 0.5)
    end

    script_name = script

    -- Fast path for Bilibili / YouTube when sprite-sheet pack is loaded in RAM:
    -- 0ms instant lookup & redraw at (x, y) without any network seek!
    if sprite_pack and sprite_pack.frames and #sprite_pack.frames > 0 then
        show_thumbnail = true
        last_x, last_y = x, y
        last_seek_time = time
        if write_sprite_frame_to_bgra(time) then
            draw(real_w, real_h, script)
        end
        return
    end

    if sprite_fetching then
        show_thumbnail = true
        last_x, last_y = x, y
        last_seek_time = time
        return
    end

    if last_x ~= x or last_y ~= y or not show_thumbnail then
        show_thumbnail = true
        last_x, last_y = x, y
        draw(real_w, real_h, script)
    end

    if options.quit_after_inactivity > 0 then
        if show_thumbnail or activity_timer:is_enabled() then
            activity_timer:kill()
        end
        activity_timer:resume()
    end

    if time == last_seek_time then return end
    last_seek_time = time
    if not spawned then spawn(time) end
    request_seek()
    if not file_timer:is_enabled() then file_timer:resume() end
end

local function watch_changes()
    if not dirty or not properties["video-out-params"] then return end
    dirty = false

    local old_w = effective_w
    local old_h = effective_h

    calc_dimensions()

    local vf_reset = vf_string(filters_reset)
    local rotate = properties["video-rotate"] or 0

    local resized = old_w ~= effective_w or
        old_h ~= effective_h or
        last_vf_reset ~= vf_reset or
        (last_rotate % 180) ~= (rotate % 180) or
        par ~= last_par or last_crop ~= properties["video-crop"]

    if resized then
        last_rotate = rotate
        info(effective_w, effective_h)
    elseif last_has_vid ~= has_vid and has_vid ~= 0 then
        info(effective_w, effective_h)
    end

    -- Start online sprite-sheet extraction for Bilibili / YouTube as soon as dimensions are known
    if not disabled and get_online_page_url() then
        if resized and sprite_pack then
            sprite_pack = nil
            sprite_fetching = false
        end
        start_online_sprite_fetch()
    end

    if spawned then
        if resized then
            -- mpv doesn't allow us to change output size
            local seek_time = last_seek_time
            run("quit")
            remove_thumbnail_files()
            spawned = false
            if show_thumbnail or options.spawn_first or seek_time then
                spawn(seek_time or mp.get_property_number("time-pos", 0))
                file_timer:resume()
            end
        else
            if rotate ~= last_rotate then
                run("set video-rotate "..rotate)
            end
            local vf_runtime = vf_string(filters_runtime)
            if vf_runtime ~= last_vf_runtime then
                run("vf set "..vf_string(filters_all, true))
                last_vf_runtime = vf_runtime
            end
        end
    else
        last_vf_runtime = vf_string(filters_runtime)
    end

    last_vf_reset = vf_reset
    last_rotate = rotate
    last_par = par
    last_crop = properties["video-crop"]
    last_has_vid = has_vid

    if not spawned and not disabled and not sprite_pack and not sprite_fetching and options.spawn_first and resized then
        spawn(mp.get_property_number("time-pos", 0))
        file_timer:resume()
    end
end

local function update_property(name, value)
    properties[name] = value
end

local function update_property_dirty(name, value)
    properties[name] = value
    dirty = true
    if name == "tone-mapping" then
        last_tone_mapping = nil
    end
end

local function update_tracklist(name, value)
    -- current-tracks shim
    for _, track in ipairs(value) do
        if track.type == "video" and track.selected then
            properties["current-tracks/video"] = track
            return
        end
    end
end

local function sync_changes(prop, val)
    update_property(prop, val)
    if val == nil then return end

    if type(val) == "boolean" then
        if prop == "vid" then
            has_vid = 0
            last_has_vid = 0
            info(effective_w, effective_h)
            clear()
            return
        end
        val = val and "yes" or "no"
    end

    if prop == "vid" then
        has_vid = 1
    end

    if not spawned then return end

    run("set "..prop.." "..val)
    dirty = true
end

local function file_load()
    pending_loadfile = nil
    sprite_pack = nil
    sprite_fetching = false
    sprite_failed = false
    sprite_seq = sprite_seq + 1
    if spawned then
        run("quit")
    end
    clear()
    remove_thumbnail_files()
    spawn_seq = spawn_seq + 1
    options.socket = base_socket .. "_" .. spawn_seq
    options.thumbnail = base_thumbnail .. "_" .. spawn_seq
    spawned = false
    real_w, real_h = nil, nil
    last_real_w, last_real_h = nil, nil
    last_tone_mapping = nil
    last_seek_time = nil
    thumb_timestamp = nil
    if info_timer then
        info_timer:kill()
        info_timer = nil
    end

    calc_dimensions()
    info(effective_w, effective_h)
    if not disabled and get_online_page_url() then
        start_online_sprite_fetch()
    end
end

local function shutdown()
    run("quit")
    remove_thumbnail_files()
    if os_name ~= "windows" then
        os.remove(options.socket)
        os.remove(options.socket..".run")
    end
end

local function on_duration(prop, val)
    local mode = get_exact_seek_mode()
    if mode == "yes" then
        allow_fast_seek = false
    elseif mode == "no" then
        allow_fast_seek = true
    else
        allow_fast_seek = properties["demuxer-via-network"] or (val or 30) >= 30
    end
end

mp.observe_property("current-tracks/video", "native", function(name, value)
    if pre_0_33_0 then
        mp.unobserve_property(update_tracklist)
        pre_0_33_0 = false
    end
    update_property(name, value)
end)

mp.observe_property("track-list", "native", update_tracklist)
mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-out-params", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("vf", "native", update_property_dirty)
mp.observe_property("tone-mapping", "native", update_property_dirty)
mp.observe_property("demuxer-via-network", "native", update_property)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("http-header-fields", "native", update_property)
mp.observe_property("user-agent", "native", update_property)
mp.observe_property("referrer", "native", update_property)
mp.observe_property("cookies-file", "native", update_property)
mp.observe_property("macos-app-activation-policy", "native", update_property)
mp.observe_property("current-vo", "native", update_property)
mp.observe_property("video-rotate", "native", update_property)
mp.observe_property("video-crop", "native", update_property)
mp.observe_property("path", "native", update_property)
mp.observe_property("vid", "native", sync_changes)
mp.observe_property("edition", "native", sync_changes)
mp.observe_property("duration", "native", on_duration)

mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)

mp.register_event("file-loaded", file_load)
mp.register_event("shutdown", shutdown)

mp.register_idle(watch_changes)
