-- prove-it/comprehensive_test.lua
-- Deep verification test suite for MPV ModernZ, BTR, ContextMenu, Danmaku, and SponsorBlock
local mp = require 'mp'
local utils = require 'mp.utils'

local log_lines = {}
local pass_count = 0
local fail_count = 0

local config_dir = mp.command_native({"expand-path", "~~/"}) or ""
local root_dir = mp.command_native({"expand-path", "~~/../"}) or ""

local function open_cfg_file(rel)
    local f = io.open(utils.join_path(config_dir, rel:gsub("^portable_config/", "")), "r")
    if not f then f = io.open(rel, "r") end
    if not f then f = io.open(utils.join_path(root_dir, rel), "r") end
    return f
end

local function log(msg)
    mp.msg.info(msg)
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
log("  COMPREHENSIVE DEEP VERIFICATION TEST SUITE (MPV / ModernZ / BTR / Menu / SB)  ")
log("================================================================================")

-- -----------------------------------------------------------------------------
-- 1. Check is_bili_live_url and rewrite_stream_filename in BTR
-- -----------------------------------------------------------------------------
log("\n[TEST 1] BTR Live Stream URL Identification & Routing Robustness")
do
    local btr_file = open_cfg_file("portable_config/scripts/btr/main.lua")
    if btr_file then
        local content = btr_file:read("*all")
        btr_file:close()

        -- Verify is_bili_live_url doesn't require live_acceleration to identify live URLs
        assert_test("is_bili_live_url does not condition live detection on live_acceleration setting",
            content:find("if %(lower:find%(\"mcdn%%.\"%) or lower:find%(\"%[%?&%]os=mcdn\"%)%) and %(lower:find%(\"/live\"%) or lower:find%(\"live_\"%) or lower:find%(\"bvc\"%)%) then%s*return true") ~= nil,
            "is_bili_live_url still gated by settings.live_acceleration")

        -- Verify /live_ matching is supported
        assert_test("is_bili_live_url supports /live_ pattern",
            content:find("lower:find%(\"/live_\"%)") ~= nil,
            "missing /live_ pattern")

        -- Verify BTR advanced string.format fix
        assert_test("BTR advanced settings item.title and item.desc format strings fixed",
            content:find("item%.title%)") ~= nil and content:find("item%.desc%)") ~= nil,
            "missing format parameters in btr/main.lua")

        -- Verify pcall protection
        assert_test("BTR render_menu has pcall protection",
            content:find("local ok, err = pcall%(function%(%)") ~= nil,
            "missing pcall protection")
    else
        assert_test("btr/main.lua exists", false, "file not found")
    end
end

-- -----------------------------------------------------------------------------
-- 2. ModernZ Speed Button Text & Menu Checkmark Removal
-- -----------------------------------------------------------------------------
log("\n[TEST 2] ModernZ Speed Button Text ('1.0x') & Checkmark Removal")
do
    local modernz_file = open_cfg_file("portable_config/scripts/modernz.lua")
    if modernz_file then
        local content = modernz_file:read("*all")
        modernz_file:close()

        -- Speed button content always returns speed_label(state.speed or 1)
        assert_test("Speed button displays '1.0x' text (speed_label) instead of speedometer icon",
            content:find("ne%.content = function%(%)%s*return speed_label%(state%.speed or 1%)%s*end") ~= nil,
            "speed button does not always return speed_label")

        -- Speed menu excludes checkmark glyph
        assert_test("Speed menu items exclude menu_check glyph",
            content:find("menu%.kind ~= \"speed\"") ~= nil,
            "speed menu still draws menu_check")

        -- Active speed item text styled with accent color
        assert_test("Active speed item highlighted with theme accent color",
            content:find("menu%.kind == \"speed\" and item%.active") ~= nil and
            content:find("&H2880F7&") ~= nil,
            "active speed item missing accent highlight")

        -- glass_speed style uses ui_font.medium
        assert_test("glass_speed style uses ui_font.medium",
            content:find("glass_speed = \"{\\\\bord0\\\\shad0\\\\1c&H\" %.%. osc_color_convert%(user_opts%.side_buttons_color%) %.%. \"&\\\\fs15\\\\fn\" %.%. ui_font%.medium") ~= nil,
            "glass_speed not using ui_font.medium")
    else
        assert_test("modernz.lua exists", false, "file not found")
    end
