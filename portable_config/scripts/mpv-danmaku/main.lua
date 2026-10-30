-- mpv-danmaku/main.lua
-- Bilibili & YouTube (B2Y) & 外部掛載 (XML/ASS) 彈幕載入主控制模組
-- 核心特性：
-- 1. 次字幕軌道（secondary-sid）獨立綁定：外掛 CC 字幕與彈幕同時顯示、獨立開關、互不衝突
-- 2. 外部彈幕全面支援：自動偵測同名彈幕 (.xml / .ass)、拖曳檔案掛載、剪貼簿掛載、即時接管外掛字幕
-- 3. 全局彈幕面板聯動：pakku 智能合併刷屏、字號縮放、不透明度、速度、顯示區域即時熱重載
-- 4. YouTube (B2Y) 自動智能匹配：在 YouTube 享受高畫質的同時，自動檢索並同步 B 站同名影片彈幕
-- 5. 支援時間軸校準與外部屏蔽詞整合

local mp = require 'mp'
local utils = require 'mp.utils'
local directory = mp.get_script_directory()

-- 輸出目錄改為系統暫存目錄，避免污染桌面或影片目錄
local out_directory = os.getenv("TEMP") or utils.join_path(os.getenv("USERPROFILE") or "", "AppData\\Local\\Temp")
local output_dir = out_directory

-- 前向宣告核心函式，確保全模組任意地方皆可互相呼叫，絕不因宣告順序導致 nil 錯誤
local convert_and_mount
local find_sibling_danmaku
local cycle_sibling_danmaku
local pick_external_danmaku
local load_external_danmaku
local setsub
local unloadsub
local load_danmaku_by_cid

-- 設定檔與屏蔽詞路徑 (位於 portable_config)
local config_dir = mp.command_native({"expand-path", "~~/"})
local settings_path = utils.join_path(config_dir, "danmaku_settings.json")
local filter_json = utils.join_path(config_dir, "danmaku_filters.json")
local filter_txt = utils.join_path(config_dir, "danmaku_filters.txt")

local function get_filter_path()
    local f = io.open(filter_json, "r")
    if f then
        f:close()
        return filter_json
    end
    return filter_txt
end

-- 尋找 yt-dlp 執行檔（優先使用 MPV 資料夾內的 yt-dlp.exe）
local mpv_root = mp.command_native({"expand-path", "~~/.."})
local local_ytdlp = utils.join_path(mpv_root, "yt-dlp.exe")
local ytdlp_cmd = "yt-dlp"
local f = io.open(local_ytdlp, "r")
if f then
    f:close()
    ytdlp_cmd = local_ytdlp
end

local py_path = utils.join_path(directory, "danmaku2ass.py")
local b2y_py = utils.join_path(directory, "b2y_search.py")
local cookie_path = "C:\\Users\\Administrator\\AppData\\Local\\Temp\\mpv_active_cookies.txt"

-- 彈幕狀態變數
local source_file = nil      -- 原始彈幕來源檔案 (XML 或 ASS)，保持純淨以供隨時重新轉換
local xmlfile = nil          -- 相容舊版變數
local assfile = nil          -- 轉換後的目標 ASS 檔案 (位於 TEMP)
local created_files = {}     -- 臨時生成檔案清單 (退出時自動清理)
local danmaku_track_id = nil -- MPV 中的次字幕軌道 ID
local is_loading = false
local is_converting = false
local is_file_active = false
local pending_setsub_msg = nil
local early_cid_loading = false

local function extract_bili_cid()
    local path = mp.get_property("path", "")
    local stream_path = mp.get_property("stream-open-filename", "")

    local url_cid = path:match("[?&]cid=(%d+)") or stream_path:match("[?&]cid=(%d+)")
    if url_cid and url_cid ~= "" then return url_cid end

    local upos_cid = stream_path:match("/upgcxcode/%d+/%d+/(%d+)/")
        or stream_path:match("/(%d+)[%-_][%w%-]+%.m4s")
        or stream_path:match("/(%d+)[%-_][%w%-]+%.mp4")
    if upos_cid and upos_cid ~= "" then return upos_cid end

    local ytdl_raw = mp.get_property("user-data/mpv/ytdl/json-subprocess-result")
    if ytdl_raw and ytdl_raw ~= "" then
        local res = utils.parse_json(ytdl_raw)
        if res and res.stdout then
            local data = utils.parse_json(res.stdout)
            if data then
                if data.subtitles and data.subtitles.danmaku then
                    for _, item in ipairs(data.subtitles.danmaku) do
                        if item.url then
                            local c = item.url:match("comment%.bilibili%.com/(%d+)%.xml")
                            if c then return c end
                        end
                    end
                end
                if data.formats then
                    for _, fmt in ipairs(data.formats) do
                        local u = fmt.url or ""
                        local c = u:match("/upgcxcode/%d+/%d+/(%d+)/")
                            or u:match("/(%d+)[%-_][%w%-]+%.m4s")
                        if c then return c end
                    end
                end
            end
        end
    end

    return nil
end

-- 路徑標準化 (Windows 反斜線小寫統一)
local function normalize_path(p)
    if not p then return "" end
    return p:gsub("[/\\]+", "\\"):lower()
end

local function is_internal_file(fn)
    if not fn or fn == "" then return true end
    if fn:find("^edl://") or fn:find("^memory://") or fn:find("^https?://") then return true end
    local norm = normalize_path(fn)
    if assfile and norm == normalize_path(assfile) then return true end
    if norm:match("_danmaku_active%.ass$") then return true end
    return false
end

local function file_exists(p)
    if not p or p == "" then return false end
    local info = utils.file_info(p)
    if info and info.is_file then return true end
    local ff = io.open(p, "r")
    if ff then
        ff:close()
        return true
    end
    return false
end

