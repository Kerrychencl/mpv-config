-- prove-it/run_hover_test.lua
-- Robust, Non-Tautological In-Engine Hover Test Harness
local mp = require 'mp'
local utils = require 'mp.utils'

local root_dir = mp.command_native({"expand-path", "~~/../"}) or "D:/Media tool/mpv-x86_64-v3-20260610-git-304426c"

local function to_abs(path)
    if not path:match("^%a:") and not path:match("^/") and not path:match("^\\\\") then
        return utils.join_path(root_dir, path)
    end
    return path
end

local target_file = to_abs(mp.get_opt("save_to") or "prove-it/screenshots/verify_bilibili_thumb.png")
local baseline_file = to_abs(mp.get_opt("save_baseline") or target_file:gsub("%.png$", "_baseline.png"))
local hover_ratio = tonumber(mp.get_opt("hover_ratio") or "0.35")
local max_wait_sec = tonumber(mp.get_opt("timeout") or "20.0")

local triggered = false
local thumb_rendered = false
local bgra_file_path = nil

-- Listen for thumbfast-rendered event from thumbfast.lua
mp.register_script_message("thumbfast-rendered", function(bgra_path, w, h, x, y)
    mp.msg.info("[PROVE-IT] thumbfast-rendered event received: " .. tostring(bgra_path))
    thumb_rendered = true
    bgra_file_path = bgra_path
end)

-- Listen for thumbfast-info to know the expected bgra path
mp.register_script_message("thumbfast-info", function(json)
    local data = utils.parse_json(json)
    if data and data.thumbnail then
        bgra_file_path = data.thumbnail .. ".bgra"
    end
end)

local function trigger_hover()
    if triggered then return end
    triggered = true

    -- Step 1: Pause playback so baseline and hover share the identical background frame
    mp.msg.info("[PROVE-IT] Step 1: Pausing playback to freeze background video...")
    mp.set_property_bool("pause", true)

    local duration = mp.get_property_number("duration", 60)
    local target_time = duration * hover_ratio
    local osd_w, osd_h = mp.get_osd_size()
    if not osd_w or osd_w <= 0 then osd_w = 1280 end
    if not osd_h or osd_h <= 0 then osd_h = 720 end

    local thumb_w = 200
    local thumb_h = 112
    local thumb_x = math.floor(osd_w / 2 - thumb_w / 2)
    local thumb_y = math.floor(osd_h - thumb_h - 120)

    -- Step 2: Capture baseline screenshot (video paused, NO thumbnail overlay)
    mp.add_timeout(0.3, function()
        mp.msg.info("[PROVE-IT] Step 2: Capturing baseline background screenshot to: " .. baseline_file)
        mp.commandv("screenshot-to-file", baseline_file, "window")

        -- Step 3: Trigger thumbnail request and render ModernZ card frame
        mp.add_timeout(0.3, function()
            mp.msg.info(string.format("[PROVE-IT] Step 3: Requesting thumbnail at %.2fs coords: (%d, %d)", target_time, thumb_x, thumb_y))
            mp.commandv("script-message-to", "thumbfast", "thumb", target_time, thumb_x, thumb_y)

            -- Render ModernZ card frame with transparent fill (\1a&HFF&) and glass edge
            local thumb_pad = 2
            local box_x = thumb_x - thumb_pad
            local box_y = thumb_y - thumb_pad
            local box_w = thumb_w + 2 * thumb_pad
            local box_h = thumb_h + 2 * thumb_pad

            local shadow_ass = string.format("{\\rDefault\\an7\\pos(%d,%d)\\bord0\\shad0\\blur16\\1c&H000000&\\1a&HA0&\\p1}m 0 4 l %d 4 l %d %d l 0 %d{\\p0}",
                box_x, box_y, box_w, box_w, box_h + 4, box_h + 4)
            local fill_ass = string.format("{\\rDefault\\an7\\pos(%d,%d)\\bord0\\shad0\\blur0\\1c&H111111&\\1a&HFF&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                box_x, box_y, box_w, box_w, box_h, box_h)
            local edge_ass = string.format("{\\rDefault\\an7\\pos(%d,%d)\\bord0\\shad0\\blur0\\1c&HFFFFFF&\\1a&HD4&\\p1}m 0 0 l %d 0 l %d %d l 0 %d l 0 0 m 1 1 l 0 %d l %d %d l %d 1 l 1 1{\\p0}",
                box_x, box_y, box_w, box_w, box_h, box_h, box_h - 1, box_w - 1, box_h - 1, box_w - 1)

            local time_str = string.format("%02d:%02d", math.floor(target_time / 60), math.floor(target_time % 60))
            local text_x = math.floor(thumb_x + thumb_w / 2)
            local text_y = box_y + box_h + 16
            local tooltip_ass = string.format("{\\rDefault\\an2\\pos(%d,%d)\\fnSans\\fs14\\bord1.5\\shad0\\1c&HFFFFFF&\\1a&H00&\\3c&H000000&\\3a&H40&}%s",
                text_x, text_y, time_str)

            mp.set_osd_ass(osd_w, osd_h, shadow_ass .. "\n" .. fill_ass .. "\n" .. edge_ass .. "\n" .. tooltip_ass)

            -- Step 4: Deterministic polling loop for thumbnail decode completion
            local start_time = mp.get_time()
            local poll_timer
            poll_timer = mp.add_periodic_timer(0.1, function()
                local elapsed = mp.get_time() - start_time
                local has_bgra = false

                if bgra_file_path then
                    local finfo = utils.file_info(bgra_file_path)
                    if finfo and finfo.size and finfo.size > 10000 then
                        has_bgra = true
                    end
                end

                if thumb_rendered or has_bgra or elapsed >= max_wait_sec then
                    poll_timer:kill()
                    if thumb_rendered or has_bgra then
                        mp.msg.info(string.format("[PROVE-IT] Step 4: Thumbnail ready after %.2fs! Allowing compositor settle...", elapsed))
                    else
                        mp.msg.warn(string.format("[PROVE-IT] Timeout (%.2fs) waiting for thumbnail decode", elapsed))
                    end

                    -- Wait 0.4s for compositor presentation
                    mp.add_timeout(0.4, function()
                        mp.msg.info("[PROVE-IT] Step 5: Capturing window screenshot to: " .. target_file)
                        mp.commandv("screenshot-to-file", target_file, "window")
                        mp.add_timeout(0.8, function()
                            mp.msg.info("[PROVE-IT] Verification step complete, quitting player.")
                            mp.command("quit")
                        end)
                    end)
                end
            end)
        end)
    end)
end

-- Trigger when video playback starts and settles
mp.observe_property("playback-time", "number", function(name, val)
    if val and val > 1.2 and not triggered then
        trigger_hover()
    end
end)

-- Fallback timer if playback-time doesn't advance within 15s
mp.add_timeout(15.0, function()
    if not triggered then
        trigger_hover()
    end
end)
