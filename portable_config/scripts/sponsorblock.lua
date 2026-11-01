-- sponsorblock.lua
-- 統一 SponsorBlock 模組 (完整支援 YouTube 與 Bilibili 小電視空降助手)
-- 核心特性：
-- 1. 雙平台自動精準識別：YouTube (SponsorBlock 官方 API) + Bilibili (BilibiliSponsorBlock / bsbsb.top)
-- 2. 進度條全彩區間標記：與 ModernZ 深度整合，進度條直接繪製對應類別顏色區間
-- 3. 自動精確跳過：進入商業廣告、促銷等片段時自動秒跳，並顯示 OSD 提示；支援開檔/恢復播放瞬間處於廣告時秒跳
-- 4. 支援跳過復原：按 Alt+u 即可一鍵跳回廣告開頭
-- 5. 時間軸章節標記：自動寫入 MPV [SB] 章節，與進度條切換點完美融合

local mp = require 'mp'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

local config_dir = mp.command_native({"expand-path", "~~/"})
local helper_py = utils.join_path(config_dir, "sponsorblock_shared/sponsor_unified.py")

local current_segments = {}
local last_skip = nil
local active_video_id = nil
local is_fetching = false

local function format_time(seconds)
    if not seconds or seconds < 0 then return "00:00" end
    local s = math.floor(seconds)
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    if h > 0 then
        return string.format("%02d:%02d:%02d", h, m, sec)
    else
        return string.format("%02d:%02d", m, sec)
    end
end

local function clean_chapters()
    local chapters = mp.get_property_native("chapter-list") or {}
    local new_chapters = {}
    for _, ch in ipairs(chapters) do
        if not ch.title or not ch.title:match("^%[SB%]") then
            table.insert(new_chapters, ch)
        end
    end
    mp.set_property_native("chapter-list", new_chapters)
end

local function add_sb_chapters(segments)
    if not segments or #segments == 0 then return end
    local chapters = mp.get_property_native("chapter-list") or {}
    local dur = mp.get_property_number("duration", 0)

    for _, seg in ipairs(segments) do
        if seg.end_time and seg.start_time and seg.end_time > seg.start_time then
            local name = seg.name or "贊助片段"
            local st = math.max(0, seg.start_time)
            local et = (dur > 0 and seg.end_time >= dur) and (dur - 0.05) or seg.end_time
            table.insert(chapters, {
                title = string.format("[SB] %s 開始", name),
                time = st
            })
            table.insert(chapters, {
                title = string.format("[SB] %s 結束", name),
                time = et
            })
        end
    end

    table.sort(chapters, function(a, b) return a.time < b.time end)
    mp.set_property_native("chapter-list", chapters)
end

local function extract_ids()
    local path = mp.get_property("path") or ""
    local webpage_url = mp.get_property("metadata/by-key/webpage_url") or ""
    local filtered_url = mp.get_property("filtered-metadata/by-key/webpage_url") or ""
    local stream_open = mp.get_property("stream-open-filename") or ""
    local filename = mp.get_property("filename") or ""
    local media_title = mp.get_property("media-title") or ""
    local playlist_path = mp.get_property("playlist-path") or ""
    
    local targets = { webpage_url, filtered_url, path, stream_open, filename, media_title, playlist_path }
    local yt_id = nil
    local bvid = nil

    for _, target in ipairs(targets) do
        if target and target ~= "" then
            -- 1. YouTube ID (11 字元 ID，嚴格比對，排除 googlevideo EDL token 誤判)
            if not yt_id then
                local y = target:match("[?&]v=([%w_%-]+)")
                    or target:match("youtu%.be/([%w_%-]+)")
                    or target:match("youtube%.com/shorts/([%w_%-]+)")
                    or target:match("youtube%.com/embed/([%w_%-]+)")
                    or target:match("youtube%.com/live/([%w_%-]+)")
                    or target:match("ytdl://([%w_%-]+)")
                    or target:match("%[([%w_%-]{11})%]")
                    or target:match("%-([%w_%-]{11})%.%w+$")
                if y and #y >= 11 then
                    yt_id = y:sub(1, 11)
                end
            end

            -- 2. Bilibili BV ID (以 BV1 開頭，長度至少 10 位) 或 AV ID
            if not bvid then
                local b = target:match("([Bb][Vv]1[%w]+)")
                    or target:match("bilibili%.com/video/([Bb][Vv][%w]+)")
                if b and #b >= 10 then
                    bvid = b
                else
                    local a = target:match("bilibili%.com/video/[Aa][Vv](%d+)")
                        or target:match("[Aa][Vv](%d%d%d%d%d+)")
                        or target:match("^[Aa][Vv](%d+)$")
                    if a then
                        bvid = "av" .. a
                    end
                end
            end
        end
    end

    return bvid, yt_id