local function get_settings()
    local s = {
        enabled = true,
        display_area = 0.75,
        opacity = 0.80,
        fontsize_pct = 1.00,
        speed_seconds = 10.0,
        sync_speed = false,
        font = "SimHei",
        bold = 1,
        outline_type = "zhongmu",
        pakku = true
    }
    local sf = io.open(settings_path, "r")
    if sf then
        local raw = sf:read("*all")
        sf:close()
        local data = utils.parse_json(raw)
        if data then
            if data.enabled ~= nil then s.enabled = data.enabled end
            if data.display_area ~= nil then s.display_area = data.display_area end
            if data.opacity ~= nil then s.opacity = data.opacity end
            if data.fontsize_pct ~= nil then s.fontsize_pct = data.fontsize_pct end
            if data.speed_seconds ~= nil then s.speed_seconds = data.speed_seconds end
            if data.sync_speed ~= nil then s.sync_speed = data.sync_speed end
            if data.font ~= nil then s.font = data.font end
            if data.bold ~= nil then s.bold = data.bold and 1 or 0 end
            if data.outline_type ~= nil then s.outline_type = data.outline_type end
            if data.pakku ~= nil then s.pakku = data.pakku end
        end
    end
    return s
end

local function build_convert_args(in_p, ass_p)
    local s = get_settings()
    local effective_dm = s.speed_seconds
    if s.sync_speed then
        local cur_spd = mp.get_property_number("speed", 1.0)
        if cur_spd > 0 then effective_dm = effective_dm / cur_spd end
    end
    local protect_h = math.floor(1080 * (1 - s.display_area))
    local fs = math.floor(50 * s.fontsize_pct)

    local args = {
        'python', '-X', 'utf8', py_path,
        '-o', ass_p,
        '-s', '1920x1080',
        '-fs', tostring(fs),
        '-a', string.format("%.2f", s.opacity),
        '-dm', string.format("%.1f", effective_dm),
        '-p', tostring(protect_h),
        '-fn', s.font,
        '--bold', tostring(s.bold),
        '--outline-type', s.outline_type
    }
    if s.pakku then
        table.insert(args, '--pakku')
    else
        table.insert(args, '--no-pakku')
    end
    local fp = get_filter_path()
    local ff = io.open(fp, "r")
    if ff then
        ff:close()
        table.insert(args, '-flf')
        table.insert(args, fp)
    end
    table.insert(args, in_p)
    return args
end

-- 判斷 ASS 字幕是否為彈幕（依檔名關鍵字或前 100 行中是否包含 \move / Danmaku 標記）
local function is_ass_danmaku_file(filepath)
    if not filepath or filepath == "" or is_internal_file(filepath) then return false end
    local lower = filepath:lower()
    if lower:match("danmaku") or filepath:find("彈幕") or filepath:find("弹幕") or lower:match("comment") then
        return true
    end
    local ff = io.open(filepath, "r")
    if not ff then
        if lower:match("%.danmaku%.ass$") then return true end
        return false
    end
    local move_count = 0
    local line_count = 0
    for line in ff:lines() do
        line_count = line_count + 1
        if line:find("\\move%(") or line:find("Danmaku") or line:find("danmaku") or line:find("Niconvert") or line:find("R2L") then
            move_count = move_count + 1
            if move_count >= 2 then
                ff:close()
                return true
            end
        end
        if line_count > 100 then break end
    end
    ff:close()
    return false
end

-- 同目錄彈幕候選快取與輪播狀態
local sibling_danmakus = {}
local sibling_danmaku_index = 0

-- 掃描同目錄下所有彈幕候選檔案
local function get_directory_danmaku_files(dir)
    local results = {}
    if not dir or dir == "" then return results end
    local files, _ = utils.readdir(dir, "files")
    if not files then return results end

    for _, f in ipairs(files) do
        local lower = f:lower()
        if lower:match("%.xml$") or lower:match("%.danmaku%.ass$") or lower:match("%.d%-art%.xml$") or lower:match("%.bilibili%.xml$") then
            table.insert(results, utils.join_path(dir, f))
        elseif lower:match("%.ass$") then
            local full_p = utils.join_path(dir, f)
            if is_ass_danmaku_file(full_p) then
                table.insert(results, full_p)
            end
        end
    end
    table.sort(results)
    return results
end

-- 清理主檔名中常見的後綴（如 cmp, compressed, 1080p, (1) 等）以利智慧模糊比對
local function clean_stem_name(name)
    if not name then return "" end
    local s = name
    -- 移除壓制標記 (如 ' cmp', '_cmp', '-cmp', '.cmp')
    s = s:gsub("%s+[Cc][Mm][Pp]$", ""):gsub("_[Cc][Mm][Pp]$", ""):gsub("%-[Cc][Mm][Pp]$", ""):gsub("%.[Cc][Mm][Pp]$", "")
    -- 移除 compressed 標記
    s = s:gsub("%s*【[Cc][Oo][Mm][Pp][Rr][Ee][Ss][Ss][Ee][Dd]】", ""):gsub("%s*%[[Cc][Oo][Mm][Pp][Rr][Ee][Ss][Ss][Ee][Dd]%]", ""):gsub("_compressed$", "")
    -- 移除解析度標籤 (如 [1080p], 【720P】)
    s = s:gsub("%s*%[[0-9]+[pP]%]", ""):gsub("%s*【[0-9]+[pP]】", "")
    -- 移除尾隨括號編號 (如 (1), _1)
    s = s:gsub("%s*%([0-9]+%)$", ""):gsub("_[0-9]+$", "")
    return s
end

