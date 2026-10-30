-- b2y-menu.lua
-- 高仿真 B2Y 視覺化彈幕匹配與管理面板
-- 核心特性：
-- 1. 使用 mp.create_osd_overlay('ass-events') 與 mp.get_osd_size()，保證任意視窗尺寸/解析度完美居中且滑鼠座標 100% 精準對齊
-- 2. 仿真 B 站擴充套件視覺風格（搜尋框、候選列表、手動匹配卡片）
-- 3. 候選影片清單即點即切換、剪貼簿連結一鍵導入
-- 4. Windows 食指指標 (IDC_HAND) 與青藍色懸停反饋
-- 5. 支援 UTF-8 安全字串截斷，徹底杜絕中文亂碼與字尾字元破碎問題

local mp = require 'mp'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

local osd = mp.create_osd_overlay('ass-events')
local is_open = false
local prev_dragging = "yes"
local hovered_btn = nil

-- =====================================================================
-- 【B2Y 面板自訂尺寸與字體設定】
-- 若您日後想將面板調大、調小或縮放字體，可直接在此處修改數值：
-- =====================================================================
local CW = 820             -- 面板寬度 (預設 720 像素，建議範圍: 600 ~ 950)
local CH = 600             -- 面板高度 (預設 530 像素，建議範圍: 450 ~ 750)
local FONT_TITLE = 20      -- 頂部主標題字體大小
local FONT_SUB = 15        -- 區塊次標題字體大小 (如「當前匹配」、「候選列表」)
local FONT_BODY = 16       -- 內文字體大小 (搜尋框、影片標題)
local FONT_META = 14       -- 次要資訊字體大小 (UP主、彈幕數、時長)
local FONT_BTN = 15        -- 按鈕字體大小 (搜尋、手動匹配、清除彈幕)
-- =====================================================================

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

local function get_card_pos()
    local ww, wh = mp.get_osd_size()
    if not ww or ww == 0 then ww, wh = 1280, 720 end
    local cur_w = math.min(CW, ww - 24)
    local cur_h = math.min(CH, wh - 24)
    local x0 = math.max(12, math.floor((ww - cur_w) / 2))
    local y0 = math.max(12, math.floor((wh - cur_h) / 2))
    return x0, y0, cur_w, cur_h, ww, wh
end

-- 安全 UTF-8 字串長度截斷，絕不斷在多位元組字元中間
local function utf8_truncate(str, max_chars)
    if not str or str == "" then return "" end
    local ulen = 0
    local byte_pos = 1
    local len = #str
    while byte_pos <= len do
        ulen = ulen + 1
        local b = str:byte(byte_pos)
        local step = 1
        if b >= 0xF0 then step = 4
        elseif b >= 0xE0 then step = 3
        elseif b >= 0xC0 then step = 2
        end
        if ulen > max_chars then
            return str:sub(1, byte_pos - 1) .. "..."
        end
        byte_pos = byte_pos + step
    end
    return str
end

local buttons = {}
local close_menu -- 前置宣告

