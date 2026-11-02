-- prove-it/adversarial_challenge.lua
-- Adversarial Challenge Harness for MPV Seekbar Thumbnail & ModernZ Layering
local mp = require 'mp'
local utils = require 'mp.utils'

local opt_mode = mp.get_opt("challenge_mode") or "single"
local opt_save1 = mp.get_opt("save_file1") or "prove-it/screenshots/challenge_output1.png"
local opt_save2 = mp.get_opt("save_file2") or "prove-it/screenshots/challenge_output2.png"
local opt_t1 = tonumber(mp.get_opt("t1") or "5.0")
local opt_t2 = tonumber(mp.get_opt("t2") or "15.0")
local opt_pause = mp.get_opt("pause_before_hover") == "yes"

local root_dir = mp.command_native({"expand-path", "~~/../"}) or "D:/Media tool/mpv-x86_64-v3-20260610-git-304426c"

local function to_abs(path)
    if not path:match("^%a:") and not path:match("^/") and not path:match("^\\\\") then
        return utils.join_path(root_dir, path)
    end
    return path
end

opt_save1 = to_abs(opt_save1)
opt_save2 = to_abs(opt_save2)

local triggered = false

local function render_modernz_card(target_time, thumb_x, thumb_y, thumb_w, thumb_h)
    local osd_w, osd_h = mp.get_osd_size()
    if not osd_w or osd_w <= 0 then osd_w = 1280 end
    if not osd_h or osd_h <= 0 then osd_h = 720 end

    local thumb_pad = 2
    local thumb_radius = 4
    local box_x = thumb_x - thumb_pad
    local box_y = thumb_y - thumb_pad
    local box_w = thumb_w + 2 * thumb_pad
    local box_h = thumb_h + 2 * thumb_pad

    -- ModernZ ASS Card:
    -- 1. Shadow: subtle blurred black shadow (\blur16\1c&H000000&\1a&HA0&)
    -- 2. Box Fill: 100% transparent (\1c&H111111&\1a&HFF&) -- CRITICAL FIX UNDER TEST
    -- 3. Glass Edge: semi-transparent white border (\1c&HFFFFFF&\1a&HD4&)
    local shadow_ass = string.format("{\\rDefault\\an7\\pos(%d,%d)\\bord0\\shad0\\blur16\\1c&H000000&\\1a&HA0&\\p1}m 0 4 l %d 4 l %d %d l 0 %d{\\p0}",
        box_x, box_y, box_w, box_w, box_h + 4, box_h + 4)
    
    local fill_ass = string.format("{\\rDefault\\an7\\pos(%d,%d)\\bord0\\shad0\\blur0\\1c&H111111&\\1a&HFF&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
        box_x, box_y, box_w, box_w, box_h, box_h)

    local edge_ass = string.format("{\\rDefault\\an7\\pos(%d,%d)\\bord0\\shad0\\blur0\\1c&HFFFFFF&\\1a&HD4&\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0 m 1 1 l 0 %d l %d %d l %d 1 l 1 1{\\p0}",
        box_x, box_y, box_w, box_w, box_h, box_h, box_h - 1, box_w - 1, box_h - 1, box_w - 1)

    -- Tooltip text: anchored below thumbnail (between thumbnail and seekbar)
    local min = math.floor(target_time / 60)
    local sec = math.floor(target_time % 60)
    local dur = math.floor(mp.get_property_number("duration", 0))
    local dur_min = math.floor(dur / 60)
    local dur_sec = math.floor(dur % 60)
    local time_str = string.format("%02d:%02d / %02d:%02d", min, sec, dur_min, dur_sec)

    local text_x = math.floor(thumb_x + thumb_w / 2)
    local text_y = box_y + box_h + 16
    local tooltip_ass = string.format("{\\rDefault\\an2\\pos(%d,%d)\\fnSans\\fs14\\bord1.5\\shad0\\1c&HFFFFFF&\\1a&H00&\\3c&H000000&\\3a&H40&}%s",
        text_x, text_y, time_str)

    -- Seekbar Track: bottom panel seekbar representation
    local seekbar_y = text_y + 8
    local seekbar_ass = string.format("{\\rDefault\\an7\\pos(40,%d)\\bord0\\shad0\\blur0\\1c&HFFFFFF&\\1a&HAA&\\p1}m 0 0 l %d 0 l %d 4 l 0 4{\\p0}",
        seekbar_y, osd_w - 80, osd_w - 80)

    local full_ass = shadow_ass .. "\n" .. fill_ass .. "\n" .. edge_ass .. "\n" .. tooltip_ass .. "\n" .. seekbar_ass
    mp.set_osd_ass(osd_w, osd_h, full_ass)
end

