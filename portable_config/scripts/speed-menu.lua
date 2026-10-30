-- speed-menu.lua
-- 仿 YouTube / Bilibili 視覺化倍速控制卡片
-- 支援滑鼠 Hover 高亮反饋、食指指標 (IDC_HAND)、0.05 精細微調滑桿與常用預設檔位

local mp = require 'mp'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

-- 載入 Windows API (ffi) 支援滑鼠游標切換為食指手指 (IDC_HAND)
local ffi_ok, ffi = pcall(require, 'ffi')
local hHand = nil
local hArrow = nil
local user32 = nil

if ffi_ok then
    pcall(function()
        ffi.cdef[[
            void* LoadCursorA(void* hInstance, int lpCursorName);
            void* SetCursor(void* hCursor);
        ]]
        user32 = ffi.load('user32')
        hHand = user32.LoadCursorA(nil, 32649)   -- IDC_HAND (食指按東西樣式)
        hArrow = user32.LoadCursorA(nil, 32512)  -- IDC_ARROW (標準箭頭樣式)
    end)
end

local function set_pointer_cursor(is_hand)
    if user32 then
        if is_hand and hHand then
            user32.SetCursor(hHand)
        elseif hArrow then
            user32.SetCursor(hArrow)
        end
    end
end

local active = false
local dragging = false
local hovered_element = nil
local timeout_timer = nil
local osd = mp.create_osd_overlay('ass-events')

-- 記憶開啟面板前的視窗拖動設定，以便關閉時還原
local prev_window_dragging = "yes"
local prev_builtin_dragging = "yes"

-- 卡片尺寸與參數
local CW = 360
local CH = 245
local MIN_SPEED = 0.25
local MAX_SPEED = 3.00

local presets = {
    { text = "1.0",  sub = "正常", val = 1.00, x_off = 50 },
    { text = "1.25", sub = "",     val = 1.25, x_off = 115 },
    { text = "1.5",  sub = "",     val = 1.50, x_off = 180 },
    { text = "2.0",  sub = "",     val = 2.00, x_off = 245 },
    { text = "3.0",  sub = "",     val = 3.00, x_off = 310, badge = "P" },
}

local function round(val, step)
    step = step or 0.05
    return math.floor((val / step) + 0.5) * step
end

local function clamp(val, min_v, max_v)
    return math.max(min_v, math.min(max_v, val))
end

local function get_card_pos()
    local ww, wh = mp.get_osd_size()
    if not ww or ww == 0 then ww, wh = 1280, 720 end

    local x0 = ww - CW - 30
    local y0 = wh - CH - 60
    if x0 < 20 then x0 = math.max(0, math.floor((ww - CW) / 2)) end
    if y0 < 20 then y0 = math.max(0, math.floor((wh - CH) / 2)) end
    return x0, y0, ww, wh
end

local close_menu -- 前置宣告

local function reset_timer()
    if timeout_timer then timeout_timer:kill() end
    timeout_timer = mp.add_timeout(8, close_menu)
end

local function set_speed(new_speed)
    reset_timer()
    new_speed = clamp(round(new_speed, 0.05), MIN_SPEED, MAX_SPEED)
    mp.set_property_number("speed", new_speed)
end

-- 偵測滑鼠懸停項目 (Hover Detection)
local function detect_hover(mx, my)
    local x0, y0 = get_card_pos()
    if mx < x0 or mx > x0 + CW or my < y0 or my > y0 + CH then
        return nil
    end

    -- 1. 右上角關閉按鈕 ✕
    if mx >= x0 + CW - 42 and mx <= x0 + CW - 10 and my >= y0 + 10 and my <= y0 + 40 then
        return "btn_close"
    end

    -- 2. 標題區域
    if mx >= x0 + 12 and mx <= x0 + 130 and my >= y0 + 10 and my <= y0 + 40 then
        return "btn_title"
    end

    -- 3. 當前倍速大字（點擊可快速還原 1.00x）
    if mx >= x0 + 110 and mx <= x0 + 250 and my >= y0 + 52 and my <= y0 + 96 then
        return "btn_cur_speed"
    end

    local y_mid = y0 + 126
    local x_btn_minus = x0 + 36
    local x_btn_plus = x0 + CW - 36
    local x_track_start = x0 + 68
    local x_track_end = x0 + CW - 68

    -- 4. 減號按鈕 -
    if (mx - x_btn_minus)^2 + (my - y_mid)^2 <= 20^2 then
        return "btn_minus"
    end

    -- 5. 加號按鈕 +
    if (mx - x_btn_plus)^2 + (my - y_mid)^2 <= 20^2 then
        return "btn_plus"
    end

    -- 6. 滑桿軌道區域
    if my >= y_mid - 14 and my <= y_mid + 14 and mx >= x_track_start - 8 and mx <= x_track_end + 8 then
        return "slider"
    end

    -- 7. 預設倍速按鈕 (1.0, 1.25, 1.5, 2.0, 3.0)
    local y_preset_top = y0 + 154
    local y_preset_bot = y0 + 200
    if my >= y_preset_top and my <= y_preset_bot then
        for i, p in ipairs(presets) do
            local px = x0 + p.x_off
            if mx >= px - 26 and mx <= px + 26 then
                return "preset_" .. i
            end
        end
    end

    return nil