local function render_menu()
    if not is_open then
        osd.hidden = true
        osd.data = ''
        osd:update()
        return
    end

    local x0, y0, w, h, ww, wh = get_card_pos()
    buttons = {}
    local ass = assdraw.ass_new()

    -- 1. 半透明暗色背景遮罩 (覆蓋全視窗)
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H70&}")
    ass:draw_start()
    ass:rect_cw(0, 0, ww, wh)
    ass:draw_stop()

    -- 2. 卡片外框與深色本體
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H444444&\\1c&H1e1e1e&\\1a&H08&\\3a&H30&}")
    ass:draw_start()
    ass:round_rect_cw(x0, y0, x0 + w, y0 + h, 12)
    ass:draw_stop()

    -- 3. 頂部標題與關閉按鈕
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}B站彈幕 (B2Y 跨平台匹配)", x0 + 22, y0 + 26, FONT_TITLE))

    local close_is_h = (hovered_btn == "close")
    local close_col = close_is_h and "\\1c&HD8A000&\\b1" or "\\1c&H888888&\\b0"
    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei%s}✕", x0 + w - 24, y0 + 26, FONT_TITLE + 2, close_col))
    table.insert(buttons, { id = "close", x = x0 + w - 44, y = y0 + 10, w = 36, h = 36 })

    -- 取得當前數據
    local b2y_info = mp.get_property_native("user-data/b2y/info") or {}
    local yt_title = b2y_info.yt_title or mp.get_property("media-title") or "未獲取到影片標題"
    local search_kw = b2y_info.search_query or yt_title

    -- 4. 搜尋列（輸入框 + 搜尋按鈕）
    local s_box_x = x0 + 20
    local s_box_y = y0 + 52
    local s_btn_w = 90
    local s_box_w = w - 40 - s_btn_w - 10
    local s_box_h = 42

    -- 搜尋框本體
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H3a3a3a&\\1c&H2b2b2b&\\1a&H10&}")
    ass:draw_start()
    ass:round_rect_cw(s_box_x, s_box_y, s_box_x + s_box_w, s_box_y + s_box_h, 6)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&HE0E0E0&}%s", s_box_x + 12, s_box_y + s_box_h / 2, FONT_BODY, utf8_truncate(search_kw, 34)))

    -- 搜尋按鈕
    local s_btn_x = s_box_x + s_box_w + 10
    local s_btn_is_h = (hovered_btn == "search")
    local s_btn_bg = s_btn_is_h and "\\1c&HF5B500&" or "\\1c&HD8A000&"
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0" .. s_btn_bg .. "}")
    ass:draw_start()
    ass:round_rect_cw(s_btn_x, s_box_y, s_btn_x + s_btn_w, s_box_y + s_box_h, 6)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}搜尋", s_btn_x + s_btn_w / 2, s_box_y + s_box_h / 2, FONT_BTN))
    table.insert(buttons, { id = "search", x = s_btn_x, y = s_box_y, w = s_btn_w, h = s_box_h })

    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&H888888&}按當前標題搜尋 B 站影片", s_box_x, s_box_y + s_box_h + 12, FONT_META - 1))

    -- 5. 當前匹配狀態卡片
    local status_y = s_box_y + s_box_h + 28
    local status_h = 92
    local is_matched = (b2y_info.status == "ok" or b2y_info.status == "bilibili_native")
    local st_border = is_matched and "\\3c&H82D400&" or "\\3c&H2AA6FE&"
    local st_bg = is_matched and "\\1c&H1c2620&" or "\\1c&H26221c&"

    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord1" .. st_border .. st_bg .. "\\1a&H10&}")
    ass:draw_start()
    ass:round_rect_cw(s_box_x, status_y, s_box_x + w - 40, status_y + status_h, 8)
    ass:draw_stop()

    if is_matched then
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&H82D400&}● 當前已匹配 B 站影片：", s_box_x + 14, status_y + 18, FONT_SUB))
        local t_show = utf8_truncate(b2y_info.title or b2y_info.bvid or "", 38)
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%s", s_box_x + 14, status_y + 44, FONT_BODY, t_show))
        local sub_info = string.format("稿件：%s ｜ UP：%s ｜ 彈幕：%s 條 ｜ 時長：%s", 
            b2y_info.bvid or "未知", b2y_info.author or "未知", tostring(b2y_info.danmaku or 0), b2y_info.duration or "--:--")
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&HAAAAAA&}%s", s_box_x + 14, status_y + 70, FONT_META, sub_info))
    else
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&H2AA6FE&}○ 未匹配到B站視頻，可搜尋標題或輸入視頻連結", s_box_x + 14, status_y + 28, FONT_SUB))
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&HAAAAAA&}%s", s_box_x + 14, status_y + 58, FONT_META, b2y_info.message or "點選下方候選影片切換，或使用剪貼簿手動匹配"))
    end

    -- 6. 候選影片清單（點選即換）
    local cand_title_y = status_y + status_h + 18
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&HE0E0E0&}B 站候選影片列表 (滑鼠點選立即更換彈幕)：", s_box_x, cand_title_y, FONT_SUB))

    local cand_y = cand_title_y + 16
    local candidates = b2y_info.candidates or {}
    if #candidates == 0 then
        ass:new_event()
        ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H2f2f2f&\\1c&H232323&}")
        ass:draw_start()
        ass:round_rect_cw(s_box_x, cand_y, s_box_x + w - 40, cand_y + 44, 6)
        ass:draw_stop()

        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&H777777&}（暫無候選，點擊上方【搜尋】或複製 B 站連結後點擊下方手動匹配）", s_box_x + (w - 40) / 2, cand_y + 22, FONT_META))
        cand_y = cand_y + 52
    else
        local show_n = math.min(#candidates, 3)
        for i = 1, show_n do
            local c = candidates[i]
            local c_btn_id = "cand_" .. tostring(i)
            local is_h = (hovered_btn == c_btn_id)
            local c_border = is_h and "\\3c&HD8A000&" or "\\3c&H333333&"
            local c_bg = is_h and "\\1c&H2b3c4a&" or "\\1c&H232323&"

            local item_h = 42
            ass:new_event()
            ass:append("{\\an7\\pos(0,0)\\bord1" .. c_border .. c_bg .. "}")
            ass:draw_start()
            ass:round_rect_cw(s_box_x, cand_y, s_box_x + w - 40, cand_y + item_h, 6)
            ass:draw_stop()

            local c_t_col = is_h and "\\1c&HD8A000&\\b1" or "\\1c&HFFFFFF&\\b0"
            local item_txt = string.format("[%d] %s", i, utf8_truncate(c.title or c.bvid or "", 32))
            ass:new_event()
            ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei%s}%s", s_box_x + 12, cand_y + item_h / 2, FONT_BODY - 1, c_t_col, item_txt))

            local meta = string.format("%s ｜ %d彈幕 ｜ %s", c.author or "", c.danmaku or 0, c.duration or "")
            ass:new_event()
            ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&H888888&}%s", s_box_x + w - 52, cand_y + item_h / 2, FONT_META, meta))

            table.insert(buttons, { id = c_btn_id, bvid = c.bvid, x = s_box_x, y = cand_y, w = w - 40, h = item_h })
            cand_y = cand_y + item_h + 8
        end
    end

    -- 7. 底部剪貼簿與操作按鈕
    local bottom_y = y0 + h - 56
    local clip_text = mp.get_property("clipboard/text") or ""
    local clip_bv = clip_text:match("([Bb][Vv][%w]+)") or clip_text:match("([Aa][Vv]%d+)")

    local manual_w = 110
    local unload_w = 95
    local b_h = 42
    local clip_w = w - 40 - manual_w - unload_w - 20

    -- 剪貼簿預覽框
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H333333&\\1c&H232323&}")
    ass:draw_start()
    ass:round_rect_cw(s_box_x, bottom_y, s_box_x + clip_w, bottom_y + b_h, 6)
    ass:draw_stop()

    if clip_bv then
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&HD8A000&}剪貼簿：%s", s_box_x + 10, bottom_y + b_h / 2, FONT_META, clip_bv))
    else
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&H666666&}https://bilibili.com/video/BV...", s_box_x + 10, bottom_y + b_h / 2, FONT_META))
    end

    -- 【手動匹配】按鈕
    local manual_x = s_box_x + clip_w + 10
    local m_is_h = (hovered_btn == "manual")
    local m_bg = m_is_h and "\\1c&HF5B500&" or "\\1c&HD8A000&"
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0" .. m_bg .. "}")
    ass:draw_start()
    ass:round_rect_cw(manual_x, bottom_y, manual_x + manual_w, bottom_y + b_h, 6)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs%d\\b1\\fnMicrosoft JhengHei\\1c&HFFFFFF&}手動匹配", manual_x + manual_w / 2, bottom_y + b_h / 2, FONT_BTN))
    table.insert(buttons, { id = "manual", x = manual_x, y = bottom_y, w = manual_w, h = b_h })

    -- 【清除彈幕】按鈕
    local unload_x = manual_x + manual_w + 10
    local u_is_h = (hovered_btn == "unload")
    local u_bg = u_is_h and "\\1c&H4a4a4a&" or "\\1c&H363636&"
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0" .. u_bg .. "}")
    ass:draw_start()
    ass:round_rect_cw(unload_x, bottom_y, unload_x + unload_w, bottom_y + b_h, 6)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs%d\\fnMicrosoft JhengHei\\1c&HCCCCCC&}清除彈幕", unload_x + unload_w / 2, bottom_y + b_h / 2, FONT_BTN))
    table.insert(buttons, { id = "unload", x = unload_x, y = bottom_y, w = unload_w, h = b_h })

    osd.res_x = ww
    osd.res_y = wh
    osd.hidden = false
    osd.data = ass.text
    osd:update()
