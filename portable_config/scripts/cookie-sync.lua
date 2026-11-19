-- cookie-sync.lua
-- 1. 保護使用者的 cookies.txt 不被 yt-dlp 在結束時覆寫 / 清空
-- 2. 智慧 Cookie 憑證管理：
--    - 支援標準 Netscape 格式與 Raw Cookie 字串，自動消除 UTF-8 BOM
--    - 支援一鍵 / 自動自瀏覽器 (Firefox / Edge / Chrome) 同步最新憑證（全非同步，永不卡頓 UI）
--    - 即時校驗 B 站 SESSDATA 登入狀態 (檢查 API 是否返回 isLogin，安全透過 stdin 傳遞，絕不洩漏於 CLI 參數)
--    - 【核心防呆機制】：若檢測到 B 站 Cookie 失效或過期，自動自瀏覽器重整（僅限 1 次重試防遞迴爆棧）；
--      若仍無有效憑證，自動自給 yt-dlp 的串流參數中剔除過期 B 站 Cookie，回退為免登訪客 WBI 模式！
--      （徹底解決 B 站因接收無效/過期 Cookie 而將解析度強制鎖死限速在 480P 的問題，免登模式最高可直達 1080P/720P）
-- 3. 自動注入 B 站串流身分憑證與 Referer / Origin 防盜鏈標頭（採用 file-local-options，絕不污染全域標頭）

local utils = require 'mp.utils'
local msg = require 'mp.msg'

local mpv_root = mp.command_native({"expand-path", "~~/"})
local user_cookie_file = utils.join_path(mpv_root, "cookies.txt")
local temp_dir = os.getenv("TEMP") or utils.join_path(mpv_root, "cache")
local active_cookie_file = utils.join_path(temp_dir, "mpv_active_cookies.txt")
local extracted_cookie_file = utils.join_path(temp_dir, "mpv_extracted_cookies.txt")

local cached_bili_cookie = nil
local bili_verified = false
local bili_is_valid = false
local bili_uname = nil
local bili_is_vip = false
local last_verify_time = 0
local last_bili_raw_cookie = nil

local is_verifying = false
local is_extracting = false
local verify_callbacks = {}

local function get_ytdl_path()
    local ytdl_path = utils.join_path(mpv_root, "yt-dlp.exe")
    local info = utils.file_info(ytdl_path)
    if not info then
        ytdl_path = utils.join_path(mpv_root, "../yt-dlp.exe")
        info = utils.file_info(ytdl_path)
    end
    if not info then ytdl_path = "yt-dlp" end
    return ytdl_path
end

local function strip_bom(str)
    if str and str:sub(1, 3) == "\239\187\191" then
        return str:sub(4)
    end
    return str
end

local function write_active_cookies(general_lines, bili_lines, include_bili)
    local out = io.open(active_cookie_file, "w")
    if out then
        out:write("# Netscape HTTP Cookie File\n")
        if general_lines then
            for _, line in ipairs(general_lines) do
                out:write(line .. "\n")
            end
        end
        if include_bili and bili_lines then
            for _, line in ipairs(bili_lines) do
                out:write(line .. "\n")
            end
        end
        out:close()
    end

    local ytdl_raw = mp.get_property("ytdl-raw-options", "")
    if not ytdl_raw:find("cookies=") then
        mp.commandv("change-list", "ytdl-raw-options", "append", "cookies=" .. active_cookie_file)
    end
end

-- 非同步校驗 B 站憑證，透過 stdin 傳遞 Cookie 設定（curl -K -），杜絕 CLI 參數洩露敏感憑證
local function verify_bilibili_cookie(cookie_str, callback)
    if not cookie_str or not cookie_str:find("SESSDATA=") then
        if callback then callback(false, nil, false) end
        return
    end

    local safe_cookie = cookie_str:gsub("[\r\n]", ""):gsub('\\', '\\\\'):gsub('"', '\\"')
    local curl_config = string.format(
        'header = "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)"\nheader = "Cookie: %s"\n',
        safe_cookie
    )

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        stdin_data = curl_config,
        args = {
            "curl.exe", "-s", "--max-time", "3",
            "-K", "-",
            "https://api.bilibili.com/x/web-interface/nav"
        }
    }, function(success, res, err)
        if success and res and res.status == 0 and res.stdout then
            local data = utils.parse_json(res.stdout)
            if data and data.code == 0 and data.data and data.data.isLogin == true then
                local uname = data.data.uname or "已登入用戶"
                local is_vip = (data.data.vipType and data.data.vipType > 0)
                if callback then callback(true, uname, is_vip) end
                return
            end
        end
        if callback then callback(false, nil, false) end
    end)