end

local function render()
    if not active then return end

    local cur_speed = round(mp.get_property_number("speed", 1.0), 0.05)
    local x0, y0, ww, wh = get_card_pos()

    local ass = assdraw.ass_new()

    -- 1. 卡片深色半透明圓角背景（與彈幕面板一致）
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H363636&\\1c&H161616&\\1a&H14&\\3a&H40&}")
    ass:draw_start()
    ass:round_rect_cw(x0, y0, x0 + CW, y0 + CH, 12)
    ass:draw_stop()

    -- 2. 標題列："播放速度"
    local title_is_h = (hovered_element == "btn_title")
    local title_col = title_is_h and "\\1c&HD8A000&\\b1" or "\\1c&HE0E0E0&\\b1"
    ass:new_event()
    ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs18\\fnMicrosoft JhengHei%s}播放速度", x0 + 18, y0 + 24, title_col))

    -- 頂部右側：關閉按鈕 ✕ (Hover 變白高亮)
    local close_is_h = (hovered_element == "btn_close")
    local close_col = close_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&H777777&\\b0"
    ass:new_event()
    ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs16\\fnMicrosoft JhengHei%s}✕", x0 + CW - 18, y0 + 24, close_col))

    -- 標題列分隔線
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0\\1c&H383838&\\1a&H30&}")
    ass:draw_start()
    ass:rect_cw(x0 + 15, y0 + 44, x0 + CW - 15, y0 + 46)
    ass:draw_stop()

    -- 3. 當前倍速大字（例如 1.00x，Hover 時微顯青藍色並可點擊還原）
    local speed_is_h = (hovered_element == "btn_cur_speed")
    local speed_col = speed_is_h and "\\1c&HD8A000&" or "\\1c&HFFFFFF&"
    ass:new_event()
    ass:append(string.format("{\\an8\\pos(%d,%d)\\bord0\\shad0\\fs32\\fnMicrosoft JhengHei\\b1%s}%.2fx", x0 + math.floor(CW / 2), y0 + 54, speed_col, cur_speed))

    -- 4. 滑動條與加減按鈕
    local y_mid = y0 + 126
    local x_btn_minus = x0 + 36
    local x_btn_plus = x0 + CW - 36
    local x_track_start = x0 + 68
    local x_track_end = x0 + CW - 68

    -- 4.1 減號按鈕 −
    local minus_is_h = (hovered_element == "btn_minus")
    local minus_bg = minus_is_h and "\\1c&H484848&\\3c&HD8A000&" or "\\1c&H2C2C2C&\\3c&H444444&"
    local minus_txt = minus_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HD0D0D0&\\b0"
    ass:new_event()
    ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", minus_bg))
    ass:draw_start()
    ass:round_rect_cw(x_btn_minus - 16, y_mid - 16, x_btn_minus + 16, y_mid + 16, 16)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs22\\fnMicrosoft JhengHei%s}−", x_btn_minus, y_mid - 2, minus_txt))

    -- 4.2 加號按鈕 +
    local plus_is_h = (hovered_element == "btn_plus")
    local plus_bg = plus_is_h and "\\1c&H484848&\\3c&HD8A000&" or "\\1c&H2C2C2C&\\3c&H444444&"
    local plus_txt = plus_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HD0D0D0&\\b0"
    ass:new_event()
    ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", plus_bg))
    ass:draw_start()
    ass:round_rect_cw(x_btn_plus - 16, y_mid - 16, x_btn_plus + 16, y_mid + 16, 16)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs22\\fnMicrosoft JhengHei%s}+", x_btn_plus, y_mid - 1, plus_txt))

    -- 4.3 進度滑桿軌道 (計算滑桿圓鈕位置)
    local ratio = (cur_speed - MIN_SPEED) / (MAX_SPEED - MIN_SPEED)
    ratio = clamp(ratio, 0, 1)
    local x_thumb = x_track_start + ratio * (x_track_end - x_track_start)
    local slider_is_h = (hovered_element == "slider" or dragging)

    -- 未填充軌道（深灰色）
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0\\1c&H444444&\\1a&H30&}")
    ass:draw_start()
    ass:round_rect_cw(x_track_start, y_mid - 2, x_track_end, y_mid + 2, 2)
    ass:draw_stop()

    -- 已填充軌道（B站青藍色 #00a0d8 -> BGR &HD8A000&，與彈幕面板風格一致）
    if x_thumb > x_track_start then
        ass:new_event()
        ass:append("{\\an7\\pos(0,0)\\bord0\\1c&HD8A000&}")
        ass:draw_start()
        ass:round_rect_cw(x_track_start, y_mid - 2, x_thumb, y_mid + 2, 2)
        ass:draw_stop()
    end

    -- 滑塊圓鈕（白色實心圓球，Hover 或拖動時稍微放大）
    local tr = slider_is_h and 9 or 7
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord2\\3c&H222222&\\3a&H40&\\1c&HFFFFFF&}")
    ass:draw_start()
    ass:round_rect_cw(x_thumb - tr, y_mid - tr, x_thumb + tr, y_mid + tr, tr)
    ass:draw_stop()

    -- 5. 快速預設倍速列（1.0, 1.25, 1.5, 2.0, 3.0）
    local y_preset = y0 + 172
    for i, p in ipairs(presets) do
        local px = x0 + p.x_off
        local is_curr = (math.abs(cur_speed - p.val) < 0.02)
        local is_h = (hovered_element == "preset_" .. i)

        -- 按鈕膠囊底框
        local pill_w = 48
        local pill_h = 32
        if is_curr then
            ass:new_event()
            ass:append("{\\an7\\pos(0,0)\\bord1\\3c&HD8A000&\\1c&H2B2B2B&}")
            ass:draw_start()
            ass:round_rect_cw(px - math.floor(pill_w/2), y_preset - 13, px + math.floor(pill_w/2), y_preset - 13 + pill_h, 4)
            ass:draw_stop()
        elseif is_h then
            ass:new_event()
            ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H666666&\\1c&H3D3D3D&}")
            ass:draw_start()
            ass:round_rect_cw(px - math.floor(pill_w/2), y_preset - 13, px + math.floor(pill_w/2), y_preset - 13 + pill_h, 4)
            ass:draw_stop()
        end

        local color_tag = is_curr and "\\1c&HD8A000&\\b1" or (is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HA0A0A0&\\b0")

        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs16\\fnMicrosoft JhengHei%s}%s", px, y_preset - 1, color_tag, p.text))

        -- 3.0 後方的紅色小標誌 (P)
        if p.badge then
            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\1c&H2424E6&}", px - 18, y_preset - 1))
            ass:draw_start()
            ass:round_rect_cw(px - 25, y_preset - 8, px - 11, y_preset + 6, 2)
            ass:draw_stop()

            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs10\\fnMicrosoft JhengHei\\b1\\1c&HFFFFFF&}", px - 18, y_preset - 2))
            ass:append(p.badge)
        end

        -- 1.0 底下的 "正常"
        if p.sub and p.sub ~= "" then
            local sub_col = is_curr and "\\1c&HD8A000&" or (is_h and "\\1c&HCCCCCC&" or "\\1c&H777777&")
            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei%s}%s", px, y_preset + 12, sub_col, p.sub))
        end
    end

    -- 6. 底部微型提示線
    ass:new_event()
    ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs11\\fnMicrosoft JhengHei\\1c&H666666&}按 [ / ] 微調 ±0.05 ｜ Backspace 還原 1.0x", x0 + math.floor(CW / 2), y0 + 225))

    osd.res_x = ww
    osd.res_y = wh
    osd.hidden = false
    osd.data = ass.text
    osd:update()
