-- Elvenide's HUD Stats
-- Enhances the existing bottom-right Main Sequence version TextBlock in-place
-- (preserving its exact font, size, color, and format) to display:
--   FPS: <game fps> | Playtime: <H:MM:SS> | MS v<main sequence version>
-- (On the Main Menu before loading a save: FPS: <game fps> | MS v<main sequence version>)

local Core = require("core")

local Feature = {
    Name        = "HudVersionBar",
    DisplayName = "HUD FPS & Playtime Bar",
    Description = "Displays live FPS and total save play time alongside the game version in the bottom-right HUD.",
}

local TargetTextBlock = nil
local OriginalMSVersion = nil
local OriginalMSRawText = nil
local PollRunning = false
local CurrentFps = 0
local LastScanTime = -999.0
local SessionStartClock = nil
local PlaytimeSource = nil -- { kind = "prop"|"fn"|"tick_prop"|"tick_fn"|"save_snapshot"|"session", ... }
local PlaytimeDiscovered = false
local PlaytimeBaseSeconds = 0.0
local PlaytimeBaseClock = nil
local CurrentLoadedSaveName = nil
local IsInActiveSave = false
local CachedSavePlaytimes = {} -- normalizedSaveKey -> seconds

local function SafeStr(val)
    if type(val) == "string" then return val end
    if val == nil then return "" end
    local ok, s = pcall(function() return val:ToString() end)
    return (ok and type(s) == "string") and s or ""
end

local function NormalizeSaveKey(name)
    if type(name) ~= "string" then return "" end
    local s = name:lower():gsub("_s$", ""):gsub("[^a-z0-9]", "")
    return s
end

local SAVE_PLAYTIME_TICK_HZ = 30.0 -- Verified: Main Sequence stores SaveGame.Playtime in 30 Hz simulation ticks