end

-- 非同步自瀏覽器同步 Cookies，完全不阻塞 MPV 主執行緒
local function try_extract_browser_cookies(show_osd, callback)
    if is_extracting then
        msg.warn("[cookie-sync] 瀏覽器 Cookies 提取已在進行中，略過重複請求")
        if callback then callback(false, nil) end
        return
    end

    local ytdl_path = get_ytdl_path()
    if show_osd then
        mp.osd_message("[Cookies] 正在自瀏覽器同步最新 Cookies...", 5)
    end
    msg.info("[cookie-sync] 嘗試從瀏覽器同步最新 Cookies (非同步)...")

    -- 優先順序：Firefox (Windows 下無 Chromium DPAPI 加密阻擋) -> Edge -> Chrome
    local browsers = {"firefox", "edge", "chrome"}
    local test_url = "https://www.bilibili.com/video/BV1xx411c7mD"
    is_extracting = true

    local function try_browser(index)
        if index > #browsers then
            is_extracting = false
            msg.warn("[cookie-sync] 未能自任何瀏覽器成功提取 Cookies")
            if callback then callback(false, nil) end
            return
        end

        local browser = browsers[index]
        msg.info(string.format("[cookie-sync] 嘗試自 %s 提取 Cookies...", browser))
        pcall(function() os.remove(extracted_cookie_file) end)

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = {
                ytdl_path,
                "--cookies-from-browser", browser,
                "--cookies", extracted_cookie_file,
                "--simulate", "--skip-download",
                test_url
            }
        }, function(success, res, err)
            if success and res and res.status == 0 then
                local fin = io.open(extracted_cookie_file, "r")
                if fin then
                    local content = fin:read("*all")
                    fin:close()
                    if content and content:find("Netscape HTTP Cookie File") then
                        local fout = io.open(user_cookie_file, "w")
                        if fout then
                            fout:write(content)
                            fout:close()
                            is_extracting = false
                            msg.info(string.format("[cookie-sync] 成功自 %s 同步最新 Cookies 至本地 cookies.txt！", browser))
                            if callback then callback(true, browser) end
                            return
                        end
                    end
                end
            end
            try_browser(index + 1)
        end)
    end

    try_browser(1)
end