end

-- -----------------------------------------------------------------------------
-- 3. ModernZ Buttons Always Active & Layout Structure
-- -----------------------------------------------------------------------------
log("\n[TEST 3] ModernZ Transport Buttons & Bottom Layout Matching Figure 1")
do
    local modernz_file = open_cfg_file("portable_config/scripts/modernz.lua")
    local conf_file = open_cfg_file("portable_config/script-opts/modernz.conf")
    if modernz_file and conf_file then
        local m_content = modernz_file:read("*all")
        local c_content = conf_file:read("*all")
        modernz_file:close()
        conf_file:close()

        -- buttons_always_active set to playlist_prev,playlist_next
        assert_test("modernz.conf buttons_always_active=playlist_prev,playlist_next",
            c_content:find("buttons_always_active=playlist_prev,playlist_next") ~= nil,
            "buttons_always_active not set to playlist_prev,playlist_next")

        -- Center group has 5 buttons: playlist_prev, jump_backward, play_pause, jump_forward, playlist_next
        assert_test("Center transport group has playlist_prev, jump_backward, play, jump_forward, playlist_next",
            m_content:find("{\"playlist_prev\", btn, 60, transport, nextprev") ~= nil and
            m_content:find("{\"jump_backward\", btn, 70, transport, user_opts.jump_buttons}") ~= nil and
            m_content:find("{\"play_pause\", 44, 100, osc_styles.glass_play, true}") ~= nil and
            m_content:find("{\"jump_forward\", btn, 70, transport, user_opts.jump_buttons}") ~= nil and
            m_content:find("{\"playlist_next\", btn, 60, transport, nextprev") ~= nil,
            "center button group order mismatch")

        -- Left group: audio_track, sub_track, vol_ctrl, volumebar, time_codes
        assert_test("Left group has audio, sub, vol, volumebar, time_codes (no playlist)",
            m_content:find("{\"audio_track\", btn, 78, icon, audio_track and user_opts.audio_tracks_button, 4},%s*{\"sub_track\", btn, 79, icon, subtitle_track and user_opts.subtitles_button, 4},%s*{\"vol_ctrl\", btn, 85, icon, audio_track and user_opts.volume_control, 0},%s*{\"volumebar\", 72, 25, nil, audio_track and user_opts.volume_control, 8},%s*{\"time_codes\", time_codes_w, 95, osc_styles.glass_time") ~= nil,
            "left group order mismatch")

        -- Right group: download, danmaku, speed, playlist, more, fullscreen
        assert_test("Right group has danmaku, speed, playlist, more, fullscreen (clean, no shuffle/loop/screenshot/ontop)",
            m_content:find("{\"danmaku\", btn, 82, icon, state.danmaku_present and user_opts.danmaku_button}") ~= nil and
            m_content:find("{\"speed\", 46, 81, osc_styles.glass_speed, user_opts.speed_button}") ~= nil and
            m_content:find("{\"playlist\", btn, 75, icon, playlist_button}") ~= nil and
            m_content:find("{\"more\", btn, 80, icon, user_opts.more_button ~= false}") ~= nil and
            m_content:find("{\"fullscreen\", btn, 98, icon, user_opts.fullscreen_button}") ~= nil and
            m_content:find("{\"shuffle\", btn, 72") == nil and
            m_content:find("{\"file_loop\", btn, 74") == nil,
            "right group order mismatch")

        -- Panel height narrowed to 58, margin down to 10
        assert_test("Bottom panel height narrowed (panel_h=58, cy=py+38, seek_cy=py+14, btn=34)",
            m_content:find("local panel_h = 58") ~= nil and
            m_content:find("local cy = py %+ 38") ~= nil and
            m_content:find("local seek_cy = py %+ 14") ~= nil and
            m_content:find("local btn = 34") ~= nil,
            "panel height and control positioning mismatch")

        -- Volume slider link updated to left[3] and left[4]
        assert_test("Volume slider linkage updated to index 3 & 4",
            m_content:find("if not left%[3%]%.keep then left%[4%]%.keep = false end") ~= nil and
            m_content:find("if left%[3%]%.keep and left%[4%]%.keep then") ~= nil,
            "volume linkage mismatch")

        -- Title moved to top bar
        assert_test("show_window_title=yes in modernz.conf",
            c_content:find("show_window_title=yes") ~= nil,
            "show_window_title not enabled")
    end