end

local function on_mouse_move()
    if not is_open then return end
    local mx, my = mp.get_mouse_pos()
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
    local mx, my = mp.get_mouse_pos()
    local x0, y0, w, h = get_card_pos()

    -- 點選卡片外部自動關閉
    if mx < x0 or mx > x0 + w or my < y0 or my > y0 + h then
        close_menu()
        return
    end

    for _, btn in ipairs(buttons) do
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
            if btn.id == "close" then
                close_menu()
            elseif btn.id == "search" then
                local b2y_info = mp.get_property_native("user-data/b2y/info") or {}
                local q = b2y_info.search_query or b2y_info.yt_title or mp.get_property("media-title") or ""
                mp.commandv("script-message", "b2y-search", q)
                mp.add_timeout(0.5, render_menu)
            elseif btn.id:match("^cand_") and btn.bvid then
                mp.osd_message("[B2Y] 正在載入候選彈幕: " .. btn.bvid .. "...", 2.0)
                mp.commandv("script-message", "b2y-select-candidate", btn.bvid)
                close_menu()
            elseif btn.id == "manual" then
                mp.commandv("script-message", "b2y-manual-clipboard")
                close_menu()
            elseif btn.id == "unload" then
                mp.commandv("script-message", "b2y-unload")
                close_menu()
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

    mp.remove_key_binding("b2y_panel_mbtn_left")
    mp.remove_key_binding("b2y_panel_mouse_move")
    mp.remove_key_binding("b2y_panel_esc")
    mp.remove_key_binding("b2y_panel_mbtn_right")

    osd.hidden = true
    osd.data = ''
    osd:update()
