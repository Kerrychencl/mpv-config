local mp = require 'mp'
local utils = require 'mp.utils'

local sb_path = "portable_config/scripts/sponsorblock.lua"
local f = io.open(sb_path, "r")
if not f then
    sb_path = utils.join_path(mp.command_native({"expand-path", "~~/"}), "scripts/sponsorblock.lua")
    f = io.open(sb_path, "r")
end
if not f then
    sb_path = "D:/Media tool/mpv-x86_64-v3-20260610-git-304426c/portable_config/scripts/sponsorblock.lua"
    f = io.open(sb_path, "r")
end

if not f then
    mp.msg.error("Cannot find sponsorblock.lua")
    mp.command("quit 1")
    return
end

local content = f:read("*a")
f:close()

local chunk, err = loadstring(content .. "\nreturn extract_ids")
if not chunk then
    mp.msg.error("Failed to compile sponsorblock: " .. tostring(err))
    mp.command("quit 1")
    return
end

local extract_ids = chunk()

local mock_props = {}
mp.get_property = function(name)
    if mock_props[name] ~= nil then
        return mock_props[name]
    end
    return nil
end

-- Call 1: Bilibili video WITH cid
mock_props["path"] = "https://www.bilibili.com/video/BV1xx411c7mD?cid=12345678"
local bvid1, yt_id1, cid1 = extract_ids()
if bvid1 ~= "BV1xx411c7mD" or cid1 ~= "12345678" then
    mp.msg.error("Call 1 failed: bvid=" .. tostring(bvid1) .. ", cid=" .. tostring(cid1))
    mp.command("quit 1")
    return
end

-- Call 2: Bilibili video WITHOUT cid (test for stale cid pollution)
mock_props["path"] = "https://www.bilibili.com/video/BV1yy411c7mE"
local bvid2, yt_id2, cid2 = extract_ids()
if bvid2 ~= "BV1yy411c7mE" or cid2 ~= nil then
    mp.msg.error("Call 2 CID LEAK: cid2 was expected to be nil, got: " .. tostring(cid2))
    mp.command("quit 1")
    return
end

-- Call 3: YouTube video
mock_props["path"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
local bvid3, yt_id3, cid3 = extract_ids()
if yt_id3 ~= "dQw4w9WgXcQ" or bvid3 ~= nil or cid3 ~= nil then
    mp.msg.error("Call 3 failed: yt_id=" .. tostring(yt_id3) .. ", bvid=" .. tostring(bvid3) .. ", cid=" .. tostring(cid3))
    mp.command("quit 1")
    return
end

mp.msg.info("SPONSORBLOCK_CID_ISOLATION_PASS")
print("SPONSORBLOCK_CID_ISOLATION_PASS")
mp.command("quit 0")