-- 本機影片播放時，智慧尋找同目錄下的同名或關聯 XML/ASS 彈幕檔案（支援精確、模糊匹配與單一彈幕回退）
find_sibling_danmaku = function(video_path)
    if not video_path or video_path == "" or video_path:match("^%a+://") then
        sibling_danmakus = {}
        sibling_danmaku_index = 0
        return nil
    end
    local dir, filename = utils.split_path(video_path)
    if not dir or not filename then return nil end
    local stem = filename:match("(.+)%..+$") or filename

    -- 1. 取得同目錄下所有彈幕檔案清單
    local dir_danmakus = get_directory_danmaku_files(dir)
    sibling_danmakus = dir_danmakus

    -- 2. 第一優先級：精確檔名匹配
    local exact_candidates = {
        utils.join_path(dir, stem .. ".xml"),
        utils.join_path(dir, stem .. ".danmaku.xml"),
        utils.join_path(dir, stem .. ".danmaku.ass"),
        utils.join_path(dir, stem .. ".bilibili.xml"),
        utils.join_path(dir, stem .. ".d-art.xml"),
        utils.join_path(dir, stem .. ".zh.xml"),
        utils.join_path(dir, stem .. ".sc.xml"),
        utils.join_path(dir, stem .. ".ass"),
        utils.join_path(dir, utils.join_path("danmaku", stem .. ".xml")),
        utils.join_path(dir, utils.join_path("danmaku", stem .. ".ass")),
    }

    for _, c in ipairs(exact_candidates) do
        if file_exists(c) then
            if c:lower():match("%.ass$") then
                if is_ass_danmaku_file(c) then
                    for idx, df in ipairs(sibling_danmakus) do
                        if normalize_path(df) == normalize_path(c) then sibling_danmaku_index = idx break end
                    end
                    return c
                end
            else
                for idx, df in ipairs(sibling_danmakus) do
                    if normalize_path(df) == normalize_path(c) then sibling_danmaku_index = idx break end
                end
                return c
            end
        end
    end

    -- 3. 第二優先級：智慧清理後綴（如 cmp, compressed）模糊比對
    local clean_stem = clean_stem_name(stem)
    if clean_stem ~= stem and clean_stem ~= "" then
        local fuzzy_candidates = {
            utils.join_path(dir, clean_stem .. ".xml"),
            utils.join_path(dir, clean_stem .. ".danmaku.xml"),
            utils.join_path(dir, clean_stem .. ".danmaku.ass"),
            utils.join_path(dir, clean_stem .. ".bilibili.xml"),
            utils.join_path(dir, clean_stem .. ".d-art.xml"),
            utils.join_path(dir, clean_stem .. ".ass"),
        }
        for _, c in ipairs(fuzzy_candidates) do
            if file_exists(c) then
                for idx, df in ipairs(sibling_danmakus) do
                    if normalize_path(df) == normalize_path(c) then sibling_danmaku_index = idx break end
                end
                return c
            end
        end
    end

    -- 4. 第三優先級：在同目錄彈幕列表中比對前綴或包含關係
    for idx, c in ipairs(sibling_danmakus) do
        local _, c_fn = utils.split_path(c)
        local c_stem = c_fn:match("(.+)%..+$") or c_fn
        local clean_c_stem = clean_stem_name(c_stem)
        if stem:find(c_stem, 1, true) or c_stem:find(stem, 1, true) or
           (clean_stem ~= "" and (clean_stem:find(clean_c_stem, 1, true) or clean_c_stem:find(clean_stem, 1, true))) then
            sibling_danmaku_index = idx
            return c
        end
    end

    -- 5. 第四優先級：若目錄下僅有唯一一個彈幕檔案，安全回退匹配
    if #sibling_danmakus == 1 then
        sibling_danmaku_index = 1
        return sibling_danmakus[1]
    end

    return nil
end

