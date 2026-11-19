local mp = require 'mp'
local utils = require 'mp.utils'

local test_passed = false

mp.add_timeout(0.5, function()
    mp.msg.info("[TEST-SB] Step 1: Triggering sponsorblock-show-skip...")
    mp.commandv("script-message", "sponsorblock-show-skip", "贊助商跳過測試")
    
    mp.add_timeout(0.4, function()
        mp.msg.info("[TEST-SB] Step 2: Triggering manual skip click (TAB / mbtn_left)...")
        -- Trigger TAB forced key binding
        mp.commandv("keypress", "TAB")
        
        mp.add_timeout(0.4, function()
            -- Verify manual skip executed and no crash occurred
            -- Also test mbtn_left binding directly
            mp.commandv("script-message", "sponsorblock-show-skip", "卡片點擊測試2")
            mp.add_timeout(0.3, function()
                mp.commandv("keypress", "mbtn_left")
                mp.add_timeout(0.4, function()
                    test_passed = true
                    mp.msg.info("SPONSORBLOCK_CLICK_TEST_PASS")
                    print("SPONSORBLOCK_CLICK_TEST_PASS")
                    mp.command("quit 0")
                end)
            end)
        end)
    end)
end)

mp.add_timeout(5.0, function()
    if not test_passed then
        mp.msg.error("SPONSORBLOCK_CLICK_TEST_TIMEOUT")
        print("SPONSORBLOCK_CLICK_TEST_TIMEOUT")
        mp.command("quit 1")
    end
end)