-- 憑證同步核心：
-- 1. 同步階段僅做本地 cookies.txt 解析與寫入 mpv_active_cookies.txt，UI 零凍結
-- 2. 網路校驗與瀏覽器提取均走非同步
-- 3. 預設允許 1 次重試，遞迴調用傳入 sync_cookies(false, false)；若再失敗則直接鎖定訪客保底，徹底防止爆棧
local function sync_cookies(force_verify, allow_browser_retry, on_complete)
    if force_verify == nil then force_verify = false end
    if allow_browser_retry == nil then allow_browser_retry = true end

    local f = io.open(user_cookie_file, "r")
    local content = nil
    if f then
        content = strip_bom(f:read("*all"))
        f:close()
    end

    local has_target_domain = content and (
        content:find("youtube%.") or
        content:find("bilibili%.") or
        content:find("biligame%.") or
        content:find("huasheng%.")
    )

    -- 若本地完全無有效 cookies.txt，先同步寫入空白保護檔，再非同步嘗試提取
    if not content or content:match("^%s*$") or not has_target_domain then
        write_active_cookies({}, {}, false)
        cached_bili_cookie = nil
        bili_verified = true
        bili_is_valid = false
        if allow_browser_retry then
            msg.info("[cookie-sync] 本地無有效 cookies.txt，非同步嘗試自瀏覽器同步...")
            try_extract_browser_cookies(false, function(ok, browser)
                if ok then
                    sync_cookies(false, false, on_complete)
                else
                    if on_complete then on_complete(false, nil, false) end
                end
            end)
        else
            if on_complete then on_complete(false, nil, false) end
        end
        return
    end

    local general_lines = {}
    local bili_lines = {}
    local bili_pairs = {}

    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" and not trimmed:match("^#") then
            local _, tab_count = trimmed:gsub("\t", "")
            if tab_count >= 5 then
                local parts = {}
                for p in trimmed:gmatch("[^\t]+") do table.insert(parts, p) end
                local is_bili = (parts[1] and (parts[1]:find("bilibili%.") or parts[1]:find("biligame%.") or parts[1]:find("huasheng%.")))
                if is_bili then
                    table.insert(bili_lines, trimmed)
                    if #parts >= 7 then
                        table.insert(bili_pairs, parts[6] .. "=" .. parts[7])
                    end
                else
                    table.insert(general_lines, trimmed)
                end
            else
                local clean = trimmed:gsub("^[Cc]ookie:%s*", "")
                for pair in clean:gmatch("[^;]+") do
                    local k, v = pair:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
                    if k and v and k ~= "" and v ~= "" and not k:match("^#") then
                        local is_yt = (k:match("^__Secure") or k:match("^__Host") or k == "SID" or k == "HSID" or k == "SSID" or k == "APISID" or k == "SAPISID" or k == "LOGIN_INFO" or k == "PREF" or k == "YSC" or k == "VISITOR_INFO1_LIVE" or k == "VISITOR_PRIVACY_METADATA" or k == "NID" or k == "wide" or k == "SIDCC")
                        local domain = is_yt and ".youtube.com" or ".bilibili.com"
                        local netscape_line = string.format("%s\tTRUE\t/\tFALSE\t2147483647\t%s\t%s", domain, k, v)
                        if not is_yt then
                            table.insert(bili_lines, netscape_line)
                            table.insert(bili_pairs, k .. "=" .. v)
                        else
                            table.insert(general_lines, netscape_line)
                        end
                    end
                end
            end
        end
    end

    local bili_raw_cookie = table.concat(bili_pairs, "; ")
    if last_bili_raw_cookie ~= bili_raw_cookie then
        -- Cookie 檔案內容變更，重置校驗快取
        bili_verified = false
        bili_is_valid = false
        last_bili_raw_cookie = bili_raw_cookie
        last_verify_time = 0
    end

    -- 【同步極速交差】：立即依當前已知狀態寫入 active_cookie_file，不阻塞播放器
    local include_bili = bili_is_valid or (not bili_verified)
    write_active_cookies(general_lines, bili_lines, include_bili)
    if include_bili then
        cached_bili_cookie = bili_raw_cookie
    else
        cached_bili_cookie = nil
    end

    local now = os.time()
    local need_verify = (#bili_pairs > 0) and (force_verify or not bili_verified or (now - last_verify_time > 3600))

    if not need_verify then
        if #bili_pairs == 0 then
            bili_verified = true
            bili_is_valid = false
            cached_bili_cookie = nil
        end
        if on_complete then on_complete(bili_is_valid, bili_uname, bili_is_vip) end
        return
    end

    if is_verifying then
        if on_complete then table.insert(verify_callbacks, on_complete) end
        return
    end

    if on_complete then table.insert(verify_callbacks, on_complete) end
    is_verifying = true

    -- 非同步校驗階段
    verify_bilibili_cookie(bili_raw_cookie, function(valid, uname, is_vip)
        is_verifying = false
        local verify_now = os.time()
        local cbs = verify_callbacks
        verify_callbacks = {}

        local function notify_all(ok, u, v)
            for _, cb in ipairs(cbs) do
                pcall(cb, ok, u, v)
            end
        end

        if valid then
            bili_verified = true
            bili_is_valid = true
            bili_uname = uname
            bili_is_vip = is_vip
            last_verify_time = verify_now
            cached_bili_cookie = bili_raw_cookie
            write_active_cookies(general_lines, bili_lines, true)
            msg.info(string.format("[cookie-sync] B 站憑證校驗有效：使用者 %s%s", uname, is_vip and " (大會員)" or ""))
            notify_all(true, uname, is_vip)
        else
            if allow_browser_retry then
                msg.warn("[cookie-sync] 本地 B 站憑證已失效，嘗試自瀏覽器重新同步...")
                try_extract_browser_cookies(false, function(ok, browser)
                    if ok then
                        -- 僅允許重試 1 次，遞迴調用傳入 sync_cookies(false, false)
                        sync_cookies(false, false, function(rec_ok, rec_u, rec_v)
                            notify_all(rec_ok, rec_u, rec_v)
                        end)
                    else
                        bili_verified = true
                        bili_is_valid = false
                        bili_uname = nil
                        bili_is_vip = false
                        last_verify_time = verify_now
                        cached_bili_cookie = nil
                        write_active_cookies(general_lines, bili_lines, false)
                        msg.warn("[cookie-sync] B 站憑證未登入或已過期！已自動啟動【訪客保底模式】（剔除無效 Cookie 以保證直通 1080P/720P，防止 B 站鎖死 480P）")
                        notify_all(false, nil, false)
                    end
                end)
            else
                -- 若再失敗，直接標記失效並終止重試，杜絕無限循環與爆棧
                bili_verified = true
                bili_is_valid = false
                bili_uname = nil
                bili_is_vip = false
                last_verify_time = verify_now
                cached_bili_cookie = nil
                write_active_cookies(general_lines, bili_lines, false)
                msg.warn("[cookie-sync] B 站憑證未登入或已過期且已達重試上限！已啟動【訪客保底模式】")
                notify_all(false, nil, false)
            end
        end
    end)
end

-- 注入 B 站串流防盜鏈標頭與 Cookie，限定於當前播放串流 (file-local-options)，絕不污染全域設定
local function inject_cookie_header()
    local path = mp.get_property("path", "")
    local stream_path = mp.get_property("stream-open-filename", "")
    local target = (path .. " " .. stream_path):lower()
    if target:find("bilibili%.com") or target:find("bilivideo%.com") or target:find("akamaized%.net") or target:find("/upgcxcode/") then
        local raw_headers = mp.get_property_native("file-local-options/http-header-fields")
            or mp.get_property_native("http-header-fields")
            or {}
        local new_headers = {}
        local has_cookie = false
        local has_referer = false
        local has_origin = false

        for _, h in ipairs(raw_headers) do
            table.insert(new_headers, h)
            local hl = h:lower()
            if hl:match("^cookie:") then has_cookie = true end
            if hl:match("^referer:") then has_referer = true end
            if hl:match("^origin:") then has_origin = true end
        end

        if not has_referer then
            table.insert(new_headers, "referer: https://www.bilibili.com")
        end
        if not has_origin then
            table.insert(new_headers, "origin: https://www.bilibili.com")
        end

        if cached_bili_cookie and cached_bili_cookie ~= "" and not has_cookie then
            table.insert(new_headers, "cookie: " .. cached_bili_cookie)
            msg.info("[cookie-sync] 已成功向 B 站串流注入已認證身分憑證 (file-local)")
        end

        mp.set_property_native("file-local-options/http-header-fields", new_headers)
    end
end

-- 註冊選單點擊 / 快捷訊息：手動觸發同步
mp.register_script_message("sync-browser-cookies", function()
    try_extract_browser_cookies(true, function(ok, browser)
        if ok then
            sync_cookies(true, false, function(valid, uname, is_vip)
                if valid then
                    mp.osd_message(string.format("[Cookies] 同步成功 (%s)！\nB 站: %s%s\nYouTube: 憑證已就緒", browser, uname or "已登入", is_vip and " (大會員)" or ""), 4)
                else
                    mp.osd_message(string.format("[Cookies] 同步完成 (%s)！\nB 站: 訪客模式 (最高 1080P)\nYouTube: 憑證已就緒", browser), 4)
                end
            end)
        else
            mp.osd_message("[Cookies] 同步失敗：請確認 Firefox 是否有登入該網站", 4)
        end
    end)
end)

sync_cookies(true)
mp.register_event("start-file", function() sync_cookies(false) end)
mp.add_hook("on_load", 15, inject_cookie_header)