-- 快速輪播切換同目錄下的彈幕檔案
cycle_sibling_danmaku = function()
    local cur_path = mp.get_property("path") or ""
    if not cur_path or cur_path == "" or cur_path:match("^%a+://") then
        mp.osd_message("[彈幕] 目前播放非本機影片，無法切換同目錄彈幕", 2.0)
        return
    end

    local dir, _ = utils.split_path(cur_path)
    if not dir then
        mp.osd_message("[彈幕] 無法獲取當前影片目錄", 2.0)
        return
    end

    sibling_danmakus = get_directory_danmaku_files(dir)
    if not sibling_danmakus or #sibling_danmakus == 0 then
        mp.osd_message("[彈幕] 同目錄下未發現其他 XML/ASS 彈幕檔案", 2.0)
        return
    end

    if #sibling_danmakus == 1 then
        local _, fn = utils.split_path(sibling_danmakus[1])
        mp.osd_message(string.format("[彈幕] 同目錄下僅有此彈幕檔案:\n%s", fn), 2.5)
        return
    end

    local cur_idx = sibling_danmaku_index
    if source_file then
        local norm_src = normalize_path(source_file)
        for i, df in ipairs(sibling_danmakus) do
            if normalize_path(df) == norm_src then
                cur_idx = i
                break
            end
        end
    end

    sibling_danmaku_index = (cur_idx % #sibling_danmakus) + 1
    local target = sibling_danmakus[sibling_danmaku_index]
    local _, fn = utils.split_path(target)
    convert_and_mount(target, "sibling", string.format("[彈幕] 已切換同目錄彈幕 (%d/%d):\n%s", sibling_danmaku_index, #sibling_danmakus, fn))
end

-- 將彈幕掛載至次字幕軌（secondary-sid），確保外掛 CC 字幕（sid）絕不被頂替
function setsub(custom_msg)
    if not assfile then return end

    if not is_file_active then
        pending_setsub_msg = custom_msg or true
        return
    end

    local prev_sid = mp.get_property("sid")

    mp.commandv("sub-add", assfile, "auto")

    mp.add_timeout(0.1, function()
        local tracks = mp.get_property_native("track-list") or {}
        local target_id = nil
        local norm_ass = normalize_path(assfile)

        for _, t in ipairs(tracks) do
            if t.type == "sub" and normalize_path(t["external-filename"]) == norm_ass then
                target_id = t.id
                break
            end
        end

        if not target_id then
            for _, t in ipairs(tracks) do
                if t.type == "sub" and t["external-filename"] and normalize_path(t["external-filename"]):match("_danmaku_active%.ass$") then
                    target_id = t.id
                    break
                end
            end
        end

        if target_id then
            danmaku_track_id = tostring(target_id)
            mp.set_property("secondary-sid", danmaku_track_id)
            mp.set_property_native("user-data/danmaku/present", true)
            local s = get_settings()
            mp.set_property("secondary-sub-visibility", s.enabled and "yes" or "no")

            if mp.get_property("sid") == danmaku_track_id then
                if prev_sid and prev_sid ~= "no" and prev_sid ~= danmaku_track_id then
                    mp.set_property("sid", prev_sid)
                else
                    mp.set_property("sid", "no")
                end
            end

            -- 清理由 yt-dlp 自動帶入的未渲染 raw XML 彈幕軌道，保持字幕選單清爽
            for _, t in ipairs(tracks) do
                if t.type == "sub" and tostring(t.id) ~= danmaku_track_id then
                    if (t.lang == "danmaku" or (t.title and t.title:lower() == "danmaku")) and t.external then
                        mp.commandv("sub-remove", t.id)
                    end
                end
            end
        end

        if custom_msg then
            mp.osd_message(custom_msg, 2.5)
        else
            mp.osd_message("彈幕載入完成 (按 b 開關彈幕 ｜ 按 d 開啟彈幕設定 ｜ 按 Alt+y 開啟 B2Y 面板)", 2.5)
        end
    end)
end

-- 通用轉換並掛載彈幕函式
convert_and_mount = function(in_path, source_tag, custom_msg, callback)
    if not in_path or in_path == "" then return end
    if assfile and normalize_path(in_path) == normalize_path(assfile) then return end
    if in_path:match("_danmaku_active%.ass$") then return end
    if is_converting then return end
    is_converting = true

    source_file = in_path
    xmlfile = in_path
    local dir, filename = utils.split_path(in_path)
    local stem = filename:match("(.+)%..+$") or filename
    stem = stem:gsub("_danmaku_active$", ""):gsub("[^%w_%-]", "_")
    assfile = utils.join_path(out_directory, stem .. "_danmaku_active.ass"):gsub("/", "\\")
    created_files[normalize_path(assfile)] = true
    created_files[assfile] = true

    mp.osd_message("[彈幕] 正在載入並解析彈幕...", 1.5)

    local convert = build_convert_args(source_file, assfile)
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = convert
    }, function(success, result, error)
        is_converting = false
        if result and result.status == 0 then
            local s = get_settings()
            local pakku_str = s.pakku and "Pakku智能合併: 開啟" or "Pakku智能合併: 關閉"
            local msg = custom_msg or string.format("[彈幕] 外部彈幕載入完成！\n(%s ｜ 字號: %d%% ｜ 區域: %d%%)",
                pakku_str,
                math.floor(s.fontsize_pct * 100),
                math.floor(s.display_area * 100)
            )

            if danmaku_track_id then
                mp.commandv("sub-remove", danmaku_track_id)
                danmaku_track_id = nil
            end

            setsub(msg)
            mp.set_property_native("user-data/b2y/info", {
                status = "external",
                title = filename,
                source_file = source_file,
                candidates = {}
            })
            if callback then callback(true) end
        else
            mp.osd_message("[彈幕] 外部彈幕轉換失敗，請確認檔案格式是否正確", 3.0)
            if callback then callback(false) end
        end
    end)
end

-- 根據最新面板設置（pakku 合併開關、字號、速度、區域、透明度等）動態重新生成並熱替換彈幕
function reconvert_danmaku()
    if is_converting then return end

    -- 若當前沒有記憶 source_file，嘗試從目前播放的字幕軌中接管外部字幕
    if not source_file then
        local tracks = mp.get_property_native("track-list") or {}
        local sec_id = mp.get_property("secondary-sid")
        local pri_id = mp.get_property("sid")

        for _, t in ipairs(tracks) do
            if t.type == "sub" and t.external and t["external-filename"] then
                local fn = t["external-filename"]
                if not is_internal_file(fn) then
                    if tostring(t.id) == tostring(sec_id) then
                        source_file = fn
                        break
                    end
                end
            end
        end

        if not source_file then
            for _, t in ipairs(tracks) do
                if t.type == "sub" and t.external and t["external-filename"] then
                    local fn = t["external-filename"]
                    if not is_internal_file(fn) then
                        if tostring(t.id) == tostring(pri_id) then
                            source_file = fn
                            break
                        end
                    end
                end
            end
        end
    end

    if not source_file then
        mp.osd_message("[彈幕] 未載入任何彈幕檔案，無法轉換", 2.0)
        return
    end

    if not assfile then
        local _, filename = utils.split_path(source_file)
        local stem = filename:match("(.+)%..+$") or filename
        stem = stem:gsub("_danmaku_active$", ""):gsub("[^%w_%-]", "_")
        assfile = utils.join_path(out_directory, stem .. "_danmaku_active.ass"):gsub("/", "\\")
        created_files[normalize_path(assfile)] = true
        created_files[assfile] = true
    end

    is_converting = true
    local convert = build_convert_args(source_file, assfile)
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = convert
    }, function(success, result, error)
        is_converting = false
        if result and result.status == 0 then
            local prev_sid = mp.get_property("sid")
            local cur_sec_vis = mp.get_property_bool("secondary-sub-visibility", true)

            if danmaku_track_id then
                mp.commandv("sub-remove", danmaku_track_id)
                danmaku_track_id = nil
            end

            mp.commandv("sub-add", assfile, "auto")

            mp.add_timeout(0.08, function()
                local tracks = mp.get_property_native("track-list") or {}
                local target_id = nil
                local norm_ass = normalize_path(assfile)

                for _, t in ipairs(tracks) do
                    if t.type == "sub" and normalize_path(t["external-filename"]) == norm_ass then
                        target_id = t.id
                        break
                    end
                end
                if not target_id then
                    for _, t in ipairs(tracks) do
                        if t.type == "sub" and t["external-filename"] and normalize_path(t["external-filename"]):match("_danmaku_active%.ass$") then
                            target_id = t.id
                            break
                        end
                    end
                end
                if target_id then
                    danmaku_track_id = tostring(target_id)
                    mp.set_property("secondary-sid", danmaku_track_id)
                    mp.set_property_native("user-data/danmaku/present", true)
                    mp.set_property_bool("secondary-sub-visibility", cur_sec_vis)
                    if mp.get_property("sid") == danmaku_track_id then
                        if prev_sid and prev_sid ~= "no" and prev_sid ~= danmaku_track_id then
                            mp.set_property("sid", prev_sid)
                        else
                            mp.set_property("sid", "no")
                        end
                    end
                end
                local s = get_settings()
                mp.osd_message(string.format("[彈幕] 彈幕已重新轉換 (Pakku: %s ｜ 字號: %d%% ｜ 區域: %d%%)",
                    s.pakku and "開啟" or "關閉",
                    math.floor(s.fontsize_pct * 100),
                    math.floor(s.display_area * 100)
                ), 2.0)
            end)
        else
            mp.osd_message("[彈幕] 重新轉換失敗", 2.0)
        end
    end)