end

-- 自動跳過監聽器 (前置宣告以便 fetch_segments 結束後立即觸發)
local on_time_pos

local function fetch_segments(url, yt_id, bvid)
    if is_fetching then return end
    is_fetching = true

    local args = { 'python', '-X', 'utf8', helper_py }
    if yt_id and yt_id ~= "" then
        table.insert(args, '--yt-id')
        table.insert(args, yt_id)
    elseif bvid and bvid ~= "" then
        table.insert(args, '--bvid')
        table.insert(args, bvid)
    elseif url and url ~= "" then
        table.insert(args, '--url')
        table.insert(args, url)
    else
        is_fetching = false
        return
    end

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = args
    }, function(success, result, error)
        is_fetching = false
        if success and result and result.status == 0 and result.stdout then
            local data = utils.parse_json(result.stdout)
            if data and data.status == "ok" and data.segments and #data.segments > 0 then
                current_segments = {}
                for _, s in ipairs(data.segments) do
                    table.insert(current_segments, {
                        uuid = s.uuid or "",
                        category = s.category or "sponsor",
                        name = s.name or "贊助片段",
                        color = s.color or "#00D482",
                        action = s.action or "skip",
                        skip = (s.skip == true),
                        start = tonumber(s.start) or 0,
                        start_time = tonumber(s.start) or 0,
                        ["end"] = tonumber(s["end"]) or 0,
                        end_time = tonumber(s["end"]) or 0,
                        skipped = false
                    })
                end

                -- 共享至 user-data 供 ModernZ seekbar 繪製彩色區間
                mp.set_property_native("user-data/sponsorblock/segments", current_segments)
                add_sb_chapters(current_segments)

                local service_name = (data.service == "bilibili") and "B站空降助手" or "YouTube SponsorBlock"
                mp.osd_message(string.format("[%s] 成功載入 %d 個標記片段", service_name, #current_segments), 2.5)
                mp.msg.info(string.format("[%s] 成功載入 %d 個標記片段 (Video ID: %s)", service_name, #current_segments, data.video_id or "未知"))

                -- 若當前播放時間已在跳過區間中 (如從歷史進度恢復播放)，立即觸發跳過
                local cur_pos = mp.get_property_number("time-pos")
                if cur_pos then
                    on_time_pos("time-pos", cur_pos)
                end
                return
            end
        end

        current_segments = {}
        mp.set_property_native("user-data/sponsorblock/segments", {})
    end)
end

local sb_overlay = mp.create_osd_overlay('ass-events')
sb_overlay.z = 2100
local manual_skip_active = nil
local manual_skip_btn_rect = nil

local MANUAL_SKIP_SECTION = "sponsorblock_manual_skip"

mp.set_key_bindings({
    {"mbtn_left", function()
        if manual_skip_active then
            execute_manual_skip(manual_skip_active)
        end
    end}
}, MANUAL_SKIP_SECTION, "force")

local function hide_manual_skip()
    if manual_skip_active then
        manual_skip_active = nil
        manual_skip_btn_rect = nil
        sb_overlay.hidden = true
        sb_overlay.data = ""
        sb_overlay:update()
        mp.set_mouse_area(0, 0, 0, 0, MANUAL_SKIP_SECTION)
        mp.disable_key_bindings(MANUAL_SKIP_SECTION)
        pcall(mp.remove_key_binding, "sb_manual_skip_tab")
    end
end

local function execute_manual_skip(seg)
    if not seg then return end
    hide_manual_skip()
    last_skip = {
        segment = seg,
        from_pos = mp.get_property_number("time-pos", seg.start_time),
        to_pos = seg.end_time
    }
    mp.set_property_number("time-pos", seg.end_time)
    local msg = string.format("⏩ [SponsorBlock] 已手動跳過 %s\n(%s → %s | 按 Alt+u 可復原)", 
        seg.name, format_time(seg.start_time), format_time(seg.end_time))
    mp.osd_message(msg, 3.0)
    mp.msg.info(msg)
end

local function show_manual_skip(seg)
    if not seg then return end
    manual_skip_active = seg

    local ww, wh = mp.get_osd_size()
    if not ww or ww == 0 then ww, wh = 1280, 720 end
    sb_overlay.res_x = ww
    sb_overlay.res_y = wh

    local btn_w = math.min(320, ww - 24)
    local btn_h = 38
    local btn_x = math.max(12, ww - btn_w - 24)

    local btn_y = wh - btn_h - 24
    local osc_visible = mp.get_property_bool("user-data/osc/visible", false)
    local panel_rect = mp.get_property_native("user-data/osc/panel_rect")
    if osc_visible and panel_rect and panel_rect.y1 and panel_rect.playresy and panel_rect.playresy > 0 then
        local osc_top = math.floor(panel_rect.y1 * (wh / panel_rect.playresy))
        if osc_top > 0 and osc_top < wh then
            btn_y = math.floor(osc_top - btn_h - 12)
        end
    end

    manual_skip_btn_rect = { x1 = btn_x, y1 = btn_y, x2 = btn_x + btn_w, y2 = btn_y + btn_h }

    local ass = assdraw.ass_new()
    -- 背景與細邊框 (ModernGlass 質感暗色微透半透明圓角膠囊)
    ass:new_event()
    ass:append("{\\pos(0,0)\\bord1.2\\3c&HFFFFFF&\\3a&H80&\\1c&H161618&\\1a&H18&}")
    ass:draw_start()
    ass:round_rect_cw(btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, 8)
    ass:draw_stop()

    -- 內層文字
    local cx = math.floor(btn_x + btn_w / 2)
    local cy = math.floor(btn_y + btn_h / 2)
    ass:new_event()
    ass:append(string.format(
        "{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\b1\\fnMicrosoft JhengHei\\1c&H00D482&}⏩ 跳過 %s {\\fs12\\b0\\1c&HFFFFFF&}(按 {\\b1\\1c&HFFDE59&}Tab{\\b0\\1c&HFFFFFF&} 或點擊)",
        cx, cy, seg.name
    ))

    sb_overlay.hidden = false
    sb_overlay.data = ass.text
    sb_overlay:update()

    mp.set_mouse_area(btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, MANUAL_SKIP_SECTION)
    mp.enable_key_bindings(MANUAL_SKIP_SECTION)

    mp.add_forced_key_binding("TAB", "sb_manual_skip_tab", function()
        execute_manual_skip(seg)
    end)
end

mp.observe_property("osd-dimensions", "native", function()
    if manual_skip_active then
        show_manual_skip(manual_skip_active)
    end
end)

mp.observe_property("user-data/osc/visible", "bool", function(_, vis)
    if manual_skip_active then
        show_manual_skip(manual_skip_active)
    end
end)

mp.observe_property("user-data/osc/panel_rect", "native", function()
    if manual_skip_active then
        show_manual_skip(manual_skip_active)
    end
end)

mp.register_script_message("sponsorblock-show-skip", function(name)
    show_manual_skip({ name = (name and name ~= "") and name or "贊助商片段", start_time = 5, end_time = 25 })
end)
mp.register_script_message("sponsorblock-hide-skip", hide_manual_skip)

-- 自動跳過與手動跳過按鈕監聽器
on_time_pos = function(name, pos)
    if not pos or #current_segments == 0 then
        hide_manual_skip()
        return
    end

    local in_manual_seg = nil

    for _, seg in ipairs(current_segments) do
        -- 離開該區間時重置 skipped 狀態，以便使用者倒退重播時能再度跳過
        if pos < (seg.start_time - 1.0) or pos > (seg.end_time + 1.0) then
            seg.skipped = false
        end

        if seg.end_time > seg.start_time then
            if seg.skip and not seg.skipped then
                -- 自動跳過區間（預設僅商業贊助廣告）
                if pos >= (seg.start_time - 0.2) and pos < (seg.end_time - 0.2) then
                    seg.skipped = true
                    hide_manual_skip()
                    last_skip = {
                        segment = seg,
                        from_pos = pos,
                        to_pos = seg.end_time
                    }
                    mp.set_property_number("time-pos", seg.end_time)
                    local msg = string.format("⏩ [SponsorBlock] 已跳過 %s\n(%s → %s | 按 Alt+u 可復原)", 
                        seg.name, format_time(seg.start_time), format_time(seg.end_time))
                    mp.osd_message(msg, 3.5)
                    mp.msg.info(msg)
                    return
                end
            elseif not seg.skip then
                -- 手動跳過區間（片頭、片尾、精彩看點、自促銷等）
                if pos >= seg.start_time and pos < seg.end_time then
                    in_manual_seg = seg
                end
            end
        end
    end

    if in_manual_seg then
        show_manual_skip(in_manual_seg)
    else
        hide_manual_skip()
    end
end

-- 復原上次跳過
local function undo_skip()
    if last_skip and last_skip.segment then
        local seg = last_skip.segment
        mp.set_property_number("time-pos", seg.start_time)
        seg.skipped = true
        hide_manual_skip()
        mp.osd_message(string.format("⏪ [SponsorBlock] 已復原，返回 %s 開始處", seg.name), 2.5)
        last_skip = nil
    else
        mp.osd_message("[SponsorBlock] 無可復原的跳過紀錄", 2.0)
    end
end

local function check_and_fetch()
    local bvid, yt_id = extract_ids()
    local target_id = yt_id or bvid
    if not target_id then return end

    -- 若目前已有同一部影片的數據或正在抓取中，不重複請求
    if active_video_id == target_id and (#current_segments > 0 or is_fetching) then
        return
    end

    active_video_id = target_id
    if yt_id then
        fetch_segments("", yt_id, nil)
    elseif bvid then
        fetch_segments("", nil, bvid)
    end
end

local function on_file_loaded()
    hide_manual_skip()
    local bvid, yt_id = extract_ids()
    local target_id = yt_id or bvid

    -- 只有切換不同影片時才清空現存數據
    if active_video_id ~= target_id then
        clean_chapters()
        current_segments = {}
        last_skip = nil
        active_video_id = nil
        is_fetching = false
        mp.set_property_native("user-data/sponsorblock/segments", {})
    else
        -- 若在 file-loaded 之前就已取得片段，重新刷新章節與進度條繪製
        if #current_segments > 0 then
            add_sb_chapters(current_segments)
            mp.set_property_native("user-data/sponsorblock/segments", current_segments)
        end
    end

    check_and_fetch()
end

local function on_end_file()
    hide_manual_skip()
    clean_chapters()
    current_segments = {}
    last_skip = nil
    active_video_id = nil
    is_fetching = false
    mp.set_property_native("user-data/sponsorblock/segments", {})
end

-- 監聽 B2Y 匹配事件：若 YouTube 影片本身無 sponsor 標記，但匹配到 B 站影片，則自動補充 B 站標記
mp.register_script_message("sponsorblock-load-bvid", function(matched_bvid)
    if matched_bvid and matched_bvid ~= "" and (#current_segments == 0) then
        mp.msg.info("[SponsorBlock] B2Y 匹配到 B 站影片 " .. matched_bvid .. "，嘗試載入空降助手標記...")
        fetch_segments("", nil, matched_bvid)
    end
end)

mp.observe_property("time-pos", "number", on_time_pos)
mp.observe_property("path", "string", check_and_fetch)
mp.observe_property("media-title", "string", check_and_fetch)
mp.observe_property("metadata", "native", function()
    check_and_fetch()
end)
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", on_end_file)

mp.add_key_binding("Alt+u", "sponsorblock-undo", undo_skip)