local function SnapshotSaveGamePlaytimes()
    local okAll, sgList = pcall(FindAllOf, "SaveGame")
    if not okAll or not sgList then return end
    local loggedSample = false
    for i = 1, #sgList do
        local sg = sgList[i]
        if Core.IsValidObj(sg) then
            local ptNum = nil
            pcall(function()
                local v = sg.Playtime or sg.PlayTime or sg.TotalPlayTime
                if type(v) == "number" then ptNum = v / SAVE_PLAYTIME_TICK_HZ
                elseif type(v) == "userdata" then ptNum = Core.GetFPFloat(v) / SAVE_PLAYTIME_TICK_HZ end
            end)
            if ptNum and ptNum >= 0 then
                local candidateNames = {}
                pcall(function()
                    for _, pn in ipairs({ "SaveName", "WorldName", "SlotName", "DisplayName", "Name", "FileName", "SaveSlotName" }) do
                        local raw = sg[pn]
                        local s = SafeStr(raw)
                        if s ~= "" then candidateNames[#candidateNames + 1] = s end
                    end
                end)
                -- Also inspect any string/FText/FName properties on the first SaveGame if none of the standard names matched
                if #candidateNames == 0 then
                    pcall(function()
                        local cls = sg:GetClass()
                        if Core.IsValidObj(cls) and cls.ForEachProperty then
                            local propsLog = {}
                            cls:ForEachProperty(function(prop)
                                local pn = nil
                                pcall(function() pn = prop:GetFName():ToString() end)
                                if type(pn) == "string" then
                                    local okV, v = pcall(function() return sg[pn] end)
                                    local s = okV and SafeStr(v) or ""
                                    if s ~= "" and #s <= 80 then
                                        candidateNames[#candidateNames + 1] = s
                                    end
                                    if not loggedSample then
                                        propsLog[#propsLog + 1] = pn
                                    end
                                end
                            end)
                            if not loggedSample and #propsLog > 0 then
                                loggedSample = true
                                Core.Log("[HudStats] SaveGame props: " .. table.concat(propsLog, ", "))
                            end
                        end
                    end)
                end
                for _, cname in ipairs(candidateNames) do
                    local key = NormalizeSaveKey(cname)
                    if key ~= "" then
                        CachedSavePlaytimes[key] = ptNum
                    end
                end
            end
        end
    end
end

local function ExtractMSVersion(str)
    if type(str) ~= "string" then return nil, nil end
    local trimmed = str:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then return nil, nil end
    -- Already formatted by us? Extract the MS v... suffix so we keep the real version
    local existing = trimmed:match("MS%s+v([^|%s]+)")
    if existing and existing ~= "" then
        return existing, nil
    end
    -- Match raw Main Sequence version strings like "0.1.0.109s" or "v0.1.0.109s"
    if trimmed:match("^[vV]?%d+%.%d+%.%d+") and #trimmed <= 24 then
        return trimmed:gsub("^[vV]", ""), trimmed
    end
    return nil, nil
end

local function IsVersionOverlayTextBlock(tb)
    local isVis = false
    pcall(function() isVis = (tb:IsVisible() == true) end)
    if not isVis then return false end

    -- Narrow match to the persistent HUD / Version / MainMenu overlay so unrelated semver UI labels
    -- (save lists, server browser entries, patch notes) are never overwritten.
    local okFull, fullName = pcall(function() return tb:GetFullName():lower() end)
    if okFull and type(fullName) == "string" then
        if fullName:find("save", 1, true) or fullName:find("server", 1, true)
            or fullName:find("changelog", 1, true) or fullName:find("patch", 1, true)
            or fullName:find("codex", 1, true) or fullName:find("chat", 1, true)
        then
            return false
        end
    end
    return true
end

local CachedGameplayStaticsCDO = nil

local function TryExtractVersionFromTextObj(tb)
    if not Core.IsValidObj(tb) or not tb.GetText or not IsVersionOverlayTextBlock(tb) then
        return nil, nil, nil
    end
    local okT, txtObj = pcall(function() return tb:GetText() end)
    if okT and txtObj ~= nil then
        local okS, s = pcall(function() return txtObj:ToString() end)
        if okS and type(s) == "string" then
            local ver, rawTxt = ExtractMSVersion(s)
            if ver then
                return tb, ver, rawTxt
            end
        end
    end
    return nil, nil, nil
end

-- Walk a UUserWidget/UPanelWidget subtree via native UMG GetRootWidget + GetChildrenCount/GetChildAt
-- (works in Shipping builds where WidgetTree is stripped and when "Is Variable" is unchecked).
local function FindVersionTextInWidgetTree(rootWidget, maxDepth)
    if not Core.IsValidObj(rootWidget) then return nil, nil, nil end
    local limit = maxDepth or 8
    local visited = {}
    local queue = { { w = rootWidget, d = 0 } }
    local head = 1
    local maxNodes = 160

    while head <= #queue and head <= maxNodes do
        local item = queue[head]
        head = head + 1
        local w = item.w
        local d = item.d
        if Core.IsValidObj(w) then
            local addr = w:GetAddress()
            if not visited[addr] then
                visited[addr] = true
                -- Check if this node itself is a TextBlock with the MS version string
                if w.GetText and w.SetText then
                    local tb, ver, rawTxt = TryExtractVersionFromTextObj(w)
                    if Core.IsValidObj(tb) then
                        return tb, ver, rawTxt
                    end
                end
                if d < limit then
                    -- UserWidget -> GetRootWidget()
                    if w.GetRootWidget then
                        local okR, rw = pcall(function() return w:GetRootWidget() end)
                        if okR and Core.IsValidObj(rw) then
                            queue[#queue + 1] = { w = rw, d = d + 1 }
                        end
                    end
                    -- PanelWidget / ContentWidget -> GetChildrenCount() + GetChildAt(i)
                    if w.GetChildrenCount and w.GetChildAt then
                        local okN, n = pcall(function() return tonumber(w:GetChildrenCount()) or 0 end)
                        if okN and n > 0 then
                            local cap = math.min(n, 32)
                            for i = 0, cap - 1 do
                                local okC, child = pcall(function() return w:GetChildAt(i) end)
                                if okC and Core.IsValidObj(child) then
                                    queue[#queue + 1] = { w = child, d = d + 1 }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, nil, nil
end

local function FindVersionTextBlockInVersionWidget(verW)
    if not Core.IsValidObj(verW) then return nil, nil, nil end
    local tb = nil
    pcall(function()
        local txtW = verW.WBP_Text
        if Core.IsValidObj(txtW) and Core.IsValidObj(txtW.TextBlock) then
            tb = txtW.TextBlock
        elseif Core.IsValidObj(verW.TextBlock) then
            tb = verW.TextBlock
        end
    end)
    if Core.IsValidObj(tb) then
        local foundTb, ver, rawTxt = TryExtractVersionFromTextObj(tb)
        if Core.IsValidObj(foundTb) then return foundTb, ver, rawTxt end
    end
    return FindVersionTextInWidgetTree(verW, 6)
end

-- Verified widget hierarchy in Main Sequence:
-- WBP_CharacterHUD_C / WBP_MainMenu_C -> WBP_Version (WBP_Version_C) -> WBP_Text -> TextBlock
-- Uses FindAllOf("WBP_Version_C") (only 1-2 instances exist in the entire game) + native UMG tree walk.
local function FindVersionTextBlock(hintWidget)
    local okAll, verList = pcall(FindAllOf, "WBP_Version_C")
    if okAll and verList then
        for i = #verList, 1, -1 do
            local vw = verList[i]
            if Core.IsValidObj(vw) then
                local tb, ver, rawTxt = FindVersionTextBlockInVersionWidget(vw)
                if Core.IsValidObj(tb) then return tb, ver, rawTxt end
            end
        end
    end
    if Core.IsValidObj(hintWidget) then
        local tb, ver, rawTxt = FindVersionTextInWidgetTree(hintWidget, 8)
        if Core.IsValidObj(tb) then return tb, ver, rawTxt end
    end
    for _, clsName in ipairs({ "WBP_CharacterHUD_C", "WBP_MainMenu_C" }) do
        local okF, host = pcall(FindFirstOf, clsName)
        if okF and Core.IsValidObj(host) then
            local tb, ver, rawTxt = FindVersionTextInWidgetTree(host, 8)
            if Core.IsValidObj(tb) then return tb, ver, rawTxt end
        end
    end
    return nil, nil, nil
end

local function FormatPlaytime(totalSeconds)
    if type(totalSeconds) ~= "number" or totalSeconds ~= totalSeconds or totalSeconds < 0 then
        return nil
    end
    local secs = math.floor(totalSeconds)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    return string.format("%d:%02d:%02d", h, m, s)
end

local function ReadNumericValue(val)
    if type(val) == "number" then return val end
    if type(val) == "userdata" then
        local fp = Core.GetFPFloat(val)
        if type(fp) == "number" and fp > 0 then return fp end
    end
    return nil
end

local function ReadPlaytimeFromMetaSlot(saveName)
    if type(saveName) ~= "string" or saveName == "" then return nil end
    if not Core.IsValidObj(CachedGameplayStaticsCDO) then
        CachedGameplayStaticsCDO = Core.GetCDO("/Script/Engine.Default__GameplayStatics")
    end
    if not Core.IsValidObj(CachedGameplayStaticsCDO) or not CachedGameplayStaticsCDO.LoadGameFromSlot then
        return nil
    end
    -- Main Sequence stores lightweight save metadata in "<SaveBase>_M.sav" alongside "<SaveBase>_S.sav"
    local baseName = saveName:gsub("_[sSmM]$", "")
    local metaSlot = baseName .. "_M"
    local okLoad, metaSave = pcall(function()
        return CachedGameplayStaticsCDO:LoadGameFromSlot(metaSlot, 0)
    end)
    if okLoad and Core.IsValidObj(metaSave) then
        local okPt, rawPt = pcall(function()
            return metaSave.Playtime or metaSave.PlayTime or metaSave.TotalPlayTime
        end)
        local num = okPt and ReadNumericValue(rawPt) or nil
        if num and num >= 0 then
            return num / SAVE_PLAYTIME_TICK_HZ, metaSlot
        end
    end
    return nil
end

local function DiscoverPlaytimeSource(worldSub, dmsWorld, gameState)
    PlaytimeDiscovered = true

    -- 1. Direct read of the active save's lightweight metadata slot ("<SaveName>_M.sav") via native LoadGameFromSlot
    --    Works reliably whether the player clicked Continue, Load Game, or loaded an Autosave!
    if CurrentLoadedSaveName and CurrentLoadedSaveName ~= "" then
        local metaSecs, metaSlot = ReadPlaytimeFromMetaSlot(CurrentLoadedSaveName)
        if metaSecs and metaSecs >= 0 then
            PlaytimeBaseSeconds = metaSecs
            PlaytimeBaseClock = os.clock()
            PlaytimeSource = { kind = "save_snapshot", objRef = nil, name = "Playtime", lastRaw = metaSecs }
            Core.Log(string.format("[HudStats] Bound total save playtime from slot '%s': %.1fs (%s)",
                tostring(metaSlot), metaSecs, FormatPlaytime(metaSecs) or "?"))
            return
        end
    end

    local directTimeProps = {
        "TotalPlayTime", "PlayTime", "Playtime", "TimePlayed", "SavePlayTime",
        "TotalTimePlayed", "ElapsedPlayTime", "GameTime", "WorldTime", "SimTime",
    }
    local directTimeFns = {
        "GetTotalPlayTime", "GetPlayTime", "GetTimePlayed", "GetElapsedPlayTime",
        "GetWorldTime", "GetSimTime", "GetGameTime",
    }
    local directTickProps = { "CurrentTick", "TickCount", "SimTick", "WorldTick", "TotalTicks" }
    local directTickFns = { "GetCurrentTick", "GetTickCount", "GetSimTick" }

    local targets = {
        { tag = "world", obj = dmsWorld },
        { tag = "sub",   obj = worldSub },
    }

    -- 1. Check known time property / function names on DMSWorld & DMSWorldSubsystem
    for _, t in ipairs(targets) do
        if Core.IsValidObj(t.obj) then
            for _, pn in ipairs(directTimeProps) do
                local ok, v = pcall(function() return t.obj[pn] end)
                local num = ok and ReadNumericValue(v) or nil
                if num and num >= 0 then
                    PlaytimeSource = { kind = "prop", owner = t.tag, name = pn }
                    Core.Log(string.format("[HudStats] Bound total save playtime to %s.%s (%.1fs)", t.tag, pn, num))
                    return
                end
            end
            for _, fn in ipairs(directTimeFns) do
                if type(t.obj[fn]) == "function" then
                    local ok, v = pcall(function() return t.obj[fn](t.obj) end)
                    local num = ok and ReadNumericValue(v) or nil
                    if num and num >= 0 then
                        PlaytimeSource = { kind = "fn", owner = t.tag, name = fn }
                        Core.Log(string.format("[HudStats] Bound total save playtime to %s:%s() (%.1fs)", t.tag, fn, num))
                        return
                    end
                end
            end
        end
    end

    -- 2. Check simulation tick counter on DMSWorld / DMSWorldSubsystem (convert via TickRate or 20 Hz default)
    local tickHz = 20.0
    if Core.IsValidObj(dmsWorld) then
        pcall(function()
            local dt = ReadNumericValue(dmsWorld.FixedDeltaTime or dmsWorld.TickInterval or dmsWorld.DeltaTime)
            if dt and dt > 0.001 and dt < 1.0 then
                tickHz = 1.0 / dt
            else
                local hz = ReadNumericValue(dmsWorld.TickRate or dmsWorld.TicksPerSecond)
                if hz and hz >= 1.0 and hz <= 240.0 then tickHz = hz end
            end
        end)
    end
    for _, t in ipairs(targets) do
        if Core.IsValidObj(t.obj) then
            for _, pn in ipairs(directTickProps) do
                local ok, v = pcall(function() return t.obj[pn] end)
                local num = ok and ReadNumericValue(v) or nil
                if num and num > 0 then
                    PlaytimeSource = { kind = "tick_prop", owner = t.tag, name = pn, tickHz = tickHz }
                    Core.Log(string.format("[HudStats] Bound total save playtime to %s.%s / %.1fHz (%.1fs)", t.tag, pn, tickHz, num / tickHz))
                    return
                end
            end
            for _, fn in ipairs(directTickFns) do
                if type(t.obj[fn]) == "function" then
                    local ok, v = pcall(function() return t.obj[fn](t.obj) end)
                    local num = ok and ReadNumericValue(v) or nil
                    if num and num > 0 then
                        PlaytimeSource = { kind = "tick_fn", owner = t.tag, name = fn, tickHz = tickHz }
                        Core.Log(string.format("[HudStats] Bound total save playtime to %s:%s() / %.1fHz (%.1fs)", t.tag, fn, tickHz, num / tickHz))
                        return
                    end
                end
            end
        end
    end

    -- 3. Resolve total save playtime:
    -- 3a. Check cached SaveGame.Playtime snapshotted from LoadExistingGame(SaveName)
    if CurrentLoadedSaveName and CurrentLoadedSaveName ~= "" then
        SnapshotSaveGamePlaytimes()
        local key = NormalizeSaveKey(CurrentLoadedSaveName)
        local cachedPt = (key ~= "") and CachedSavePlaytimes[key] or nil
        if cachedPt and cachedPt >= 0 then
            PlaytimeBaseSeconds = cachedPt
            PlaytimeBaseClock = os.clock()
            PlaytimeSource = { kind = "save_snapshot", objRef = nil, name = "Playtime", lastRaw = cachedPt }
            Core.Log(string.format("[HudStats] Bound total save playtime for '%s': %.1fs (%s)",
                CurrentLoadedSaveName, cachedPt, FormatPlaytime(cachedPt) or "?"))
            return
        end
    end

    -- 3b. Check world.SaveableRoot / gs.BlueprintSaveGame / gs numeric properties for a live playtime counter
    local extraTargets = {}
    pcall(function()
        if Core.IsValidObj(dmsWorld) and Core.IsValidObj(dmsWorld.SaveableRoot) then
            extraTargets[#extraTargets + 1] = { tag = "saveRoot", obj = dmsWorld.SaveableRoot }
        end
    end)
    pcall(function()
        if Core.IsValidObj(gameState) and Core.IsValidObj(gameState.BlueprintSaveGame) then
            extraTargets[#extraTargets + 1] = { tag = "bpSave", obj = gameState.BlueprintSaveGame }
        end
    end)
    if Core.IsValidObj(gameState) then
        extraTargets[#extraTargets + 1] = { tag = "gs", obj = gameState }
    end

    local diagCandidates = {}
    for _, holder in ipairs(extraTargets) do
        pcall(function()
            local cls = holder.obj:GetClass()
            if Core.IsValidObj(cls) and cls.ForEachProperty then
                cls:ForEachProperty(function(prop)
                    local pn = nil
                    pcall(function() pn = prop:GetFName():ToString() end)
                    if type(pn) == "string" then
                        local low = pn:lower()
                        if low:find("play", 1, true) or low:find("time", 1, true) or low:find("tick", 1, true) then
                            local okV, v = pcall(function() return holder.obj[pn] end)
                            local num = okV and ReadNumericValue(v) or nil
                            if num ~= nil then
                                diagCandidates[#diagCandidates + 1] = string.format("%s.%s=%.1f", holder.tag, pn, num)
                                if not PlaytimeSource and (low:find("playtime", 1, true) or low:find("timeplayed", 1, true) or low:find("totaltime", 1, true)) then
                                    PlaytimeBaseSeconds = num
                                    PlaytimeBaseClock = os.clock()
                                    PlaytimeSource = { kind = "save_snapshot", objRef = holder.obj, name = pn, lastRaw = num }
                                    Core.Log(string.format("[HudStats] Bound live save playtime to %s.%s (%.1fs)", holder.tag, pn, num))
                                end
                            end
                        end
                    end
                end)
            end
        end)
    end
    if PlaytimeSource then return end

    -- 4. Fallback: session elapsed time since loading into the save
    PlaytimeSource = { kind = "session" }
    local cachedKeys = {}
    for k, v in pairs(CachedSavePlaytimes) do
        cachedKeys[#cachedKeys + 1] = string.format("%s=%.0f", k, v)
    end
    Core.Log(string.format("[HudStats] Fallback to session playtime (loadedSave='%s', cachedSaves=[%s], diag=[%s])",
        tostring(CurrentLoadedSaveName), table.concat(cachedKeys, ", "), table.concat(diagCandidates, ", ")))
end

local function SamplePlaytimeSeconds()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return nil end
    local worldSub = Core.GetWorldSubsystem(pc, Core.PATHS.WorldSubsystemClass)
    local dmsWorld = nil
    if Core.IsValidObj(worldSub) and worldSub.GetDMSWorld then
        pcall(function() dmsWorld = worldSub:GetDMSWorld() end)
    end
    -- Only show Playtime when actually in a loaded save (never on the Main Menu!)
    if not IsInActiveSave or not Core.IsValidObj(dmsWorld) then
        return nil
    end
    if not SessionStartClock then
        SessionStartClock = os.clock()
    end
    if not PlaytimeDiscovered then
        local gs = nil
        pcall(function()
            local w = pc:GetWorld()
            if Core.IsValidObj(w) then gs = w.GameState end
        end)
        DiscoverPlaytimeSource(worldSub, dmsWorld, gs)
    end
    local src = PlaytimeSource
    if src and src.kind == "save_snapshot" then
        -- If the game updates SaveGame.Playtime live (e.g. on autosave or per-tick), re-sync base clock!
        if Core.IsValidObj(src.objRef) then
            local okV, v = pcall(function() return src.objRef[src.name] end)
            local num = okV and ReadNumericValue(v) or nil
            if num and num >= 0 and math.abs(num - (src.lastRaw or -1)) > 0.5 then
                src.lastRaw = num
                PlaytimeBaseSeconds = num
                PlaytimeBaseClock = os.clock()
            end
        end
        return PlaytimeBaseSeconds + math.max(0.0, os.clock() - (PlaytimeBaseClock or SessionStartClock))
    elseif src and src.kind ~= "session" then
        local target = src.objRef or ((src.owner == "world") and dmsWorld or worldSub)
        if Core.IsValidObj(target) then
            local ok, v = pcall(function()
                if src.kind == "prop" or src.kind == "tick_prop" then
                    return target[src.name]
                elseif type(target[src.name]) == "function" then
                    return target[src.name](target)
                end
                return nil
            end)
            local num = ok and ReadNumericValue(v) or nil
            if num and num >= 0 then
                if src.kind == "tick_prop" or src.kind == "tick_fn" then
                    return num / (src.tickHz or 20.0)
                end
                return num
            end
        end
    end
    return math.max(0.0, os.clock() - SessionStartClock)
end

local function UpdateVersionTextBlock()
    if not Core.IsValidObj(TargetTextBlock) or not OriginalMSVersion then return false end
    local ptSecs = SamplePlaytimeSeconds()
    local ptStr = ptSecs and FormatPlaytime(ptSecs) or nil
    local label = ptStr
        and string.format("FPS: %d | Playtime: %s | MS v%s", CurrentFps, ptStr, OriginalMSVersion)
        or  string.format("FPS: %d | MS v%s", CurrentFps, OriginalMSVersion)
    local ok = pcall(function()
        TargetTextBlock:SetText(Core.MakeText(label))
    end)
    return ok
end

local function EnsureSlotAutoSize(tb)
    if not Core.IsValidObj(tb) then return end
    pcall(function()
        if tb.Slot and Core.IsValidObj(tb.Slot) and tb.Slot.SetAutoSize then
            tb.Slot:SetAutoSize(true)
        end
    end)
end

local SCAN_RETRY_SECONDS = 8.0 -- Safety-net FindAllOf("TextBlock") interval (>= 8s per learning.md §7)

local function TryHookVersionTextBlock(hintWidget)
    if Core.IsValidObj(TargetTextBlock) then return true end
    LastScanTime = os.clock()
    local tb, ver, rawTxt = FindVersionTextBlock(hintWidget)
    if Core.IsValidObj(tb) and ver then
        TargetTextBlock = tb
        OriginalMSVersion = ver
        if rawTxt then
            OriginalMSRawText = rawTxt
        end
        EnsureSlotAutoSize(tb)
        Core.Log(string.format("[HudVersionBar] Hooked version TextBlock (MS v%s)", ver))
        return true
    end
    return false
end

local function SampleNativeFps()
    if not Core.IsValidObj(CachedGameplayStaticsCDO) then
        CachedGameplayStaticsCDO = Core.GetCDO("/Script/Engine.Default__GameplayStatics")
    end
    local pc = Core.GetLocalPlayerController()
    if Core.IsValidObj(CachedGameplayStaticsCDO) and Core.IsValidObj(pc) then
        local okDt, dt = pcall(function() return CachedGameplayStaticsCDO:GetWorldDeltaSeconds(pc) end)
        if okDt and type(dt) == "number" and dt > 0.0001 and dt < 2.0 then
            return math.max(1, math.floor((1.0 / dt) + 0.5))
        end
    end
    return CurrentFps
end

local function StartLoop()
    if PollRunning then return end
    PollRunning = true

    -- Poll at 2 Hz (every 500ms) reading Unreal's native GetWorldDeltaSeconds instead of
    -- running a 120+ Hz every-frame Lua callback just to count frames!
    local function Tick()
        if not Core.IsFeatureEnabled("HudVersionBar") then
            PollRunning = false
            return
        end
        CurrentFps = SampleNativeFps()
        local now = os.clock()
        if not Core.IsValidObj(TargetTextBlock) then
            if (now - LastScanTime) >= SCAN_RETRY_SECONDS then
                TryHookVersionTextBlock()
            end
        end
        if Core.IsValidObj(TargetTextBlock) then
            UpdateVersionTextBlock()
        end
        ExecuteInGameThreadWithDelay(500, Tick)
    end

    ExecuteInGameThreadWithDelay(500, Tick)
end

-- Trigger a prompt one-shot scan when major HUD/menu widgets construct
local function ScheduleHintScan(w)
    if not Core.IsFeatureEnabled("HudVersionBar") then return end
    for _, delayMs in ipairs({ 200, 1000 }) do
        ExecuteInGameThreadWithDelay(delayMs, function()
            if Core.IsFeatureEnabled("HudVersionBar") and not Core.IsValidObj(TargetTextBlock) then
                TryHookVersionTextBlock(w)
            end
        end)
    end
end

Feature.WatchWidgets = {
    WBP_CharacterHUD_C = function(w)
        IsInActiveSave = true
        ScheduleHintScan(w)
    end,
    WBP_MainMenu_C = function(w)
        IsInActiveSave = false
        ScheduleHintScan(w)
        ExecuteInGameThreadWithDelay(600, SnapshotSaveGamePlaytimes)
    end,
}

function Feature.OnToggle(enabled)
    if enabled then
        StartLoop()
    else
        local restoreText = OriginalMSRawText or OriginalMSVersion
        if Core.IsValidObj(TargetTextBlock) and restoreText then
            pcall(function() TargetTextBlock:SetText(Core.MakeText(restoreText)) end)
        end
    end
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "HudStats_LoadExistingGame",
        "/Script/MainSequence.DMSWorldSubsystem:LoadExistingGame",
        function(_, SaveNameParam)
            local saveName = SafeStr(Core.UnwrapStruct(SaveNameParam))
            ExecuteInGameThread(function()
                -- Snapshot SaveGame.Playtime from the Main Menu's loaded save metadata BEFORE map transition GCs them!
                SnapshotSaveGamePlaytimes()
                CurrentLoadedSaveName = (saveName ~= "") and saveName or CurrentLoadedSaveName
                IsInActiveSave = true
                SessionStartClock = os.clock()
                PlaytimeSource = nil
                PlaytimeDiscovered = false
            end)
        end
    )
    Core.TryRegisterHook(
        "HudStats_StartNewGame",
        "/Script/MainSequence.DMSWorldSubsystem:StartNewGame",
        function()
            ExecuteInGameThread(function()
                CurrentLoadedSaveName = nil
                IsInActiveSave = true
                PlaytimeBaseSeconds = 0.0
                PlaytimeBaseClock = os.clock()
                SessionStartClock = os.clock()
                PlaytimeSource = { kind = "session" }
                PlaytimeDiscovered = true
            end)
        end
    )
end

function Feature.Init()
    if Core.IsFeatureEnabled("HudVersionBar") then
        StartLoop()
    end
end

function Feature.OnMapLoad()
    TargetTextBlock = nil
    LastScanTime = -999.0
    PlaytimeSource = nil
    PlaytimeDiscovered = false
    if Core.IsFeatureEnabled("HudVersionBar") then StartLoop() end
end

function Feature.OnClientRestart()
    TargetTextBlock = nil
    LastScanTime = -999.0
    if not SessionStartClock then SessionStartClock = os.clock() end
    PlaytimeSource = nil
    PlaytimeDiscovered = false
    if Core.IsFeatureEnabled("HudVersionBar") then StartLoop() end
end

return Feature
