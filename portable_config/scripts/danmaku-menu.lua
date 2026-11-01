-- danmaku-menu.lua
-- 仿 Bilibili 視覺化彈幕控制與高級設置面板 (支援滑鼠 Hover 高亮、食指指標、繁體中文、pakku.js、JSON 屏蔽詞、自定義下拉選單)

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
local page = "main" -- 每次開啟必定強制重置為 "main"
local dropdown_open = false -- 字型下拉選單展開狀態
local dragging_slider = nil
local hovered_element = nil
local timeout_timer = nil
local osd = mp.create_osd_overlay('ass-events')
osd.z = 2500

-- 記憶開啟面板前的視窗拖動設定，以便關閉時還原
local prev_window_dragging = "yes"
local prev_builtin_dragging = "yes"

local mpv_root = mp.command_native({"expand-path", "~~/"})
local settings_path = utils.join_path(mpv_root, "danmaku_settings.json")
local filter_file_path = utils.join_path(mpv_root, "danmaku_filters.json")
local user_downloads_filter = "d:\\Domwloads\\bilibili.block.json"

-- 卡片尺寸
local CW = 350
local CH = 356

-- 狀態與預設值
local state = {
    enabled = true,
    display_area = 0.75,   -- 0.25, 0.50, 0.75, 1.00
    opacity = 0.80,        -- 0.10 ~ 1.00
    fontsize_pct = 1.00,   -- 0.50 ~ 2.00 (50% ~ 200%)
    speed_idx = 3,         -- 1..5: 極慢, 較慢, 適中, 較快, 極快
    sync_speed = false,
    font_idx = 1,          -- 1: 黑體, 2: 宋體, 3: 新宋體, 4: 仿宋, 5: 微軟正黑體, 6: 微軟雅黑, 7: 標楷體
    bold = true,
    outline_type = "zhongmu", -- "zhongmu", "miaobian", "shadow"
    pakku = true
}

local speed_names = { "極慢", "較慢", "適中", "較快", "極快" }
local speed_seconds = { 16.0, 13.0, 10.0, 7.5, 5.0 }
local font_names = { "黑體", "宋體", "新宋體", "仿宋", "微軟正黑體", "微軟雅黑", "標楷體" }
local font_families = { "SimHei", "SimSun", "NSimSun", "FangSong", "Microsoft JhengHei", "Microsoft YaHei", "DFKai-SB" }
local display_steps = { 0.25, 0.50, 0.75, 1.00 }

local function sync_user_blocklist()
    local f_src = io.open(user_downloads_filter, "rb")
    if f_src then
        local data = f_src:read("*all")
        f_src:close()
        local f_dst = io.open(filter_file_path, "wb")
        if f_dst then
            f_dst:write(data)
            f_dst:close()
        end
        return true
    end
    return false
end

local function load_settings()
    local f = io.open(settings_path, "r")
    if f then
        local raw = f:read("*all")
        f:close()
        local data = utils.parse_json(raw)
        if data then
            if data.enabled ~= nil then state.enabled = data.enabled end
            if data.display_area ~= nil then state.display_area = data.display_area end
            if data.opacity ~= nil then state.opacity = data.opacity end
            if data.fontsize_pct ~= nil then state.fontsize_pct = data.fontsize_pct end
            if data.speed_idx ~= nil then state.speed_idx = data.speed_idx end
            if data.sync_speed ~= nil then state.sync_speed = data.sync_speed end
            if data.font_idx ~= nil then state.font_idx = data.font_idx end
            if data.bold ~= nil then state.bold = data.bold end
            if data.outline_type ~= nil then state.outline_type = data.outline_type end
            if data.pakku ~= nil then state.pakku = data.pakku end
        end
    end
    -- 若存在使用者下載目錄的屏蔽檔，確保同步到 portable_config
    sync_user_blocklist()
end

local function save_settings(skip_reconvert)
    local data = {
        enabled = state.enabled,
        display_area = state.display_area,
        opacity = state.opacity,
        fontsize_pct = state.fontsize_pct,
        speed_idx = state.speed_idx,
        speed_seconds = speed_seconds[state.speed_idx] or 10.0,
        sync_speed = state.sync_speed,
        font = font_families[state.font_idx] or "SimHei",
        font_idx = state.font_idx,
        bold = state.bold,
        outline_type = state.outline_type,
        pakku = state.pakku
    }
    local f = io.open(settings_path, "w")
    if f then
        f:write(utils.format_json(data))
        f:close()
    end
    -- 通知 mpv-danmaku 重新生成並重載 ASS 字幕
    if not skip_reconvert then
        mp.commandv("script-message", "danmaku-reconvert")
    end
end

load_settings()

local function clamp(val, min_v, max_v)
    return math.max(min_v, math.min(max_v, val))
end