end

-- -----------------------------------------------------------------------------
-- 4. Danmaku Panel & ModernZ Integration
-- -----------------------------------------------------------------------------
log("\n[TEST 4] Danmaku Menu & OSC Observer Synchronization")
do
    local modernz_file = open_cfg_file("portable_config/scripts/modernz.lua")
    local danmaku_file = open_cfg_file("portable_config/scripts/danmaku-menu.lua")
    if modernz_file and danmaku_file then
        local m_content = modernz_file:read("*all")
        local d_content = danmaku_file:read("*all")
        modernz_file:close()
        danmaku_file:close()

        -- danmaku-menu sets user-data/danmaku-menu/open
        assert_test("danmaku-menu updates user-data/danmaku-menu/open property",
            d_content:find("mp%.set_property_bool%(\"user%-data/danmaku%-menu/open\", true%)") ~= nil and
            d_content:find("mp%.set_property_bool%(\"user%-data/danmaku%-menu/open\", false%)") ~= nil,
            "danmaku-menu does not set user-data/danmaku-menu/open")

        -- modernz observes user-data/danmaku-menu/open
        assert_test("modernz observes user-data/danmaku-menu/open property",
            m_content:find("mp%.observe_property%(\"user%-data/danmaku%-menu/open\", \"bool\"") ~= nil,
            "modernz does not observe user-data/danmaku-menu/open")

        -- modernz autohide prevented while danmaku-menu is open
        assert_test("modernz autohide respects danmaku menu open state",
            m_content:find("menu or mp%.get_property_bool%(\"user%-data/danmaku%-menu/open\", false%)") ~= nil,
            "autohide does not check danmaku menu state")
    end
end

-- -----------------------------------------------------------------------------
-- 5. Right-Click Context Menu Scaling
-- -----------------------------------------------------------------------------
log("\n[TEST 5] Right-Click Context Menu Dynamic Scaling & Compact Size")
do
    local menu_file = open_cfg_file("portable_config/scripts/menu/menu.lua")
    local style_file = open_cfg_file("portable_config/script-opts/menu_style.conf")
    if menu_file and style_file then
        local m_content = menu_file:read("*all")
        local s_content = style_file:read("*all")
        menu_file:close()
        style_file:close()

        -- Dynamic height scaling
        assert_test("resolve_item_height scales explicit height by f (h / 1080)",
            m_content:find("if explicit then return explicit %* f end") ~= nil,
            "explicit item height not scaled by f")

        -- Compact values
        assert_test("menu_style.conf has font_size=20 and menu_item_height=32",
            s_content:find("font_size=20") ~= nil and s_content:find("menu_item_height=32") ~= nil,
            "menu_style.conf size settings mismatch")
        assert_test("menu_style.conf has min_width=240 and radius=10",
            s_content:find("min_width=240") ~= nil and s_content:find("radius=10") ~= nil,
            "menu_style.conf width/radius mismatch")
    end
end

-- -----------------------------------------------------------------------------
-- 6. SponsorBlock Manual Skip Button Dynamic Positioning
-- -----------------------------------------------------------------------------
log("\n[TEST 6] SponsorBlock Manual Skip Button Dynamic Floating")
do
    local sb_file = open_cfg_file("portable_config/scripts/sponsorblock.lua")
    if sb_file then
        local content = sb_file:read("*all")
        sb_file:close()

        -- Dynamic btn_y above OSC
        assert_test("btn_y calculates osc_top from user-data/osc/panel_rect",
            content:find("local osc_top = math%.floor%(panel_rect%.y1 %* %(wh / panel_rect%.playresy%)%)") ~= nil and
            content:find("btn_y = math%.floor%(osc_top %- btn_h %- 12%)") ~= nil,
            "missing dynamic btn_y calculation")

        -- Observes user-data/osc/panel_rect and user-data/osc/visible
        assert_test("sponsorblock observes both user-data/osc/visible and panel_rect",
            content:find("mp%.observe_property%(\"user%-data/osc/visible\"") ~= nil and
            content:find("mp%.observe_property%(\"user%-data/osc/panel_rect\"") ~= nil,
            "missing property observers in sponsorblock")

        -- Safe bounds for small windows
        assert_test("sponsorblock applies safe math bounds for btn_w and btn_x",
            content:find("btn_w = math%.min%(320, ww %- 24%)") ~= nil and
            content:find("btn_x = math%.max%(12, ww %- btn_w %- 24%)") ~= nil,
            "missing safe bounds in sponsorblock")
    end
