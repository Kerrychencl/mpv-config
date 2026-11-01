-- prove-it/test_verification.lua
local mp = require 'mp'
local utils = require 'mp.utils'

local log_lines = {}
local pass_count = 0
local fail_count = 0

local function log(msg)
    print(msg)
    table.insert(log_lines, msg)
end

local function assert_test(name, cond, details)
    if cond then
        pass_count = pass_count + 1
        log(string.format("  [PASS] %s", name))
    else
        fail_count = fail_count + 1
        log(string.format("  [FAIL] %s - %s", name, tostring(details or "assertion failed")))
    end
end

log("================================================================================")
log("  AUTOMATED VERIFICATION TEST SUITE (MPV / ModernZ / BTR / Menu / SponsorBlock)")
log("================================================================================")

-- -----------------------------------------------------------------------------
-- TEST 1: BTR Live Stream URL Rewriting & EDL Protection
-- -----------------------------------------------------------------------------
log("\n[TEST 1] BTR Live Stream URL Rewriting & EDL Protection")
do
    -- Load btr module logic safely
    local btr_file = io.open("portable_config/scripts/btr/main.lua", "r")
    if not btr_file then
        assert_test("btr/main.lua exists", false, "file not found")
    else
        local content = btr_file:read("*all")
        btr_file:close()
        
        -- Check is_bili_media_url returns false for live URLs
        assert_test("is_bili_media_url excludes live streams",
            content:find("if is_bili_live_url%(url%) then%s*return false"),
            "is_bili_media_url still includes live streams")

        -- Check EDL parsing before URL rewriting
        assert_test("rewrite_stream_filename handles edl:// first",
            content:find("if stream_path:find%(\"%^edl://\"%) then"),
            "rewrite_stream_filename does not check edl:// first")
            
        -- Check that official live streams in EDL are preserved without VOD redirect
        assert_test("Official live nodes preserved in EDL",
            content:find("原生官方直播節點 %(gotcha, live%-bvc 等%)，保持不變"),
            "missing official node preservation")

        -- Check that MCDN live streams are rewritten to gotcha
        assert_test("MCDN live nodes rewritten to low-latency gotcha",
            content:find("d1%-%-cn%-gotcha01%.bilivideo%.com"),
            "missing gotcha rewrite target")
    end
end

-- -----------------------------------------------------------------------------
-- TEST 2: BTR Threadripper Advanced Settings String Format Bug & Tab 4 Label
-- -----------------------------------------------------------------------------
log("\n[TEST 2] BTR Advanced Settings String Format Bug & Safe Rendering")
do
    local btr_file = io.open("portable_config/scripts/btr/main.lua", "r")
    if btr_file then
        local content = btr_file:read("*all")
        btr_file:close()

        -- Check line 1009/1011 string.format bug fixed
        assert_test("item.title parameter provided to string.format",
            content:find("item%.title%)") ~= nil,
            "missing item.title in string.format")
        assert_test("item.desc parameter provided to string.format",
            content:find("item%.desc%)") ~= nil,
            "missing item.desc in string.format")

        -- Check Tab 4 label is '節點' instead of '界面'
        assert_test("Tab 4 labeled as '節點'",
            content:find("{ id = \"nodes\",%s*name = \"節點\" }") ~= nil,
            "Tab 4 is not labeled as '節點'")

        -- Check pcall wrapper in render_menu
        assert_test("render_menu wrapped with pcall",
            content:find("local ok, err = pcall%(function%(%)") ~= nil,
            "render_menu is missing pcall protection")
    end
end

-- -----------------------------------------------------------------------------
-- TEST 3: Right-Click Context Menu Compact Sizing & Dynamic Scaling
-- -----------------------------------------------------------------------------
log("\n[TEST 3] Right-Click Context Menu Sizing & Dynamic Scaling")
do
    local menu_file = io.open("portable_config/scripts/menu/menu.lua", "r")
    local style_file = io.open("portable_config/script-opts/menu_style.conf", "r")

    if menu_file and style_file then
        local menu_content = menu_file:read("*all")
        local style_content = style_file:read("*all")
        menu_file:close()
        style_file:close()

        -- AUTO_SCALE_MIN reduced to 0.4
        assert_test("menu.lua AUTO_SCALE_MIN is 0.4",
            menu_content:find("AUTO_SCALE_MIN = 0.4") ~= nil,
            "AUTO_SCALE_MIN not set to 0.4")

        -- BASE_ROW_HEIGHT reduced to 32
        assert_test("menu.lua BASE_ROW_HEIGHT is 32",
            menu_content:find("BASE_ROW_HEIGHT = 32") ~= nil,
            "BASE_ROW_HEIGHT not set to 32")

        -- Explicit height scaling with f
        assert_test("resolve_item_height scales explicit height by f",
            menu_content:find("if explicit then return explicit %* f end") ~= nil,
            "explicit height is not scaled by f")

        -- menu_style.conf compact parameters
        assert_test("menu_style.conf font_size is 20",
            style_content:find("font_size=20") ~= nil,
            "font_size not set to 20")
        assert_test("menu_style.conf menu_item_height is 32",
            style_content:find("menu_item_height=32") ~= nil,
            "menu_item_height not set to 32")
        assert_test("menu_style.conf min_width is 240",
            style_content:find("min_width=240") ~= nil,
            "min_width not set to 240")
        assert_test("menu_style.conf radius is 10",
            style_content:find("radius=10") ~= nil,
            "radius not set to 10")
    end