local function get_card_pos()
    local ww, wh = mp.get_osd_size()
    if not ww or ww == 0 then ww, wh = 1280, 720 end
    local osc_margins = mp.get_property_native("user-data/osc/margins")
    local panel_rect = mp.get_property_native("user-data/osc/panel_rect")
    local bottom_offset = nil
    if panel_rect and type(panel_rect) == "table" then
        if panel_rect.bottom_ratio and panel_rect.bottom_ratio > 0 then
            bottom_offset = math.floor(wh * panel_rect.bottom_ratio + 12)
        elseif panel_rect.bottom_height and panel_rect.playresy and panel_rect.playresy > 0 then
            bottom_offset = math.floor(wh * (panel_rect.bottom_height / panel_rect.playresy) + 12)
        end
    end
    if not bottom_offset and osc_margins and type(osc_margins) == "table" and osc_margins.b and osc_margins.b > 0 then
        bottom_offset = math.floor(wh * osc_margins.b + 12)
    end
    if not bottom_offset then
        bottom_offset = math.floor(wh * 0.14 + 12)
    end
    local x0 = ww - CW - 30
    local y0 = wh - CH - bottom_offset
    if x0 < 20 then x0 = math.max(0, math.floor((ww - CW) / 2)) end
    if y0 < 20 then y0 = math.max(0, math.floor((wh - CH) / 2)) end
    return x0, y0, ww, wh
end

local close_menu -- 前置宣告

local function reset_timer()
    if timeout_timer then timeout_timer:kill() end
    timeout_timer = mp.add_timeout(10, close_menu)
end

-- 繪製滑動軌道與滑塊
local function draw_slider(ass, x_start, x_end, y_mid, ratio, dots, is_hover)
    ratio = clamp(ratio, 0, 1)
    local x_thumb = x_start + ratio * (x_end - x_start)

    -- 未填充底軌 (深灰色)
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0\\1c&H444444&\\1a&H30&}")
    ass:draw_start()
    ass:round_rect_cw(x_start, y_mid - 2, x_end, y_mid + 2, 2)
    ass:draw_stop()

    -- 已填充軌道 (B站標誌性青藍色 #00a0d8 -> BGR &HD8A000&)
    if x_thumb > x_start then
        ass:new_event()
        ass:append("{\\an7\\pos(0,0)\\bord0\\1c&HD8A000&}")
        ass:draw_start()
        ass:round_rect_cw(x_start, y_mid - 2, x_thumb, y_mid + 2, 2)
        ass:draw_stop()
    end

    -- 刻度點 (若有提供)
    if dots then
        for _, dot_r in ipairs(dots) do
            local dx = x_start + dot_r * (x_end - x_start)
            ass:new_event()
            ass:append("{\\an7\\pos(0,0)\\bord0\\1c&HFFFFFF&}")
            ass:draw_start()
            ass:round_rect_cw(dx - 2, y_mid - 2, dx + 2, y_mid + 2, 2)
            ass:draw_stop()
        end
    end

    -- 白色實心圓形滑塊（Hover 或拖動時稍微放大）
    local tr = (is_hover or dragging_slider) and 8 or 7
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord2\\3c&H222222&\\3a&H40&\\1c&HFFFFFF&}")
    ass:draw_start()
    ass:round_rect_cw(x_thumb - tr, y_mid - tr, x_thumb + tr, y_mid + tr, tr)
    ass:draw_stop()
end

