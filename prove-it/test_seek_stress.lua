local mp = require 'mp'

local seeks = { 30, 60, -45, 15, -20, 10 }
local seek_idx = 1
local initial_playback_verified = false

mp.msg.info("[SEEK-STRESS] Script loaded, waiting for playback to start...")

mp.observe_property("playback-time", "number", function(name, val)
    if val and val > 1.5 and not initial_playback_verified then
        initial_playback_verified = true
        mp.msg.info(string.format("[SEEK-STRESS] Playback verified at %.2fs. Initiating seek barrage...", val))
        
        local function do_next_seek()
            if seek_idx <= #seeks then
                local offset = seeks[seek_idx]
                seek_idx = seek_idx + 1
                local cur_time = mp.get_property_number("playback-time", 0)
                mp.msg.info(string.format("[SEEK-STRESS] [%d/%d] Executing seek: %+ds (current time: %.2fs)", seek_idx - 1, #seeks, offset, cur_time))
                mp.commandv("seek", offset, "relative", "exact")
                mp.add_timeout(0.6, do_next_seek)
            else
                mp.msg.info("[SEEK-STRESS] Seek barrage complete. Waiting 3.5s to verify playback stabilization...")
                local pre_check_time = mp.get_property_number("playback-time", 0)
                mp.add_timeout(3.5, function()
                    local post_check_time = mp.get_property_number("playback-time", 0)
                    local paused = mp.get_property_bool("pause", false)
                    local eof = mp.get_property_bool("eof-reached", false)
                    local core_idle = mp.get_property_bool("core-idle", false)
                    mp.msg.info(string.format("[SEEK-STRESS] Post-barrage check: pre=%.2fs, post=%.2fs, delta=%.2fs, paused=%s, eof=%s, idle=%s",
                        pre_check_time, post_check_time, post_check_time - pre_check_time, tostring(paused), tostring(eof), tostring(core_idle)))
                    
                    if post_check_time > pre_check_time and not core_idle then
                        mp.msg.info("[SEEK-STRESS] SUCCESS: Video continues smooth playback after stress seeks!")
                        mp.commandv("quit", "0")
                    else
                        mp.msg.warn("[SEEK-STRESS] FAILURE: Video stalled or did not advance after seeks!")
                        mp.commandv("quit", "2")
                    end
                end)
            end
        end
        
        do_next_seek()
    end
end)

mp.add_timeout(35.0, function()
    mp.msg.warn("[SEEK-STRESS] TIMEOUT: Seek stress test exceeded 35s limit.")
    mp.commandv("quit", "1")
end)