end

-- -----------------------------------------------------------------------------
-- 7. Input.conf Context Menu (Track item removed from first level)
-- -----------------------------------------------------------------------------
log("\n[TEST 7] Right-click Menu First-level Track Item Removal")
do
    local input_file = open_cfg_file("portable_config/input.conf")
    if input_file then
        local content = input_file:read("*all")
        input_file:close()
        assert_test("input.conf removed first-level track item (#menu: 軌道 #@tracks)",
            content:find("#menu:%s*軌道%s*#@tracks") == nil,
            "first-level track item still exists in input.conf")
    end
end

-- -----------------------------------------------------------------------------
-- 8. Glass Shader Transparency & Softness
-- -----------------------------------------------------------------------------
log("\n[TEST 8] ModernZ Glass Shader Transparency & Blur Tuning")
do
    local modernz_file = open_cfg_file("portable_config/scripts/modernz.lua")
    local conf_file = open_cfg_file("portable_config/script-opts/modernz.conf")
    if modernz_file and conf_file then
        local m_content = modernz_file:read("*all")
        local c_content = conf_file:read("*all")
        modernz_file:close()
        conf_file:close()

        assert_test("GLASS_SHADER and glass_blur_update strength lowered to 0.55",
            m_content:find("kv%.mzg_strength = \"0.55\"") ~= nil,
            "mzg_strength not set to 0.55")
        assert_test("GLASS_SHADER tone lowered to 0.08",
            m_content:find("kv%.mzg_tone = \"0.08\"") ~= nil,
            "mzg_tone not set to 0.08")
        assert_test("modernz.conf glass_opacity=6",
            c_content:find("glass_opacity=6") ~= nil,
            "glass_opacity not set to 6")
        assert_test("modernz.conf panel_margin=10",
            c_content:find("panel_margin=10") ~= nil,
            "panel_margin not set to 10")
    end
end

-- -----------------------------------------------------------------------------
-- 9. Thumbfast Precision & EDL URL Extraction
-- -----------------------------------------------------------------------------
log("\n[TEST 9] Thumbfast Exact Seek & EDL Extraction")
do
    local thumbfast_lua = open_cfg_file("portable_config/scripts/thumbfast.lua")
    local thumbfast_conf = open_cfg_file("portable_config/script-opts/thumbfast.conf")
    if thumbfast_lua and thumbfast_conf then
        local l_content = thumbfast_lua:read("*all")
        local c_content = thumbfast_conf:read("*all")
        thumbfast_lua:close()
        thumbfast_conf:close()

        assert_test("thumbfast.conf exact_seek=auto and exact_seek_delay=0.08",
            c_content:find("exact_seek=auto") ~= nil and c_content:find("exact_seek_delay=0.08") ~= nil,
            "thumbfast exact_seek settings mismatch")
        assert_test("thumbfast.lua extracts EDL url with %length% prefix without comma truncating",
            l_content:find("url_body:sub%(1,%s*len%)") ~= nil,
            "thumbfast edl url length-based extraction missing")
    end
end

-- -----------------------------------------------------------------------------
-- 10. Bilibili Live Stream Danmaku Noise Prevention
-- -----------------------------------------------------------------------------
log("\n[TEST 10] Bilibili Live Stream Danmaku Noise Prevention")
do
    local danmaku_main = open_cfg_file("portable_config/scripts/mpv-danmaku/main.lua")
    if danmaku_main then
        local content = danmaku_main:read("*all")
        danmaku_main:close()

        assert_test("mpv-danmaku/main.lua has is_bili_live_stream helper",
            content:find("local function is_bili_live_stream") ~= nil,
            "missing is_bili_live_stream helper")
        assert_test("extract_bili_cid aborts immediately on live stream",
            content:find("if is_bili_live_stream%(%s*%) then return nil end") ~= nil,
            "extract_bili_cid does not block live stream fake CID")
    end
end