end

local function open_menu()
    is_open = true
    hovered_btn = nil
    prev_dragging = mp.get_property("window-dragging", "yes")
    pcall(function()
        mp.set_property("window-dragging", "no")
    end)

    mp.add_forced_key_binding("MBTN_LEFT", "b2y_panel_mbtn_left", on_mouse_click)
    mp.add_forced_key_binding("MOUSE_MOVE", "b2y_panel_mouse_move", on_mouse_move)
    mp.add_forced_key_binding("ESC", "b2y_panel_esc", close_menu)
    mp.add_forced_key_binding("MBTN_RIGHT", "b2y_panel_mbtn_right", close_menu)

    render_menu()
end

local function toggle_menu()
    if is_open then
        close_menu()
    else
        open_menu()
    end
end

mp.observe_property("user-data/b2y/info", "native", function()
    if is_open then render_menu() end
end)

mp.observe_property("osd-dimensions", "native", function()
    if is_open then render_menu() end
end)

mp.add_key_binding("Alt+y", "b2y-toggle-menu", toggle_menu)
mp.add_key_binding("Ctrl+b", "b2y-toggle-menu-ctrl", toggle_menu)

mp.register_script_message("b2y-open-menu", open_menu)
mp.register_script_message("b2y-close-menu", close_menu)
