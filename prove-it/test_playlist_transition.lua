local mp = require 'mp'

local step = 1

local function dump_headers(tag)
    local headers = mp.get_property_native("http-header-fields") or {}
    mp.msg.info(string.format("[CHALLENGE-RESULT] %s HEADERS COUNT: %d", tag, #headers))
    for i, h in ipairs(headers) do
        mp.msg.info(string.format("[CHALLENGE-RESULT] %s HEADER[%d]: %s", tag, i, h))
    end
end

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    mp.msg.info(string.format("[CHALLENGE-RESULT] EVENT file-loaded step=%d path=%s", step, path))
    dump_headers("LOADED-STEP-" .. step)

    if step == 1 then
        step = 2
        mp.msg.info("[CHALLENGE-RESULT] Step 1 finished. Waiting 2s then replacing with YouTube...")
        mp.add_timeout(2.0, function()
            mp.msg.info("[CHALLENGE-RESULT] Executing loadfile for YouTube...")
            mp.commandv("loadfile", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "replace")
        end)
    elseif step == 2 then
        step = 3
        mp.msg.info("[CHALLENGE-RESULT] Step 2 loaded. Waiting 3s to verify YouTube playback...")
        mp.add_timeout(3.0, function()
            local time_pos = mp.get_property_number("playback-time", -1)
            dump_headers("YOUTUBE-VERIFY")
            mp.msg.info(string.format("[CHALLENGE-RESULT] YouTube final playback-time: %.2f", time_pos))
            mp.msg.info("[CHALLENGE-RESULT] Transition test complete. Quitting with code 0.")
            mp.commandv("quit", "0")
        end)
    end
end)

mp.add_timeout(20.0, function()
    mp.msg.warn("[CHALLENGE-RESULT] TIMEOUT reached.")
    mp.commandv("quit", "1")
end)
