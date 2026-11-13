-- cookie-sync.lua
-- 1. 保護使用者的 cookies.txt 不被 yt-dlp 在結束時覆寫 / 清空
-- 2. 智慧 Cookie 憑證管理：
--    - 支援標準 Netscape 格式與 Raw Cookie 字串，自動消除 UTF-8 BOM
--    - 支援一鍵 / 自動自瀏覽器 (Firefox / Edge / Chrome) 同步最新憑證
--    - 即時校驗 B 站 SESSDATA 登入狀態 (檢查 API 是否返回 isLogin)
--    - 【核心防呆機制】：若檢測到 B 站 Cookie 失效或過期，自動自瀏覽器重整；
--      若仍無有效憑證，自動自給 yt-dlp 的串流參數中剔除過期 B 站 Cookie，回退為免登訪客 WBI 模式！
--      （徹底解決 B 站因接收無效/過期 Cookie 而將解析度強制鎖死限速在 480P 的問題，免登模式最高可直達 1080P/720P）
-- 3. 自動注入 B 站串流身分憑證與 Referer / Origin 防盜鏈標頭

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

local function verify_bilibili_cookie(cookie_str)
    if not cookie_str or not cookie_str:find("SESSDATA=") then
        return false, nil, false
    end
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl.exe", "-s", "--max-time", "3",
            "-H", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
            "-H", "Cookie: " .. cookie_str,
            "https://api.bilibili.com/x/web-interface/nav"
        }
    })
    if res and res.status == 0 and res.stdout then
        local data = utils.parse_json(res.stdout)
        if data and data.code == 0 and data.data and data.data.isLogin == true then
            local uname = data.data.uname or "已登入用戶"
            local is_vip = (data.data.vipType and data.data.vipType > 0)
            return true, uname, is_vip
        end
    end
    return false, nil, false
end

local function try_extract_browser_cookies(show_osd)
    local ytdl_path = get_ytdl_path()
    if show_osd then
        mp.osd_message("[Cookies] 正在自瀏覽器同步最新 Cookies...", 5)
    end
    msg.info("[cookie-sync] 嘗試從瀏覽器同步最新 Cookies...")

    -- 優先順序：Firefox (Windows 下無 Chromium DPAPI 加密阻擋) -> Edge -> Chrome
    local browsers = {"firefox", "edge", "chrome"}
    local test_url = "https://www.bilibili.com/video/BV1xx411c7mD"

    for _, browser in ipairs(browsers) do
        msg.info(string.format("[cookie-sync] 嘗試自 %s 提取 Cookies...", browser))
        os.remove(extracted_cookie_file)
        local res = mp.command_native({
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
        })
        if res and res.status == 0 then
            local fin = io.open(extracted_cookie_file, "r")
            if fin then
                local content = fin:read("*all")
                fin:close()
                if content and content:find("Netscape HTTP Cookie File") then
                    local fout = io.open(user_cookie_file, "w")
                    if fout then
                        fout:write(content)
                        fout:close()
                        msg.info(string.format("[cookie-sync] 成功自 %s 同步最新 Cookies 至本地 cookies.txt！", browser))
                        return true, browser
                    end
                end
            end
        end
    end

    msg.warn("[cookie-sync] 未能自任何瀏覽器成功提取 Cookies")
    return false, nil
end

