# Bilibili Thread Ripper (BTR) Engine for MPV
# High-concurrency chunk streaming proxy and CDN mirror optimizer
import http.server
import http.client
import socketserver
import threading
import urllib.request
import urllib.parse
import json
import time
import sys
import os
import re
import ssl
import queue
import collections
from concurrent.futures import ThreadPoolExecutor, as_completed

MAINLAND_HOSTS = [
    "upos-sz-mirrorali.bilivideo.com",
    "upos-sz-mirrorcos.bilivideo.com",
    "upos-sz-mirrorhw.bilivideo.com",
    "upos-sz-mirrorbos.bilivideo.com",
    "upos-sz-mirror08c.bilivideo.com",
    "upos-sz-mirrorbd.bilivideo.com",
    "upos-sz-mirror14b.bilivideo.com",
    "upos-sz-estgoss.bilivideo.com",
    "upos-sz-mirrorcoso1.bilivideo.com",
]

OVERSEAS_HOSTS = [
    "upos-sz-mirrorcosov.bilivideo.com",
    "upos-sz-mirroraliov.bilivideo.com",
    "cn-hk-eq-01-01.bilivideo.com",
    "cn-hk-eq-01-03.bilivideo.com",
    "upos-hz-mirrorakam.akamaized.net",
]

LIVE_HOSTS = [
    "d1--cn-gotcha01.bilivideo.com",
    "d1--cn-gotcha04.bilivideo.com",
    "d1--cn-gotcha05.bilivideo.com",
    "d1--cn-gotcha07.bilivideo.com",
]

ALLOWED_DOMAINS = (
    "bilivideo.com",
    "bilivideo.cn",
    "akamaized.net",
    "bilibili.com",
    "hdslb.com",
)

def is_allowed_upstream_url(url: str) -> bool:
    try:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            return False
        host = (parsed.hostname or "").lower()
        if not host:
            return False
        return any(host == d or host.endswith("." + d) for d in ALLOWED_DOMAINS)
    except Exception:
        return False

DEFAULT_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    "Referer": "https://www.bilibili.com",
    "Origin": "https://www.bilibili.com",
}

class HTTPConnectionPool:
    def __init__(self, maxsize_per_host=32, timeout=3.5):
        self.maxsize = maxsize_per_host
        self.timeout = timeout
        self.pools = {}
        self.lock = threading.Lock()
        self.ssl_context = ssl.create_default_context()

    def get_connection(self, scheme: str, host: str, port: int = None):
        if port is None:
            port = 443 if scheme == "https" else 80
        key = (scheme, host, port)
        with self.lock:
            if key not in self.pools:
                self.pools[key] = queue.LifoQueue(maxsize=self.maxsize)
            q = self.pools[key]
        try:
            conn = q.get_nowait()
        except queue.Empty:
            if scheme == "https":
                conn = http.client.HTTPSConnection(host, port, timeout=self.timeout, context=self.ssl_context)
            else:
                conn = http.client.HTTPConnection(host, port, timeout=self.timeout)
        conn.timeout = self.timeout
        return conn, key

    def release_connection(self, key, conn, close=False):
        if close:
            try:
                conn.close()
            except Exception:
                pass
            return
        with self.lock:
            q = self.pools.get(key)
        if q is not None:
            try:
                q.put_nowait(conn)
            except queue.Full:
                try:
                    conn.close()
                except Exception:
                    pass
        else:
            try:
                conn.close()
            except Exception:
                pass

http_pool = HTTPConnectionPool(maxsize_per_host=32, timeout=3.5)

# Cache for probe results: {host: {"latency_ms": float, "status": str, "ts": float}}
probe_cache = {}
probe_cache_lock = threading.Lock()

# Cache for stream metadata: {url_key: {"total_size": int, "content_type": str, "ts": float}}
FILE_INFO_CACHE_TTL = 600.0
FILE_INFO_CACHE_MAX_ENTRIES = 128
file_info_cache = collections.OrderedDict()
file_info_cache_lock = threading.Lock()