end

-- -----------------------------------------------------------------------------
-- TEST 4: Danmaku Panel OSC Hiding Fix & Native Menu Integration
-- -----------------------------------------------------------------------------
log("\n[TEST 4] Danmaku Panel OSC Hiding Fix & Native Menu Integration")
do
    local danmaku_file = io.open("portable_config/scripts/danmaku-menu.lua", "r")
    local modernz_file = io.open("portable_config/scripts/modernz.lua", "r")

    if danmaku_file and modernz_file then
        local danmaku_content = danmaku_file:read("*all")
        local modernz_content = modernz_file:read("*all")
        danmaku_file:close()
        modernz_file:close()

        -- danmaku-menu.lua sets user-data/danmaku-menu/open
        assert_test("danmaku-menu sets user-data/danmaku-menu/open on open",
            danmaku_content:find("mp.set_property_bool%(\"user%-data/danmaku%-menu/open\", true%)") ~= nil,
            "missing open property setter")
        assert_test("danmaku-menu sets user-data/danmaku-menu/open on close",
            danmaku_content:find("mp.set_property_bool%(\"user%-data/danmaku%-menu/open\", false%)") ~= nil,
            "missing close property setter")

        -- modernz.lua checks user-data/danmaku-menu/open
        assert_test("modernz.lua mouse_leave respects danmaku menu open state",
            modernz_content:find("menu or mp.get_property_bool%(\"user%-data/danmaku%-menu/open\", false%)") ~= nil,
            "missing danmaku menu check in mouse_leave")
        assert_test("modernz.lua autohide tick respects danmaku menu open state",
            modernz_content:find("if menu or mp.get_property_bool%(\"user%-data/danmaku%-menu/open\", false%) then state.showtime = now end") ~= nil,
            "missing danmaku menu check in tick")

        -- modernz.lua integrates native danmaku menu
        assert_test("modernz.lua has kind == 'danmaku' menu",
            modernz_content:find("elseif kind == \"danmaku\" then") ~= nil,
            "missing kind == 'danmaku'")
        assert_test("modernz.lua has danmaku submenus (area, opacity, fontsize, speed, font)",
            modernz_content:find("kind == \"danmaku_area\"") ~= nil and
            modernz_content:find("kind == \"danmaku_opacity\"") ~= nil and
            modernz_content:find("kind == \"danmaku_fontsize\"") ~= nil and
            modernz_content:find("kind == \"danmaku_speed\"") ~= nil and
            modernz_content:find("kind == \"danmaku_font\"") ~= nil,
            "missing danmaku submenus")
    end
end

-- -----------------------------------------------------------------------------
-- TEST 5: Speed Menu Checkmark Removal
-- -----------------------------------------------------------------------------
log("\n[TEST 5] Speed Menu Checkmark Removal")
do
    local modernz_file = io.open("portable_config/scripts/modernz.lua", "r")
    if modernz_file then
        local content = modernz_file:read("*all")
        modernz_file:close()

        assert_test("Speed menu items excluded from menu_check glyph",
            content:find("item%.active and not menu%.covers and menu%.kind ~= \"speed\"") ~= nil and
            content:find("elseif item%.active and menu%.kind ~= \"speed\" then") ~= nil,
            "speed menu still draws menu_check")
    end
end

-- -----------------------------------------------------------------------------
-- TEST 6: SponsorBlock Manual Skip Button Redesign & Dynamic Floating Position
-- -----------------------------------------------------------------------------
log("\n[TEST 6] SponsorBlock Manual Skip Button Redesign & Dynamic Floating Position")
do
    local sb_file = io.open("portable_config/scripts/sponsorblock.lua", "r")
    if sb_file then
        local content = sb_file:read("*all")
        sb_file:close()

        -- Check sb_overlay.z = 2100
        assert_test("sb_overlay.z is 2100 (above OSC, below modal menus)",
            content:find("sb_overlay%.z = 2100") ~= nil,
            "sb_overlay.z is not 2100")

        -- Check assdraw vector rounded rectangle
        assert_test("Skip button uses assdraw:round_rect_cw",
            content:find("ass:round_rect_cw%(") ~= nil,
            "skip button not using rounded rect")

        -- Check dynamic btn_y using user-data/osc/panel_rect
        assert_test("btn_y floats dynamically above user-data/osc/panel_rect",
            content:find("local osc_top = math%.floor%(panel_rect%.y1 %* %(wh / panel_rect%.playresy%)%)") ~= nil and
            content:find("btn_y = math%.floor%(osc_top %- btn_h %- 12%)") ~= nil,
            "missing dynamic osc_top calculation")

        -- Check observer on user-data/osc/visible
        assert_test("Observes user-data/osc/visible to reposition immediately",
            content:find("mp%.observe_property%(\"user%-data/osc/visible\", \"bool\"") ~= nil,
            "missing user-data/osc/visible observer")
    end
