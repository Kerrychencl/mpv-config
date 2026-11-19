-- Bilibili Thread Ripper (BTR) for MPV
-- 專門解決海外用戶播放 B 站卡頓、緩衝慢問題
-- 移植與深度重構自 https://github.com/MrTangLuyao/Bilibili-thread-ripper
--
-- 特性：
-- 1. 深度還原 BTR 官方 UI 視覺設計（主面板與高級設置四分頁面板）
-- 2. 智慧 CDN 鏡像劫持重定向 (大陸阿里雲 / 騰訊雲 / 華為雲 / 百度雲 / 智慧優選 / 海外)
-- 3. 執行緒撕裂者多線程併發分塊加速引擎 (Multi-threaded Range Streaming Engine)
-- 4. B站直播 (live.bilibili.com) 自動攔截 P2P/PCDN (mcdn) 並無縫改寫為官方低延遲直播邊緣節點
-- 5. EDL 多軌串流自動改寫 (無縫支援 1080P/4K/8K 視訊軌與多音訊軌)
-- 6. Windows 原生食指指標 (IDC_HAND)、Hover 高亮、設定自動持久化

local mp = require 'mp'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

local script_name = "btr"
local mpv_root = mp.command_native({"expand-path", "~~/"})
local settings_file = utils.join_path(mpv_root, "btr_settings.json")
local engine_script = utils.join_path(utils.join_path(mpv_root, "scripts"), "btr/btr_engine.py")

local function get_python()
    local cand1 = utils.join_path(mpv_root, "../python/python.exe")
    local i1 = utils.file_info(cand1)
    if i1 and i1.is_file then return cand1 end
    local cand2 = utils.join_path(mpv_root, "../python.exe")
    local i2 = utils.file_info(cand2)
    if i2 and i2.is_file then return cand2 end
    return (package.config:sub(1,1) == "\\" and "python" or "python3")
end
local py_cmd = get_python()

-- 預設節點列表
local MAINLAND_HOSTS = {
    { id = "upos-sz-mirrorali.bilivideo.com", name = "大陸 阿里雲", desc = "頻寬充足、海外連線最優推薦" },
    { id = "upos-sz-mirrorcos.bilivideo.com", name = "大陸 騰訊雲", desc = "廣東/上海核心機房" },
    { id = "upos-sz-mirrorhw.bilivideo.com",  name = "大陸 華為雲", desc = "北方/華東優選節點" },
    { id = "upos-sz-mirrorbos.bilivideo.com", name = "大陸 百度雲", desc = "百度雲 CDN 鏡像" },
}

local OVERSEAS_HOSTS = {
    { id = "upos-sz-mirrorcosov.bilivideo.com", name = "海外 騰訊雲", desc = "海外官方邊緣節點" },
    { id = "upos-hz-mirrorakam.akamaized.net",  name = "海外 Akamai", desc = "海外 Akamai 節點" },
}

local LIVE_HOSTS = {
    "d1--cn-gotcha01.bilivideo.com",
    "d1--cn-gotcha04.bilivideo.com",
    "d1--cn-gotcha05.bilivideo.com",
    "d1--cn-gotcha07.bilivideo.com",
}

-- 預設設定
local settings = {
    enabled = true,
    cdn_mode = "mainland", -- "mainland", "auto", "overseas", "original", or specific host
    preferred_host = "upos-sz-mirrorali.bilivideo.com",
    engine_mode = "direct", -- "direct" (兼容模式 / 極速直連) or "ripper" (全接管 / 多線程併發)
    threads = 32,
    auto_threads = true,
    live_acceleration = true,
    osd_notify = true,
    fallback_enabled = true,
    current_tab = "network", -- "network", "buffer", "features", "nodes"
}

-- 載入設定
local function load_settings()
    local f = io.open(settings_file, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local data, err = utils.parse_json(content)
            if data and not err then
                for k, v in pairs(data) do
                    settings[k] = v
                end
            end
        end
    end
end

-- 儲存設定
local function save_settings()
    local f = io.open(settings_file, "w")
    if f then
        f:write(utils.format_json(settings))
        f:close()
    end
end

load_settings()

-- 執行狀態
local runtime = {
    page = "main", -- "main" (圖一主面板) or "advanced" (圖二高級設置面板)
    is_accelerated = false,
    is_live = false,
    original_host = "",
    target_host = "",
    mode_used = "",
    tracks_modified = 0,
    engine_port = 0,
    probe_results = {},
    probing = false,
    original_stream_path = nil,
    live_host_idx = 1,
}

-- 尋找或啟動 btr_engine
local function get_temp_port_file()
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Users\\Administrator\\AppData\\Local\\Temp"
    local pid = utils.getpid and utils.getpid() or 0
    if pid > 0 then
        return utils.join_path(temp_dir, string.format("mpv_btr_port_%d.txt", pid))
    else
        return utils.join_path(temp_dir, "mpv_btr_port.txt")
    end
end

local engine_timer = nil

local function check_port_file()
    local port_file = get_temp_port_file()
    local f = io.open(port_file, "r")
    if f then
        local p_str = f:read("*all")
        f:close()
        local port = tonumber(p_str and p_str:match("%d+"))
        if port and port > 0 then
            runtime.engine_port = port
            return port
        end
    end
    return nil
end

local function launch_engine_async()
    if runtime.engine_port and runtime.engine_port > 0 then
        return runtime.engine_port
    end
    local existing_port = check_port_file()
    if existing_port then
        return existing_port
    end

    local pid = utils.getpid and utils.getpid() or 0
    mp.msg.info("[BTR] 正在異步預加載後台多線程加速引擎: " .. engine_script)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = {py_cmd, engine_script, "--parent-pid", tostring(pid)},
    })

    if engine_timer then
        engine_timer:kill()
        engine_timer = nil
    end

    local attempts = 0
    engine_timer = mp.add_periodic_timer(0.05, function()
        attempts = attempts + 1
        local port = check_port_file()
        if port then
            mp.msg.info("[BTR] 後台加速引擎已在連接埠 " .. port .. " 就緒")
            if engine_timer then
                engine_timer:kill()
                engine_timer = nil
            end
        elseif attempts >= 60 then
            if engine_timer then
                engine_timer:kill()
                engine_timer = nil
            end
        end
    end)
    return nil
end

local function ensure_engine_running()
    if runtime.engine_port and runtime.engine_port > 0 then
        return runtime.engine_port
    end
    local port = check_port_file()
    if port then
        runtime.engine_port = port
        return port
    end
    launch_engine_async()
    return nil
end