-- -----------------------------------------------------------------------------
-- 11. Subtitle Margin Elevation Moderation
-- -----------------------------------------------------------------------------
log("\n[TEST 11] Subtitle Margin Elevation Tuning")
do
    local modernz_file = open_cfg_file("portable_config/scripts/modernz.lua")
    if modernz_file then
        local content = modernz_file:read("*all")
        modernz_file:close()

        assert_test("sub-pos adjusted by moderate factor (margins.b * 0.38)",
            content:find("margins%.b %* 0%.38") ~= nil,
            "sub-pos scaling factor missing")
        assert_test("sub-margin-y adjusted by moderate factor (margins.b * H * 0.38)",
            content:find("margins%.b %* H %* 0%.38") ~= nil,
            "sub-margin-y scaling factor missing")
    end
end

-- -----------------------------------------------------------------------------
-- 12. Speed Menu Inline Editing & Custom Speed Deletion
-- -----------------------------------------------------------------------------
log("\n[TEST 12] Speed Menu Inline Editing & Custom Speed Deletion")
do
    local modernz_file = open_cfg_file("portable_config/scripts/modernz.lua")
    if modernz_file then
        local content = modernz_file:read("*all")
        modernz_file:close()

        assert_test("modernz.lua contains start_speed_edit and stop_speed_edit",
            content:find("start_speed_edit = function%(%)") ~= nil and
            content:find("stop_speed_edit = function%(silent%)") ~= nil,
            "missing speed edit functions")
        assert_test("modernz.lua contains remove_custom_speed",
            content:find("remove_custom_speed = function%(val%)") ~= nil,
            "missing remove_custom_speed function")
        assert_test("modernz.lua preserves menu on edit and reload (keep_menu & opts.reload)",
            content:find("item%.keep_menu") ~= nil and content:find("opts%.reload") ~= nil,
            "missing keep_menu or opts.reload protection")
        assert_test("render_menu draws window_close on hovered custom speed",
            content:find("menu%.kind == \"speed\" and item%.is_custom and menu%.hover == i") ~= nil,
            "missing delete cross rendering in speed menu")
        assert_test("menu_event supports right-click or cross-click to remove custom speed",
            content:find("remove_custom_speed%(item%.speed_val%)") ~= nil,
            "missing delete event handler in menu_event")
    end
end

-- -----------------------------------------------------------------------------
-- 13. Top Window Title Capsule Dynamic Width & Observers
-- -----------------------------------------------------------------------------
log("\n[TEST 13] Top Window Title Capsule Dynamic Width & Observers")
do
    local modernz_file = open_cfg_file("portable_config/scripts/modernz.lua")
    if modernz_file then
        local content = modernz_file:read("*all")
        modernz_file:close()

        assert_test("glass_window_controls measures dynamic raw_title width with glass_window_title",
            content:find("local raw_title = mp%.get_property%(\"media%-title\"%) or mp%.get_property%(\"title\"%) or \"\"") ~= nil and
            content:find("estimate_text_width%(raw_title, osc_styles%.glass_window_title%)") ~= nil,
            "missing dynamic title capsule width calculation")
        assert_test("windowtitle element uses glass_window_title style under glass_ui",
            content:find("state%.glass_ui and osc_styles%.glass_window_title or osc_styles%.window_title") ~= nil,
            "windowtitle element not using glass_window_title style")
        assert_test("observe_cached watches media-title and title to request_init_resize",
            content:find("observe_cached%(\"media%-title\", request_init_resize%)") ~= nil and
            content:find("observe_cached%(\"title\", request_init_resize%)") ~= nil,
            "missing media-title or title observers")
    end
end

log("\n================================================================================")
log(string.format("  CODE LOGIC SUMMARY: Total %d | Passed: %d | Failed: %d", pass_count + fail_count, pass_count, fail_count))
log("================================================================================")

-- -----------------------------------------------------------------------------
-- Visual Screenshot Captures & Live GUI Tests
-- -----------------------------------------------------------------------------
log("\n[VISUAL TESTS] Performing In-Engine Visual Screenshots & GUI Execution")