class NodeHealthTracker:
    def __init__(self):
        self.lock = threading.Lock()
        self.hosts = {}
        for h in MAINLAND_HOSTS + OVERSEAS_HOSTS + LIVE_HOSTS:
            self.hosts[h] = {
                "ewma_latency_ms": 150.0,
                "ewma_speed_mbps": 20.0,
                "fail_count": 0,
                "cooldown_until": 0.0,
            }

    def is_healthy(self, host: str) -> bool:
        with self.lock:
            info = self.hosts.get(host)
            if not info:
                return True
            return time.time() >= info.get("cooldown_until", 0.0)

    def record_probe(self, host: str, latency_ms: float):
        with self.lock:
            if host not in self.hosts:
                self.hosts[host] = {
                    "ewma_latency_ms": latency_ms,
                    "ewma_speed_mbps": 20.0,
                    "fail_count": 0,
                    "cooldown_until": 0.0,
                }
            else:
                info = self.hosts[host]
                info["ewma_latency_ms"] = 0.3 * latency_ms + 0.7 * info["ewma_latency_ms"]

    def record_success(self, host: str, latency_ms: float = None, speed_mbps: float = None):
        with self.lock:
            if host not in self.hosts:
                self.hosts[host] = {
                    "ewma_latency_ms": latency_ms or 150.0,
                    "ewma_speed_mbps": speed_mbps or 20.0,
                    "fail_count": 0,
                    "cooldown_until": 0.0,
                }
                return
            info = self.hosts[host]
            info["fail_count"] = 0
            if latency_ms is not None and latency_ms > 0:
                info["ewma_latency_ms"] = 0.3 * latency_ms + 0.7 * info["ewma_latency_ms"]
            if speed_mbps is not None and speed_mbps > 0:
                info["ewma_speed_mbps"] = 0.3 * speed_mbps + 0.7 * info["ewma_speed_mbps"]

    def record_failure(self, host: str):
        with self.lock:
            if host not in self.hosts:
                self.hosts[host] = {
                    "ewma_latency_ms": 500.0,
                    "ewma_speed_mbps": 5.0,
                    "fail_count": 1,
                    "cooldown_until": 0.0,
                }
                return
            info = self.hosts[host]
            info["fail_count"] += 1
            info["ewma_latency_ms"] = max(info["ewma_latency_ms"] * 1.5, 500.0)
            if info["fail_count"] >= 2:
                info["cooldown_until"] = time.time() + 60.0

    def record_hedge_loser(self, host: str, latency_ms: float = None):
        with self.lock:
            if host not in self.hosts:
                self.hosts[host] = {
                    "ewma_latency_ms": latency_ms or 300.0,
                    "ewma_speed_mbps": 15.0,
                    "fail_count": 0,
                    "cooldown_until": 0.0,
                }
                return
            info = self.hosts[host]
            # Slower in hedged race: slightly adjust ewma_latency_ms without incrementing fail_count
            if latency_ms is not None and latency_ms > 0:
                info["ewma_latency_ms"] = 0.3 * latency_ms + 0.7 * info["ewma_latency_ms"]
            else:
                info["ewma_latency_ms"] = info["ewma_latency_ms"] * 1.15

    def select_healthy_hosts(self, target_host: str, cdn_mode: str = "mainland", count: int = 4) -> list:
        with self.lock:
            now = time.time()
            candidate_hosts = []
            if target_host:
                candidate_hosts.append(target_host)

            if (target_host and target_host in OVERSEAS_HOSTS) or cdn_mode == "overseas":
                for h in OVERSEAS_HOSTS:
                    if h not in candidate_hosts:
                        candidate_hosts.append(h)
                for h in MAINLAND_HOSTS[:2]:
                    if h not in candidate_hosts:
                        candidate_hosts.append(h)
            elif (target_host and target_host in LIVE_HOSTS) or cdn_mode == "live":
                for h in LIVE_HOSTS:
                    if h not in candidate_hosts:
                        candidate_hosts.append(h)
            else:
                for h in MAINLAND_HOSTS:
                    if h not in candidate_hosts:
                        candidate_hosts.append(h)
                for h in OVERSEAS_HOSTS[:2]:
                    if h not in candidate_hosts:
                        candidate_hosts.append(h)

            healthy = [h for h in candidate_hosts if now >= self.hosts.get(h, {}).get("cooldown_until", 0.0)]
            if not healthy:
                healthy = candidate_hosts

            is_target_healthy = target_host and (target_host in healthy) and (now >= self.hosts.get(target_host, {}).get("cooldown_until", 0.0))

            other_healthy = [h for h in healthy if h != target_host]
            other_healthy.sort(key=lambda h: self.hosts.get(h, {}).get("ewma_latency_ms", 999.0))

            if is_target_healthy:
                res = [target_host] + other_healthy
            else:
                healthy.sort(key=lambda h: self.hosts.get(h, {}).get("ewma_latency_ms", 999.0))
                res = healthy

            return res[:count]

    def get_healthy_hosts_list(self) -> list:
        with self.lock:
            now = time.time()
            healthy = [h for h, info in self.hosts.items() if now >= info.get("cooldown_until", 0.0)]
            healthy.sort(key=lambda h: self.hosts[h].get("ewma_latency_ms", 999.0))
            return healthy

health_tracker = NodeHealthTracker()