-- 並發測速節點
local function probe_all_nodes(callback)
    if runtime.probing then return end
    runtime.probing = true

    local hosts_to_test = {}
    for _, h in ipairs(MAINLAND_HOSTS) do table.insert(hosts_to_test, h.id) end
    for _, h in ipairs(OVERSEAS_HOSTS) do table.insert(hosts_to_test, h.id) end

    local py_code = string.format([[
import urllib.request, time, json
from concurrent.futures import ThreadPoolExecutor, as_completed

hosts = %s
results = {}
headers = {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://www.bilibili.com'}

def probe(h):
    t0 = time.perf_counter()
    status = 'error'
    latency = 9999
    try:
        req = urllib.request.Request(f'https://{h}/', headers=headers)
        with urllib.request.urlopen(req, timeout=1.8) as resp:
            latency = (time.perf_counter() - t0) * 1000
            status = 'ok'
    except urllib.error.HTTPError as e:
        latency = (time.perf_counter() - t0) * 1000
        status = 'ok' if (e.code in (200, 403, 404, 405, 959) or e.code < 500) else f'http_{e.code}'
    except Exception:
        status = 'timeout'
    return h, {'latency_ms': round(latency, 1), 'status': status}

with ThreadPoolExecutor(max_workers=len(hosts)) as pool:
    futures = [pool.submit(probe, h) for h in hosts]
    for f in as_completed(futures):
        h, res = f.result()
        results[h] = res

print(json.dumps(results))
]], utils.format_json(hosts_to_test))

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = {py_cmd, "-c", py_code},
    }, function(success, res)
        runtime.probing = false
        if success and res and res.stdout then
            local data = utils.parse_json(res.stdout)
            if data then
                runtime.probe_results = data
            end
        end
        if callback then callback() end
    end)
end

-- 取得最佳目標節點
local function resolve_target_host(original_host)
    if settings.cdn_mode == "original" then
        return original_host or MAINLAND_HOSTS[3].id
    elseif settings.cdn_mode == "auto" then
        local best_host = nil
        local lowest_ping = 9999
        local all_hosts = {}
        for _, mh in ipairs(MAINLAND_HOSTS) do table.insert(all_hosts, mh.id) end
        for _, oh in ipairs(OVERSEAS_HOSTS) do table.insert(all_hosts, oh.id) end

        for _, hid in ipairs(all_hosts) do
            local info = runtime.probe_results[hid]
            if info and info.status == "ok" and info.latency_ms < lowest_ping then
                lowest_ping = info.latency_ms
                best_host = hid
            end
        end

        if best_host then
            return best_host
        end

        if original_host and original_host ~= "" then
            return original_host
        end
        return MAINLAND_HOSTS[3].id -- 華為雲
    elseif settings.cdn_mode == "overseas" then
        if settings.preferred_host and settings.preferred_host ~= "" and settings.preferred_host ~= "auto" then
            return settings.preferred_host
        end
        return OVERSEAS_HOSTS[1].id
    elseif settings.cdn_mode == "mainland" then
        if settings.preferred_host and settings.preferred_host ~= "" and settings.preferred_host ~= "auto" then
            return settings.preferred_host
        end
        return MAINLAND_HOSTS[3].id
    else
        return settings.preferred_host or settings.cdn_mode or original_host or MAINLAND_HOSTS[3].id
    end
end

-- 判斷 URL 是否為 B 站直播串流
local function is_bili_live_url(url)
    if not url or url == "" then return false end
    local lower = url:lower()
    if lower:find("live%-bvc") or lower:find("gotcha") or lower:find("/live/") or lower:find("/live%-") or lower:find("/live_") or lower:find("live%.bilibili%.com") then
        return true
    end
    if (lower:find("mcdn%.") or lower:find("[?&]os=mcdn")) and (lower:find("/live") or lower:find("live_") or lower:find("bvc")) then
        return true
    end
    return false
end

-- 判斷 URL 是否為 B 站媒體串流
local function is_bili_media_url(url)
    if not url or url == "" then return false end
    if url:find("://127%.0%.0%.1") or url:find("://localhost") then
        return false
    end
    if is_bili_live_url(url) then
        return false
    end
    if url:find("bilivideo%.com") or url:find("bilivideo%.cn") or url:find("akamaized%.net") or url:find("/upgcxcode/") then
        return true
    end
    if url:find("mcdn%.") or url:find("[?&]os=mcdn") or url:find("/v1/resource/") then
        return true
    end
    return false
end