local function render()
    if not active then return end
    local x0, y0, ww, wh = get_card_pos()
    local ass = assdraw.ass_new()

    -- 1. 卡片深色半透明圓角背景
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H363636&\\1c&H161616&\\1a&H14&\\3a&H40&}")
    ass:draw_start()
    ass:round_rect_cw(x0, y0, x0 + CW, y0 + CH, 12)
    ass:draw_stop()

    if page == "main" then
        -- ==================== 第一頁：主設定面板 (繁體中文 + Hover 高亮) ====================
        -- 頂部快捷開關列
        local sw_is_h = (hovered_element == "toggle_sw")
        local sw_col = state.enabled and "\\1c&HD8A000&\\b1" or "\\1c&H777777&\\b0"
        if sw_is_h then sw_col = "\\1c&HFFFFFF&\\b1" end
        local sw_txt = state.enabled and "[ 彈幕: 開啟 ]" or "[ 彈幕: 關閉 ]"
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs16\\fnMicrosoft JhengHei%s}%s", x0 + 18, y0 + 18, sw_col, sw_txt))

        ass:new_event()
        ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs12\\fnMicrosoft JhengHei\\1c&H888888&}按 b 鍵快速開關", x0 + CW - 18, y0 + 18))

        -- 頂部兩枚按鈕：[ 彈幕觀看屏蔽詞 ]  [ 同步屏蔽清單 ]
        local btn_w = 150
        local btn_h = 28
        local btn_y = y0 + 38

        -- 按鈕 1: 彈幕觀看屏蔽詞
        local b1_is_h = (hovered_element == "btn_filter")
        local b1_bg = b1_is_h and "\\1c&H737373&\\3c&H888888&" or "\\1c&H303030&\\3c&H444444&"
        local b1_txt = b1_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", b1_bg))
        ass:draw_start()
        ass:round_rect_cw(x0 + 16, btn_y, x0 + 16 + btn_w, btn_y + btn_h, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}彈幕觀看屏蔽詞", x0 + 16 + math.floor(btn_w/2), btn_y + math.floor(btn_h/2), b1_txt))

        -- 按鈕 2: 同步屏蔽清單
        local b2_is_h = (hovered_element == "btn_sync")
        local b2_bg = b2_is_h and "\\1c&H737373&\\3c&H888888&" or "\\1c&H303030&\\3c&H444444&"
        local b2_txt = b2_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", b2_bg))
        ass:draw_start()
        ass:round_rect_cw(x0 + CW - 16 - btn_w, btn_y, x0 + CW - 16, btn_y + btn_h, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}同步屏蔽清單", x0 + CW - 16 - math.floor(btn_w/2), btn_y + math.floor(btn_h/2), b2_txt))

        -- 4 個滑桿區域
        local xs = x0 + 82
        local xe = x0 + 265
        local labels = { "顯示區域", "不透明度", "彈幕字號", "彈幕速度" }
        local y_offsets = { y0 + 94, y0 + 134, y0 + 174, y0 + 214 }

        -- 標籤 1: 顯示區域
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei\\b1\\1c&HEEEEEE&}%s", x0 + 16, y_offsets[1], labels[1]))
        local dot_steps = { 0.0, 0.333, 0.666, 1.0 }
        local r_area = (state.display_area - 0.25) / 0.75
        draw_slider(ass, xs, xe, y_offsets[1], r_area, dot_steps, hovered_element == "slider_1")
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\fnMicrosoft JhengHei\\1c&HCCCCCC&}%d%%", x0 + 305, y_offsets[1], math.floor(state.display_area * 100)))

        -- 標籤 2: 不透明度
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei\\b1\\1c&HEEEEEE&}%s", x0 + 16, y_offsets[2], labels[2]))
        local r_op = (state.opacity - 0.10) / 0.90
        draw_slider(ass, xs, xe, y_offsets[2], r_op, nil, hovered_element == "slider_2")
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\fnMicrosoft JhengHei\\1c&HCCCCCC&}%d%%", x0 + 305, y_offsets[2], math.floor(state.opacity * 100)))

        -- 標籤 3: 彈幕字號
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei\\b1\\1c&HEEEEEE&}%s", x0 + 16, y_offsets[3], labels[3]))
        local r_fs = (state.fontsize_pct - 0.50) / 1.50
        draw_slider(ass, xs, xe, y_offsets[3], r_fs, nil, hovered_element == "slider_3")
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\fnMicrosoft JhengHei\\1c&HCCCCCC&}%d%%", x0 + 305, y_offsets[3], math.floor(state.fontsize_pct * 100)))

        -- 標籤 4: 彈幕速度
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei\\b1\\1c&HEEEEEE&}%s", x0 + 16, y_offsets[4], labels[4]))
        local dot_speed = { 0.0, 0.25, 0.50, 0.75, 1.0 }
        local r_sp = (state.speed_idx - 1) / 4.0
        draw_slider(ass, xs, xe, y_offsets[4], r_sp, dot_speed, hovered_element == "slider_4")
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\fnMicrosoft JhengHei\\1c&HCCCCCC&}%s", x0 + 305, y_offsets[4], speed_names[state.speed_idx] or "適中"))

        -- 分隔線
        ass:new_event()
        ass:append("{\\an7\\pos(0,0)\\bord0\\1c&H383838&\\1a&H30&}")
        ass:draw_start()
        ass:rect_cw(x0 + 16, y0 + 252, x0 + CW - 16, y0 + 254)
        ass:draw_stop()

        -- 底部跳轉「高級設置 ›」與「B2Y 匹配 ›」
        local adv_is_h = (hovered_element == "btn_advanced")
        local adv_col = adv_is_h and "\\1c&HD8A000&\\1a&H00&\\b1" or "\\1c&HE0E0E0&\\1a&H00&\\b1"
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei%s}高級設置 ›", x0 + 18, y0 + 282, adv_col))

        local b2y_is_h = (hovered_element == "btn_b2y")
        local b2y_col = b2y_is_h and "\\1c&HD8A000&\\1a&H00&\\b1" or "\\1c&H00A0D8&\\1a&H00&\\b1"
        ass:new_event()
        ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei%s}B2Y 匹配 ›", x0 + CW - 18, y0 + 282, b2y_col))

        -- 頁 1 底部按鈕：[ 📂 選取外部彈幕檔案 (Alt+o) ]
        local pick_w = CW - 36
        local pick_h = 28
        local pick_x = x0 + 18
        local pick_y = y0 + 310
        local pick_is_h = (hovered_element == "btn_pick_danmaku")
        local pick_bg = pick_is_h and "\\1c&H484848&\\3c&HD8A000&" or "\\1c&H242424&\\3c&H444444&"
        local pick_txt = pick_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", pick_bg))
        ass:draw_start()
        ass:round_rect_cw(pick_x, pick_y, pick_x + pick_w, pick_y + pick_h, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}📂  選取外部彈幕檔案 (Alt+o)", pick_x + math.floor(pick_w/2), pick_y + math.floor(pick_h/2), pick_txt))

    else
        -- ==================== 第二頁：高級設置 (繁體中文 + 下拉選單) ====================
        -- 頂部返回箭頭與標題 ‹ 更多彈幕設置 (Hover 呈現青藍色)
        local back_is_h = (hovered_element == "btn_back")
        local back_col = back_is_h and "\\1c&HD8A000&\\1a&H00&\\b1" or "\\1c&HEEEEEE&\\1a&H00&\\b1"
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs18\\fnMicrosoft JhengHei%s}‹  更多彈幕設置", x0 + 18, y0 + 26, back_col))

        -- 分隔線
        ass:new_event()
        ass:append("{\\an7\\pos(0,0)\\bord0\\1c&H383838&\\1a&H30&}")
        ass:draw_start()
        ass:rect_cw(x0 + 16, y0 + 46, x0 + CW - 16, y0 + 48)
        ass:draw_stop()

        -- 項 1: ☐ / ☑ 彈幕速度同步播放倍數
        local sync_is_h = (hovered_element == "chk_sync_speed")
        local sync_chk = state.sync_speed and "☑" or "☐"
        local sync_col = state.sync_speed and "\\1c&HD8A000&" or "\\1c&H888888&"
        local sync_txt_col = sync_is_h and "\\1c&HD8A000&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs18\\fnMicrosoft JhengHei%s}%s  {%s\\fs15}彈幕速度同步播放倍數", x0 + 18, y0 + 72, sync_col, sync_chk, sync_txt_col))

        -- 項 2: 彈幕字型
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei\\b1\\1c&HE0E0E0&}彈幕字型", x0 + 18, y0 + 104))

        -- 下拉選擇框背景 [ 黑體   ▾ ]
        local fw = 150
        local fh = 28
        local fy = y0 + 118
        local font_is_h = (hovered_element == "dropdown_font")
        local font_bg = (font_is_h or dropdown_open) and "\\1c&H303030&\\3c&HD8A000&" or "\\1c&H212121&\\3c&H444444&"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", font_bg))
        ass:draw_start()
        ass:round_rect_cw(x0 + 18, fy, x0 + 18 + fw, fy + fh, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs14\\fnMicrosoft JhengHei\\1c&HFFFFFF&}%s", x0 + 28, fy + math.floor(fh/2), font_names[state.font_idx] or "黑體"))
        ass:new_event()
        local arrow_symbol = dropdown_open and "▴" or "▾"
        ass:append(string.format("{\\an6\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei\\1c&HAAAAAA&}%s", x0 + 18 + fw - 10, fy + math.floor(fh/2), arrow_symbol))

        -- 右側: ☑ 粗體
        local bold_is_h = (hovered_element == "chk_bold")
        local bold_chk = state.bold and "☑" or "☐"
        local bold_col = state.bold and "\\1c&HD8A000&" or "\\1c&H888888&"
        local bold_txt_col = bold_is_h and "\\1c&HD8A000&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs18\\fnMicrosoft JhengHei%s}%s  {%s\\fs15}粗體", x0 + 200, fy + math.floor(fh/2), bold_col, bold_chk, bold_txt_col))

        -- 項 3: 描邊類型
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs15\\fnMicrosoft JhengHei\\b1\\1c&HE0E0E0&}描邊類型", x0 + 18, y0 + 168))

        -- 3 個按鈕: [ 重墨 ]  [ 描邊 ]  [ 45°投影 ]
        local types = { { id = "zhongmu", name = "重墨" }, { id = "miaobian", name = "描邊" }, { id = "shadow", name = "45°投影" } }
        local tw = 98
        local th = 30
        local ty = y0 + 184
        for i, t in ipairs(types) do
            local bx = x0 + 18 + (i - 1) * (tw + 10)
            local is_sel = (state.outline_type == t.id)
            local is_h = (hovered_element == "outline_" .. t.id)
            local bg_c = is_sel and "\\1c&HD8A000&\\3c&HD8A000&" or (is_h and "\\1c&H484848&\\3c&H777777&" or "\\1c&H303030&\\3c&H444444&")
            local txt_c = is_sel and "\\1c&HFFFFFF&\\b1" or (is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HCCCCCC&\\b0")

            ass:new_event()
            ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", bg_c))
            ass:draw_start()
            ass:round_rect_cw(bx, ty, bx + tw, ty + th, 4)
            ass:draw_stop()

            ass:new_event()
            ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs14\\fnMicrosoft JhengHei%s}%s", bx + math.floor(tw/2), ty + math.floor(th/2), txt_c, t.name))
        end

        -- 項 4: 智能合併刷屏 (pakku.js) 開關
        local pakku_is_h = (hovered_element == "chk_pakku")
        local pakku_chk = state.pakku and "☑" or "☐"
        local pakku_col = state.pakku and "\\1c&HD8A000&" or "\\1c&H888888&"
        local pakku_txt_col = pakku_is_h and "\\1c&HD8A000&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs16\\fnMicrosoft JhengHei%s}%s  {%s\\fs13}智能合併刷屏彈幕 (pakku.js)", x0 + 18, y0 + 238, pakku_col, pakku_chk, pakku_txt_col))

        -- 項 5: [ 恢復預設設置 ] 按鈕
        local rw = 140
        local rh = 28
        local rx = x0 + 18
        local ry = y0 + 268
        local reset_is_h = (hovered_element == "btn_reset")
        local reset_bg = reset_is_h and "\\1c&H505050&\\3c&H888888&" or "\\1c&H242424&\\3c&H444444&"
        local reset_txt = reset_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", reset_bg))
        ass:draw_start()
        ass:round_rect_cw(rx, ry, rx + rw, ry + rh, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}恢復預設設置", rx + math.floor(rw/2), ry + math.floor(rh/2), reset_txt))

        -- 項 6: [ 匹配 B 站彈幕 (B2Y) ] 按鈕
        local b2y_w = 150
        local b2y_h = 28
        local b2y_x = x0 + CW - 18 - b2y_w
        local b2y_y = y0 + 268
        local b2y_is_h = (hovered_element == "btn_b2y")
        local b2y_bg = b2y_is_h and "\\1c&H484848&\\3c&HD8A000&" or "\\1c&H242424&\\3c&H444444&"
        local b2y_txt = b2y_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", b2y_bg))
        ass:draw_start()
        ass:round_rect_cw(b2y_x, b2y_y, b2y_x + b2y_w, b2y_y + b2y_h, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}匹配 B 站彈幕 (B2Y)", b2y_x + math.floor(b2y_w/2), b2y_y + math.floor(b2y_h/2), b2y_txt))

        -- 項 7: [ 📂 選取外部彈幕 ] 與 [ 🔄 切換同目錄彈幕 ] 按鈕
        local pw = 140
        local ph = 28
        local px = x0 + 18
        local py = y0 + 310
        local pick_is_h = (hovered_element == "btn_pick_danmaku")
        local pick_bg = pick_is_h and "\\1c&H484848&\\3c&HD8A000&" or "\\1c&H242424&\\3c&H444444&"
        local pick_txt = pick_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", pick_bg))
        ass:draw_start()
        ass:round_rect_cw(px, py, px + pw, py + ph, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}📂 選取外部彈幕", px + math.floor(pw/2), py + math.floor(ph/2), pick_txt))

        local cw_btn = 150
        local ch_btn = 28
        local cx = x0 + CW - 18 - cw_btn
        local cy = y0 + 310
        local cyc_is_h = (hovered_element == "btn_cycle_danmaku")
        local cyc_bg = cyc_is_h and "\\1c&H484848&\\3c&HD8A000&" or "\\1c&H242424&\\3c&H444444&"
        local cyc_txt = cyc_is_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0"
        ass:new_event()
        ass:append(string.format("{\\an7\\pos(0,0)\\bord1%s}", cyc_bg))
        ass:draw_start()
        ass:round_rect_cw(cx, cy, cx + cw_btn, cy + ch_btn, 4)
        ass:draw_stop()
        ass:new_event()
        ass:append(string.format("{\\an5\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}🔄 切換同目錄彈幕", cx + math.floor(cw_btn/2), cy + math.floor(ch_btn/2), cyc_txt))

        -- ==================== 下拉展開選單（彈出層，覆蓋於上層） ====================
        if dropdown_open then
            local dy = fy + fh
            local ih = 24
            local total_dh = #font_names * ih

            -- 1. 下拉選單底框（深灰黑 #212121，帶陰影邊框）
            ass:new_event()
            ass:append("{\\an7\\pos(0,0)\\bord1\\3c&H555555&\\1c&H212121&}")
            ass:draw_start()
            ass:round_rect_cw(x0 + 18, dy, x0 + 18 + fw, dy + total_dh, 4)
            ass:draw_stop()

            -- 2. 右側精緻滾動條指示器（還原用戶截圖，寬 4px，圓角，#6d7f7a）
            ass:new_event()
            ass:append("{\\an7\\pos(0,0)\\bord0\\1c&H7A7F6D&}")
            ass:draw_start()
            ass:round_rect_cw(x0 + 18 + fw - 6, dy + 4, x0 + 18 + fw - 2, dy + 45, 2)
            ass:draw_stop()

            -- 3. 各個字型選項項目
            for i, fname in ipairs(font_names) do
                local iy = dy + (i - 1) * ih
                local is_opt_h = (hovered_element == "font_opt_" .. i)
                local is_opt_sel = (state.font_idx == i)

                if is_opt_h or is_opt_sel then
                    local opt_bg = is_opt_sel and "\\1c&H2F2F2F&" or "\\1c&H3D3D3D&"
                    ass:new_event()
                    ass:append(string.format("{\\an7\\pos(0,0)\\bord0%s}", opt_bg))
                    ass:draw_start()
                    ass:rect_cw(x0 + 19, iy + 1, x0 + 18 + fw - 7, iy + ih - 1)
                    ass:draw_stop()
                end

                local opt_col = is_opt_sel and "\\1c&HD8A000&\\b1" or (is_opt_h and "\\1c&HFFFFFF&\\b1" or "\\1c&HE0E0E0&\\b0")
                ass:new_event()
                ass:append(string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\fs13\\fnMicrosoft JhengHei%s}%s", x0 + 26, iy + math.floor(ih/2), opt_col, fname))
            end
        end
    end

    osd.res_x = ww
    osd.res_y = wh
    osd.z = 2500
    osd.hidden = false
    osd.data = ass.text
    osd:update()
