#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
b2y_search.py - YouTube 接入 B 站彈幕搜尋與匹配模組 (仿 B2Y 插件)
支援：
1. 自動清理 YouTube 標題綴詞（【4K】、[Official MV]、頻道後綴等）
2. B 站 WBI 簽名綜合搜尋（依彈幕數排序 order=dm）
3. 標題相似度與影片時長雙重權重比對
4. 直接支援手動指定 BV 號 / B 站 URL / 剪貼簿快捷導入
5. 自動呼叫 yt-dlp 下載彈幕 XML
6. 支援候選清單搜尋與視覺化面板數據回傳
"""

import sys
import os
import re
import json
import time
import urllib.request
import urllib.parse
import http.cookiejar
import hashlib
import difflib
import subprocess

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass

def clean_youtube_title(title):
    if not title:
        return ""
    t = title
    # 移除常見方括號/花括號綴詞
    t = re.sub(r'【(?:4K|1080P|60FPS|官方|高清|完整版|自制|搬运|中字|熟肉|生肉|首播)[^】]*】', '', t, flags=re.I)
    t = re.sub(r'\[(?:4K|1080P|60FPS|Official|MV|HD|CC|Sub|Audio|Video)[^\]]*\]', '', t, flags=re.I)
    t = re.sub(r'\((?:4K|1080P|60FPS|Official|MV|HD|Video)[^\)]*\)', '', t, flags=re.I)
    # 移除末尾常見的 " | 頻道名"、" - 頻道名"、" _ 頻道名"
    t = re.sub(r'\s*[|\-_／]\s*[^|\-_／]{2,25}$', '', t)
    # 移除 hashtag
    t = re.sub(r'#\S+', '', t)
    # 壓縮空白
    t = re.sub(r'\s+', ' ', t).strip()
    return t

def parse_duration_str(dur_str):
    if not dur_str:
        return 0
    parts = str(dur_str).strip().split(':')
    try:
        if len(parts) == 2:
            return int(parts[0]) * 60 + int(parts[1])
        elif len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    except Exception:
        pass
    return 0

def calc_similarity(a, b):
    a_norm = re.sub(r'[^\w\u4e00-\u9fa5]', '', a.lower())
    b_norm = re.sub(r'[^\w\u4e00-\u9fa5]', '', b.lower())
    if not a_norm or not b_norm:
        return 0.0
    if a_norm in b_norm or b_norm in a_norm:
        return 0.95
    return difflib.SequenceMatcher(None, a_norm, b_norm).ratio()

def get_wbi_keys(opener):
    req = urllib.request.Request('https://api.bilibili.com/x/web-interface/nav', headers={
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://www.bilibili.com/'
    })
    resp = opener.open(req, timeout=8)
    data = json.loads(resp.read().decode('utf-8'))
    wbi_img = data.get('data', {}).get('wbi_img', {})
    img_url = wbi_img.get('img_url', '')
    sub_url = wbi_img.get('sub_url', '')
    img_key = img_url.rsplit('/', 1)[-1].split('.')[0]
    sub_key = sub_url.rsplit('/', 1)[-1].split('.')[0]
    return img_key, sub_key

def search_bilibili(keyword, opener, cookie_file=None):
    try:
        img_key, sub_key = get_wbi_keys(opener)
    except Exception:
        img_key, sub_key = "7cd084941338484aae1ad9425b84077c", "4932caff0ff746eab6f01bf08b70ac45"

    mixinKeyEncTab = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]
    raw_key = img_key + sub_key
    mixin_key = ''.join(raw_key[i] for i in mixinKeyEncTab[:32])

    params = {
        'keyword': keyword,
        'order': 'dm',
        'wts': int(time.time())
    }
    query_parts = []
    for k in sorted(params.keys()):
        v = str(params[k])
        v = re.sub(r"[!'()*]", "", v)
        query_parts.append(f"{urllib.parse.quote(k)}={urllib.parse.quote(v)}")
    query_str = '&'.join(query_parts)
    w_rid = hashlib.md5((query_str + mixin_key).encode('utf-8')).hexdigest()
    search_url = f"https://api.bilibili.com/x/web-interface/wbi/search/all/v2?{query_str}&w_rid={w_rid}"

    req = urllib.request.Request(search_url, headers={
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://search.bilibili.com/'
    })
    resp = opener.open(req, timeout=10)
    data = json.loads(resp.read().decode('utf-8'))
    
    candidates = []
    items = data.get('data', {}).get('result', [])
    for sec in items:
        if sec.get('result_type') == 'video':
            for v in sec.get('data', []):
                raw_title = v.get('title', '')
                clean_t = re.sub(r'<[^>]+>', '', raw_title)
                candidates.append({
                    'bvid': v.get('bvid'),
                    'title': clean_t,
                    'author': v.get('author'),
                    'danmaku': int(v.get('danmaku') or 0),
                    'duration': v.get('duration', ''),
                    'duration_sec': parse_duration_str(v.get('duration', ''))
                })
    return candidates

def find_best_match(candidates, target_title, target_duration=0):
    if not candidates:
        return None
    
    best = None
    best_score = -1.0

    for cand in candidates:
        sim = calc_similarity(target_title, cand['title'])
        score = sim * 100.0

        # 時長加分（若時長差在 10 秒以內，視為同一影片）
        if target_duration > 0 and cand['duration_sec'] > 0:
            diff = abs(target_duration - cand['duration_sec'])
            if diff <= 5:
                score += 35.0
            elif diff <= 15:
                score += 20.0
            elif diff <= 30:
                score += 10.0
            elif diff > 120 and sim < 0.8:
                score -= 25.0

        # 彈幕數加分（優先推薦有真實彈幕的稿件）
        dm = cand['danmaku']
        if dm > 500:
            score += 15.0
        elif dm > 50:
            score += 8.0
        elif dm > 0:
            score += 3.0

        cand['match_score'] = round(score, 1)
        if score > best_score:
            best_score = score
            best = cand

    return best or candidates[0]

def download_bilibili_danmaku(bvid, ytdlp_cmd, work_dir, cookie_file=None):
    bili_url = f"https://www.bilibili.com/video/{bvid}"
    out_tmpl = os.path.join(work_dir, f"{bvid}.%(ext)s")
    cmd = [ytdlp_cmd, bili_url, '--skip-download', '--write-subs', '--retries', '3', '-o', out_tmpl]
    if cookie_file and os.path.exists(cookie_file):
        cmd.extend(['--cookies', cookie_file])
    
    subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='ignore')
    
    # 尋找匹配 bvid 的 XML 檔案
    for f in os.listdir(work_dir):
        if f.lower().startswith(bvid.lower()) and f.endswith('.xml'):
            return os.path.join(work_dir, f)
    for f in os.listdir(work_dir):
        if bvid.lower() in f.lower() and f.endswith('.xml'):
            return os.path.join(work_dir, f)
    
    return None

def main():
    import argparse
    parser = argparse.ArgumentParser(description="B2Y Bilibili Danmaku Searcher for MPV")
    parser.add_argument('--title', default='', help="YouTube / Media Title")
    parser.add_argument('--duration', type=float, default=0.0, help="Video duration in seconds")
    parser.add_argument('--bvid', default='', help="Direct Bilibili BVID or URL")
    parser.add_argument('--cookies', default='', help="Path to cookies.txt")
    parser.add_argument('--work-dir', required=True, help="Working directory to save xml")
    parser.add_argument('--ytdlp', default='yt-dlp', help="Path to yt-dlp executable")
    parser.add_argument('--search-only', action='store_true', help="Only return candidates list without downloading")
    args = parser.parse_args()

    cj = http.cookiejar.MozillaCookieJar()
    if args.cookies and os.path.exists(args.cookies):
        try:
            cj.load(args.cookies, ignore_discard=True, ignore_expires=True)
        except Exception:
            pass
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    target_bvid = None
    target_info = None
    candidates = []

    # 1. 直接指定 BV 號或連結
    if args.bvid:
        m = re.search(r'([Bb][Vv][0-9A-Za-z]+)', args.bvid) or re.search(r'([Aa][Vv]\d+)', args.bvid)
        if m:
            target_bvid = m.group(1)
            target_info = {'bvid': target_bvid, 'title': target_bvid, 'danmaku': 0}

    # 2. 標題搜尋候選
    cleaned_kw = clean_youtube_title(args.title) if args.title else ""
    if not target_bvid and cleaned_kw:
        try:
            candidates = search_bilibili(cleaned_kw, opener, args.cookies)
        except Exception:
            candidates = []
        if not candidates and args.title and cleaned_kw != args.title:
            try:
                candidates = search_bilibili(args.title[:35], opener, args.cookies)
            except Exception:
                candidates = []

        if candidates:
            best = find_best_match(candidates, cleaned_kw, args.duration)
            if best:
                target_bvid = best['bvid']
                target_info = best

    # 若為純搜尋模式（供可視化面板取得候選清單）
    if args.search_only:
        out = {
            'status': 'candidates',
            'query': cleaned_kw or args.title,
            'candidates': candidates[:6]
        }
        print(json.dumps(out, ensure_ascii=False))
        return

    if not target_bvid:
        print(json.dumps({'status': 'not_found', 'query': cleaned_kw, 'candidates': [], 'message': '未在 B 站找到相符影片'}, ensure_ascii=False))
        return

    # 3. 下載彈幕 XML
    xml_path = download_bilibili_danmaku(target_bvid, args.ytdlp, args.work_dir, args.cookies)
    if not xml_path or not os.path.exists(xml_path):
        print(json.dumps({'status': 'download_failed', 'bvid': target_bvid, 'candidates': candidates[:6], 'message': '下載彈幕 XML 失敗'}, ensure_ascii=False))
        return

    output = {
        'status': 'ok',
        'bvid': target_bvid,
        'title': target_info.get('title', target_bvid) if target_info else target_bvid,
        'author': target_info.get('author', '') if target_info else '',
        'danmaku': target_info.get('danmaku', 0) if target_info else 0,
        'duration': target_info.get('duration', '') if target_info else '',
        'xml_path': xml_path,
        'candidates': candidates[:6]
    }
    print(json.dumps(output, ensure_ascii=False))

if __name__ == '__main__':
    main()