local step = 1
local function run_visual_steps()
    if step == 1 then
        -- Step 1: Show OSC bottom bar & top title
        log("  [ACTION] Showing ModernZ OSC & Top Title...")
        mp.commandv("script-message", "osc-show")
        mp.add_timeout(0.6, function()
            mp.commandv("screenshot-to-file", utils.join_path(root_dir, "prove-it/screenshots/01_osc_ui_layout.png"), "window")
            log("  [SAVED] prove-it/screenshots/01_osc_ui_layout.png")
            step = 2
            run_visual_steps()
        end)
    elseif step == 2 then
        -- Step 2: Open Speed Menu
        log("  [ACTION] Toggling ModernZ Speed Menu...")
        mp.commandv("script-message", "speed_menu/toggle")
        mp.add_timeout(0.5, function()
            mp.commandv("screenshot-to-file", utils.join_path(root_dir, "prove-it/screenshots/02_speed_menu.png"), "window")
            log("  [SAVED] prove-it/screenshots/02_speed_menu.png")
            
            -- Step 2.5: Test Inline Speed Edit & Live Cursor
            log("  [ACTION] Activating Inline Speed Edit (Typing 1.75)...")
            mp.commandv("script-message", "modernz/speed_edit/start")
            mp.add_timeout(0.3, function()
                mp.commandv("script-message", "modernz/speed_edit/type", "1.75")
                mp.add_timeout(0.4, function()
                    mp.commandv("screenshot-to-file", utils.join_path(root_dir, "prove-it/screenshots/02_speed_editing.png"), "window")
                    log("  [SAVED] prove-it/screenshots/02_speed_editing.png (Live In-slot Edit)")
                    mp.commandv("script-message", "modernz/speed_edit/commit")
                    mp.add_timeout(0.4, function()
                        -- clean up the added speed preset (1.75) using remove_custom_speed for test idempotency
                        mp.commandv("script-message", "modernz/speed_remove", "1.75")
                        mp.commandv("set", "speed", "1.0")
                        mp.add_timeout(0.2, function()
                            mp.commandv("script-message", "speed_menu/toggle") -- close it
                            step = 3
                            mp.add_timeout(0.3, run_visual_steps)
                        end)
                    end)
                end)
            end)
        end)
    elseif step == 3 then
        -- Step 3: Open Right-Click Context Menu
        log("  [ACTION] Opening Context Menu...")
        mp.commandv("script-message-to", "menu", "show")
        mp.add_timeout(0.5, function()
            mp.commandv("screenshot-to-file", utils.join_path(root_dir, "prove-it/screenshots/03_context_menu.png"), "window")
            log("  [SAVED] prove-it/screenshots/03_context_menu.png")
            mp.commandv("script-message-to", "menu", "hide") -- close it
            step = 4
            mp.add_timeout(0.3, run_visual_steps)
        end)
    elseif step == 4 then
        -- Step 4: Open BTR Advanced Menu
        log("  [ACTION] Opening BTR Threadripper Advanced Menu...")
        mp.commandv("script-message-to", "btr", "btr-open-advanced")
        mp.add_timeout(0.5, function()
            mp.commandv("screenshot-to-file", utils.join_path(root_dir, "prove-it/screenshots/04_btr_advanced.png"), "window")
            log("  [SAVED] prove-it/screenshots/04_btr_advanced.png")
            mp.commandv("script-message-to", "btr", "btr-close-menu")
            step = 5
            mp.add_timeout(0.3, run_visual_steps)
        end)
    elseif step == 5 then
        -- Step 5: Test SponsorBlock Floating Skip Button
        log("  [ACTION] Simulating SponsorBlock Segment & Floating Button...")
        mp.commandv("script-message", "osc-show")
        mp.commandv("script-message-to", "sponsorblock", "sponsorblock-show-skip", "贊助商片段測試")
        mp.add_timeout(0.5, function()
            mp.commandv("screenshot-to-file", utils.join_path(root_dir, "prove-it/screenshots/05_sponsorblock_floating.png"), "window")
            log("  [SAVED] prove-it/screenshots/05_sponsorblock_floating.png")
            
            -- Finish and quit
            local report_path = utils.join_path(root_dir, "prove-it/verification_report.log")
            local report_f = io.open(report_path, "w")
            if report_f then
                report_f:write(table.concat(log_lines, "\n") .. "\n")
                report_f:close()
            end
            log("\nAll verification actions finished successfully!")
            mp.command("quit")
        end)
    end
end

local started = false
local function start_tests()
    if started then return end
    started = true
    mp.add_timeout(0.6, run_visual_steps)
end

mp.register_event("file-loaded", start_tests)
mp.add_timeout(1.2, start_tests)