class DynamicThreadController:
    def __init__(self, requested_threads: int, auto_threads: bool = True, is_audio: bool = False):
        self.requested_threads = requested_threads
        self.is_audio = is_audio
        self.auto_threads = auto_threads and not is_audio
        if self.is_audio:
            self.current_concurrency = min(requested_threads, 4)
            self.max_concurrency = min(requested_threads, 4)
        elif self.auto_threads:
            self.max_concurrency = min(requested_threads, 24)
            self.current_concurrency = min(4, self.max_concurrency)
        else:
            self.current_concurrency = requested_threads
            self.max_concurrency = requested_threads

        self.lock = threading.Lock()
        self.metrics_window = collections.deque(maxlen=10)
        self.completed_chunks = 0

    def record_chunk(self, ttfb: float, is_error: bool):
        if not self.auto_threads:
            return
        with self.lock:
            self.metrics_window.append((ttfb, is_error))
            self.completed_chunks += 1
            if is_error:
                min_c = min(4, self.max_concurrency)
                self.current_concurrency = max(min_c, self.current_concurrency // 2)
                return
            if self.completed_chunks % 2 == 0 and len(self.metrics_window) > 0:
                has_error = any(err for _, err in self.metrics_window)
                avg_ttfb = sum(t for t, _ in self.metrics_window) / len(self.metrics_window)
                if avg_ttfb < 0.8 and not has_error:
                    self.current_concurrency = min(self.max_concurrency, self.current_concurrency + 2)
                elif avg_ttfb > 1.8 or has_error:
                    min_c = min(4, self.max_concurrency)
                    self.current_concurrency = max(min_c, self.current_concurrency // 2)

    def get_concurrency(self) -> int:
        with self.lock:
            return self.current_concurrency

class EngineStats:
    def __init__(self):
        self.lock = threading.Lock()
        self.active_threads = 0
        self.target_concurrency = 4
        self.auto_threads = True
        self.speed_history = collections.deque(maxlen=60)

    def inc_active_threads(self):
        with self.lock:
            self.active_threads += 1

    def dec_active_threads(self):
        with self.lock:
            self.active_threads = max(0, self.active_threads - 1)

    def reset_active(self):
        with self.lock:
            self.active_threads = 0
            self.target_concurrency = 4

    def set_target_concurrency(self, val: int):
        with self.lock:
            self.target_concurrency = val

    def set_auto_threads(self, val: bool):
        with self.lock:
            self.auto_threads = val

    def record_bytes(self, nbytes: int):
        now = time.time()
        with self.lock:
            self.speed_history.append((now, nbytes))

    def get_speed_mbps(self) -> float:
        now = time.time()
        with self.lock:
            while self.speed_history and (now - self.speed_history[0][0] > 3.0):
                self.speed_history.popleft()
            if not self.speed_history:
                return 0.0
            total_bytes = sum(b for _, b in self.speed_history)
            duration = max(0.5, now - self.speed_history[0][0])
            mbps = (total_bytes * 8.0) / (duration * 1e6)
            return round(mbps, 2)

    def get_status(self, healthy_nodes: list) -> dict:
        with self.lock:
            active = self.active_threads
            target_c = self.target_concurrency
            auto_t = self.auto_threads
        return {
            "active_threads": active,
            "target_concurrency": target_c,
            "speed_mbps": self.get_speed_mbps(),
            "healthy_nodes": healthy_nodes,
            "auto_threads": auto_t,
        }

engine_stats = EngineStats()

def get_adaptive_chunk_size(c_idx: int) -> int:
    if c_idx < 4:
        return 256 * 1024
    elif c_idx < 12:
        return 512 * 1024
    else:
        return 1024 * 1024

def get_url_cache_key(url: str) -> str:
    try:
        parsed = urllib.parse.urlparse(url)
        return parsed.path
    except Exception:
        return url

def is_live_url(url: str) -> bool:
    try:
        parsed = urllib.parse.urlparse(url)
        host = (parsed.hostname or "").lower()
        path = parsed.path.lower()
        if "live-bvc" in host or "gotcha" in host or "/live" in path or "live.bilibili.com" in host:
            return True
        if "mcdn" in host and ("/live" in path or "bvc" in path):
            return True
    except Exception:
        pass
    return False

def is_relay_url(url: str) -> bool:
    try:
        parsed = urllib.parse.urlparse(url)
        if re.search(r'(?:^|\.)mcdn\.', parsed.hostname or '', re.I):
            return True
        if parsed.path.startswith('/v1/resource/'):
            return True
        qs = urllib.parse.parse_qs(parsed.query)
        if qs.get('os', [''])[0].lower() == 'mcdn':
            return True
    except Exception:
        pass
    return False

def swap_node(raw_url: str, target_host: str) -> str:
    if not raw_url:
        return raw_url
    try:
        parsed = urllib.parse.urlparse(raw_url)
        if parsed.hostname in ("127.0.0.1", "localhost"):
            return raw_url

        # B站直播串流優化：若為 live 串流或 PCDN (mcdn)，自動導向官方低延遲直播邊緣節點
        if is_live_url(raw_url):
            live_host = target_host if target_host in LIVE_HOSTS else LIVE_HOSTS[0]
            qs = urllib.parse.parse_qs(parsed.query)
            for p2p_key in ["os", "p2p_type", "backup_url", "p2p"]:
                qs.pop(p2p_key, None)
            clean_query = urllib.parse.urlencode(qs, doseq=True)
            return urllib.parse.urlunparse((
                "https",
                live_host,
                parsed.path,
                parsed.params,
                clean_query,
                parsed.fragment
            ))

        if not target_host or is_relay_url(raw_url):
            return raw_url

        # Akamai requires hdnts HMAC token; fallback to Alibaba mirror if token absent
        if "akamaized.net" in target_host.lower() and "hdnts=" not in raw_url:
            target_host = MAINLAND_HOSTS[0]
        netloc = target_host.lower()
        return urllib.parse.urlunparse((
            parsed.scheme or "https",
            netloc,
            parsed.path,
            parsed.params,
            parsed.query,
            parsed.fragment
        ))
    except Exception:
        return raw_url

def probe_node(host: str, timeout: float = 1.2) -> dict:
    url = f"https://{host}/"
    req = urllib.request.Request(url, headers=DEFAULT_HEADERS)
    t0 = time.perf_counter()
    status = "error"
    latency = 9999.0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            latency = (time.perf_counter() - t0) * 1000.0
            status = "ok"
    except urllib.error.HTTPError as e:
        # Bilibili UPOS root returns 959, 403 or 404, which confirms host is reachable and active
        latency = (time.perf_counter() - t0) * 1000.0
        status = "ok" if e.code in (200, 403, 404, 405, 959) or e.code < 500 else f"http_{e.code}"
    except Exception as e:
        status = f"error: {type(e).__name__}"
    res = {"host": host, "latency_ms": round(latency, 1), "status": status}
    if status == "ok":
        health_tracker.record_probe(host, latency)
    return res

def prewarm_probe():
    try:
        prewarm_hosts = MAINLAND_HOSTS[:3] + OVERSEAS_HOSTS[:2]
        with ThreadPoolExecutor(max_workers=len(prewarm_hosts)) as executor:
            futures = {executor.submit(probe_node, h, 1.2): h for h in prewarm_hosts}
            for f in as_completed(futures):
                try:
                    res = f.result()
                    with probe_cache_lock:
                        probe_cache[res["host"]] = {
                            "latency_ms": res["latency_ms"],
                            "status": res["status"],
                            "ts": time.time(),
                        }
                except Exception:
                    pass
    except Exception:
        pass

def get_probed_fastest_node() -> str:
    healthy = health_tracker.select_healthy_hosts(MAINLAND_HOSTS[0], "mainland", count=1)
    if healthy:
        return healthy[0]
    return MAINLAND_HOSTS[0]

def resolve_host_from_mode(cdn_mode: str) -> str:
    clean_mode = cdn_mode.split(',')[0].split(';')[0].strip()
    if clean_mode == "auto":
        return get_probed_fastest_node()
    if clean_mode in MAINLAND_HOSTS or clean_mode in OVERSEAS_HOSTS:
        return clean_mode
    if clean_mode == "overseas":
        return OVERSEAS_HOSTS[0]
    return MAINLAND_HOSTS[0]

def probe_upstream_metadata(target_url: str, target_host: str):
    cache_key = get_url_cache_key(target_url)
    with file_info_cache_lock:
        if cache_key in file_info_cache:
            entry = file_info_cache[cache_key]
            if time.time() - entry["ts"] < FILE_INFO_CACHE_TTL:
                file_info_cache.move_to_end(cache_key)
                return {"total_size": entry["total_size"], "content_type": entry["content_type"]}
            else:
                del file_info_cache[cache_key]

    total_size = None
    content_type = "video/mp4"

    candidate_hosts = health_tracker.select_healthy_hosts(target_host, "auto", count=4)

    for host in candidate_hosts:
        h_url = swap_node(target_url, host)
        probe_req = urllib.request.Request(
            h_url,
            headers={**DEFAULT_HEADERS, "Range": "bytes=0-0"}
        )
        try:
            with urllib.request.urlopen(probe_req, timeout=3.5) as resp:
                content_type = resp.headers.get("Content-Type", "video/mp4")
                cr = resp.headers.get("Content-Range")
                if cr:
                    m = re.match(r"bytes\s+\d+-\d+/(\d+)", cr)
                    if m:
                        total_size = int(m.group(1))
                        break
        except Exception:
            continue

    if total_size is not None:
        info = {
            "total_size": total_size,
            "content_type": content_type,
            "ts": time.time(),
        }
        with file_info_cache_lock:
            if len(file_info_cache) >= FILE_INFO_CACHE_MAX_ENTRIES:
                file_info_cache.popitem(last=False)
            file_info_cache[cache_key] = info
        return {"total_size": total_size, "content_type": content_type}

    return None

class BTRStreamingHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        if os.environ.get("BTR_DEBUG") == "1":
            sys.stderr.write(f"[btr_engine] {format % args}\n")

    def do_HEAD(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/ping":
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            return

        if path == "/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            return

        if path == "/stream":
            raw_urls = query.get("url", [])
            if not raw_urls:
                self.send_response(400)
                self.end_headers()
                return
            target_url = raw_urls[0]
            if not is_allowed_upstream_url(target_url):
                self.send_response(403)
                self.end_headers()
                return
            cdn_mode = query.get("cdn", ["mainland"])[0]
            target_host = resolve_host_from_mode(cdn_mode)

            meta = probe_upstream_metadata(target_url, target_host)
            if meta:
                self.send_response(200)
                self.send_header("Content-Type", meta["content_type"])
                self.send_header("Content-Length", str(meta["total_size"]))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                return

            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/shutdown":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"OK")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return

        if path == "/ping":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"OK")
            return

        if path == "/status":
            healthy_nodes = health_tracker.get_healthy_hosts_list()
            status_data = engine_stats.get_status(healthy_nodes)
            data = json.dumps(status_data, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/probe":
            results = []
            allowed_probe_hosts = set(MAINLAND_HOSTS + OVERSEAS_HOSTS + LIVE_HOSTS)
            raw_hosts = query.get("hosts", [])
            if not raw_hosts:
                hosts = MAINLAND_HOSTS + OVERSEAS_HOSTS
            else:
                hosts = [h.strip() for h in raw_hosts[0].split(",") if h.strip() in allowed_probe_hosts]
                if not hosts:
                    hosts = MAINLAND_HOSTS + OVERSEAS_HOSTS

            with ThreadPoolExecutor(max_workers=max(1, len(hosts))) as executor:
                futures = {executor.submit(probe_node, h, 1.2): h for h in hosts}
                for f in as_completed(futures):
                    res = f.result()
                    results.append(res)
                    with probe_cache_lock:
                        probe_cache[res["host"]] = {
                            "latency_ms": res["latency_ms"],
                            "status": res["status"],
                            "ts": time.time(),
                        }
            results.sort(key=lambda x: (0 if x["status"] == "ok" else 1, x["latency_ms"]))
            data = json.dumps(results, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/stream":
            self.handle_stream(query)
            return

        self.send_response(404)
        self.end_headers()

    def handle_stream(self, query):
        raw_urls = query.get("url", [])
        if not raw_urls:
            self.send_response(400)
            self.end_headers()
            return
        target_url = raw_urls[0]
        if not is_allowed_upstream_url(target_url):
            self.send_response(403)
            self.end_headers()
            return

        cdn_mode = query.get("cdn", ["mainland"])[0]
        target_host = resolve_host_from_mode(cdn_mode)

        try:
            threads = int(query.get("threads", ["32"])[0].split(',')[0].split(';')[0])
        except Exception:
            threads = 32
        threads = max(1, min(64, threads))

        auto_threads_raw = query.get("auto_threads", ["1"])[0].split(',')[0].split(';')[0].strip().lower()
        auto_threads = auto_threads_raw not in ("0", "false", "no", "off")

        is_thumb = query.get("thumb", ["0"])[0].split(',')[0].split(';')[0] == "1" or threads <= 1

        # Parse requested Range header from MPV client
        range_header = self.headers.get("Range")
        req_start = 0
        req_end = None
        has_range = False

        if range_header:
            match = re.match(r"bytes=(\d+)-(\d*)", range_header.strip())
            if match:
                has_range = True
                req_start = int(match.group(1))
                if match.group(2):
                    req_end = int(match.group(2))

        meta = probe_upstream_metadata(target_url, target_host)
        if not meta or not meta.get("total_size"):
            # Fallback to direct single stream proxy if total_size cannot be determined
            stream_url = swap_node(target_url, target_host)
            self.stream_direct_passthrough(stream_url, range_header)
            return

        total_size = meta["total_size"]
        content_type = meta["content_type"]

        if req_end is None or req_end >= total_size:
            req_end = total_size - 1

        content_len = max(0, req_end - req_start + 1)

        try:
            if has_range:
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {req_start}-{req_end}/{total_size}")
            else:
                self.send_response(200)

            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(content_len))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError):
            return

        active_hosts = health_tracker.select_healthy_hosts(target_host, cdn_mode, count=4)

        # Audio / small file rate limiting:
        # If total_size <= 20 MB (audio tracks or short clips), cap max threads and prefetch window to min(threads, 4).
        is_audio_or_small = (total_size <= 20 * 1024 * 1024) or ("audio" in content_type.lower())
        if is_audio_or_small:
            threads = min(threads, 4)
            prefetch_window = min(threads, 4)
        else:
            prefetch_window = min(max(threads, 4), 32)

        # For small requests or thumbnailer seeks (thumb=1 / threads=1), bypass thread pool
        # so seekbar scrubbing never spawns threads or prefetches unnecessary chunks.
        if content_len <= 256 * 1024 or is_thumb:
            for host in active_hosts[:3]:
                cur_url = swap_node(target_url, host)
                for _hop in range(3):
                    parsed = urllib.parse.urlparse(cur_url)
                    scheme = parsed.scheme or "https"
                    h_name = parsed.hostname
                    port = parsed.port
                    path_query = parsed.path or "/"
                    if parsed.query:
                        path_query += "?" + parsed.query
                    headers = dict(DEFAULT_HEADERS)
                    headers["Range"] = f"bytes={req_start}-{req_end}"
                    headers["Connection"] = "keep-alive"
                    conn, pool_key = http_pool.get_connection(scheme, h_name, port)
                    try:
                        conn.request("GET", path_query, headers=headers)
                        resp = conn.getresponse()
                        if resp.status in (200, 206):
                            while chunk := resp.read(64 * 1024):
                                self.wfile.write(chunk)
                                engine_stats.record_bytes(len(chunk))
                            http_pool.release_connection(pool_key, conn, close=False)
                            return
                        elif resp.status in (301, 302, 307, 308):
                            loc = resp.getheader("Location") or (resp.headers.get("Location") if resp.headers else None)
                            try:
                                resp.read()
                                drained = True
                            except Exception:
                                drained = False
                            http_pool.release_connection(pool_key, conn, close=not drained)
                            if loc:
                                redir_url = urllib.parse.urljoin(cur_url, loc)
                                if is_allowed_upstream_url(redir_url):
                                    cur_url = redir_url
                                    continue
                            break
                        else:
                            try:
                                resp.read()
                            except Exception:
                                pass
                            http_pool.release_connection(pool_key, conn, close=True)
                            break
                    except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError):
                        http_pool.release_connection(pool_key, conn, close=True)
                        return
                    except Exception:
                        http_pool.release_connection(pool_key, conn, close=True)
                        break
            return

        controller = DynamicThreadController(
            requested_threads=threads,
            auto_threads=auto_threads,
            is_audio=is_audio_or_small
        )
        engine_stats.set_auto_threads(controller.auto_threads)
        engine_stats.set_target_concurrency(controller.get_concurrency())

        # Adaptive chunk sizes:
        # c_idx < 4: 256 KB, 4 <= c_idx < 12: 512 KB, c_idx >= 12: 1 MB
        chunks = []
        cur = req_start
        c_idx = 0
        while cur <= req_end:
            c_size = get_adaptive_chunk_size(c_idx)
            chunk_end = min(cur + c_size - 1, req_end)
            chunks.append((c_idx, cur, chunk_end))
            cur = chunk_end + 1
            c_idx += 1

        downloaded = {}
        completed_c_idxs = set()
        in_flight_chunks = {}
        active_tasks = 0
        download_lock = threading.Lock()
        download_cond = threading.Condition(download_lock)
        stop_event = threading.Event()
        next_to_submit = 0
        consumer_idx = 0

        def get_next_submissions():
            # Must be called under download_cond
            nonlocal next_to_submit, active_tasks
            to_sub = []
            target_c = controller.get_concurrency()
            engine_stats.set_target_concurrency(target_c)
            while not stop_event.is_set() and next_to_submit < len(chunks):
                if (next_to_submit - consumer_idx) >= prefetch_window:
                    break
                if active_tasks >= target_c:
                    break
                c_i, c_s, c_e = chunks[next_to_submit]
                next_to_submit += 1
                active_tasks += 1
                in_flight_chunks[c_i] = in_flight_chunks.get(c_i, 0) + 1
                to_sub.append((c_i, c_s, c_e))
            return to_sub

        def fetch_chunk(c_idx, c_start, c_end, preferred_host=None, is_hedged=False):
            stats_inc = False
            try:
                if stop_event.is_set():
                    return
                with download_lock:
                    if c_idx in completed_c_idxs or stop_event.is_set():
                        return
                engine_stats.inc_active_threads()
                stats_inc = True
                if preferred_host:
                    candidate_hosts = [preferred_host] + [h for h in active_hosts if h != preferred_host]
                else:
                    start_node_idx = c_idx % len(active_hosts)
                    candidate_hosts = [active_hosts[(start_node_idx + i) % len(active_hosts)] for i in range(len(active_hosts))]

                for _attempt in range(2):
                    for host in candidate_hosts:
                        if stop_event.is_set():
                            return
                        with download_lock:
                            if c_idx in completed_c_idxs:
                                return
                        cur_url = swap_node(target_url, host)
                        for _hop in range(3):
                            if stop_event.is_set():
                                return
                            with download_lock:
                                if c_idx in completed_c_idxs:
                                    return
                            parsed = urllib.parse.urlparse(cur_url)
                            scheme = parsed.scheme or "https"
                            h_name = parsed.hostname
                            port = parsed.port
                            path_query = parsed.path or "/"
                            if parsed.query:
                                path_query += "?" + parsed.query

                            headers = dict(DEFAULT_HEADERS)
                            headers["Range"] = f"bytes={c_start}-{c_end}"
                            headers["Connection"] = "keep-alive"

                            conn, pool_key = http_pool.get_connection(scheme, h_name, port)
                            t_req_start = time.perf_counter()
                            ttfb = None
                            try:
                                conn.request("GET", path_query, headers=headers)
                                resp = conn.getresponse()
                                ttfb = time.perf_counter() - t_req_start

                                if resp.status in (200, 206):
                                    buf = bytearray()
                                    while not stop_event.is_set():
                                        with download_lock:
                                            if c_idx in completed_c_idxs:
                                                break
                                        piece = resp.read(128 * 1024)
                                        if not piece:
                                            break
                                        buf.extend(piece)
                                        engine_stats.record_bytes(len(piece))

                                    if stop_event.is_set():
                                        http_pool.release_connection(pool_key, conn, close=True)
                                        return

                                    expected_bytes = c_end - c_start + 1
                                    if len(buf) == expected_bytes:
                                        http_pool.release_connection(pool_key, conn, close=False)
                                        t_total = time.perf_counter() - t_req_start
                                        speed_mbps = (expected_bytes * 8.0) / (max(0.001, t_total) * 1e6)

                                        with download_cond:
                                            if c_idx in completed_c_idxs:
                                                is_winner = False
                                            else:
                                                is_winner = True
                                                completed_c_idxs.add(c_idx)
                                                downloaded[c_idx] = bytes(buf)
                                                download_cond.notify_all()

                                        if is_winner:
                                            health_tracker.record_success(host, latency_ms=ttfb * 1000.0, speed_mbps=speed_mbps)
                                            controller.record_chunk(ttfb=ttfb, is_error=False)
                                        else:
                                            health_tracker.record_hedge_loser(host, latency_ms=ttfb * 1000.0)
                                        return
                                    else:
                                        http_pool.release_connection(pool_key, conn, close=True)
                                        with download_lock:
                                            if c_idx in completed_c_idxs:
                                                return
                                        health_tracker.record_failure(host)
                                        controller.record_chunk(ttfb=ttfb or 3.5, is_error=True)
                                        break

                                elif resp.status in (301, 302, 307, 308):
                                    loc = resp.getheader("Location") or (resp.headers.get("Location") if resp.headers else None)
                                    try:
                                        resp.read()
                                        drained = True
                                    except Exception:
                                        drained = False
                                    http_pool.release_connection(pool_key, conn, close=not drained)
                                    if loc:
                                        redir_url = urllib.parse.urljoin(cur_url, loc)
                                        if is_allowed_upstream_url(redir_url):
                                            cur_url = redir_url
                                            continue
                                    break
                                else:
                                    try:
                                        resp.read()
                                    except Exception:
                                        pass
                                    http_pool.release_connection(pool_key, conn, close=True)
                                    health_tracker.record_failure(host)
                                    controller.record_chunk(ttfb=ttfb or 3.5, is_error=True)
                                    break
                            except Exception:
                                http_pool.release_connection(pool_key, conn, close=True)
                                with download_lock:
                                    if c_idx not in completed_c_idxs:
                                        health_tracker.record_failure(host)
                                        controller.record_chunk(ttfb=3.5, is_error=True)
                                break
            finally:
                if stats_inc:
                    engine_stats.dec_active_threads()
                to_schedule = []
                with download_cond:
                    nonlocal active_tasks
                    active_tasks -= 1
                    in_flight_chunks[c_idx] = in_flight_chunks.get(c_idx, 1) - 1
                    if in_flight_chunks[c_idx] <= 0:
                        in_flight_chunks.pop(c_idx, None)
                        if c_idx not in completed_c_idxs and c_idx not in downloaded:
                            downloaded[c_idx] = None
                            download_cond.notify_all()
                    to_schedule = get_next_submissions()

                for c_i, c_s, c_e in to_schedule:
                    executor.submit(fetch_chunk, c_i, c_s, c_e)

        max_workers = min(threads, 24) if controller.auto_threads else threads
        if is_audio_or_small:
            max_workers = min(threads, 4)
        executor = ThreadPoolExecutor(max_workers=max(4, max_workers))

        # Initial window ramp-up: submit only first 4 chunks
        initial_submissions = []
        with download_cond:
            initial_submissions = get_next_submissions()

        for c_i, c_s, c_e in initial_submissions:
            executor.submit(fetch_chunk, c_i, c_s, c_e)

        try:
            for c_idx, c_start, c_end in chunks:
                to_sub = []
                with download_cond:
                    consumer_idx = c_idx
                    to_sub = get_next_submissions()

                for c_i, c_s, c_e in to_sub:
                    executor.submit(fetch_chunk, c_i, c_s, c_e)

                threshold = 0.8 if c_idx < 4 else 1.5
                wait_start = time.perf_counter()
                hedged_dispatched = False

                with download_cond:
                    while c_idx not in downloaded and not stop_event.is_set():
                        time_waited = time.perf_counter() - wait_start
                        wait_time = max(0.01, threshold - time_waited) if not hedged_dispatched else 0.1
                        download_cond.wait(timeout=wait_time)

                        if c_idx in downloaded or stop_event.is_set():
                            break

                        time_waited = time.perf_counter() - wait_start
                        if not hedged_dispatched and time_waited >= threshold:
                            hedged_dispatched = True
                            # Dispatch backup hedged request to next healthy CDN node
                            primary_host = active_hosts[c_idx % len(active_hosts)]
                            backup_host = None
                            for h in active_hosts:
                                if h != primary_host:
                                    backup_host = h
                                    break
                            if not backup_host:
                                all_h = health_tracker.get_healthy_hosts_list()
                                for h in all_h:
                                    if h != primary_host:
                                        backup_host = h
                                        break
                            if not backup_host:
                                backup_host = primary_host

                            active_tasks += 1
                            in_flight_chunks[c_idx] = in_flight_chunks.get(c_idx, 0) + 1
                            executor.submit(fetch_chunk, c_idx, c_start, c_end, backup_host, True)

                    if stop_event.is_set():
                        break

                    chunk_data = downloaded.pop(c_idx, None)

                if chunk_data is None:
                    # Chunk retrieval failed after all retries and hedges
                    break

                self.wfile.write(chunk_data)

                to_sub = []
                with download_cond:
                    to_sub = get_next_submissions()

                for c_i, c_s, c_e in to_sub:
                    executor.submit(fetch_chunk, c_i, c_s, c_e)

        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError):
            pass
        finally:
            stop_event.set()
            with download_cond:
                download_cond.notify_all()
            executor.shutdown(wait=False, cancel_futures=True)

    def stream_direct_passthrough(self, stream_url, range_header):
        headers = dict(DEFAULT_HEADERS)
        if range_header:
            headers["Range"] = range_header
        req = urllib.request.Request(stream_url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ["content-type", "content-length", "content-range", "accept-ranges"]:
                        self.send_header(k, v)
                self.end_headers()
                while chunk := resp.read(128 * 1024):
                    self.wfile.write(chunk)
                    engine_stats.record_bytes(len(chunk))
        except Exception:
            pass

class ReusableThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        exc_type, exc_value, _ = sys.exc_info()
        if exc_type in (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            return
        # Suppress other benign client disconnects
        if isinstance(exc_value, OSError) and getattr(exc_value, 'winerror', None) in (10054, 10053):
            return
        super().handle_error(request, client_address)

def run_server(port=0, parent_pid=None):
    server = ReusableThreadingServer(("127.0.0.1", port), BTRStreamingHandler)
    actual_port = server.server_address[1]

    # Write port file (isolated per parent_pid if available)
    temp_dir = os.environ.get("TEMP") or os.environ.get("TMP") or "."
    if parent_pid:
        port_file = os.path.join(temp_dir, f"mpv_btr_port_{parent_pid}.txt")
    else:
        port_file = os.path.join(temp_dir, "mpv_btr_port.txt")

    with open(port_file, "w", encoding="utf-8") as f:
        f.write(str(actual_port))

    print(f"BTR Engine listening on 127.0.0.1:{actual_port}", flush=True)

    # Trigger background light pre-warm probe on server startup
    threading.Thread(target=prewarm_probe, daemon=True).start()

    # Monitor parent PID with Win32 WaitForSingleObject
    if parent_pid:
        def check_parent():
            import ctypes
            SYNCHRONIZE = 0x00100000
            WAIT_TIMEOUT = 0x00000102
            while True:
                time.sleep(1.5)
                try:
                    handle = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE, False, parent_pid)
                    if not handle:
                        os._exit(0)
                    res = ctypes.windll.kernel32.WaitForSingleObject(handle, 0)
                    ctypes.windll.kernel32.CloseHandle(handle)
                    if res != WAIT_TIMEOUT:
                        os._exit(0)
                except Exception:
                    os._exit(0)
        threading.Thread(target=check_parent, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            os.remove(port_file)
        except Exception:
            pass

if __name__ == "__main__":
    port_arg = 0
    pid_arg = None
    for i, a in enumerate(sys.argv):
        if a == "--port" and i + 1 < len(sys.argv):
            port_arg = int(sys.argv[i + 1])
        elif a == "--parent-pid" and i + 1 < len(sys.argv):
            pid_arg = int(sys.argv[i + 1])
    run_server(port=port_arg, parent_pid=pid_arg)