-- URL 編碼輔助函式
local function url_encode(str)
    if not str then return "" end
    return str:gsub("([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

-- 替換串流 URL (支援 VOD 與 Live 直播加速)
local function rewrite_stream_filename(stream_path)
    if not settings.enabled then return stream_path, 0 end
    if not stream_path or stream_path == "" then return stream_path, 0 end

    local count = 0
    local orig_host = ""
    local port = 0
    local engine_mode = settings.engine_mode

    -- 處理 EDL 串流 (包含 VOD 多音軌/視軌分離或 Live 直播)
    if stream_path:find("^edl://") then
        local is_live_stream = false
        local live_cdn = LIVE_HOSTS[runtime.live_host_idx or 1] or LIVE_HOSTS[1]

        if engine_mode == "ripper" then
            port = ensure_engine_running()
            if not port then
                engine_mode = "direct"
            end
        end

        local new_edl = stream_path:gsub('(%%)(%d+)(%%)(https?://[^;]+)', function(p1, len_str, p2, entry_str)
            local url_len = tonumber(len_str)
            local raw_url = ""
            local edl_props = ""
            if url_len and #entry_str >= url_len then
                raw_url = entry_str:sub(1, url_len)
                edl_props = entry_str:sub(url_len + 1)
            else
                raw_url, edl_props = entry_str:match("^(https?://.-)(,%a+=.*)$")
                if not raw_url then
                    raw_url = entry_str
                    edl_props = ""
                end
            end

            -- 1. 直播處理
            if is_bili_live_url(raw_url) then
                is_live_stream = true
                local this_orig_host = raw_url:match("://([^/:]+)") or ""
                if orig_host == "" then orig_host = this_orig_host end

                local is_mcdn = raw_url:find("mcdn%.") or raw_url:find("[?&]os=mcdn") or raw_url:find("/v1/resource/")
                if settings.live_acceleration and is_mcdn then
                    local clean_url = raw_url:gsub("://[^/]+", "://" .. live_cdn, 1)
                    clean_url = clean_url:gsub("[?&]os=mcdn", ""):gsub("[?&]p2p_type=%d+", ""):gsub("[?&]backup_url=[^&]+", "")
                    count = count + 1
                    return '%' .. #clean_url .. '%' .. clean_url .. edl_props
                else
                    -- 原生官方直播節點 (gotcha, live-bvc 等)，保持不變
                    return '%' .. #raw_url .. '%' .. raw_url .. edl_props
                end
            elseif is_bili_media_url(raw_url) then
                -- 2. VOD 點播處理
                local this_orig_host = raw_url:match("://([^/:]+)") or ""
                if orig_host == "" then orig_host = this_orig_host end
                local target_host = resolve_target_host(this_orig_host)
                if target_host:find("akam") and not raw_url:find("hdnts=") then
                    target_host = OVERSEAS_HOSTS[1].id
                end
                local new_url = ""
                if engine_mode == "ripper" and port and port > 0 then
                    new_url = string.format("http://127.0.0.1:%d/stream?url=%s&cdn=%s&threads=%d",
                        port, url_encode(raw_url), target_host, settings.threads or 32)
                else
                    new_url = raw_url:gsub("://[^/]+", "://" .. target_host, 1)
                end
                count = count + 1
                return '%' .. #new_url .. '%' .. new_url .. edl_props
            end
            return p1 .. len_str .. p2 .. entry_str
        end)

        if is_live_stream then
            runtime.is_live = true
            runtime.original_host = orig_host
            runtime.mode_used = "direct"
            if count > 0 then
                runtime.is_accelerated = true
                runtime.target_host = live_cdn
                runtime.tracks_modified = count
                return new_edl, count
            else
                runtime.is_accelerated = false
                runtime.target_host = orig_host
                runtime.tracks_modified = 0
                return stream_path, 0
            end
        elseif count > 0 then
            local chosen_target = resolve_target_host(orig_host)
            runtime.is_accelerated = true
            runtime.is_live = false
            runtime.original_host = orig_host
            runtime.target_host = chosen_target
            runtime.mode_used = engine_mode
            runtime.tracks_modified = count
            return new_edl, count
        end
        return stream_path, 0
    end

    -- 單一 URL 直播串流優化 (攔截 P2P/MCDN，替換為官方低延遲直播邊緣節點)
    if is_bili_live_url(stream_path) then
        local raw_url, edl_props = stream_path:match("^(https?://.-)(,%a+=.*)$")
        if not raw_url then raw_url = stream_path edl_props = "" end
        orig_host = raw_url:match("://([^/:]+)") or ""
        runtime.is_live = true
        runtime.original_host = orig_host
        runtime.mode_used = "direct"

        local is_mcdn = raw_url:find("mcdn%.") or raw_url:find("[?&]os=mcdn") or raw_url:find("/v1/resource/")
        if settings.live_acceleration and is_mcdn then
            local live_cdn = LIVE_HOSTS[runtime.live_host_idx or 1] or LIVE_HOSTS[1]
            local clean_url = raw_url:gsub("://[^/]+", "://" .. live_cdn, 1)
            clean_url = clean_url:gsub("[?&]os=mcdn", ""):gsub("[?&]p2p_type=%d+", ""):gsub("[?&]backup_url=[^&]+", "")

            runtime.is_accelerated = true
            runtime.target_host = live_cdn
            runtime.tracks_modified = 1
            return clean_url .. edl_props, 1
        else
            runtime.is_accelerated = false
            runtime.target_host = orig_host
            runtime.tracks_modified = 0
            return stream_path, 0
        end
    end

    -- 單一 URL VOD 串流
    if is_bili_media_url(stream_path) then
        if engine_mode == "ripper" then
            port = ensure_engine_running()
            if not port then
                engine_mode = "direct"
            end
        end

        local raw_url, edl_props = stream_path:match("^(https?://.-)(,%a+=.*)$")
        if not raw_url then raw_url = stream_path edl_props = "" end
        orig_host = raw_url:match("://([^/:]+)") or ""
        local target_host = resolve_target_host(orig_host)
        if target_host:find("akam") and not raw_url:find("hdnts=") then
            target_host = OVERSEAS_HOSTS[1].id
        end
        local new_url = ""
        if engine_mode == "ripper" and port and port > 0 then
            new_url = string.format("http://127.0.0.1:%d/stream?url=%s&cdn=%s&threads=%d",
                port, url_encode(raw_url), target_host, settings.threads or 32)
        else
            new_url = raw_url:gsub("://[^/]+", "://" .. target_host, 1)
        end
        runtime.is_accelerated = true
        runtime.is_live = false
        runtime.original_host = orig_host
        runtime.target_host = target_host
        runtime.mode_used = engine_mode
        runtime.tracks_modified = 1
        return new_url .. edl_props, 1
    end

    return stream_path, 0
end

local last_notify_time = 0

mp.register_event("start-file", function()
    runtime.is_accelerated = false
    runtime.is_live = false
    runtime.tracks_modified = 0
    runtime.original_host = ""
    runtime.target_host = ""
    runtime.mode_used = ""
    runtime.original_stream_path = nil
    runtime.live_host_idx = 1
    if settings.cdn_mode == "auto" and not next(runtime.probe_results) and not runtime.probing then
        probe_all_nodes()
    end
end)

-- 掛載 Hook (優先級 20，緊隨 ytdl_hook 10 之後)
local function handle_btr_load(is_fail)
    local path = mp.get_property("stream-open-filename", "")
    if path == "" then return end

    if is_fail and settings.fallback_enabled then
        if runtime.target_host and runtime.target_host ~= "" then
            if runtime.probe_results[runtime.target_host] then
                runtime.probe_results[runtime.target_host].status = "failed"
            end
            mp.msg.warn(string.format("[BTR] 目標節點 [%s] 載入失敗", runtime.target_host))
        end

        -- 若為直播且還有備用官方直播節點可切換
        if runtime.is_live and runtime.live_host_idx and runtime.live_host_idx < #LIVE_HOSTS then
            runtime.live_host_idx = runtime.live_host_idx + 1
            local next_live_host = LIVE_HOSTS[runtime.live_host_idx]
            local prev_host = runtime.target_host
            runtime.target_host = next_live_host
            mp.msg.warn(string.format("[BTR] 直播節點 [%s] 載入失敗，切換至備用官方節點 [%s]", prev_host, next_live_host))
            if runtime.original_stream_path and runtime.original_stream_path ~= "" then
                local next_path, c = rewrite_stream_filename(runtime.original_stream_path)
                if c > 0 then
                    mp.set_property("stream-open-filename", next_path)
                    return
                end
            end
        end

        -- 直接恢復原始 stream-open-filename
        if runtime.original_stream_path and runtime.original_stream_path ~= "" then
            mp.msg.warn(string.format("[BTR] 自動降級恢復原始串流 [%s]",
                runtime.original_host ~= "" and runtime.original_host or "原生節點"))
            mp.set_property("stream-open-filename", runtime.original_stream_path)
            return
        end
    end

    runtime.original_stream_path = path
    local new_path, count = rewrite_stream_filename(path)
    if count > 0 and new_path ~= path then
        mp.set_property("stream-open-filename", new_path)
        local mode_str = runtime.is_live and "直播官方邊緣" or (runtime.mode_used == "ripper" and "全接管(多線程)" or "兼容模式(直連)")
        mp.msg.info(string.format("[BTR] 已成功加速 %d 個串流軌道 -> [%s] (模式: %s)",
            count, runtime.target_host, mode_str))
    end
end

mp.add_hook("on_load", 20, function() handle_btr_load(false) end)
mp.add_hook("on_load_fail", 20, function() handle_btr_load(true) end)

mp.register_event("file-loaded", function()
    if runtime.is_accelerated and settings.osd_notify then
        local now = mp.get_time()
        if now - last_notify_time > 3.0 then
            last_notify_time = now
            if runtime.is_live then
                mp.osd_message("⚡️ [BTR 執行緒撕裂者] B站直播串流已加速\n節點: 官方低延遲邊緣 ｜ 模式: 直播極速直連", 3.0)
            else
                local mode_desc = runtime.mode_used == "ripper" and string.format("全接管 (多線程 %d 連接)", settings.threads) or "兼容模式 (極速直連)"
                local node_short = runtime.target_host:match("mirror(%w+)") or runtime.target_host
                mp.osd_message(string.format("⚡️ [BTR 執行緒撕裂者] 串流已加速\n節點: %s ｜ 模式: %s", node_short, mode_desc), 3.0)
            end
        end
    end
end)

-- =====================================================================
-- 【BTR 視覺化 OSD 設置面板（深度還原 BTR 官方樣式）】
-- =====================================================================
local osd = mp.create_osd_overlay('ass-events')
osd.z = 2500
local is_open = false
local prev_dragging = "yes"
local hovered_btn = nil
local buttons = {}
local close_menu -- 前置宣告

-- 卡片尺寸
local CW = 380
local CH = 500

-- Windows 食指指標
local user32 = nil
local hHand = nil
local hArrow = nil
pcall(function()
    local ffi = require("ffi")
    if ffi.os == "Windows" then
        ffi.cdef[[
            void* LoadCursorA(void* hInstance, int lpCursorName);
            void* SetCursor(void* hCursor);
        ]]
        user32 = ffi.load("user32.dll")
        hHand = user32.LoadCursorA(nil, 32649)   -- IDC_HAND
        hArrow = user32.LoadCursorA(nil, 32512)  -- IDC_ARROW
    end
end)

local function set_pointer_cursor(is_hand)
    if user32 then
        if is_hand and hHand then
            user32.SetCursor(hHand)
        elseif hArrow then
            user32.SetCursor(hArrow)
        end
    end
end

local function get_btr_scale()
    local raw_ww, raw_wh = mp.get_osd_size()
    if not raw_wh or raw_wh == 0 then return 1.0, 1280, 720 end
    local scale = math.max(1.0, math.min(2.5, raw_wh / 720))
    return scale, raw_ww, raw_wh
end

local function get_scaled_mouse_pos()
    local scale = get_btr_scale()
    local raw_mx, raw_my = mp.get_mouse_pos()
    return math.floor(raw_mx / scale + 0.5), math.floor(raw_my / scale + 0.5)
end

local function get_card_pos()
    local scale, raw_ww, raw_wh = get_btr_scale()
    local ww = math.floor(raw_ww / scale + 0.5)
    local wh = math.floor(raw_wh / scale + 0.5)
    local cur_w = math.min(CW, ww - 20)
    local cur_h = math.min(CH, wh - 20)
    local x0 = math.max(10, math.floor((ww - cur_w) / 2))
    local y0 = math.max(10, math.floor((wh - cur_h) / 2))
    return x0, y0, cur_w, cur_h, ww, wh, scale
end

-- 繪製開關 Switch Toggle
local function draw_switch_toggle(ass, x, y, is_on, btn_id)
    local sw_w, sw_h = 44, 24
    table.insert(buttons, { id = btn_id, x = x, y = y, w = sw_w, h = sw_h })

    -- 背景膠囊
    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\bord0\\shad0\\1c%s}", is_on and "&H9972FB&" or "&H383232&"))
    ass:draw_start()
    ass:round_rect_cw(x, y, x + sw_w, y + sw_h, 12)
    ass:draw_stop()

    -- 圓形推鈕 (白色)
    local knob_r = 9
    local knob_x = is_on and (x + sw_w - knob_r - 3) or (x + knob_r + 3)
    local knob_y = y + sw_h / 2
    ass:new_event()
    ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&}")
    ass:draw_start()
    ass:round_rect_cw(knob_x - knob_r, knob_y - knob_r, knob_x + knob_r, knob_y + knob_r, knob_r)
    ass:draw_stop()
