-- cookie-sync.lua
-- 保護使用者的 cookies.txt 不被 yt-dlp 在結束時覆寫 / 清空
-- 同時自動支援：1. 瀏覽器擴充匯出的標準 Netscape 格式
--             2. 開發者工具/PotPlayer 複製的原始 Cookie 字串 (SESSDATA=xxx; bili_jct=yyy; ...)
--             3. 自動提取 B 站 Cookie，向 MPV 的 http-header-fields 動態注入身分憑證

local utils = require 'mp.utils'
local msg = require 'mp.msg'

local mpv_root = mp.command_native({"expand-path", "~~/"})
local user_cookie_file = utils.join_path(mpv_root, "cookies.txt")
local temp_dir = os.getenv("TEMP") or utils.join_path(mpv_root, "cache")
local active_cookie_file = utils.join_path(temp_dir, "mpv_active_cookies.txt")

local cached_bili_cookie = nil

local function try_extract_browser_cookies()
    local ytdl_path = utils.join_path(mpv_root, "yt-dlp.exe")
    local info = utils.file_info(ytdl_path)
    if not info then
        ytdl_path = utils.join_path(mpv_root, "../yt-dlp.exe")
        info = utils.file_info(ytdl_path)
    end
    if not info then ytdl_path = "yt-dlp" end
    msg.info("[cookie-sync] 檢測到本地缺少 YouTube 憑證，嘗試自 Firefox 瀏覽器同步...")
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            ytdl_path,
            "--cookies-from-browser", "firefox",
            "--cookies", user_cookie_file,
            "--simulate", "--skip-download",
            "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        }
    })
    if res and res.status == 0 then
        msg.info("[cookie-sync] 成功自 Firefox 同步最新 Cookies！")
        return true
    end
    msg.warn("[cookie-sync] 無法自瀏覽器同步 Cookies")
    return false
end

local function sync_cookies()
    local f = io.open(user_cookie_file, "r")
    local content = nil
    if f then
        content = f:read("*all")
        f:close()
    end

    if not content or not content:find("youtube%.com") then
        if try_extract_browser_cookies() then
            local f2 = io.open(user_cookie_file, "r")
            if f2 then
                content = f2:read("*all")
                f2:close()
            end
        end
    end

    if not content then
        local out = io.open(active_cookie_file, "w")
        if out then
            out:write("# Netscape HTTP Cookie File\n")
            out:close()
        end
        return
    end

    local out = io.open(active_cookie_file, "w")
    if not out then return end
    out:write("# Netscape HTTP Cookie File\n")

    local bili_pairs = {}

    if content and not content:match("^%s*$") then
        for line in content:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" and not trimmed:match("^#") then
                local _, tab_count = trimmed:gsub("\t", "")
                if tab_count >= 5 then
                    out:write(trimmed .. "\n")
                    local parts = {}
                    for p in trimmed:gmatch("[^\t]+") do table.insert(parts, p) end
                    if #parts >= 7 and parts[1]:find("bilibili%.com") then
                        table.insert(bili_pairs, parts[6] .. "=" .. parts[7])
                    end
                else
                    local clean = trimmed:gsub("^[Cc]ookie:%s*", "")
                    for pair in clean:gmatch("[^;]+") do
                        local k, v = pair:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
                        if k and v and k ~= "" and v ~= "" and not k:match("^#") then
                            local is_yt = (k:match("^__Secure") or k:match("^__Host") or k == "SID" or k == "HSID" or k == "SSID" or k == "APISID" or k == "SAPISID" or k == "LOGIN_INFO" or k == "PREF" or k == "YSC" or k == "VISITOR_INFO1_LIVE" or k == "VISITOR_PRIVACY_METADATA" or k == "NID" or k == "wide" or k == "SIDCC")
                            local domain = is_yt and ".youtube.com" or ".bilibili.com"
                            out:write(string.format("%s\tTRUE\t/\tFALSE\t2147483647\t%s\t%s\n", domain, k, v))
                            if not is_yt then
                                table.insert(bili_pairs, k .. "=" .. v)
                            end
                        end
                    end
                end
            end
        end
    end
    out:close()
    if #bili_pairs > 0 then
        cached_bili_cookie = table.concat(bili_pairs, "; ")
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

        if not cached_bili_cookie then sync_cookies() end
        if cached_bili_cookie and cached_bili_cookie ~= "" and not has_cookie then
            mp.commandv("change-list", "http-header-fields", "append", "cookie: " .. cached_bili_cookie)
            mp.msg.info("[cookie-sync] 已成功向 B 站串流請求注入本地 cookies.txt 身分憑證")
        end
    end
end

sync_cookies()
mp.register_event("start-file", sync_cookies)
mp.add_hook("on_load", 15, inject_cookie_header)
mp.register_script_message("sync-browser-cookies", function()
    if try_extract_browser_cookies() then
        sync_cookies()
    end
end)