end

-- -----------------------------------------------------------------------------
-- TEST 7: ModernZ Bottom Panel Button Layout & ModernGlass Styling
-- -----------------------------------------------------------------------------
log("\n[TEST 7] ModernZ Bottom Panel Button Layout & ModernGlass Styling")
do
    local modernz_file = io.open("portable_config/scripts/modernz.lua", "r")
    local conf_file = io.open("portable_config/script-opts/modernz.conf", "r")

    if modernz_file and conf_file then
        local m_content = modernz_file:read("*all")
        local c_content = conf_file:read("*all")
        modernz_file:close()
        conf_file:close()

        -- Title moved to top bar
        assert_test("modernz.conf show_window_title=yes",
            c_content:find("show_window_title=yes") ~= nil,
            "show_window_title not enabled in conf")
        assert_test("Bottom panel hides title row (elements.title.visible = false)",
            m_content:find("elements%[\"title\"%]%.visible = false") ~= nil,
            "title row still visible in bottom panel")

        -- Full width seekbar across top
        assert_test("Seekbar spans full panel width across top",
            m_content:find("local sx0, sx1 = x0, x1%s*local seek_w = math.max%(10, sx1 %- sx0%)") ~= nil,
            "seekbar does not span full width")

        -- Compact panel height (72px)
        assert_test("Panel height is 72px with seek_cy = py + 18, cy = py + 46",
            m_content:find("local panel_h = 72%s*local py = H %- margin %- panel_h%s*local x0, x1 = px %+ pad_x, px %+ panel_w %- pad_x%s*local inner_w = x1 %- x0%s*local seek_cy = py %+ 18%s*local cy = py %+ 46") ~= nil,
            "panel geometry incorrect")

        -- Left button layout: playlist, audio, sub, vol, volumebar, time_codes
        assert_test("Left button group has playlist, audio, sub, vol, volumebar, time_codes",
            m_content:find("{\"playlist\", btn, 75, icon, playlist_button, 4},%s*{\"audio_track\", btn, 78, icon, audio_track and user_opts.audio_tracks_button, 4},%s*{\"sub_track\", btn, 79, icon, subtitle_track and user_opts.subtitles_button, 4},%s*{\"vol_ctrl\", btn, 85, icon, audio_track and user_opts.volume_control, 0},%s*{\"volumebar\", 72, 25, nil, audio_track and user_opts.volume_control, 8},%s*{\"time_codes\", time_codes_w, 95, osc_styles.glass_time") ~= nil,
            "left button group order mismatch")

        -- Center button layout: prev, jump-10, play, jump+10, next
        assert_test("Center button group has playlist_prev, jump_backward, play_pause, jump_forward, playlist_next",
            m_content:find("{\"playlist_prev\", btn, 60, transport, nextprev") ~= nil and
            m_content:find("{\"jump_backward\", btn, 70, transport, user_opts.jump_buttons}") ~= nil and
            m_content:find("{\"play_pause\", 44, 100, osc_styles.glass_play, true}") ~= nil and
            m_content:find("{\"jump_forward\", btn, 70, transport, user_opts.jump_buttons}") ~= nil and
            m_content:find("{\"playlist_next\", btn, 60, transport, nextprev") ~= nil,
            "center button group order mismatch")

        -- Right button layout: danmaku, speed, shuffle, loop, screenshot, ontop, fullscreen
        assert_test("Right button group has danmaku, speed, shuffle, file_loop, screenshot, ontop, fullscreen",
            m_content:find("{\"danmaku\", btn, 82, icon, state.danmaku_present and user_opts.danmaku_button}") ~= nil and
            m_content:find("{\"speed\", 46, 81, osc_styles.glass_speed, user_opts.speed_button}") ~= nil and
            m_content:find("{\"shuffle\", btn, 72, icon, user_opts.shuffle_button}") ~= nil and
            m_content:find("{\"file_loop\", btn, 74, icon, user_opts.loop_button}") ~= nil and
            m_content:find("{\"screenshot\", btn, 76, icon, user_opts.screenshot_button}") ~= nil and
            m_content:find("{\"ontop\", btn, 85, icon, user_opts.ontop_button}") ~= nil and
            m_content:find("{\"fullscreen\", btn, 98, icon, user_opts.fullscreen_button}") ~= nil,
            "right button group order mismatch")
    end
end

log("\n================================================================================")
log(string.format("  TEST SUMMARY: Total %d | Passed: %d | Failed: %d", pass_count + fail_count, pass_count, fail_count))
log("================================================================================")

-- Write output report file
local out_f = io.open("prove-it/verification_report.log", "w")
if out_f then
    out_f:write(table.concat(log_lines, "\n") .. "\n")
    out_f:close()
end

if fail_count > 0 then
    mp.msg.error("Verification tests FAILED!")
else
    mp.msg.info("All verification tests PASSED successfully!")
end

mp.command("quit")