end

-- 繪製圖一：主面板 (Main Page)
local function render_main_page(ass, x0, y0, w, h)
    -- 1. 頂部 Header
    -- 粉色 B 圖標 Badge (帶 3 條速度線與粗體 B)
    local badge_x = x0 + 20
    local badge_y = y0 + 18
    local badge_s = 34
    ass:new_event()
    ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&H9972FB&}")
    ass:draw_start()
    ass:round_rect_cw(badge_x, badge_y, badge_x + badge_s, badge_y + badge_s, 8)
    ass:draw_stop()

    -- 圖三：左側 3 條白色速度線
    ass:new_event()
    ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&}")
    ass:draw_start()
    ass:round_rect_cw(badge_x + 5, badge_y + 11, badge_x + 10, badge_y + 13, 1)
    ass:round_rect_cw(badge_x + 4, badge_y + 16, badge_x + 11, badge_y + 18, 1)
    ass:round_rect_cw(badge_x + 5, badge_y + 21, badge_x + 10, badge_y + 23, 1)
    ass:draw_stop()

    -- 圖三：右側粗體白色大寫 B
    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs20\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}B",
        badge_x + 21, badge_y + 17))

    -- 標題與版本
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs17\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}線程撕裂者", badge_x + badge_s + 12, badge_y + 11))
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\b0\\fnMicrosoft JhengHei\\1c&H888888&}v2026.10.29.2", badge_x + badge_s + 12, badge_y + 26))

    -- 右上角主開關 Toggle
    draw_switch_toggle(ass, x0 + w - 64, y0 + 22, settings.enabled, "toggle_enabled")

    -- 2. 接管方式 Section
    local sec1_y = y0 + 72
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&H999999&}接管方式", x0 + 20, sec1_y + 8))

    local btn_y = sec1_y + 22
    local btn_w = math.floor((w - 50) / 2)
    local btn_h = 36

    -- [全接管] 按鈕
    local is_ripper = (settings.engine_mode == "ripper")
    local is_ripper_h = (hovered_btn == "mode_ripper")
    table.insert(buttons, { id = "mode_ripper", x = x0 + 20, y = btn_y, w = btn_w, h = btn_h })
    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
        is_ripper and "&H9972FB&" or (is_ripper_h and "&H4A4242&" or "&H353030&"),
        is_ripper and "&H9972FB&" or "&H242020&"))
    ass:draw_start()
    ass:round_rect_cw(x0 + 20, btn_y, x0 + 20 + btn_w, btn_y + btn_h, 7)
    ass:draw_stop()
    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}全接管",
        x0 + 20 + btn_w / 2, btn_y + btn_h / 2))

    -- [兼容模式] 按鈕
    local is_direct = (settings.engine_mode == "direct")
    local is_direct_h = (hovered_btn == "mode_direct")
    local btn2_x = x0 + 20 + btn_w + 10
    table.insert(buttons, { id = "mode_direct", x = btn2_x, y = btn_y, w = btn_w, h = btn_h })
    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
        is_direct and "&H9972FB&" or (is_direct_h and "&H4A4242&" or "&H353030&"),
        is_direct and "&H9972FB&" or "&H242020&"))
    ass:draw_start()
    ass:round_rect_cw(btn2_x, btn_y, btn2_x + btn_w, btn_y + btn_h, 7)
    ass:draw_stop()
    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}兼容模式",
        btn2_x + btn_w / 2, btn_y + btn_h / 2))

    -- 說明文案
    local desc_y = btn_y + btn_h + 12
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H888888&}全接管：播放內核由BTR接管，速度最快。", x0 + 20, desc_y))
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H888888&}兼容模式：遇到任何問題，嘗試兼容模式。", x0 + 20, desc_y + 18))

    -- 3. 運行狀態 Section
    local sec2_y = desc_y + 40
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&H999999&}運行狀態", x0 + 20, sec2_y))

    local status_card_y = sec2_y + 14
    local card_w = w - 40
    local card_h = 50
    ass:new_event()
    ass:append("{\\pos(0,0)\\bord1\\3c&H353030&\\1c&H232020&}")
    ass:draw_start()
    ass:round_rect_cw(x0 + 20, status_card_y, x0 + 20 + card_w, status_card_y + card_h, 8)
    ass:draw_stop()

    local active_threads = runtime.is_accelerated and (runtime.mode_used == "ripper" and (settings.threads or 32) or 1) or 0
    local cache_secs = mp.get_property_number("demuxer-cache-duration") or 0
    local cache_bytes = mp.get_property_number("demuxer-cache-state/total-bytes") or 0
    local cache_mb = cache_bytes / (1024 * 1024)

    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs17\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%d {\\fs13\\b0\\1c&HAAAAAA&}條線程",
        x0 + 36, status_card_y + card_h / 2, active_threads))
    ass:new_event()
    ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs17\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%.1f {\\fs13\\b0\\1c&HAAAAAA&}MB 緩衝 (%.1fs)",
        x0 + 20 + card_w - 16, status_card_y + card_h / 2, cache_mb, cache_secs))

    -- 4. 高級設置 Section (卡片可點擊跳轉)
    local adv_card_y = status_card_y + card_h + 16
    local adv_card_h = 75
    local is_adv_h = (hovered_btn == "go_advanced")
    table.insert(buttons, { id = "go_advanced", x = x0 + 20, y = adv_card_y, w = card_w, h = adv_card_h })

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
        is_adv_h and "&H4A4242&" or "&H353030&",
        is_adv_h and "&H2A2626&" or "&H232020&"))
    ass:draw_start()
    ass:round_rect_cw(x0 + 20, adv_card_y, x0 + 20 + card_w, adv_card_y + adv_card_h, 8)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}高級設置", x0 + 36, adv_card_y + 20))
    ass:new_event()
    ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs16\\b1\\fnMicrosoft JhengHei\\1c&H888888&}›", x0 + 20 + card_w - 18, adv_card_y + 20))

    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H888888&}默認設置在絕大多數場景就是表現最優的。如果你遇到了", x0 + 36, adv_card_y + 42))
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H888888&}問題，修改這裡的一些設置可能有幫助。", x0 + 36, adv_card_y + 58))

    -- 5. 底部 [關閉] 按鈕
    local close_btn_y = y0 + h - 48
    local close_btn_h = 36
    local is_c_h = (hovered_btn == "close")
    table.insert(buttons, { id = "close", x = x0 + 20, y = close_btn_y, w = card_w, h = close_btn_h })

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
        is_c_h and "&H4F4848&" or "&H3E3838&",
        is_c_h and "&H3A3434&" or "&H322E2E&"))
    ass:draw_start()
    ass:round_rect_cw(x0 + 20, close_btn_y, x0 + 20 + card_w, close_btn_y + close_btn_h, 7)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}關閉",
        x0 + 20 + card_w / 2, close_btn_y + close_btn_h / 2))
