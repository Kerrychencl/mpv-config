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
    def __init__(self, maxsize_per_host=32, timeout=6.0):
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

http_pool = HTTPConnectionPool(maxsize_per_host=32, timeout=6.0)

# Cache for probe results: {host: {"latency_ms": float, "status": str, "ts": float}}
probe_cache = {}
probe_cache_lock = threading.Lock()

# Cache for stream metadata: {url_key: {"total_size": int, "content_type": str, "ts": float}}
FILE_INFO_CACHE_TTL = 600.0
FILE_INFO_CACHE_MAX_ENTRIES = 128
file_info_cache = collections.OrderedDict()
file_info_cache_lock = threading.Lock()

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

def probe_node(host: str, timeout: float = 2.0) -> dict:
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
    return {"host": host, "latency_ms": round(latency, 1), "status": status}

def get_probed_fastest_node() -> str:
    now = time.time()
    valid = []
    with probe_cache_lock:
        for host in MAINLAND_HOSTS:
            if host in probe_cache and (now - probe_cache[host]["ts"] < 120):
                if probe_cache[host]["status"] == "ok":
                    valid.append((probe_cache[host]["latency_ms"], host))
    if valid:
        valid.sort()
        return valid[0][1]
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

    candidate_hosts = [target_host]
    if target_host in OVERSEAS_HOSTS:
        candidate_hosts += [h for h in OVERSEAS_HOSTS if h != target_host]
        candidate_hosts += MAINLAND_HOSTS[:2]
    elif target_host in LIVE_HOSTS:
        candidate_hosts += [h for h in LIVE_HOSTS if h != target_host]
    else:
        candidate_hosts += [h for h in MAINLAND_HOSTS if h != target_host]

    for host in candidate_hosts[:4]:
        h_url = swap_node(target_url, host)
        probe_req = urllib.request.Request(
            h_url,
            headers={**DEFAULT_HEADERS, "Range": "bytes=0-0"}
        )
        try:
            with urllib.request.urlopen(probe_req, timeout=5) as resp:
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
                futures = {executor.submit(probe_node, h): h for h in hosts}
                for f in as_completed(futures):
                    res = f.result()
                    results.append(res)
                    with probe_cache_lock:
                        probe_cache[res["host"]] = {
                            "latency_ms": res["latency_ms"],
                            "status": res["status"],
                            "ts": time.time()
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
        stream_url = swap_node(target_url, target_host)

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
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            return

        CHUNK_SIZE = 1024 * 1024  # 1 MB chunks

        # Fallback host list
        candidate_hosts = [target_host]
        if target_host in OVERSEAS_HOSTS:
            candidate_hosts += [h for h in OVERSEAS_HOSTS if h != target_host]
            candidate_hosts += MAINLAND_HOSTS[:2]
        elif target_host in LIVE_HOSTS:
            candidate_hosts += [h for h in LIVE_HOSTS if h != target_host]
        else:
            candidate_hosts += [h for h in MAINLAND_HOSTS if h != target_host]

        active_hosts = candidate_hosts[:4]

        # For small requests or thumbnailer seeks (thumb=1 / threads=1), bypass thread pool
        # so seekbar scrubbing never spawns 32 threads or prefetches 64MB per keyframe seek.
        if content_len <= CHUNK_SIZE or is_thumb:
            for host in candidate_hosts[:3]:
                req_url = swap_node(target_url, host)
                parsed = urllib.parse.urlparse(req_url)
                scheme = parsed.scheme or "https"
                h_name = parsed.hostname
                port = parsed.port
                path_query = parsed.path
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
                        http_pool.release_connection(pool_key, conn, close=False)
                        return
                    else:
                        resp.read()
                        http_pool.release_connection(pool_key, conn, close=True)
                except Exception:
                    http_pool.release_connection(pool_key, conn, close=True)
                    continue
            return

        # Multi-threaded chunk downloading with bounded sliding prefetch window
        chunks = []
        cur = req_start
        idx = 0
        while cur <= req_end:
            chunk_end = min(cur + CHUNK_SIZE - 1, req_end)
            chunks.append((idx, cur, chunk_end))
            cur = chunk_end + 1
            idx += 1

        # Buffer and queue
        downloaded = {}
        download_lock = threading.Lock()
        download_cond = threading.Condition(download_lock)
        stop_event = threading.Event()

        def fetch_chunk(c_idx, c_start, c_end):
            if stop_event.is_set():
                return
            # Multi-node round-robin: distribute start node by c_idx % len(active_hosts)
            start_node_idx = c_idx % len(active_hosts)
            ordered_hosts = [active_hosts[(start_node_idx + i) % len(active_hosts)] for i in range(len(active_hosts))]

            for _attempt in range(2):
                for host in ordered_hosts:
                    if stop_event.is_set():
                        return
                    h_url = swap_node(target_url, host)
                    parsed = urllib.parse.urlparse(h_url)
                    scheme = parsed.scheme or "https"
                    h_name = parsed.hostname
                    port = parsed.port
                    path_query = parsed.path
                    if parsed.query:
                        path_query += "?" + parsed.query

                    headers = dict(DEFAULT_HEADERS)
                    headers["Range"] = f"bytes={c_start}-{c_end}"
                    headers["Connection"] = "keep-alive"

                    conn, pool_key = http_pool.get_connection(scheme, h_name, port)
                    try:
                        conn.request("GET", path_query, headers=headers)
                        resp = conn.getresponse()
                        if resp.status in (200, 206):
                            buf = bytearray()
                            while not stop_event.is_set():
                                piece = resp.read(128 * 1024)
                                if not piece:
                                    break
                                buf.extend(piece)
                            if stop_event.is_set():
                                http_pool.release_connection(pool_key, conn, close=True)
                                return
                            if len(buf) == (c_end - c_start + 1):
                                http_pool.release_connection(pool_key, conn, close=False)
                                with download_cond:
                                    downloaded[c_idx] = bytes(buf)
                                    download_cond.notify_all()
                                return
                            else:
                                http_pool.release_connection(pool_key, conn, close=True)
                        else:
                            try:
                                resp.read()
                            except Exception:
                                pass
                            http_pool.release_connection(pool_key, conn, close=True)
                    except Exception:
                        http_pool.release_connection(pool_key, conn, close=True)
                        continue

            # Mark chunk as failed to prevent consumer from hanging
            with download_cond:
                downloaded[c_idx] = None
                download_cond.notify_all()

        # Bounded prefetch window: cap at 32 chunks in flight (~32 MB max)
        PREFETCH_WINDOW = min(max(threads, 4), 32)
        executor = ThreadPoolExecutor(max_workers=threads)
        next_to_submit = 0

        # Prime the sliding window
        while next_to_submit < min(len(chunks), PREFETCH_WINDOW):
            c = chunks[next_to_submit]
            executor.submit(fetch_chunk, c[0], c[1], c[2])
            next_to_submit += 1

        try:
            for c_idx, _, _ in chunks:
                with download_cond:
                    while c_idx not in downloaded and not stop_event.is_set():
                        download_cond.wait(timeout=0.1)
                    if stop_event.is_set():
                        break
                    chunk_data = downloaded.pop(c_idx)

                if chunk_data is None:
                    # Chunk retrieval failed after retries, terminate chunk loop gracefully
                    break

                self.wfile.write(chunk_data)

                # Submit next chunk into the sliding window
                if next_to_submit < len(chunks):
                    c = chunks[next_to_submit]
                    executor.submit(fetch_chunk, c[0], c[1], c[2])
                    next_to_submit += 1

        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
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