end

close_menu = function()
    if not active then return end
    active = false
    mp.set_property_bool("user-data/danmaku-menu/open", false)
    dragging_slider = nil
    dropdown_open = false
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

    mp.remove_key_binding("danmaku_panel_mbtn_left")
    mp.remove_key_binding("danmaku_panel_mouse_move")
    mp.remove_key_binding("danmaku_panel_esc")
    mp.remove_key_binding("danmaku_panel_mbtn_right")
end

local function toggle_danmaku()
    local sec_sid = mp.get_property("secondary-sid", "no")
    local new_vis
    if sec_sid ~= "no" then
        local cur_sec_vis = mp.get_property_bool("secondary-sub-visibility", true)
        new_vis = not cur_sec_vis
        mp.set_property_bool("secondary-sub-visibility", new_vis)
    else
        local cur_sub_vis = mp.get_property_bool("sub-visibility", true)
        new_vis = not cur_sub_vis
        mp.set_property_bool("sub-visibility", new_vis)
    end
    state.enabled = new_vis
    save_settings(true)
    if state.enabled then
        mp.osd_message("彈幕: 已開啟", 1.5)
    else
        mp.osd_message("彈幕: 已隱藏", 1.5)
    end
    if active then render() end
end

local function detect_hover(mx, my)
    local x0, y0 = get_card_pos()
    if mx < x0 or mx > x0 + CW or my < y0 or my > y0 + CH then
        return nil
    end

    if page == "main" then
        if mx >= x0 + 15 and mx <= x0 + 130 and my >= y0 + 10 and my <= y0 + 32 then
            return "toggle_sw"
        end

        local btn_w = 150
        local btn_h = 28
        local btn_y = y0 + 38
        if mx >= x0 + 16 and mx <= x0 + 16 + btn_w and my >= btn_y and my <= btn_y + btn_h then
            return "btn_filter"
        end
        if mx >= x0 + CW - 16 - btn_w and mx <= x0 + CW - 16 and my >= btn_y and my <= btn_y + btn_h then
            return "btn_sync"
        end

        local xs = x0 + 82
        local xe = x0 + 265
        local y_offsets = { y0 + 94, y0 + 134, y0 + 174, y0 + 214 }
        for i = 1, 4 do
            if my >= y_offsets[i] - 12 and my <= y_offsets[i] + 12 and mx >= xs - 10 and mx <= xe + 10 then
                return "slider_" .. i
            end
        end

        local pick_w = CW - 36
        local pick_h = 28
        local pick_x = x0 + 18
        local pick_y = y0 + 310
        if mx >= pick_x and mx <= pick_x + pick_w and my >= pick_y and my <= pick_y + pick_h then
            return "btn_pick_danmaku"
        end

        if my >= y0 + 265 and my <= y0 + 298 then
            if mx >= x0 + 160 then
                return "btn_b2y"
            else
                return "btn_advanced"
            end
        end
    else
        -- 若下拉選單展開，優先判定下拉項目懸停
        if dropdown_open then
            local fw = 150
            local fh = 28
            local fy = y0 + 118
            local dy = fy + fh
            local ih = 24
            local total_dh = #font_names * ih
            if mx >= x0 + 18 and mx <= x0 + 18 + fw and my >= dy and my <= dy + total_dh then
                local idx = math.floor((my - dy) / ih) + 1
                if idx >= 1 and idx <= #font_names then
                    return "font_opt_" .. idx
                end
            end
        end

        if mx >= x0 + 10 and mx <= x0 + 180 and my >= y0 + 10 and my <= y0 + 44 then
            return "btn_back"
        end

        if my >= y0 + 60 and my <= y0 + 86 and mx >= x0 + 15 and mx <= x0 + 260 then
            return "chk_sync_speed"
        end

        local fw = 150
        local fh = 28
        local fy = y0 + 118
        if mx >= x0 + 18 and mx <= x0 + 18 + fw and my >= fy and my <= fy + fh then
            return "dropdown_font"
        end

        if mx >= x0 + 195 and mx <= x0 + 280 and my >= fy and my <= fy + fh then
            return "chk_bold"
        end

        local tw = 98
        local th = 30
        local ty = y0 + 184
        local types = { "zhongmu", "miaobian", "shadow" }
        for i, t_id in ipairs(types) do
            local bx = x0 + 18 + (i - 1) * (tw + 10)
            if mx >= bx and mx <= bx + tw and my >= ty and my <= ty + th then
                return "outline_" .. t_id
            end
        end

        if my >= y0 + 225 and my <= y0 + 252 and mx >= x0 + 15 and mx <= x0 + 280 then
            return "chk_pakku"
        end

        local rw = 140
        local rh = 28
        local rx = x0 + 18
        local ry = y0 + 268
        if mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh then
            return "btn_reset"
        end

        local b2y_w = 150
        local b2y_h = 28
        local b2y_x = x0 + CW - 18 - b2y_w
        local b2y_y = y0 + 268
        if mx >= b2y_x and mx <= b2y_x + b2y_w and my >= b2y_y and my <= b2y_y + b2y_h then
            return "btn_b2y"
        end

        local pw = 140
        local ph = 28
        local px = x0 + 18
        local py = y0 + 310
        if mx >= px and mx <= px + pw and my >= py and my <= py + ph then
            return "btn_pick_danmaku"
        end

        local cw_btn = 150
        local ch_btn = 28
        local cx = x0 + CW - 18 - cw_btn
        local cy = y0 + 310
        if mx >= cx and mx <= cx + cw_btn and my >= cy and my <= cy + ch_btn then
            return "btn_cycle_danmaku"
        end
    end
    return nil