end

-- 繪製圖二：高級設置面板 (Advanced Page)
local function render_advanced_page(ass, x0, y0, w, h)
    local card_w = w - 40

    -- 1. 頂部 Header 與返回按鈕
    local badge_x = x0 + 20
    local badge_y = y0 + 16
    local badge_s = 28
    ass:new_event()
    ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&H9972FB&}")
    ass:draw_start()
    ass:round_rect_cw(badge_x, badge_y, badge_x + badge_s, badge_y + badge_s, 6)
    ass:draw_stop()

    -- 圖三：左側 3 條白色速度線
    ass:new_event()
    ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&HFFFFFF&}")
    ass:draw_start()
    ass:round_rect_cw(badge_x + 4, badge_y + 8, badge_x + 8, badge_y + 10, 1)
    ass:round_rect_cw(badge_x + 3, badge_y + 13, badge_x + 9, badge_y + 15, 1)
    ass:round_rect_cw(badge_x + 4, badge_y + 18, badge_x + 8, badge_y + 20, 1)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs16\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}B",
        badge_x + 18, badge_y + 14))

    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}線程撕裂者", badge_x + badge_s + 10, badge_y + 9))
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs10\\b0\\fnMicrosoft JhengHei\\1c&H888888&}v2026.10.29.2", badge_x + badge_s + 10, badge_y + 22))

    draw_switch_toggle(ass, x0 + w - 64, y0 + 18, settings.enabled, "toggle_enabled")

    -- 返回主面板按鈕: < 高級設置
    local back_y = y0 + 56
    local is_back_h = (hovered_btn == "go_main")
    table.insert(buttons, { id = "go_main", x = x0 + 20, y = back_y, w = 120, h = 26 })
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\b1\\fnMicrosoft JhengHei\\1c%s}‹ 高級設置",
        x0 + 22, back_y + 13, is_back_h and "&H9972FB&" or "&HFFFFFF&"))

    -- 2. 分頁標籤列 (Tabs)
    local tab_y = back_y + 30
    local tabs = {
        { id = "network",  name = "網絡" },
        { id = "buffer",   name = "緩衝" },
        { id = "features", name = "功能" },
        { id = "nodes",    name = "節點" },
    }
    local tab_w = math.floor((card_w - 18) / 4)
    local tab_h = 30
    for i, t in ipairs(tabs) do
        local tx = x0 + 20 + (i - 1) * (tab_w + 6)
        local is_sel = (settings.current_tab == t.id)
        local is_th = (hovered_btn == "tab_" .. t.id)
        table.insert(buttons, { id = "tab_" .. t.id, tab = t.id, x = tx, y = tab_y, w = tab_w, h = tab_h })

        ass:new_event()
        ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
            is_sel and "&H9972FB&" or (is_th and "&H4A4242&" or "&H353030&"),
            is_sel and "&H3A2E38&" or "&H232020&"))
        ass:draw_start()
        ass:round_rect_cw(tx, tab_y, tx + tab_w, tab_y + tab_h, 6)
        ass:draw_stop()

        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c%s}%s",
            tx + tab_w / 2, tab_y + tab_h / 2, is_sel and "&H9972FB&" or "&HCCCCCC&", t.name))
    end

    -- 3. 分頁內容
    local content_y = tab_y + tab_h + 16

    if settings.current_tab == "network" then
        -- CDN 模式
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&H999999&}CDN 模式", x0 + 20, content_y + 6))

        local cdn_btn_y = content_y + 18
        local cdn_w = math.floor((card_w - 16) / 3)
        local cdn_h = 34

        local cdn_opts = {
            { id = "mainland", label = "大陸" },
            { id = "overseas", label = "海外" },
            { id = "auto",     label = "自定義" },
        }
        for i, opt in ipairs(cdn_opts) do
            local cx = x0 + 20 + (i - 1) * (cdn_w + 8)
            local is_sel = (settings.cdn_mode == opt.id)
            local is_ch = (hovered_btn == "cdn_" .. opt.id)
            table.insert(buttons, { id = "cdn_" .. opt.id, cdn = opt.id, x = cx, y = cdn_btn_y, w = cdn_w, h = cdn_h })

            ass:new_event()
            ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
                is_sel and "&H9972FB&" or (is_ch and "&H4A4242&" or "&H353030&"),
                is_sel and "&H9972FB&" or "&H242020&"))
            ass:draw_start()
            ass:round_rect_cw(cx, cdn_btn_y, cx + cdn_w, cdn_btn_y + cdn_h, 6)
            ass:draw_stop()

            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%s",
                cx + cdn_w / 2, cdn_btn_y + cdn_h / 2, opt.label))
        end

        -- 線程 Section
        local th_sec_y = cdn_btn_y + cdn_h + 14
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&H999999&}線程", x0 + 20, th_sec_y + 6))

        local th_card_y = th_sec_y + 18
        local th_card_h = 135
        ass:new_event()
        ass:append("{\\pos(0,0)\\bord1\\3c&H353030&\\1c&H232020&}")
        ass:draw_start()
        ass:round_rect_cw(x0 + 20, th_card_y, x0 + 20 + card_w, th_card_y + th_card_h, 8)
        ass:draw_stop()

        -- 線程加載數 + 右側 [自動] Badge
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs14\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}線程加載數", x0 + 34, th_card_y + 18))

        local auto_badge_w = 46
        local auto_badge_h = 22
        local auto_badge_x = x0 + 20 + card_w - auto_badge_w - 14
        local auto_badge_y = th_card_y + 8
        ass:new_event()
        ass:append(string.format("{\\pos(0,0)\\bord0\\shad0\\1c%s}", settings.auto_threads and "&H9972FB&" or "&H353030&"))
        ass:draw_start()
        ass:round_rect_cw(auto_badge_x, auto_badge_y, auto_badge_x + auto_badge_w, auto_badge_y + auto_badge_h, 5)
        ass:draw_stop()

        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs12\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%s",
            auto_badge_x + auto_badge_w / 2, auto_badge_y + auto_badge_h / 2,
            settings.auto_threads and "自動" or tostring(settings.threads)))

        -- 自動線程數（推薦）+ Toggle switch
        local row2_y = th_card_y + 40
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}自動線程數（推薦）", x0 + 34, row2_y + 10))
        draw_switch_toggle(ass, x0 + 20 + card_w - 56, row2_y, settings.auto_threads, "toggle_auto_threads")

        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H888888&}BTR將智能選擇需要的線程數。", x0 + 34, row2_y + 28))

        -- 線程分段 Slider (完整還原圖二樣式：連續軌道、粉色進度條、圓形滑塊與下方檔位數字)
        local th_steps = { 4, 8, 16, 32, 64, 128 }
        local track_x = x0 + 34
        local track_w = card_w - 28
        local track_y = th_card_y + 86
        local curr_idx = 4 -- 預設為 32
        for i, val in ipairs(th_steps) do
            if settings.threads == val then
                curr_idx = i
                break
            end
        end

        local thumb_x = math.floor(track_x + (curr_idx - 1) * track_w / 5)

        -- 1. 底層軌道 (深色圓角條)
        ass:new_event()
        ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&H302A2E&}")
        ass:draw_start()
        ass:round_rect_cw(track_x, track_y, track_x + track_w, track_y + 8, 4)
        ass:draw_stop()

        -- 2. 已選進度條 (粉色填滿)
        if curr_idx > 1 then
            ass:new_event()
            ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&H885BEB&}")
            ass:draw_start()
            ass:round_rect_cw(track_x, track_y, thumb_x, track_y + 8, 4)
            ass:draw_stop()
        end

        -- 3. 圓形滑塊 Knob (灰色/懸停高亮)
        local is_thumb_h = (hovered_btn and hovered_btn:match("^th_step_"))
        ass:new_event()
        ass:append(string.format("{\\pos(0,0)\\bord0\\shad0\\1c%s}", is_thumb_h and "&HFFFFFF&" or "&H857A7C&"))
        ass:draw_start()
        ass:round_rect_cw(thumb_x - 9, track_y + 4 - 9, thumb_x + 9, track_y + 4 + 9, 9)
        ass:draw_stop()

        -- 4. 下方各檔位數字標籤與點擊熱區
        local step_half_w = math.floor(track_w / 5 / 2)
        for i, val in ipairs(th_steps) do
            local sx = math.floor(track_x + (i - 1) * track_w / 5)
            table.insert(buttons, { id = "th_step_" .. val, threads = val, x = sx - step_half_w, y = track_y - 8, w = step_half_w * 2, h = 38 })

            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c%s}%d",
                sx, track_y + 22, (curr_idx == i) and "&HFFFFFF&" or "&H888888&", val))
        end

    elseif settings.current_tab == "buffer" then
        -- 緩衝分頁
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&H999999&}快取緩衝記憶體 (demuxer-max-bytes)", x0 + 20, content_y + 6))

        local buf_y = content_y + 20
        local buf_w = math.floor((card_w - 18) / 4)
        local cur_mb = mp.get_property_number("demuxer-max-bytes") or (500 * 1024 * 1024)
        local cur_mb_val = math.floor(cur_mb / (1024 * 1024))
        local buf_opts = {
            { val = 150, label = "150M" },
            { val = 300, label = "300M" },
            { val = 500, label = "500M" },
            { val = 1024, label = "1GB" },
        }
        for i, opt in ipairs(buf_opts) do
            local bx = x0 + 20 + (i - 1) * (buf_w + 6)
            local is_bs = (math.abs(cur_mb_val - opt.val) < 50)
            local is_bh = (hovered_btn == "buf_" .. opt.val)
            table.insert(buttons, { id = "buf_" .. opt.val, bytes = opt.val, x = bx, y = buf_y, w = buf_w, h = 32 })

            ass:new_event()
            ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
                is_bs and "&H9972FB&" or (is_bh and "&H4A4242&" or "&H353030&"),
                is_bs and "&H9972FB&" or "&H242020&"))
            ass:draw_start()
            ass:round_rect_cw(bx, buf_y, bx + buf_w, buf_y + 32, 6)
            ass:draw_stop()

            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs12\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%s",
                bx + buf_w / 2, buf_y + 16, opt.label))
        end

        -- 預讀秒數
        local read_sec_y = buf_y + 48
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&H999999&}預讀秒數 (demuxer-readahead-secs)", x0 + 20, read_sec_y + 6))

        local read_btn_y = read_sec_y + 20
        local cur_sec = mp.get_property_number("demuxer-readahead-secs") or 30
        local sec_opts = {
            { val = 15, label = "15秒" },
            { val = 30, label = "30秒" },
            { val = 60, label = "60秒" },
            { val = 120, label = "120秒" },
        }
        for i, opt in ipairs(sec_opts) do
            local sx = x0 + 20 + (i - 1) * (buf_w + 6)
            local is_ss = (cur_sec == opt.val)
            local is_sh = (hovered_btn == "sec_" .. opt.val)
            table.insert(buttons, { id = "sec_" .. opt.val, secs = opt.val, x = sx, y = read_btn_y, w = buf_w, h = 32 })

            ass:new_event()
            ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
                is_ss and "&H9972FB&" or (is_sh and "&H4A4242&" or "&H353030&"),
                is_ss and "&H9972FB&" or "&H242020&"))
            ass:draw_start()
            ass:round_rect_cw(sx, read_btn_y, sx + buf_w, read_btn_y + 32, 6)
            ass:draw_stop()

            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs12\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%s",
                sx + buf_w / 2, read_btn_y + 16, opt.label))
        end

        local card_info_y = read_btn_y + 48
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H888888&}增大緩衝可以在海外高延遲或網路波動時提供持續流暢播放，", x0 + 20, card_info_y))
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H888888&}避免拖動進度條時反覆等待重連。", x0 + 20, card_info_y + 18))

    elseif settings.current_tab == "features" then
        -- 功能分頁
        local feat_items = {
            { id = "toggle_live", title = "B 站直播加速 (實驗性)", val = settings.live_acceleration,
              desc = "攔截直播串流，自動過濾 P2P/mcdn 改寫為官方低延遲直播邊緣節點。" },
            { id = "toggle_osd", title = "OSD 浮窗加速提示", val = settings.osd_notify,
              desc = "影片加載完成時，於畫面頂部浮窗顯示當前加速節點與模式。" },
            { id = "toggle_fallback", title = "線路容災自動降級", val = settings.fallback_enabled,
              desc = "當目標鏡像節點連線失敗時，自動無縫回退至原生官方節點。" },
        }

        local fy = content_y
        for _, item in ipairs(feat_items) do
            local f_card_h = 56
            ass:new_event()
            ass:append("{\\pos(0,0)\\bord1\\3c&H353030&\\1c&H232020&}")
            ass:draw_start()
            ass:round_rect_cw(x0 + 20, fy, x0 + 20 + card_w, fy + f_card_h, 8)
            ass:draw_stop()

            ass:new_event()
            ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs14\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%s", x0 + 34, fy + 16, item.title))
            ass:new_event()
            ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs10\\fnMicrosoft JhengHei\\1c&H888888&}%s", x0 + 34, fy + 36, item.desc))

            draw_switch_toggle(ass, x0 + 20 + card_w - 56, fy + 12, item.val, item.id)

            fy = fy + f_card_h + 12
        end

    elseif settings.current_tab == "nodes" then
        -- 節點與測速分頁
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c&H999999&}優選鏡像節點", x0 + 20, content_y + 4))

        -- 立即測速按鈕
        local probe_w = 88
        local probe_h = 24
        local probe_x = x0 + 20 + card_w - probe_w
        local is_pr_h = (hovered_btn == "probe_all")
        table.insert(buttons, { id = "probe_all", x = probe_x, y = content_y - 2, w = probe_w, h = probe_h })

        ass:new_event()
        ass:append(string.format("{\\pos(0,0)\\bord1\\3c&H9972FB&\\1c%s}", is_pr_h and "&H3A2E38&" or "&H232020&"))
        ass:draw_start()
        ass:round_rect_cw(probe_x, content_y - 2, probe_x + probe_w, content_y - 2 + probe_h, 5)
        ass:draw_stop()

        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs11\\b1\\fnMicrosoft JhengHei\\1c&H9972FB&}%s",
            probe_x + probe_w / 2, content_y - 2 + probe_h / 2, runtime.probing and "測速中..." or "🔄 立即測速"))

        local n_list_y = content_y + 26
        local n_card_h = 32
        local all_nodes = {
            { id = "upos-sz-mirrorhw.bilivideo.com", name = "大陸 華為雲" },
            { id = "upos-sz-mirrorali.bilivideo.com", name = "大陸 阿里雲" },
            { id = "upos-sz-mirrorcos.bilivideo.com", name = "大陸 騰訊雲" },
            { id = "upos-sz-mirrorbos.bilivideo.com", name = "大陸 百度雲" },
            { id = "upos-sz-mirrorcosov.bilivideo.com", name = "海外 騰訊雲" },
            { id = "upos-hz-mirrorakam.akamaized.net",  name = "海外 Akamai" },
        }

        for i, node in ipairs(all_nodes) do
            local ny = n_list_y + (i - 1) * (n_card_h + 6)
            local is_node_sel = (settings.preferred_host == node.id)
            local is_nh = (hovered_btn == "node_" .. node.id)
            table.insert(buttons, { id = "node_" .. node.id, host = node.id, x = x0 + 20, y = ny, w = card_w, h = n_card_h })

            ass:new_event()
            ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
                is_node_sel and "&H9972FB&" or (is_nh and "&H4A4242&" or "&H353030&"),
                is_node_sel and "&H3A2E38&" or "&H232020&"))
            ass:draw_start()
            ass:round_rect_cw(x0 + 20, ny, x0 + 20 + card_w, ny + n_card_h, 6)
            ass:draw_stop()

            ass:new_event()
            ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\b1\\fnMicrosoft JhengHei\\1c%s}%s",
                x0 + 32, ny + n_card_h / 2, is_node_sel and "&H9972FB&" or "&HFFFFFF&", node.name))

            local p_info = runtime.probe_results[node.id]
            local ping_str = "-- ms"
            local ping_col = "&H888888&"
            if p_info then
                if p_info.status == "ok" then
                    ping_str = string.format("%d ms", math.floor(p_info.latency_ms))
                    ping_col = p_info.latency_ms < 150 and "&H52D670&" or (p_info.latency_ms < 280 and "&H40C5FB&" or "&H4D80F5&")
                else
                    ping_str = "超時"
                    ping_col = "&H5555EE&"
                end
            end
            ass:new_event()
            ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs12\\b1\\fnMicrosoft JhengHei\\1c%s}● %s",
                x0 + 20 + card_w - 14, ny + n_card_h / 2, ping_col, ping_str))
        end
    end

    -- 4. 底部 [關閉] 按鈕
    local close_btn_y = y0 + h - 48
    local close_btn_h = 36
    local is_c_h = (hovered_btn == "close")
    table.insert(buttons, { id = "close", x = x0 + 20, y = close_btn_y, w = card_w, h = close_btn_h })

    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\bord1\\3c%s\\1c%s}",
        is_c_h and "&H4F4848&" or "&H3E3838&",
        is_c_h and "&H3A3434&" or "&H322E2E&"))
    ass:draw_start()
    ass:round_rect_cw(x0 + 20, close_btn_y, x0 + 20 + card_w, close_btn_y + close_btn_h, 7)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}關閉",
        x0 + 20 + card_w / 2, close_btn_y + close_btn_h / 2))