end

close_menu = function()
    if not active then return end
    active = false
    dragging = false
    hovered_element = nil
    set_pointer_cursor(false)

    -- 還原視窗拖動設定
    pcall(function()
        mp.set_property("window-dragging", prev_window_dragging or "yes")
        mp.set_property("input-builtin-dragging", prev_builtin_dragging or "yes")
    end)

    osd.hidden = true
    osd.data = ''
    osd:update()
    if timeout_timer then
        timeout_timer:kill()
        timeout_timer = nil
    end

    mp.remove_key_binding("speed_card_mbtn_left")
    mp.remove_key_binding("speed_card_mouse_move")
    mp.remove_key_binding("speed_card_wheel_up")
    mp.remove_key_binding("speed_card_wheel_down")
    mp.remove_key_binding("speed_card_esc")
    mp.remove_key_binding("speed_card_mbtn_right")
    mp.remove_key_binding("speed_card_left")
    mp.remove_key_binding("speed_card_right")
    mp.remove_key_binding("speed_card_bs")
end

local function on_mouse_down_at(mx, my)
    reset_timer()
    local x0, y0 = get_card_pos()

    -- 點擊卡片外部：直接關閉
    if mx < x0 or mx > x0 + CW or my < y0 or my > y0 + CH then
        close_menu()
        return
    end

    -- 點擊右上角關閉 ✕ 或標題
    if (mx >= x0 + CW - 42 and mx <= x0 + CW - 10 and my >= y0 + 10 and my <= y0 + 40) or
       (mx >= x0 + 12 and mx <= x0 + 130 and my >= y0 + 10 and my <= y0 + 40) then
        close_menu()
        return
    end

    -- 點擊當前倍速大字：快速還原 1.00x 原速
    if mx >= x0 + 110 and mx <= x0 + 250 and my >= y0 + 52 and my <= y0 + 96 then
        set_speed(1.00)
        mp.osd_message("倍速已還原: 1.00x", 1.5)
        render()
        return
    end

    local y_mid = y0 + 126
    local x_btn_minus = x0 + 36
    local x_btn_plus = x0 + CW - 36
    local x_track_start = x0 + 68
    local x_track_end = x0 + CW - 68

    -- 點擊減號按鈕 - (0.05 微調)
    if (mx - x_btn_minus)^2 + (my - y_mid)^2 <= 20^2 then
        local cur = mp.get_property_number("speed", 1.0)
        set_speed(cur - 0.05)
        render()
        return
    end

    -- 點擊加號按鈕 + (0.05 微調)
    if (mx - x_btn_plus)^2 + (my - y_mid)^2 <= 20^2 then
        local cur = mp.get_property_number("speed", 1.0)
        set_speed(cur + 0.05)
        render()
        return
    end

    -- 點擊滑桿軌道區域
    if my >= y_mid - 14 and my <= y_mid + 14 and mx >= x_track_start - 8 and mx <= x_track_end + 8 then
        dragging = true
        local r = (mx - x_track_start) / (x_track_end - x_track_start)
        local val = MIN_SPEED + clamp(r, 0, 1) * (MAX_SPEED - MIN_SPEED)
        set_speed(val)
        render()
        return
    end

    -- 點擊預設倍速項 (1.0, 1.25, 1.5, 2.0, 3.0)
    local y_preset_top = y0 + 154
    local y_preset_bot = y0 + 200
    if my >= y_preset_top and my <= y_preset_bot then
        for _, p in ipairs(presets) do
            local px = x0 + p.x_off
            if mx >= px - 26 and mx <= px + 26 then
                set_speed(p.val)
                render()
                return
            end
        end
    end