end

mp.register_script_message("danmaku-reconvert", reconvert_danmaku)

local function findxml(vid, callback)
    local find_cmd = { 'python', '-X', 'utf8', '-c', [==[
import sys, glob, os
d = sys.argv[1]
vid = sys.argv[2] if len(sys.argv) > 2 else ''
fs = [f for f in glob.glob(os.path.join(d, '*.xml')) if os.path.isfile(f)]
matching = [f for f in fs if vid and vid.lower() in f.lower()]
target = matching if matching else fs
print(max(target, key=os.path.getmtime) if target else '')
]==], directory, vid or "" }

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = find_cmd
    }, function(success, result, error)
        local path = nil
        if success and result.status == 0 and result.stdout then
            path = result.stdout:gsub("%s+$", "")
            if path == "" then path = nil end
        end
        callback(path)
    end)
end

local function handle_downloaded(vid)
    findxml(vid, function(path)
        if not path then return end
        source_file = path
        xmlfile = path
        local _, filename = utils.split_path(path)
        local stem = filename:match("(.+)%..+$") or filename
        stem = stem:gsub("[^%w_%-]", "_")
        assfile = utils.join_path(out_directory, stem .. ".ass"):gsub("/", "\\")
        created_files[normalize_path(source_file)] = true
        created_files[normalize_path(assfile)] = true
        local convert = build_convert_args(source_file, assfile)
        mp.command_native_async({
            name = 'subprocess',
            playback_only = false,
            capture_stdout = true,
            args = convert
        }, function(success, result, error)
            if result and result.status == 0 then
                setsub()
            end
        end)
    end)
end

-- ==================== Bilibili CID 彈幕直接載入 (相容 External Player 油猴插件) ====================
function load_danmaku_by_cid(cid, callback)
    if not cid or cid == "" then return end
    if is_loading or is_converting then return end

    local safe_cid = tostring(cid):match("%d+")
    if not safe_cid then return end

    local cached_xml = utils.join_path(out_directory, "bilibili_cid_" .. safe_cid .. ".xml"):gsub("/", "\\")
    local target_ass = utils.join_path(out_directory, "bilibili_cid_" .. safe_cid .. "_danmaku_active.ass"):gsub("/", "\\")

    -- 如果 TEMP 中已有下載過的快取 XML，直接快速轉換並掛載
    if file_exists(cached_xml) then
        convert_and_mount(cached_xml, "cid", string.format("[彈幕] 已載入 B 站快取彈幕 (CID: %s)", safe_cid), callback)
        mp.set_property_native("user-data/b2y/info", {
            status = "bilibili_cid",
            cid = safe_cid,
            title = mp.get_property("media-title") or ("CID: " .. safe_cid),
            candidates = {}
        })
        return
    end

    is_loading = true
    mp.osd_message(string.format("[彈幕] 正在獲取 B 站彈幕 (CID: %s)...", safe_cid), 2.5)

    local s = get_settings()
    local effective_dm = s.speed_seconds
    if s.sync_speed then
        local cur_spd = mp.get_property_number("speed", 1.0)
        if cur_spd > 0 then effective_dm = effective_dm / cur_spd end
    end
    local protect_h = math.floor(1080 * (1 - s.display_area))
    local fs = math.floor(50 * s.fontsize_pct)

    local args = {
        'python', '-X', 'utf8', py_path,
        '--cid', safe_cid,
        '--save-xml', cached_xml,
        '-o', target_ass,
        '-s', '1920x1080',
        '-fs', tostring(fs),
        '-a', string.format("%.2f", s.opacity),
        '-dm', string.format("%.1f", effective_dm),
        '-p', tostring(protect_h),
        '-fn', s.font,
        '--bold', tostring(s.bold),
        '--outline-type', s.outline_type
    }
    if s.pakku then
        table.insert(args, '--pakku')
    else
        table.insert(args, '--no-pakku')
    end

    local fp = get_filter_path()
    local ff = io.open(fp, "r")
    if ff then
        ff:close()
        table.insert(args, '-flf')
        table.insert(args, fp)
    end

    local fc = io.open(cookie_path, "r")
    if fc then
        fc:close()
        table.insert(args, '--cookies')
        table.insert(args, cookie_path)
    end

    created_files[normalize_path(cached_xml)] = true
    created_files[normalize_path(target_ass)] = true

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }, function(success, result, error)
        is_loading = false
        if result and result.status == 0 and file_exists(target_ass) then
            source_file = cached_xml
            xmlfile = cached_xml
            assfile = target_ass

            if danmaku_track_id then
                mp.commandv("sub-remove", danmaku_track_id)
                danmaku_track_id = nil
            end

            local pakku_str = s.pakku and "Pakku智能合併: 開啟" or "Pakku智能合併: 關閉"
            local msg = string.format("[彈幕] B 站彈幕載入完成 (CID: %s)！\n(%s ｜ 字號: %d%% ｜ 區域: %d%%)",
                safe_cid,
                pakku_str,
                math.floor(s.fontsize_pct * 100),
                math.floor(s.display_area * 100)
            )
            setsub(msg)
            mp.set_property_native("user-data/b2y/info", {
                status = "bilibili_cid",
                cid = safe_cid,
                title = mp.get_property("media-title") or ("CID: " .. safe_cid),
                candidates = {}
            })
        else
            mp.msg.warn(string.format("[mpv-danmaku] 透過 CID: %s 線上下載彈幕失敗，自動啟動備援解析", safe_cid))
            local path = mp.get_property("path") or ""
            if path:find("bilibili%.com") or path:find("b23%.tv") then
                load_bilibili_danmaku(path)
            else
                mp.osd_message(string.format("[彈幕] 獲取 B 站彈幕失敗 (CID: %s)", safe_cid), 3.0)
            end
            if callback then callback(false) end
        end
    end)
end