local function sync_cookies(force_verify)
    local f = io.open(user_cookie_file, "r")
    local content = nil
    if f then
        content = strip_bom(f:read("*all"))
        f:close()
    end

    -- 若本地完全無 cookies.txt 或缺少 YouTube/Bilibili 任何一項，自動自瀏覽器提取
    if not content or (not content:find("youtube%.com") and not content:find("bilibili%.com")) then
        local ok, _ = try_extract_browser_cookies(false)
        if ok then
            local f2 = io.open(user_cookie_file, "r")
            if f2 then
                content = strip_bom(f2:read("*all"))
                f2:close()
            end
        end
    end

    if not content or content:match("^%s*$") then
        local out = io.open(active_cookie_file, "w")
        if out then
            out:write("# Netscape HTTP Cookie File\n")
            out:close()
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
    local now = os.time()

    -- 驗證 B 站憑證有效性（若強制校驗、未校驗過、或快取超過 1 小時）
    if #bili_pairs > 0 then
        if force_verify or not bili_verified or (now - last_verify_time > 3600) then
            local valid, uname, is_vip = verify_bilibili_cookie(bili_raw_cookie)
            if valid then
                bili_verified = true
                bili_is_valid = true
                bili_uname = uname
                bili_is_vip = is_vip
                last_verify_time = now
                msg.info(string.format("[cookie-sync] B 站憑證校驗有效：使用者 %s%s", uname, is_vip and " (大會員)" or ""))
            else
                msg.warn("[cookie-sync] 本地 B 站憑證已失效，嘗試自瀏覽器重新同步...")
                local ok, _ = try_extract_browser_cookies(false)
                if ok then
                    return sync_cookies(false)
                else
                    bili_verified = true
                    bili_is_valid = false
                    bili_uname = nil
                    bili_is_vip = false
                    last_verify_time = now
                    msg.warn("[cookie-sync] B 站憑證未登入或已過期！已自動啟動【訪客保底模式】（剔除無效 Cookie 以保證直通 1080P/720P，防止 B 站鎖死 480P）")
                end
            end
        end
    else
        bili_verified = true
        bili_is_valid = false
        bili_uname = nil
        bili_is_vip = false
    end

    local out = io.open(active_cookie_file, "w")
    if out then
        out:write("# Netscape HTTP Cookie File\n")
        -- 寫入通用 / YouTube 等正常 Cookie
        for _, line in ipairs(general_lines) do
            out:write(line .. "\n")
        end
        -- 只有在 B 站憑證確定有效時才寫入 B 站 Cookie！
        if bili_is_valid then
            for _, line in ipairs(bili_lines) do
                out:write(line .. "\n")
            end
            cached_bili_cookie = bili_raw_cookie
        else
            cached_bili_cookie = nil
        end
        out:close()
    end

    local ytdl_raw = mp.get_property("ytdl-raw-options", "")
    if not ytdl_raw:find("cookies=") then
        mp.commandv("change-list", "ytdl-raw-options", "append", "cookies=" .. active_cookie_file)
    end
end

local function inject_cookie_header()
    local path = mp.get_property("path", "")
    local stream_path = mp.get_property("stream-open-filename", "")
    local target = (path .. " " .. stream_path):lower()
    if target:find("bilibili%.com") or target:find("bilivideo%.com") or target:find("akamaized%.net") or target:find("/upgcxcode/") then
        local headers = mp.get_property_native("http-header-fields") or {}
        local has_cookie = false
        local has_referer = false
        local has_origin = false
        for _, h in ipairs(headers) do
            local hl = h:lower()
            if hl:match("^cookie:") then has_cookie = true end
            if hl:match("^referer:") then has_referer = true end
            if hl:match("^origin:") then has_origin = true end
        end

        if not has_referer then
            mp.commandv("change-list", "http-header-fields", "append", "referer: https://www.bilibili.com")
        end
        if not has_origin then
            mp.commandv("change-list", "http-header-fields", "append", "origin: https://www.bilibili.com")
        end

        if cached_bili_cookie and cached_bili_cookie ~= "" and not has_cookie then
            mp.commandv("change-list", "http-header-fields", "append", "cookie: " .. cached_bili_cookie)
            msg.info("[cookie-sync] 已成功向 B 站串流注入已認證身分憑證")
        end
    end
end

-- 註冊選單點擊 / 快捷訊息：手動觸發同步
mp.register_script_message("sync-browser-cookies", function()
    local ok, browser = try_extract_browser_cookies(true)
    if ok then
        sync_cookies(true)
        if bili_is_valid then
            mp.osd_message(string.format("[Cookies] 同步成功 (%s)！\nB 站: %s%s\nYouTube: 憑證已就緒", browser, bili_uname or "已登入", bili_is_vip and " (大會員)" or ""), 4)
        else
            mp.osd_message(string.format("[Cookies] 同步完成 (%s)！\nB 站: 訪客模式 (最高 1080P)\nYouTube: 憑證已就緒", browser), 4)
        end
    else
        mp.osd_message("[Cookies] 同步失敗：請確認 Firefox 是否有登入該網站", 4)
    end
end)

sync_cookies(true)
mp.register_event("start-file", function() sync_cookies(false) end)
mp.add_hook("on_load", 15, inject_cookie_header)