end

local function on_mouse_down()
    local mx, my = mp.get_mouse_pos()
    on_mouse_down_at(mx, my)
end

local function on_mouse_move()
    if not active then return end
    reset_timer()
    local mx, my = mp.get_mouse_pos()
    local x0, y0 = get_card_pos()
    local x_track_start = x0 + 68
    local x_track_end = x0 + CW - 68

    if dragging then
        set_pointer_cursor(true)
        local r = (mx - x_track_start) / (x_track_end - x_track_start)
        local val = MIN_SPEED + clamp(r, 0, 1) * (MAX_SPEED - MIN_SPEED)
        set_speed(val)
        render()
        return
    end

    -- 檢查懸停狀態 (Hover Detection)
    local cur_hover = detect_hover(mx, my)
    set_pointer_cursor(cur_hover ~= nil)

    if cur_hover ~= hovered_element then
        hovered_element = cur_hover
        render()
    end
end

local function on_mouse_up()
    if dragging then
        dragging = false
        render()
    end
end

local function open_menu()
    if not active then
        -- 停用視窗拖曳，確保調節滑桿時絕不誤拖動整個 MPV 視窗！
        pcall(function()
            prev_window_dragging = mp.get_property("window-dragging", "yes")
            prev_builtin_dragging = mp.get_property("input-builtin-dragging", "yes")
            mp.set_property("window-dragging", "no")
            mp.set_property("input-builtin-dragging", "no")
        end)
    end

    active = true
    dragging = false
    hovered_element = nil

    render()
    reset_timer()

    local function on_mouse_btn(e)
        if e.event == "down" then
            on_mouse_down()
        elseif e.event == "up" then
            on_mouse_up()
        end
    end
    mp.add_forced_key_binding("MBTN_LEFT", "speed_card_mbtn_left", on_mouse_btn, {complex=true})
    mp.add_forced_key_binding("MOUSE_MOVE", "speed_card_mouse_move", on_mouse_move)

    mp.add_forced_key_binding("WHEEL_UP", "speed_card_wheel_up", function()
        reset_timer()
        local cur = mp.get_property_number("speed", 1.0)
        set_speed(cur + 0.05)
        render()
    end)
    mp.add_forced_key_binding("WHEEL_DOWN", "speed_card_wheel_down", function()
        reset_timer()
        local cur = mp.get_property_number("speed", 1.0)
        set_speed(cur - 0.05)
        render()
    end)

    mp.add_forced_key_binding("LEFT", "speed_card_left", function()
        reset_timer()
        local cur = mp.get_property_number("speed", 1.0)
        set_speed(cur - 0.05)
        render()
    end, {repeatable=true})

    mp.add_forced_key_binding("RIGHT", "speed_card_right", function()
        reset_timer()
        local cur = mp.get_property_number("speed", 1.0)
        set_speed(cur + 0.05)
        render()
    end, {repeatable=true})

    mp.add_forced_key_binding("BS", "speed_card_bs", function()
        set_speed(1.0)
        mp.osd_message("倍速已還原: 1.00x", 1.5)
        render()
    end)

    mp.add_forced_key_binding("ESC", "speed_card_esc", close_menu)
    mp.add_forced_key_binding("MBTN_RIGHT", "speed_card_mbtn_right", close_menu)