-- ==================== Bilibili 原生影片彈幕載入 ====================
function load_bilibili_danmaku(biliurl)
    if is_loading then return end
    is_loading = true

    local vid = biliurl:match("([Bb][Vv][%w]+)") or biliurl:match("([Aa][Vv]%d+)") or ""

    local download = { ytdlp_cmd }
    local fc = io.open(cookie_path, "r")
    if fc then
        fc:close()
        table.insert(download, "--cookies")
        table.insert(download, cookie_path)
    end
    table.insert(download, biliurl)
    table.insert(download, '--skip-download')
    table.insert(download, '--write-subs')
    table.insert(download, '--retries')
    table.insert(download, '3')
    table.insert(download, '--paths')
    table.insert(download, directory)

    mp.osd_message("正在獲取 B 站彈幕...", 2.0)
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = download
    }, function(success, result, error)
        is_loading = false
        if result and result.status == 0 then
            handle_downloaded(vid)
            mp.set_property_native("user-data/b2y/info", {
                status = "bilibili_native",
                bvid = vid,
                title = mp.get_property("media-title") or vid,
                candidates = {}
            })
        end
    end)
end

-- ==================== YouTube (B2Y) 跨平台彈幕接入 ====================
function trigger_b2y(override_bvid, check_clipboard, custom_query)
    if is_loading then return end
    is_loading = true

    local title = custom_query or mp.get_property("media-title") or ""
    local dur = mp.get_property_number("duration", 0)

    local target_bvid = override_bvid
    if (not target_bvid or target_bvid == "") and check_clipboard then
        local clip = mp.get_property("clipboard/text") or ""
        local m = clip:match("([Bb][Vv][%w]+)") or clip:match("([Aa][Vv]%d+)")
        if m then
            target_bvid = m
            mp.osd_message("[B2Y] 偵測到剪貼簿 B 站序號: " .. target_bvid .. "\n正在獲取彈幕...", 2.5)
        end
    end

    if not target_bvid and (title == "" or title:match("^https?://")) then
        is_loading = false
        return
    end

    mp.osd_message("[B2Y] 正在檢索並匹配 B 站彈幕...", 2.0)

    local args = {
        'python', '-X', 'utf8', b2y_py,
        '--title', title,
        '--duration', tostring(math.floor(dur)),
        '--work-dir', directory,
        '--ytdlp', ytdlp_cmd
    }
    if target_bvid and target_bvid ~= "" then
        table.insert(args, '--bvid')
        table.insert(args, target_bvid)
    end
    local fc = io.open(cookie_path, "r")
    if fc then
        fc:close()
        table.insert(args, '--cookies')
        table.insert(args, cookie_path)
    end

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = args
    }, function(success, result, error)
        is_loading = false
        if success and result and result.status == 0 and result.stdout then
            local res_data = utils.parse_json(result.stdout)
            if res_data and res_data.status == "ok" and res_data.xml_path then
                source_file = res_data.xml_path
                xmlfile = source_file
                local _, filename = utils.split_path(source_file)
                local stem = filename:match("(.+)%..+$") or filename
                stem = stem:gsub("[^%w_%-]", "_")
                assfile = utils.join_path(out_directory, stem .. ".ass"):gsub("/", "\\")
                created_files[normalize_path(source_file)] = true
                created_files[normalize_path(assfile)] = true

                local b2y_info = {
                    status = "ok",
                    yt_title = mp.get_property("media-title") or "",
                    yt_duration = dur,
                    bvid = res_data.bvid or target_bvid or "",
                    title = res_data.title or res_data.bvid or "",
                    author = res_data.author or "",
                    danmaku = res_data.danmaku or 0,
                    duration = res_data.duration or "",
                    candidates = res_data.candidates or {}
                }
                mp.set_property_native("user-data/b2y/info", b2y_info)

                if res_data.bvid then
                    mp.commandv("script-message", "sponsorblock-load-bvid", res_data.bvid)
                end

                local convert = build_convert_args(source_file, assfile)
                mp.command_native_async({
                    name = 'subprocess',
                    playback_only = false,
                    capture_stdout = true,
                    args = convert
                }, function(conv_ok, conv_res, conv_err)
                    if conv_ok and conv_res and conv_res.status == 0 then
                        setsub()
                        local msg_t = res_data.title or ""
                        if #msg_t > 30 then msg_t = msg_t:sub(1, 30) .. "..." end
                        mp.osd_message(string.format("[B2Y] 成功匹配 B 站彈幕！\n%s\n(%s | %d 條彈幕)", msg_t, res_data.bvid or "", res_data.danmaku or 0), 3.5)
                    else
                        mp.osd_message("[B2Y] 彈幕轉換 ASS 失敗", 2.0)
                    end
                end)
            else
                local msg = (res_data and res_data.message) or "未在 B 站搜尋到相符彈幕"
                mp.osd_message("[B2Y] " .. msg .. " (可按 Alt+y 開啟面板手動匹配)", 3.0)
                mp.set_property_native("user-data/b2y/info", {
                    status = "not_found",
                    yt_title = mp.get_property("media-title") or "",
                    yt_duration = dur,
                    message = msg,
                    candidates = (res_data and res_data.candidates) or {}
                })
            end
        else
            mp.osd_message("[B2Y] 彈幕匹配逾時或失敗", 2.5)
        end
    end)
end