local function run_challenge()
    if triggered then return end
    triggered = true

    local osd_w, osd_h = mp.get_osd_size()
    if not osd_w or osd_w <= 0 then osd_w = 1280 end
    if not osd_h or osd_h <= 0 then osd_h = 720 end

    local thumb_w = 200
    local thumb_h = 112
    local thumb_x = math.floor(osd_w / 2 - thumb_w / 2)
    local thumb_y = math.floor(osd_h - thumb_h - 120)

    if opt_pause then
        mp.msg.info("[CHALLENGER] Pausing playback before hover...")
        mp.set_property_bool("pause", true)
    end

    if opt_mode == "single" or opt_mode == "paused" or opt_mode == "active" then
        mp.msg.info(string.format("[CHALLENGER] Triggering hover at timestamp %.2fs...", opt_t1))
        mp.commandv("script-message-to", "thumbfast", "thumb", opt_t1, thumb_x, thumb_y)
        render_modernz_card(opt_t1, thumb_x, thumb_y, thumb_w, thumb_h)

        -- Allow slave mpv 3.5 seconds to decode and overlay
        mp.add_timeout(3.5, function()
            mp.msg.info("[CHALLENGER] Capturing screenshot to " .. opt_save1)
            mp.commandv("screenshot-to-file", opt_save1, "window")
            mp.add_timeout(1.0, function()
                mp.msg.info("[CHALLENGER] Test finished, quitting mpv.")
                mp.command("quit")
            end)
        end)

    elseif opt_mode == "rapid" then
        -- Stress test: rapid scrubbing jumps across timeline
        local jumps = {
            opt_t1 * 0.4,
            opt_t1 * 1.8,
            opt_t1 * 0.8,
            opt_t1 * 1.4,
            opt_t1        -- Final target timestamp
        }

        mp.msg.info("[CHALLENGER] Starting RAPID HOVER stress test (5 seeks in 1.2s)...")
        for i, t in ipairs(jumps) do
            mp.add_timeout((i - 1) * 0.25, function()
                local cur_t = t
                mp.msg.info(string.format("[CHALLENGER] Rapid hover seek #%d -> %.2fs", i, cur_t))
                mp.commandv("script-message-to", "thumbfast", "thumb", cur_t, thumb_x, thumb_y)
                render_modernz_card(cur_t, thumb_x, thumb_y, thumb_w, thumb_h)
            end)
        end

        -- Wait 3.5s after final jump to verify slave mpv recovers and settles on final timestamp
        local final_delay = #jumps * 0.25 + 3.5
        mp.add_timeout(final_delay, function()
            mp.msg.info("[CHALLENGER] Rapid hover settled. Capturing screenshot to " .. opt_save1)
            mp.commandv("screenshot-to-file", opt_save1, "window")
            mp.add_timeout(1.0, function()
                mp.msg.info("[CHALLENGER] Rapid hover test complete, quitting mpv.")
                mp.command("quit")
            end)
        end)

    elseif opt_mode == "diff" then
        -- Two distinct timestamps test
        mp.msg.info(string.format("[CHALLENGER] Triggering Phase 1 hover at t1 = %.2fs...", opt_t1))
        mp.commandv("script-message-to", "thumbfast", "thumb", opt_t1, thumb_x, thumb_y)
        render_modernz_card(opt_t1, thumb_x, thumb_y, thumb_w, thumb_h)

        mp.add_timeout(3.5, function()
            mp.msg.info("[CHALLENGER] Capturing Phase 1 screenshot to " .. opt_save1)
            mp.commandv("screenshot-to-file", opt_save1, "window")

            -- Move to Phase 2
            mp.add_timeout(1.0, function()
                mp.msg.info(string.format("[CHALLENGER] Triggering Phase 2 hover at t2 = %.2fs...", opt_t2))
                mp.commandv("script-message-to", "thumbfast", "thumb", opt_t2, thumb_x, thumb_y)
                render_modernz_card(opt_t2, thumb_x, thumb_y, thumb_w, thumb_h)

                mp.add_timeout(3.5, function()
                    mp.msg.info("[CHALLENGER] Capturing Phase 2 screenshot to " .. opt_save2)
                    mp.commandv("screenshot-to-file", opt_save2, "window")
                    mp.add_timeout(1.0, function()
                        mp.msg.info("[CHALLENGER] Diff test complete, quitting mpv.")
                        mp.command("quit")
                    end)
                end)
            end)
        end)
    end
end

-- Wait until playback is rolling or timeout fallback
mp.observe_property("playback-time", "number", function(name, val)
    if val and val > 0.5 and not triggered then
        run_challenge()
    end
end)

mp.add_timeout(15.0, function()
    if not triggered then
        mp.msg.warn("[CHALLENGER] Fallback trigger fired after 15s")
        run_challenge()
    end
end)