end

local function toggle_menu()
    if active then
        close_menu()
    else
        open_menu()
    end
end

-- 供外部快速微調
local function step_up()
    local cur = mp.get_property_number("speed", 1.0)
    set_speed(cur + 0.05)
    mp.osd_message(string.format("倍速: %.2fx", round(mp.get_property_number("speed", 1.0), 0.05)), 1.5)
end

local function step_down()
    local cur = mp.get_property_number("speed", 1.0)
    set_speed(cur - 0.05)
    mp.osd_message(string.format("倍速: %.2fx", round(mp.get_property_number("speed", 1.0), 0.05)), 1.5)
end

local function reset_speed()
    set_speed(1.0)
    mp.osd_message("倍速: 1.00x", 1.5)
end

mp.add_key_binding(nil, "toggle", toggle_menu)
mp.add_key_binding(nil, "step_up", step_up)
mp.add_key_binding(nil, "step_down", step_down)
mp.add_key_binding(nil, "reset", reset_speed)

-- 提供 script-message 供外部或測試調用
mp.register_script_message("speed-open", open_menu)
mp.register_script_message("speed-close", close_menu)
mp.register_script_message("speed-click", function(x, y)
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
        on_mouse_down_at(nx, ny)
    end
end)
mp.register_script_message("speed-set-hover", function(h)
    hovered_element = h
    set_pointer_cursor(h ~= nil and h ~= "")
    if active then render() end
end)

mp.observe_property("speed", "number", function()
    if active then render() end
end)