-- 純搜尋候選影片（供可視化面板點選【搜尋】時使用）
local function search_candidates_only(keyword)
    if is_loading then return end
    is_loading = true

    local dur = mp.get_property_number("duration", 0)
    local args = {
        'python', '-X', 'utf8', b2y_py,
        '--title', keyword,
        '--duration', tostring(math.floor(dur)),
        '--work-dir', directory,
        '--ytdlp', ytdlp_cmd,
        '--search-only'
    }
    local fc = io.open(cookie_path, "r")
    if fc then
        fc:close()
        table.insert(args, '--cookies')
        table.insert(args, cookie_path)
    end

    mp.osd_message("[B2Y] 正在搜尋 B 站候選影片...", 2.0)
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = args
    }, function(success, result, error)
        is_loading = false
        if success and result and result.status == 0 and result.stdout then
            local res_data = utils.parse_json(result.stdout)
            if res_data and res_data.candidates then
                local cur_info = mp.get_property_native("user-data/b2y/info") or {}
                cur_info.candidates = res_data.candidates
                cur_info.search_query = res_data.query or keyword
                mp.set_property_native("user-data/b2y/info", cur_info)
                mp.osd_message(string.format("[B2Y] 找到 %d 個相關 B 站影片", #res_data.candidates), 2.5)
            end
        end
    end)
end

local pick_py = utils.join_path(directory, "pick_file.py")

-- 開啟原生 Windows 檔案瀏覽器對話框，任意選取外部彈幕或字幕檔案
pick_external_danmaku = function()
    local cur_path = mp.get_property("path") or ""
    local init_arg = ""
    if cur_path ~= "" and not cur_path:match("^%a+://") then
        local dir, _ = utils.split_path(cur_path)
        init_arg = dir or ""
    end

    local tmp_out = utils.join_path(out_directory, "picked_danmaku_" .. os.time() .. ".txt")
    mp.osd_message("[彈幕] 請在開啟的視窗中選取外部彈幕/字幕檔案...", 3.0)

    local sanitized_dir = init_arg:gsub('\\+$', ''):gsub('/+$', '')
    local args = {
        'python', '-X', 'utf8', pick_py,
        '--dir', sanitized_dir,
        '--out', tmp_out
    }

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }, function(success, result, error)
        local chosen = nil
        local f = io.open(tmp_out, "rb")
        if f then
            chosen = f:read("*a")
            f:close()
            os.remove(tmp_out)
        end

        if not chosen or chosen == "" then
            if success and result and result.stdout then
                chosen = result.stdout
            end
        end

        if chosen then
            chosen = chosen:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^"', ''):gsub('"$', '')
        end

        if chosen and chosen ~= "" and file_exists(chosen) then
            local lower = chosen:lower()
            local _, fn = utils.split_path(chosen)
            if lower:match("%.xml$") or lower:match("%.json$") or lower:match("%.ass$") then
                convert_and_mount(chosen, "picked_file", string.format("[彈幕] 成功載入外部彈幕:\n%s", fn or chosen))
            else
                mp.commandv("sub-add", chosen, "select")
                mp.osd_message(string.format("[字幕] 已成功掛載字幕:\n%s", fn or chosen), 3.0)
            end
        else
            mp.osd_message("[彈幕] 已取消選取外部檔案", 1.5)
        end
    end)
end

-- 外部彈幕手動載入 (支援剪貼簿路徑、BV號、接管當前字幕，或開啟選取視窗)
load_external_danmaku = function()
    local clip = mp.get_property("clipboard/text") or ""
    clip = clip:gsub('^"', ''):gsub('"$', ''):gsub("^'", ""):gsub("'$", ""):gsub("%s+$", ""):gsub("^%s+", "")

    local lower_clip = clip:lower()
    if (lower_clip:match("%.xml$") or lower_clip:match("%.ass$")) and file_exists(clip) then
        convert_and_mount(clip, "clipboard", "[彈幕] 已從剪貼簿路徑載入外部彈幕！")
        return
    end

    local m = clip:match("([Bb][Vv][%w]+)") or clip:match("([Aa][Vv]%d+)")
    if m then
        load_bilibili_danmaku("https://www.bilibili.com/video/" .. m)
        return
    end

    local tracks = mp.get_property_native("track-list") or {}
    local sec_id = mp.get_property("secondary-sid")
    local pri_id = mp.get_property("sid")
    local candidate_track = nil

    for _, t in ipairs(tracks) do
        if t.type == "sub" and t.external and t["external-filename"] then
            local fn = t["external-filename"]
            if not is_internal_file(fn) then
                if tostring(t.id) == tostring(sec_id) then
                    candidate_track = fn
                    break
                elseif tostring(t.id) == tostring(pri_id) and not candidate_track then
                    candidate_track = fn
                end
            end
        end
    end

    if candidate_track then
        convert_and_mount(candidate_track, "active_track", "[彈幕] 已將當前外掛字幕接管為彈幕控制！")
        return
    end

    -- 若無剪貼簿路徑或外掛軌道，開啟檔案瀏覽器讓使用者任意選取
    pick_external_danmaku()
end

local function convert_active_sub()
    local tracks = mp.get_property_native("track-list") or {}
    local sec_id = mp.get_property("secondary-sid")
    local pri_id = mp.get_property("sid")
    local target_fn = nil

    for _, t in ipairs(tracks) do
        if t.type == "sub" and t.external and t["external-filename"] then
            local fn = t["external-filename"]
            if not is_internal_file(fn) then
                if tostring(t.id) == tostring(sec_id) then
                    target_fn = fn
                    break
                elseif tostring(t.id) == tostring(pri_id) and not target_fn then
                    target_fn = fn
                end
            end
        end
    end

    if target_fn then
        convert_and_mount(target_fn, "active_track", "[彈幕] 已將當前外掛字幕接管為彈幕控制！")
    else
        mp.osd_message("[彈幕] 當前無外掛字幕可接管為彈幕", 2.0)
    end
end

-- 監聽字幕軌道變動：攔截使用者拖入的 XML 或 ASS 彈幕，防止 MPV 解析失敗並自動轉換套用 pakku
local function on_track_list_changed(_, tracks)
    if not tracks or is_converting then return end

    for _, t in ipairs(tracks) do
        if t.type == "sub" and t.external and t["external-filename"] then
            local fn = t["external-filename"]
            if not is_internal_file(fn) and file_exists(fn) then
                local lower = fn:lower()
                if lower:match("%.xml$") then
                    mp.commandv("sub-remove", t.id)
                    convert_and_mount(fn, "drag_drop_xml", "[彈幕] 已載入並轉換外部 XML 彈幕！")
                    break
                elseif lower:match("%.ass$") and is_ass_danmaku_file(fn) then
                    mp.commandv("sub-remove", t.id)
                    convert_and_mount(fn, "drag_drop_ass", "[彈幕] 已接管外部 ASS 彈幕 (Pakku智能合併已套用)")
                    break
                end
            end
        end
    end
end

