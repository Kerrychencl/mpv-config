#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sponsor_unified.py - 統一 SponsorBlock 查詢核心 (支援 YouTube 與 B 站小電視空降助手)
1. YouTube: 請求 SponsorBlock 官方 API (https://sponsor.ajay.app)
2. Bilibili: 請求 BilibiliSponsorBlock 官方 API (https://bsbsb.top)
3. 統一輸出標準化片段數據供 MPV 自動跳過與 ModernZ 進度條全彩繪製
"""

import sys
import os
import re
import json
import hashlib
import urllib.request
import urllib.parse

try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass

CATEGORY_CONFIG = {
    'sponsor': {'name': '商業贊助廣告', 'color': '#00D482', 'default_skip': True},
    'selfpromo': {'name': '節目宣傳/自促銷', 'color': '#FEA62A', 'default_skip': False},
    'interaction': {'name': '三連/求訂閱關注', 'color': '#00D2F3', 'default_skip': False},
    'intro': {'name': '片頭/開場動畫', 'color': '#5C7CFA', 'default_skip': False},
    'outro': {'name': '片尾/幕後致謝', 'color': '#5C7CFA', 'default_skip': False},
    'preview': {'name': '預告/前情提要', 'color': '#FFDE59', 'default_skip': False},
    'filler': {'name': '無效轉場/廢話', 'color': '#A0A0A0', 'default_skip': False},
    'music_offtopic': {'name': '非音樂片段', 'color': '#FF9F43', 'default_skip': False},
    'poi_highlight': {'name': '高能精彩看點', 'color': '#9B51E0', 'default_skip': False},
}

def get_bilibili_segments(bvid):
    if not bvid:
        return []
    h = hashlib.sha256(bvid.encode('utf-8')).hexdigest()[:4]
    url = f'https://bsbsb.top/api/skipSegments/{h}'
    req = urllib.request.Request(url, headers={'User-Agent': 'mpv-bilibili-sponsorblock/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=6) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            for item in data:
                if item.get('videoID', '').lower() == bvid.lower():
                    raw_segs = item.get('segments', [])
                    normalized = []
                    for s in raw_segs:
                        cat = s.get('category', 'sponsor')
                        cfg = CATEGORY_CONFIG.get(cat, {'name': '自訂片段', 'color': '#A0A0A0', 'default_skip': False})
                        seg_range = s.get('segment', [0, 0])
                        action = s.get('actionType', 'skip')
                        is_skip = (cat == 'sponsor') and (action != 'poi')
                        if seg_range[1] >= seg_range[0]:
                            normalized.append({
                                'uuid': s.get('UUID', ''),
                                'category': cat,
                                'name': cfg['name'],
                                'color': cfg['color'],
                                'action': action,
                                'skip': is_skip,
                                'start': round(float(seg_range[0]), 3),
                                'end': round(float(seg_range[1]), 3)
                            })
                    return normalized
    except Exception:
        pass
    return []

def get_youtube_segments(vid):
    if not vid:
        return []
    h = hashlib.sha256(vid.encode('utf-8')).hexdigest()[:4]
    cats = json.dumps(list(CATEGORY_CONFIG.keys()))
    url = f'https://sponsor.ajay.app/api/skipSegments/{h}?categories=' + urllib.parse.quote(cats)
    req = urllib.request.Request(url, headers={'User-Agent': 'mpv-youtube-sponsorblock/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=6) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            for item in data:
                if item.get('videoID') == vid:
                    raw_segs = item.get('segments', [])
                    normalized = []
                    for s in raw_segs:
                        cat = s.get('category', 'sponsor')
                        cfg = CATEGORY_CONFIG.get(cat, {'name': '自訂片段', 'color': '#A0A0A0', 'default_skip': False})
                        seg_range = s.get('segment', [0, 0])
                        action = s.get('actionType', 'skip')
                        is_skip = (cat == 'sponsor') and (action != 'poi')
                        if seg_range[1] >= seg_range[0]:
                            normalized.append({
                                'uuid': s.get('UUID', ''),
                                'category': cat,
                                'name': cfg['name'],
                                'color': cfg['color'],
                                'action': action,
                                'skip': is_skip,
                                'start': round(float(seg_range[0]), 3),
                                'end': round(float(seg_range[1]), 3)
                            })
                    return normalized
    except Exception:
        pass
    return []

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Unified SponsorBlock for MPV")
    parser.add_argument('--url', default='', help="Video URL or path")
    parser.add_argument('--yt-id', default='', help="YouTube Video ID")
    parser.add_argument('--bvid', default='', help="Bilibili BV ID")
    args = parser.parse_args()

    url = args.url or ""
    yt_id = args.yt_id or ""
    bvid = args.bvid or ""

    if not yt_id and not bvid and url:
        m_bv = re.search(r'([Bb][Vv][0-9A-Za-z]+)', url)
        if m_bv:
            bvid = m_bv.group(1)
        m_yt = re.search(r'(?:v=|youtu\.be/|/embed/|/v/)([a-zA-Z0-9_-]{11})', url)
        if m_yt:
            yt_id = m_yt.group(1)

    result = {
        'status': 'empty',
        'service': None,
        'video_id': None,
        'segments': []
    }

    if bvid:
        segs = get_bilibili_segments(bvid)
        result['status'] = 'ok' if segs else 'empty'
        result['service'] = 'bilibili'
        result['video_id'] = bvid
        result['segments'] = segs
    elif yt_id:
        segs = get_youtube_segments(yt_id)
        result['status'] = 'ok' if segs else 'empty'
        result['service'] = 'youtube'
        result['video_id'] = yt_id
        result['segments'] = segs

    print(json.dumps(result, ensure_ascii=False))

if __name__ == '__main__':
    main()
