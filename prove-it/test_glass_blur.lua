local mp = require 'mp'
local utils = require 'mp.utils'

local test_passed = false

mp.add_timeout(1.0, function()
    -- Ensure OSC is visible so glass blur stays active
    mp.commandv("script-message", "osc-show")
    
    mp.add_timeout(0.5, function()
        local shaders = mp.get_property_native("glsl-shaders") or {}
        local has_glass = false
        for _, s in ipairs(shaders) do
            if s:find("modernz%-glass%.glsl") then has_glass = true end
        end
        mp.msg.info(string.format("[GLASS-TEST] Initial shaders count: %d, has_glass: %s", #shaders, tostring(has_glass)))

        -- Step 2: Trigger Ctrl+1 (Anime4K Mode A)
        mp.msg.info("[GLASS-TEST] Pressing Ctrl+1...")
        mp.commandv("keypress", "Ctrl+1")
        
        mp.add_timeout(0.5, function()
            local shaders_after_c1 = mp.get_property_native("glsl-shaders") or {}
            mp.msg.info(string.format("[GLASS-TEST] After Ctrl+1: %d shaders", #shaders_after_c1))
            
            -- Step 3: Trigger Ctrl+0 (Clear all shaders)
            mp.msg.info("[GLASS-TEST] Pressing Ctrl+0...")
            mp.commandv("keypress", "Ctrl+0")
            
            -- Keep OSC visible so on_resume re-attaches
            mp.commandv("script-message", "osc-show")
            
            mp.add_timeout(0.8, function()
                local shaders_after_c0 = mp.get_property_native("glsl-shaders") or {}
                local glass_reattached = false
                for _, s in ipairs(shaders_after_c0) do
                    if s:find("modernz%-glass%.glsl") then glass_reattached = true end
                end
                mp.msg.info(string.format("[GLASS-TEST] After Ctrl+0: %d shaders, glass_reattached: %s", #shaders_after_c0, tostring(glass_reattached)))
                
                if glass_reattached then
                    test_passed = true
                    mp.msg.info("GLASS_BLUR_PERSISTENCE_PASS")
                    print("GLASS_BLUR_PERSISTENCE_PASS")
                    mp.command("quit 0")
                else
                    mp.msg.error("GLASS_BLUR_PERSISTENCE_FAIL")
                    print("GLASS_BLUR_PERSISTENCE_FAIL")
                    mp.command("quit 1")
                end
            end)
        end)
    end)
end)

mp.add_timeout(8.0, function()
    if not test_passed then
        mp.msg.error("GLASS_BLUR_TEST_TIMEOUT")
        print("GLASS_BLUR_TEST_TIMEOUT")
        mp.command("quit 1")
    end
end)