end

local function render_menu()
    if not is_open then
        osd.hidden = true
        osd.data = ''
        osd:update()
        return
    end

    local ok, err = pcall(function()
        local x0, y0, w, h, ww, wh = get_card_pos()
        local ass = assdraw.ass_new()
        buttons = {}

        -- 1. 背景暗層
        ass:new_event()
        ass:append("{\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H70&}")
        ass:draw_start()
        ass:rect_cw(0, 0, ww, wh)
        ass:draw_stop()

        -- 2. 主卡片圓角背景 (#18181A) 與邊框 (#35353A)
        ass:new_event()
        ass:append("{\\pos(0,0)\\bord1.5\\3c&H3A3535&\\1c&H1A1818&\\1a&H10&}")
        ass:draw_start()
        ass:round_rect_cw(x0, y0, x0 + w, y0 + h, 14)
        ass:draw_stop()

        if runtime.page == "advanced" then
            render_advanced_page(ass, x0, y0, w, h)
        else
            render_main_page(ass, x0, y0, w, h)
        end

        osd.res_x = ww
        osd.res_y = wh
        osd.z = 2500
        osd.hidden = false
        osd.data = ass.text
        osd:update()
    end)

    if not ok then
        mp.msg.error("[BTR] render_menu error: " .. tostring(err))
    end
end

local function on_mouse_move()
    if not is_open then return end
    local mx, my = get_scaled_mouse_pos()
    local prev_h = hovered_btn
    hovered_btn = nil

    for _, btn in ipairs(buttons) do
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
            hovered_btn = btn.id
            break
        end
    end

    set_pointer_cursor(hovered_btn ~= nil)
    if prev_h ~= hovered_btn then
        render_menu()
    end
end

local function on_mouse_click()
    if not is_open then return end
    local mx, my = get_scaled_mouse_pos()
    local x0, y0, w, h = get_card_pos()

    -- 點擊卡片外關閉
    if mx < x0 or mx > x0 + w or my < y0 or my > y0 + h then
        close_menu()
        return
    end

    for _, btn in ipairs(buttons) do
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
            if btn.id == "close" then
                close_menu()
            elseif btn.id == "toggle_enabled" then
                settings.enabled = not settings.enabled
                save_settings()
                mp.osd_message("[BTR] 加速功能已" .. (settings.enabled and "開啟" or "關閉"), 1.5)
                render_menu()
            elseif btn.id == "mode_ripper" then
                settings.engine_mode = "ripper"
                save_settings()
                ensure_engine_running()
                mp.osd_message("[BTR] 已切換為：全接管模式 (多線程併發加速)", 1.5)
                render_menu()
            elseif btn.id == "mode_direct" then
                settings.engine_mode = "direct"
                save_settings()
                mp.osd_message("[BTR] 已切換為：兼容模式 (極速直連)", 1.5)
                render_menu()
            elseif btn.id == "go_advanced" then
                runtime.page = "advanced"
                render_menu()
            elseif btn.id == "go_main" then
                runtime.page = "main"
                render_menu()
            elseif btn.id:match("^tab_") and btn.tab then
                settings.current_tab = btn.tab
                save_settings()
                render_menu()
            elseif btn.id:match("^cdn_") and btn.cdn then
                settings.cdn_mode = btn.cdn
                save_settings()
                mp.osd_message("[BTR] 已切換 CDN 模式: " .. (btn.cdn == "mainland" and "大陸" or (btn.cdn == "overseas" and "海外" or "自定義")), 1.5)
                render_menu()
            elseif btn.id == "toggle_auto_threads" then
                settings.auto_threads = not settings.auto_threads
                if settings.auto_threads then
                    settings.threads = 32
                end
                save_settings()
                mp.osd_message("[BTR] 自動線程數已" .. (settings.auto_threads and "開啟 (推薦32線程)" or "關閉"), 1.5)
                render_menu()
            elseif btn.id:match("^th_step_") and btn.threads then
                settings.threads = btn.threads
                settings.auto_threads = false
                save_settings()
                mp.osd_message(string.format("[BTR] 併發線程數設定為: %d", btn.threads), 1.5)
                render_menu()
            elseif btn.id:match("^buf_") and btn.bytes then
                mp.set_property("demuxer-max-bytes", tostring(btn.bytes) .. "M")
                mp.osd_message(string.format("[BTR] 快取緩衝設定為: %d MB", btn.bytes), 1.5)
                render_menu()
            elseif btn.id:match("^sec_") and btn.secs then
                mp.set_property("demuxer-readahead-secs", tostring(btn.secs))
                mp.osd_message(string.format("[BTR] 預讀秒數設定為: %d 秒", btn.secs), 1.5)
                render_menu()
            elseif btn.id == "toggle_live" then
                settings.live_acceleration = not settings.live_acceleration
                save_settings()
                mp.osd_message("[BTR] B站直播加速已" .. (settings.live_acceleration and "開啟" or "關閉"), 1.5)
                render_menu()
            elseif btn.id == "toggle_osd" then
                settings.osd_notify = not settings.osd_notify
                save_settings()
                mp.osd_message("[BTR] OSD 提示已" .. (settings.osd_notify and "開啟" or "關閉"), 1.5)
                render_menu()
            elseif btn.id == "toggle_fallback" then
                settings.fallback_enabled = not settings.fallback_enabled
                save_settings()
                mp.osd_message("[BTR] 容災自動降級已" .. (settings.fallback_enabled and "開啟" or "關閉"), 1.5)
                render_menu()
            elseif btn.id:match("^node_") and btn.host then
                settings.preferred_host = btn.host
                if btn.host:find("ov") or btn.host:find("akam") then
                    settings.cdn_mode = "overseas"
                else
                    settings.cdn_mode = "mainland"
                end
                save_settings()
                mp.osd_message("[BTR] 已切換優選節點: " .. btn.host, 1.5)
                render_menu()
            elseif btn.id == "probe_all" then
                probe_all_nodes(function()
                    render_menu()
                end)
                render_menu()
            end
            return
        end
    end
end

close_menu = function()
    if not is_open then return end
    is_open = false
    hovered_btn = nil
    set_pointer_cursor(false)

    pcall(function()
        mp.set_property("window-dragging", prev_dragging or "yes")
    end)

    mp.remove_key_binding("btr_panel_mbtn_left")
    mp.remove_key_binding("btr_panel_mouse_move")
    mp.remove_key_binding("btr_panel_esc")
    mp.remove_key_binding("btr_panel_mbtn_right")

    osd.hidden = true
    osd.data = ''
    osd:update()
end

local function open_menu(initial_page)
    is_open = true
    hovered_btn = nil
    runtime.page = initial_page or "main"
    prev_dragging = mp.get_property("window-dragging", "yes")
    pcall(function()
        mp.set_property("window-dragging", "no")
    end)

    mp.add_forced_key_binding("MBTN_LEFT", "btr_panel_mbtn_left", on_mouse_click)
    mp.add_forced_key_binding("MOUSE_MOVE", "btr_panel_mouse_move", on_mouse_move)
    mp.add_forced_key_binding("ESC", "btr_panel_esc", close_menu)
    mp.add_forced_key_binding("MBTN_RIGHT", "btr_panel_mbtn_right", close_menu)

    render_menu()

    if not next(runtime.probe_results) then
        probe_all_nodes(function()
            if is_open then render_menu() end
        end)
    end
end

local function toggle_menu()
    if is_open then
        close_menu()
    else
        open_menu()
    end
end

mp.observe_property("osd-dimensions", "native", function()
    if is_open then render_menu() end
end)

mp.add_key_binding("Alt+t", "toggle_menu", toggle_menu)
mp.add_key_binding(nil, "toggle_menu", toggle_menu)
mp.add_key_binding(nil, "toggle", toggle_menu)
mp.register_script_message("toggle_menu", toggle_menu)
mp.register_script_message("toggle", toggle_menu)
mp.register_script_message("btr-open-menu", open_menu)
mp.register_script_message("btr-close-menu", close_menu)
mp.register_script_message("btr-toggle-menu", toggle_menu)
mp.register_script_message("btr-open-advanced", function()
    runtime.page = "advanced"
    if not is_open then open_menu("advanced") else render_menu() end
end)

launch_engine_async()
mp.msg.info("[BTR] Bilibili 執行緒撕裂者模組已就緒 (快捷鍵: Alt+t)")