end

local function on_mouse_down_at(mx, my)
    reset_timer()
    local x0, y0 = get_card_pos()

    -- 點擊卡片外部：直接關閉
    if mx < x0 or mx > x0 + CW or my < y0 or my > y0 + CH then
        close_menu()
        return
    end

    if page == "main" then
        -- 點擊開關標題
        if mx >= x0 + 15 and mx <= x0 + 130 and my >= y0 + 10 and my <= y0 + 32 then
            toggle_danmaku()
            return
        end

        -- 點擊 [ 彈幕觀看屏蔽詞 ]
        local btn_w = 150
        local btn_h = 28
        local btn_y = y0 + 38
        if mx >= x0 + 16 and mx <= x0 + 16 + btn_w and my >= btn_y and my <= btn_y + btn_h then
            local target_f = filter_file_path
            local fc = io.open(user_downloads_filter, "r")
            if fc then
                fc:close()
                target_f = user_downloads_filter
            end
            utils.subprocess_detached({ args = { 'notepad.exe', target_f } })
            mp.osd_message("已開啟彈幕屏蔽表", 2.0)
            return
        end

        -- 點擊 [ 同步屏蔽清單 ]
        if mx >= x0 + CW - 16 - btn_w and mx <= x0 + CW - 16 and my >= btn_y and my <= btn_y + btn_h then
            local ok = sync_user_blocklist()
            save_settings()
            if ok then
                mp.osd_message("已成功同步 B 站屏蔽表 (244 條規則)", 2.0)
            else
                mp.osd_message("已重新同步與套用彈幕屏蔽清單", 2.0)
            end
            return
        end

        local xs = x0 + 82
        local xe = x0 + 265
        local y_offsets = { y0 + 94, y0 + 134, y0 + 174, y0 + 214 }

        -- 點擊滑桿 1: 顯示區域
        if my >= y_offsets[1] - 12 and my <= y_offsets[1] + 12 and mx >= xs - 10 and mx <= xe + 10 then
            local r = clamp((mx - xs) / (xe - xs), 0, 1)
            local step = math.floor(r * 3 + 0.5)
            state.display_area = display_steps[step + 1] or 0.75
            dragging_slider = 1
            save_settings()
            render()
            return
        end

        -- 點擊滑桿 2: 不透明度
        if my >= y_offsets[2] - 12 and my <= y_offsets[2] + 12 and mx >= xs - 10 and mx <= xe + 10 then
            local r = clamp((mx - xs) / (xe - xs), 0, 1)
            state.opacity = clamp(0.10 + r * 0.90, 0.10, 1.00)
            dragging_slider = 2
            save_settings()
            render()
            return
        end

        -- 點擊滑桿 3: 彈幕字號
        if my >= y_offsets[3] - 12 and my <= y_offsets[3] + 12 and mx >= xs - 10 and mx <= xe + 10 then
            local r = clamp((mx - xs) / (xe - xs), 0, 1)
            state.fontsize_pct = clamp(0.50 + r * 1.50, 0.50, 2.00)
            dragging_slider = 3
            save_settings()
            render()
            return
        end

        -- 點擊滑桿 4: 彈幕速度
        if my >= y_offsets[4] - 12 and my <= y_offsets[4] + 12 and mx >= xs - 10 and mx <= xe + 10 then
            local r = clamp((mx - xs) / (xe - xs), 0, 1)
            local step = math.floor(r * 4 + 0.5) + 1
            state.speed_idx = clamp(step, 1, 5)
            dragging_slider = 4
            save_settings()
            render()
            return
        end

        local pick_w = CW - 36
        local pick_h = 28
        local pick_x = x0 + 18
        local pick_y = y0 + 310
        if mx >= pick_x and mx <= pick_x + pick_w and my >= pick_y and my <= pick_y + pick_h then
            close_menu()
            mp.commandv("script-message", "pick-external-danmaku")
            return
        end

        -- 點擊底部「高級設置 ›」或「B2Y 匹配 ›」
        if my >= y0 + 265 and my <= y0 + 298 then
            if mx >= x0 + 160 then
                close_menu()
                mp.commandv("script-message", "b2y-open-menu")
            else
                page = "advanced"
                dropdown_open = false
                hovered_element = nil
                render()
            end
            return
        end

    else
        -- ==================== 第二頁互動 ====================
        local fw = 150
        local fh = 28
        local fy = y0 + 118
        local dy = fy + fh
        local ih = 24
        local total_dh = #font_names * ih

        -- 若下拉選單展開，優先處理下拉項目的點選
        if dropdown_open then
            if mx >= x0 + 18 and mx <= x0 + 18 + fw and my >= dy and my <= dy + total_dh then
                local idx = math.floor((my - dy) / ih) + 1
                if idx >= 1 and idx <= #font_names then
                    state.font_idx = idx
                    save_settings()
                    dropdown_open = false
                    hovered_element = nil
                    mp.osd_message("彈幕字型: " .. font_names[idx], 1.5)
                    render()
                    return
                end
            elseif mx >= x0 + 18 and mx <= x0 + 18 + fw and my >= fy and my <= fy + fh then
                -- 點擊原本的字型框：收起下拉選單
                dropdown_open = false
                render()
                return
            else
                -- 點擊外部：關閉下拉選單
                dropdown_open = false
                render()
                return
            end
        end

        -- 點擊頂部 ‹ 更多彈幕設置 返回
        if mx >= x0 + 10 and mx <= x0 + 180 and my >= y0 + 10 and my <= y0 + 44 then
            page = "main"
            dropdown_open = false
            hovered_element = nil
            render()
            return
        end

        -- 點擊 彈幕速度同步播放倍數
        if my >= y0 + 60 and my <= y0 + 86 and mx >= x0 + 15 and mx <= x0 + 260 then
            state.sync_speed = not state.sync_speed
            save_settings()
            mp.osd_message("速度同步倍數: " .. (state.sync_speed and "開啟" or "關閉"), 1.5)
            render()
            return
        end

        -- 點擊 彈幕字型 框：展開下拉選單
        if mx >= x0 + 18 and mx <= x0 + 18 + fw and my >= fy and my <= fy + fh then
            dropdown_open = true
            render()
            return
        end

        -- 點擊 粗體
        if mx >= x0 + 195 and mx <= x0 + 280 and my >= fy and my <= fy + fh then
            state.bold = not state.bold
            save_settings()
            mp.osd_message("彈幕粗體: " .. (state.bold and "開啟" or "關閉"), 1.5)
            render()
            return
        end

        -- 點擊 描邊類型 三按鈕
        local tw = 98
        local th = 30
        local ty = y0 + 184
        local types = { "zhongmu", "miaobian", "shadow" }
        local type_names = { zhongmu = "重墨", miaobian = "描邊", shadow = "45°投影" }
        for i, t_id in ipairs(types) do
            local bx = x0 + 18 + (i - 1) * (tw + 10)
            if mx >= bx and mx <= bx + tw and my >= ty and my <= ty + th then
                state.outline_type = t_id
                save_settings()
                mp.osd_message("彈幕樣式: " .. (type_names[t_id] or t_id), 1.5)
                render()
                return
            end
        end

        -- 點擊 pakku.js 合併開關
        if my >= y0 + 225 and my <= y0 + 252 and mx >= x0 + 15 and mx <= x0 + 280 then
            state.pakku = not state.pakku
            save_settings()
            mp.osd_message("智能合併刷屏: " .. (state.pakku and "開啟" or "關閉"), 1.5)
            render()
            return
        end

        -- 點擊 恢復預設設置
        local rw = 140
        local rh = 28
        local rx = x0 + 18
        local ry = y0 + 268
        if mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh then
            state.display_area = 0.75
            state.opacity = 0.80
            state.fontsize_pct = 1.00
            state.speed_idx = 3
            state.sync_speed = false
            state.font_idx = 1
            state.bold = true
            state.outline_type = "zhongmu"
            state.pakku = true
            dropdown_open = false
            save_settings()
            mp.osd_message("已恢復彈幕預設設置", 1.5)
            render()
            return
        end

        -- 點擊 匹配 B 站彈幕 (B2Y)
        local b2y_w = 150
        local b2y_h = 28
        local b2y_x = x0 + CW - 18 - b2y_w
        local b2y_y = y0 + 268
        if mx >= b2y_x and mx <= b2y_x + b2y_w and my >= b2y_y and my <= b2y_y + b2y_h then
            close_menu()
            mp.commandv("script-message", "b2y-match")
            return
        end

        -- 點擊 [ 📂 選取外部彈幕 ]
        local pw = 140
        local ph = 28
        local px = x0 + 18
        local py = y0 + 310
        if mx >= px and mx <= px + pw and my >= py and my <= py + ph then
            close_menu()
            mp.commandv("script-message", "pick-external-danmaku")
            return
        end

        -- 點擊 [ 🔄 切換同目錄彈幕 ]
        local cw_btn = 150
        local ch_btn = 28
        local cx = x0 + CW - 18 - cw_btn
        local cy = y0 + 310
        if mx >= cx and mx <= cx + cw_btn and my >= cy and my <= cy + ch_btn then
            mp.commandv("script-message", "cycle-sibling-danmaku")
            return
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
    local xs = x0 + 82
    local xe = x0 + 265
    local r = clamp((mx - xs) / (xe - xs), 0, 1)

    if dragging_slider then
        set_pointer_cursor(true)
        if dragging_slider == 1 then
            local step = math.floor(r * 3 + 0.5)
            state.display_area = display_steps[step + 1] or 0.75
        elseif dragging_slider == 2 then
            state.opacity = clamp(0.10 + r * 0.90, 0.10, 1.00)
        elseif dragging_slider == 3 then
            state.fontsize_pct = clamp(0.50 + r * 1.50, 0.50, 2.00)
        elseif dragging_slider == 4 then
            local step = math.floor(r * 4 + 0.5) + 1
            state.speed_idx = clamp(step, 1, 5)
        end
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
    if dragging_slider then
        dragging_slider = nil
        save_settings()
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
    mp.set_property_bool("user-data/danmaku-menu/open", true)
    -- 核心需求：每次打開彈幕面板時，強制重置在第一部分（主設定面板）！
    page = "main"
    dropdown_open = false
    dragging_slider = nil
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
    mp.add_forced_key_binding("MBTN_LEFT", "danmaku_panel_mbtn_left", on_mouse_btn, {complex=true})
    mp.add_forced_key_binding("MOUSE_MOVE", "danmaku_panel_mouse_move", on_mouse_move)
    mp.add_forced_key_binding("ESC", "danmaku_panel_esc", close_menu)
    mp.add_forced_key_binding("MBTN_RIGHT", "danmaku_panel_mbtn_right", close_menu)
end

local function toggle_menu()
    if active then
        close_menu()
    else
        open_menu()
    end
end

mp.add_key_binding(nil, "toggle_menu", toggle_menu)
mp.add_key_binding(nil, "toggle_danmaku", toggle_danmaku)

mp.register_script_message("danmaku-open", open_menu)
mp.register_script_message("danmaku-close", close_menu)
mp.register_script_message("danmaku-set-page", function(p)
    page = p
    dropdown_open = false
    hovered_element = nil
    if not active then open_menu() else render() end
end)
mp.register_script_message("danmaku-toggle-dropdown", function()
    if page == "advanced" then
        dropdown_open = not dropdown_open
        render()
    end
end)
mp.register_script_message("danmaku-set-hover", function(h)
    hovered_element = h
    set_pointer_cursor(h ~= nil and h ~= "")
    if active then render() end
end)
mp.register_script_message("danmaku-click", function(x, y)
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
        on_mouse_down_at(nx, ny)
    end
end)

mp.set_property_bool("user-data/danmaku-menu/open", false)