-- 當影片正式載入並取得媒體資訊時觸發
function on_file_loaded()
    is_file_active = true

    if pending_setsub_msg and assfile and file_exists(assfile) then
        local pmsg = (type(pending_setsub_msg) == "string") and pending_setsub_msg or nil
        pending_setsub_msg = nil
        setsub(pmsg)
        return
    end

    if is_loading or is_converting or danmaku_track_id then
        return
    end

    local path = mp.get_property("path") or ""
    local lower_p = path:lower()

    -- 1. 優先檢查是否由 External Player (油猴插件) 或外部透過 --script-opts / --script-opts-append 傳入 cid
    local opt_cid = mp.get_opt("cid")
    if opt_cid and opt_cid ~= "" then
        load_danmaku_by_cid(opt_cid)
        return
    end

    -- 2. 檢查 yt-dlp 下載或外掛軌道中是否包含帶有 cid 的 danmaku xml 軌道
    local track_cid = nil
    local tracks = mp.get_property_native("track-list") or {}
    for _, track in ipairs(tracks) do
        if track["lang"] == "danmaku" and track["external-filename"] then
            track_cid = track["external-filename"]:match("/(%d-)%.xml$") or track["external-filename"]:match("\\(%d-)%.xml$")
            if track_cid then
                if track["id"] then mp.commandv("sub-remove", track["id"]) end
                break
            end
        end
    end
    if track_cid and track_cid ~= "" then
        load_danmaku_by_cid(track_cid)
        return
    end

    -- 3. 檢查網址或路徑參數中是否直接帶有 cid (例如 ?cid=... 或 &cid=...)
    local url_cid = path:match("[?&]cid=(%d+)")
    if url_cid and url_cid ~= "" then
        load_danmaku_by_cid(url_cid)
        return
    end

    local is_bili = (lower_p:match("bilibili%.com") or lower_p:match("b23%.tv")) and lower_p:match("http")
    local is_yt = (lower_p:match("youtube%.com") or lower_p:match("youtu%.be")) and lower_p:match("http")

    if is_bili then
        local detected_cid = extract_bili_cid()
        if detected_cid and detected_cid ~= "" then
            mp.msg.info(string.format("[mpv-danmaku] 偵測到 B 站 CID: %s，直接啟動極速彈幕解析", detected_cid))
            load_danmaku_by_cid(detected_cid)
            return
        end
        load_bilibili_danmaku(path)
    elseif is_yt then
        trigger_b2y(nil, false)
    else
        -- 本機影片播放：自動尋找同目錄下的同名 XML / ASS 彈幕檔案
        local sibling = find_sibling_danmaku(path)
        if sibling then
            convert_and_mount(sibling, "sibling", "[彈幕] 已自動載入同名外部彈幕！")
        end
    end
end

function unloadsub()
    if danmaku_track_id then
        mp.commandv("sub-remove", danmaku_track_id)
        danmaku_track_id = nil
    end
    source_file = nil
    xmlfile = nil
    assfile = nil
    is_loading = false
    is_converting = false
    is_file_active = false
    pending_setsub_msg = nil
    early_cid_loading = false
    mp.set_property_native("options/sub-file-paths", "")
    mp.set_property("sub-auto", "fuzzy")
    mp.set_property_native("user-data/danmaku/present", false)
    mp.set_property_native("user-data/b2y/info", {})
end

local function handle_early_bili_danmaku()
    local path = mp.get_property("path", "")
    local stream_path = mp.get_property("stream-open-filename", "")
    local target = (path .. " " .. stream_path):lower()
    local is_bili = target:find("bilibili%.com") or target:find("b23%.tv") or target:find("bilivideo%.com") or target:find("/upgcxcode/")

    if is_bili and not early_cid_loading and not danmaku_track_id and not is_loading then
        local cid = extract_bili_cid()
        if cid and cid ~= "" then
            early_cid_loading = true
            mp.msg.info(string.format("[mpv-danmaku] on_load 預先提取到 B 站 CID: %s，提前啟動彈幕解析", cid))
            load_danmaku_by_cid(cid)
        end
    end
end

mp.add_hook("on_load", 25, handle_early_bili_danmaku)

function clean()
    for path in pairs(created_files) do
        os.remove(path)
        os.remove(path .. ".part")
    end
end

mp.observe_property("track-list", "native", on_track_list_changed)
mp.register_event("start-file", function()
    is_file_active = false
    pending_setsub_msg = nil
    early_cid_loading = false
    mp.set_property_native("user-data/danmaku/present", false)
end)
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", unloadsub)
mp.register_event("shutdown", clean)

-- 快捷鍵與指令綁定
mp.add_key_binding("B", "reload-danmaku", function()
    unloadsub()
    on_file_loaded()
end)

mp.add_key_binding(nil, "load-external-danmaku", load_external_danmaku)
mp.add_key_binding(nil, "pick-external-danmaku", pick_external_danmaku)
mp.add_key_binding(nil, "cycle-sibling-danmaku", cycle_sibling_danmaku)
mp.add_key_binding(nil, "convert-active-sub", convert_active_sub)
mp.register_script_message("load-external-danmaku", load_external_danmaku)
mp.register_script_message("pick-external-danmaku", pick_external_danmaku)
mp.register_script_message("cycle-sibling-danmaku", cycle_sibling_danmaku)
mp.register_script_message("convert-active-sub", convert_active_sub)

mp.add_key_binding(nil, "b2y-match", function()
    trigger_b2y(nil, true)
end)
mp.register_script_message("b2y-match", function(bvid)
    trigger_b2y(bvid, false)
end)
mp.register_script_message("b2y-select-candidate", function(bvid)
    trigger_b2y(bvid, false)
end)
mp.register_script_message("b2y-search", function(keyword)
    search_candidates_only(keyword)
end)
mp.register_script_message("b2y-manual-clipboard", function()
    trigger_b2y(nil, true)
end)
mp.register_script_message("b2y-unload", function()
    unloadsub()
    mp.osd_message("[B2Y] 已解除並關閉當前彈幕", 2.0)
end)

-- 相容 itKelis / External Player / 外部工具之 script-message 調用
mp.register_script_message("load-danmaku", function(cid)
    load_danmaku_by_cid(cid)
end)
mp.register_script_message("load-cid", function(cid)
    load_danmaku_by_cid(cid)
end)
