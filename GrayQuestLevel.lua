-- Gray Quest Level
-- Line 1: the lowest quest level that is still green, and where quests turn gray.
-- Line 2: how many more XP gains of the last size it takes to reach the next level.
-- Works on Retail-API clients (incl. WoW Forever beta), where GetQuestGreenRange
-- no longer exists.

local ADDON_NAME = ...

GrayQuestLevelDB = GrayQuestLevelDB or {}         -- account-wide: source, offset, lastGain
GrayQuestLevelCharDB = GrayQuestLevelCharDB or {} -- per character: position, challenge state

-- The box position used to be account-wide. It is per character now, because a
-- character with a different UI wants the box somewhere else. Seed each
-- character from the old account-wide value once, then let them diverge -- the
-- flag is what stops a later `/gql reset` being undone by this on next login.
if GrayQuestLevelDB.pos and not GrayQuestLevelCharDB.posMigrated then
    GrayQuestLevelCharDB.pos = GrayQuestLevelDB.pos
    GrayQuestLevelCharDB.posMigrated = true
end

-- An earlier build learned quest XP into saved variables. QuestXP.lua is the
-- only source now, so drop the orphaned table rather than leave it on disk.
GrayQuestLevelDB.questXP = nil

-- ---------------------------------------------------------------------------
-- Chat output
-- ---------------------------------------------------------------------------
-- Everything the addon says goes through Say(), so it can be routed to one
-- chat window instead of whichever one is default. Per character, because chat
-- layouts are per character.

local refreshOptions -- set by the options panel below, if it could be built

local function ChatFrameFor(index)
    index = tonumber(index)
    if not index then return nil end
    local f = _G["ChatFrame" .. index]
    -- Checked on every call: a window can be closed after being chosen.
    if type(f) == "table" and type(f.AddMessage) == "function" then return f end
end

local function Say(msg)
    local target = ChatFrameFor(GrayQuestLevelCharDB.chatFrame)
    if target and pcall(target.AddMessage, target, msg) then return end
    print(msg) -- the default window, and the fallback if the chosen one is gone
end

-- The windows this client actually has. GetChatWindowInfo returns an empty name
-- for unused slots, and the frame itself may not exist on this build.
local function ChatWindows()
    local list = {}
    for i = 1, (tonumber(NUM_CHAT_WINDOWS) or 10) do
        local ok, name, _, _, _, _, _, shown, _, docked = pcall(GetChatWindowInfo, i)
        if ok and type(name) == "string" and name ~= "" and ChatFrameFor(i) then
            list[#list + 1] = { index = i, name = name, open = (shown or docked) and true or false }
        end
    end
    return list
end

local function ChatTargetName()
    local index = tonumber(GrayQuestLevelCharDB.chatFrame)
    if not index then return "default" end
    for _, w in ipairs(ChatWindows()) do
        if w.index == index then return w.name end
    end
    return ("window %d"):format(index)
end

local function SetChatFrame(index)
    GrayQuestLevelCharDB.chatFrame = tonumber(index)
    if refreshOptions then pcall(refreshOptions) end
end

-- Screenshot on level-up, per character. On by default, so only an explicit
-- false turns it off -- a character that has never touched it reads nil.
local function ScreenshotOnLevel()
    return GrayQuestLevelCharDB.screenshot ~= false
end

local function SetScreenshotOnLevel(on)
    GrayQuestLevelCharDB.screenshot = on and true or false
    if refreshOptions then pcall(refreshOptions) end
end

-- ---------------------------------------------------------------------------
-- Safe reads
-- ---------------------------------------------------------------------------

-- Reads a number from an API that may be absent, may throw, or (on this client)
-- may hand back a secret value that throws when compared. Everything that
-- touches the value happens inside pcall.
local function SafeNumber(fn, unit)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, unit)
    if not ok then return nil end
    local ok2, usable = pcall(function()
        return type(value) == "number" and value == value -- NaN check
    end)
    if ok2 and usable then return value end
end

local function PlayerLevel()
    return SafeNumber(UnitEffectiveLevel, "player")
        or SafeNumber(UnitLevel, "player")
        or 1
end

-- ---------------------------------------------------------------------------
-- Quest level math
-- ---------------------------------------------------------------------------

-- How many levels below you a quest can be and still be green.
-- Looked up by name each time: globals are resolved lazily, and a plain
-- table + ipairs would stop at the first nil candidate.
local RANGE_FUNCS = { "UnitQuestTrivialLevelRange", "GetQuestGreenRange" }

local function GetGreenRange()
    for i = 1, #RANGE_FUNCS do
        local range = SafeNumber(_G[RANGE_FUNCS[i]], "player")
        if range then return range end
    end
end

-- Two colour tables can be the same colour without being the same table, so
-- fall back to comparing the components. Wrapped by the caller's pcall.
local function ColorsMatch(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    -- Both must actually carry components. Without this check a client that
    -- hands back bare tables makes every level "match" (nil == nil), and the
    -- scan reports your own level as gray.
    if type(a.r) ~= "number" or type(b.r) ~= "number" then return false end
    return a.r == b.r and a.g == b.g and a.b == b.b
end

-- Ask the game's own quest-colour function which levels are gray. This is the
-- function the quest log itself colours entries with, so whatever it says is
-- by definition what you see in the log -- no arithmetic, nothing to get out
-- of step with the client.
-- Returns the highest gray level, or 0 if the function works but nothing is
-- gray yet, or nil if this client has no usable colour API.
local function ScanForGray(level)
    if type(GetQuestDifficultyColor) ~= "function"
        or type(QuestDifficultyColors) ~= "table"
        or not QuestDifficultyColors.trivial then
        return nil
    end
    local worked = false
    for q = level, 1, -1 do
        local ok, color = pcall(GetQuestDifficultyColor, q)
        if ok and color ~= nil then
            worked = true
            local ok2, isTrivial = pcall(ColorsMatch, color, QuestDifficultyColors.trivial)
            if ok2 and isTrivial then
                return q -- highest gray level
            end
        end
    end
    if worked then return 0 end -- nothing is gray at this level yet
end

-- The three ways of working out the boundary, kept side by side so they can be
-- compared -- on the Forever beta they do not always agree.
--
--   table  : the published vanilla gray-level table (default)
--   range  : playerLevel - UnitQuestTrivialLevelRange("player")
--   colors : walk GetQuestDifficultyColor down until it reports trivial
--
-- `table` is the default as of v1.5, because both client-API sources are
-- demonstrably wrong here: UnitQuestTrivialLevelRange returns a flat 5 on this
-- build (Retail's non-scaling value) when vanilla scales it with level. The
-- level-8 reading that validated `range` in v1.4 did so by coincidence --
-- floor(8/10) is 0, so the missing term happened not to matter at that level.
--
-- Measured at level 20: `range` said gray 15, `colors` said gray 14, and the
-- quest log showed a level-14 quest ("The Dead Fields", wowhead quest=437)
-- still green, turning gray at 21. That is gray 13, i.e.
-- 20 - floor(20/10) - 5 -- the table, and neither API.
local function RangeGray(level)
    local range = GetGreenRange()
    if range then return level - range end
end

-- Vanilla's gray-level table: the highest level that is trivial to a player of
-- `level`. Quests and mobs share it. Returns 0 when nothing is gray yet.
--
-- The 6-39 band is confirmed against this client at levels 8 and 20. The 40+
-- bands are the published vanilla formulas and are NOT yet verified here --
-- the bands are not continuous at 60 (59 gives 47, 60 gives 51), which is how
-- the tables are written, not a transcription slip. If the display disagrees
-- with your quest log at those levels, `/gql debug` prints every source and
-- `/gql calibrate <n>` applies an offset.
local function TableGray(level)
    if level <= 5 then
        return 0 -- nothing is trivial this early
    elseif level <= 39 then
        return level - math.floor(level / 10) - 5
    elseif level <= 59 then
        return level - math.floor(level / 5) - 1
    else
        return level - 9
    end
end

-- Order used by `auto`, and as the fallback when the preferred source has
-- nothing to say: most trustworthy on this client first.
local SOURCE_ORDER = { "table", "range", "colors" }

local function Compute()
    local level = PlayerLevel()
    local pref = GrayQuestLevelDB.source or "auto"

    local byTable = TableGray(level)
    local byRange = RangeGray(level)
    local byColors = ScanForGray(level)

    -- 0 is a real answer ("nothing gray yet") and is truthy in Lua, so a
    -- present-but-zero source is still picked over a later one.
    local candidates = { table = byTable, range = byRange, colors = byColors }

    local highestGray, source = candidates[pref], pref
    if highestGray == nil then
        for i = 1, #SOURCE_ORDER do
            local name = SOURCE_ORDER[i]
            if candidates[name] ~= nil then
                highestGray, source = candidates[name], name
                break
            end
        end
    end

    if highestGray == nil then return level, nil, nil, "none", byTable, byRange, byColors end

    highestGray = highestGray + (tonumber(GrayQuestLevelDB.offset) or 0)
    return level, math.max(1, highestGray + 1), highestGray, source, byTable, byRange, byColors
end

-- ---------------------------------------------------------------------------
-- XP tracking
-- ---------------------------------------------------------------------------
-- The WeakAura this replaces read a "last mob XP" value that its own trigger
-- filled in from the combat XP chat message. Parsing that message is a bad bet
-- on this client (Retail API, restricted combat log, localised strings), so
-- instead we watch the XP bar itself: every PLAYER_XP_UPDATE, the difference
-- from the previous reading IS the amount just gained, whatever caused it.

local lastXP, lastMax   -- previous reading of the bar
local lastGain          -- size of the most recent gain
local pendingLevelUp    -- set when we level, so the next delta isn't nonsense

local function IsMaxLevel()
    local maxLevel = SafeNumber(GetMaxPlayerLevel) or SafeNumber(GetMaxLevelForPlayerExpansion)
    if maxLevel and PlayerLevel() >= maxLevel then return true end
    local max = SafeNumber(UnitXPMax, "player")
    return max ~= nil and max <= 0
end

local function XPDisabled()
    if type(IsXPUserDisabled) ~= "function" then return false end
    local ok, disabled = pcall(IsXPUserDisabled)
    return ok and disabled == true
end

-- Records the current bar position, and returns the gain since last time.
local function SampleXP()
    local xp = SafeNumber(UnitXP, "player")
    local max = SafeNumber(UnitXPMax, "player")
    if not xp or not max then return nil end

    local gain
    if lastXP and lastMax then
        if pendingLevelUp or xp < lastXP then
            -- Crossed a level: finish the old bar, then add the new bar's XP.
            -- Only meaningful for a single level; a multi-level gain is
            -- undercounted, which is fine for an estimate.
            gain = (lastMax - lastXP) + xp
        else
            gain = xp - lastXP
        end
    end

    pendingLevelUp = nil
    lastXP, lastMax = xp, max

    if gain and gain > 0 then
        lastGain = gain
        if GrayQuestLevelDB then GrayQuestLevelDB.lastGain = gain end
    end
    return gain
end

-- Returns: killsNeeded, xpRemaining, gainSize — or nil plus a reason string.
local function ComputeKills()
    if XPDisabled() then return nil, "xp off" end
    if IsMaxLevel() then return nil, "max level" end

    local xp = SafeNumber(UnitXP, "player")
    local max = SafeNumber(UnitXPMax, "player")
    if not xp or not max or max <= 0 then return nil, "no xp data" end

    local remaining = max - xp
    local gain = lastGain or (GrayQuestLevelDB and GrayQuestLevelDB.lastGain)
    if not gain or gain <= 0 then return nil, "waiting", remaining end

    return math.ceil(remaining / gain), remaining, gain
end

-- ---------------------------------------------------------------------------
-- Stored EXP (the levelling challenge)
-- ---------------------------------------------------------------------------
-- Turning in a gray quest is supposed to cost you: the XP the quest would have
-- given at level, minus the reduced amount actually awarded, becomes a debt you
-- have to grind off before the quest "counts".
--
-- The full value cannot be read from the API. GetQuestLogRewardXP() returns the
-- already-reduced amount, and QUEST_TURNED_IN's xpReward argument is what was
-- actually granted -- the pre-reduction figure is never exposed. Rather than
-- invert an undocumented reduction curve and be silently wrong, the addon
-- reports what the quest paid and you supply the full value:
--
--   /gql quest <full XP>   -- stores (full - awarded) for the last turn-in
--   /gql exp <+/-n>        -- adjust the debt by hand
--
-- Per character, because the challenge is per character.

local pendingQuestXP -- the next XP gain came from a hand-in, not from grinding

local function StoredXP()
    return math.max(0, math.floor(tonumber(GrayQuestLevelCharDB.storedXP) or 0))
end

-- Clamped at zero: the debt is something you pay off, never bank.
local function SetStoredXP(value)
    GrayQuestLevelCharDB.storedXP = math.max(0, math.floor(tonumber(value) or 0))
    return GrayQuestLevelCharDB.storedXP
end

local function Grinding()
    return GrayQuestLevelCharDB.grinding == true
end

-- Full (un-reduced) quest XP, keyed by quest ID. One source: the table in
-- QuestXP.lua, maintained by hand. Nothing is ever written back -- a value is
-- either in that file or it is not, which is why a gray quest that is missing
-- from it gets reported rather than guessed at.
--
-- QuestXP.lua is read at load, so edits need a /reload to take effect.
local function KnownQuestXP(questID)
    if not questID or type(GrayQuestLevelQuestXP) ~= "table" then return nil end
    return tonumber(GrayQuestLevelQuestXP[questID])
end

local function CountQuestXP()
    local count = 0
    if type(GrayQuestLevelQuestXP) == "table" then
        for _ in pairs(GrayQuestLevelQuestXP) do count = count + 1 end
    end
    return count
end

-- QUEST_TURNED_IN fires after the quest has already left the log, so its level
-- has to be remembered while it is still there. Rebuilt on login and on accept
-- rather than on QUEST_LOG_UPDATE, which fires far too often to scan on.
local questLevels = {}

local function CacheQuestLevels()
    if type(C_QuestLog) ~= "table" or type(C_QuestLog.GetNumQuestLogEntries) ~= "function" then return end
    local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
    if not ok or type(count) ~= "number" then return end
    for i = 1, count do
        local ok2, info = pcall(C_QuestLog.GetInfo, i)
        if ok2 and type(info) == "table" and not info.isHeader and info.questID then
            questLevels[info.questID] = tonumber(info.level)
        end
    end
end

-- ---------------------------------------------------------------------------
-- On-screen display
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "GrayQuestLevelFrame", UIParent)
frame:SetSize(170, 40)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")

local bg = frame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.45)

local storedText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
local questText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
local killText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")

-- The rows are re-anchored on every update because the Stored EXP line is
-- absent entirely when the debt is zero, rather than blank.
local ROW_HEIGHT, ROW_GAP, PADDING = 14, 2, 8

local function LayoutRows()
    local showStored = StoredXP() > 0

    storedText:ClearAllPoints()
    questText:ClearAllPoints()
    killText:ClearAllPoints()

    if showStored then
        storedText:Show()
        storedText:SetPoint("TOP", frame, "TOP", 0, -4)
        questText:SetPoint("TOP", storedText, "BOTTOM", 0, -ROW_GAP)
    else
        storedText:Hide()
        questText:SetPoint("TOP", frame, "TOP", 0, -4)
    end
    killText:SetPoint("TOP", questText, "BOTTOM", 0, -ROW_GAP)

    local rows = showStored and 3 or 2
    frame:SetHeight(PADDING + rows * ROW_HEIGHT + (rows - 1) * ROW_GAP)
end

local function ApplyPosition()
    frame:ClearAllPoints()
    local p = GrayQuestLevelCharDB.pos
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
end

frame:SetScript("OnDragStart", function(self)
    if not GrayQuestLevelDB.locked then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    GrayQuestLevelCharDB.pos = { point, relPoint, x, y }
    GrayQuestLevelCharDB.posMigrated = true
end)

frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Gray Quest Level")
    GameTooltip:AddLine("Quests at the green number or above give normal XP.", 1, 1, 1, true)
    GameTooltip:AddLine("Quests at the gray number or below are gray.", 1, 1, 1, true)
    local kills, remaining, gain = ComputeKills()
    if kills and gain then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(("Last XP gain: %d  |  %d XP to go"):format(gain, remaining), 1, 1, 1)
    end
    GameTooltip:AddLine("Drag to move  |  /gql lock", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function Update()
    -- Line 0: the stored-EXP debt, shown only when there is one.
    local stored = StoredXP()
    if stored > 0 then
        storedText:SetText(("Stored EXP: |cffffd100%d|r%s")
            :format(stored, Grinding() and "  |cff40c040(grinding)|r" or ""))
    end

    -- Line 1: quest levels
    local ok, _, lowestGreen, highestGray = pcall(Compute)
    if not ok or not lowestGreen then
        questText:SetText("|cffff5555Gray level: unavailable|r")
    elseif highestGray < 1 then
        questText:SetText("|cff40c040Green: all|r  |cff808080-|r  |cff9d9d9dno gray yet|r")
    else
        questText:SetText(("|cff40c040Green %d+|r  |cff808080-|r  |cff9d9d9dGray %d-|r")
            :format(lowestGreen, highestGray))
    end

    -- Line 2: kills to level. When `kills` is nil the second return is the
    -- reason string rather than an XP amount.
    local ok2, kills, reason = pcall(ComputeKills)
    if not ok2 then
        killText:SetText("|cff808080Kills to level: ?|r")
    elseif kills then
        killText:SetText(("Kills to level: |cffffd100%d|r"):format(kills))
    else
        if reason == "max level" then
            killText:SetText("|cff808080Max level|r")
        elseif reason == "xp off" then
            killText:SetText("|cff808080XP gain off|r")
        else
            killText:SetText("|cff808080Kills to level: ?|r")
        end
    end

    LayoutRows()

    local widest = math.max(questText:GetStringWidth(), killText:GetStringWidth())
    if stored > 0 then widest = math.max(widest, storedText:GetStringWidth()) end
    frame:SetWidth(math.max(140, widest + 20))
end

-- ---------------------------------------------------------------------------
-- Options panel: Esc -> Options -> AddOns -> Gray Quest Level
-- ---------------------------------------------------------------------------
-- Entirely optional. `/gql chat` does the same job with no UI APIs at all, so
-- every step here is allowed to fail: a build without these APIs just gets no
-- panel. Blizzard moved addon options to Settings.* in 10.0 and replaced
-- UIDropDownMenu with Blizzard_Menu in 11.0, so both dropdowns are attempted.

local optionsCategory

local function SafeCreateFrame(...)
    local ok, f = pcall(CreateFrame, ...)
    if ok then return f end
end

-- 11.0+ : a DropdownButton whose menu is described by SetupMenu.
local function SetupModernDropdown(dd)
    if type(dd.SetupMenu) ~= "function" then return false end
    return (pcall(dd.SetupMenu, dd, function(_, root)
        root:CreateRadio("Default chat window",
            function() return GrayQuestLevelCharDB.chatFrame == nil end,
            function() SetChatFrame(nil) end)
        for _, w in ipairs(ChatWindows()) do
            local index = w.index -- captured per entry, not per loop
            root:CreateRadio(w.name,
                function() return GrayQuestLevelCharDB.chatFrame == index end,
                function() SetChatFrame(index) end)
        end
    end))
end

-- Pre-11.0 fallback.
local function SetupLegacyDropdown(dd)
    if type(UIDropDownMenu_Initialize) ~= "function" then return false end
    local ok = pcall(UIDropDownMenu_Initialize, dd, function()
        UIDropDownMenu_AddButton({
            text = "Default chat window",
            checked = GrayQuestLevelCharDB.chatFrame == nil,
            func = function() SetChatFrame(nil) end,
        })
        for _, w in ipairs(ChatWindows()) do
            local index = w.index
            UIDropDownMenu_AddButton({
                text = w.name,
                checked = GrayQuestLevelCharDB.chatFrame == index,
                func = function() SetChatFrame(index) end,
            })
        end
    end)
    if ok then pcall(UIDropDownMenu_SetWidth, dd, 160) end
    return ok
end

local function BuildOptions()
    if optionsCategory then return true end
    if type(Settings) ~= "table"
        or type(Settings.RegisterCanvasLayoutCategory) ~= "function"
        or type(Settings.RegisterAddOnCategory) ~= "function" then
        return false
    end

    local panel = SafeCreateFrame("Frame")
    if not panel then return false end
    panel.name = "Gray Quest Level"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Gray Quest Level")

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    note:SetText("Which chat window this addon prints to. Saved per character.")

    local dd = SafeCreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    local wired = dd and SetupModernDropdown(dd)
    if not wired then
        dd = SafeCreateFrame("Frame", "GrayQuestLevelChatDropdown", panel, "UIDropDownMenuTemplate")
        wired = dd and SetupLegacyDropdown(dd)
    end
    if dd then
        pcall(dd.SetPoint, dd, "TOPLEFT", note, "BOTTOMLEFT", -16, -16)
        pcall(dd.SetSize, dd, 200, 32)
    end

    local shot = SafeCreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    if shot then
        pcall(shot.SetPoint, shot, "TOPLEFT", dd or note, "BOTTOMLEFT", dd and 12 or -4, -16)
        pcall(shot.SetScript, shot, "OnClick", function(self)
            SetScreenshotOnLevel(self:GetChecked())
        end)
        -- Own label rather than the template's: its text key has moved between builds.
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", shot, "RIGHT", 4, 0)
        label:SetText("Take a screenshot on level-up (saved per character)")
    end

    -- Keep the controls in step with the settings, however they were changed --
    -- the slash commands bypass the panel entirely.
    refreshOptions = function()
        if shot then pcall(shot.SetChecked, shot, ScreenshotOnLevel()) end
        if not (dd and wired) then return end
        local label = ChatTargetName()
        if not pcall(dd.SetDefaultText, dd, label) then
            pcall(UIDropDownMenu_SetText, dd, label)
        end
    end

    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
    if not ok or not category then return false end
    if not pcall(Settings.RegisterAddOnCategory, category) then return false end

    optionsCategory = category
    refreshOptions()
    return true
end

local function OpenOptions()
    if not optionsCategory then return false end
    if type(Settings) == "table" and type(Settings.OpenToCategory) == "function" then
        if pcall(Settings.OpenToCategory, optionsCategory) then return true end
        local ok, id = pcall(optionsCategory.GetID, optionsCategory)
        if ok and pcall(Settings.OpenToCategory, id) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- Grinding pays off the debt. Quest XP deliberately does not: the hand-in is
-- what created the debt, so letting its own XP settle it would cancel out.
local function ApplyGrind(gain)
    if not gain or gain <= 0 then return end
    if pendingQuestXP then
        pendingQuestXP = nil
        return
    end
    if not Grinding() then return end

    local before = StoredXP()
    if before <= 0 then return end

    local after = SetStoredXP(before - gain)
    if after == 0 then
        Say("|cff40c040Gray Quest Level|r: stored EXP cleared - debt paid off.")
    end
end

local function OnQuestTurnedIn(questID, xpReward)
    xpReward = tonumber(xpReward) or 0
    -- Only claim the next gain is quest XP if the quest actually paid some;
    -- otherwise the flag would linger and swallow the next kill.
    if xpReward > 0 then pendingQuestXP = true end

    local level = questID and questLevels[questID]
    GrayQuestLevelCharDB.lastQuestXP = xpReward
    GrayQuestLevelCharDB.lastQuestLevel = level
    GrayQuestLevelCharDB.lastQuestID = questID
    GrayQuestLevelCharDB.lastQuestSettled = false
    if questID then questLevels[questID] = nil end

    -- Only gray quests are reduced, so only they owe anything.
    local _, _, highestGray = Compute()
    if not level or not highestGray or level > highestGray then return end

    -- Missing from QuestXP.lua: say so, with the ID and what it paid, so the
    -- entry can be added. This is the only prompt the addon ever gives.
    local full = KnownQuestXP(questID)
    if not full then
        Say(("|cff40c040Gray Quest Level|r: gray quest |cffffd100%s|r (level %d) paid %d XP"
            .. " - not in QuestXP.lua.")
            :format(tostring(questID), level, xpReward))
        Say(("  Add |cffffd100[%s] = <full XP>|r to QuestXP.lua (then /reload),"
            .. " or /gql quest <full XP> to count it now."):format(tostring(questID)))
        return
    end

    GrayQuestLevelCharDB.lastQuestSettled = true
    local owed = full - xpReward
    if owed <= 0 then
        Say(("|cff40c040Gray Quest Level|r: gray quest paid %d of its %d value - nothing owed.")
            :format(xpReward, full))
        return
    end

    local after = SetStoredXP(StoredXP() + owed)
    Say(("|cff40c040Gray Quest Level|r: gray quest (level %d): %d full - %d paid = |cffffd100%d|r stored.")
        :format(level, full, xpReward, owed))
    Say(("  Stored EXP now %d."):format(after))
end

-- PLAYER_LEVEL_UP and PLAYER_LEVEL_CHANGED both fire for one ding, so the level
-- already captured is remembered and the second event is ignored.
local lastShotLevel

local function LevelUpScreenshot(newLevel)
    newLevel = tonumber(newLevel)
    if not newLevel or not ScreenshotOnLevel() or type(Screenshot) ~= "function" then return end
    if lastShotLevel and newLevel <= lastShotLevel then return end
    lastShotLevel = newLevel
    -- A moment's delay so the level-up banner is in the shot.
    C_Timer.After(1, function() pcall(Screenshot) end)
end

local function SafeRegister(event)
    pcall(frame.RegisterEvent, frame, event) -- unknown events throw on this client
end

SafeRegister("PLAYER_ENTERING_WORLD")
SafeRegister("PLAYER_LEVEL_UP")
SafeRegister("PLAYER_LEVEL_CHANGED")
SafeRegister("UNIT_LEVEL")
SafeRegister("PLAYER_XP_UPDATE")
SafeRegister("DISABLE_XP_GAIN")
SafeRegister("ENABLE_XP_GAIN")
SafeRegister("QUEST_TURNED_IN")
SafeRegister("QUEST_ACCEPTED")

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_ENTERING_WORLD" then
        ApplyPosition()
        BuildOptions() -- first call registers it; later ones are a no-op
        CacheQuestLevels()
        SampleXP() -- establish the baseline; no gain recorded from this one
        Update()
    elseif event == "PLAYER_XP_UPDATE" then
        ApplyGrind(SampleXP())
        Update()
    elseif event == "QUEST_TURNED_IN" then
        pcall(OnQuestTurnedIn, arg1, arg2)
        Update()
    elseif event == "QUEST_ACCEPTED" then
        CacheQuestLevels()
    elseif event == "PLAYER_LEVEL_UP" or event == "PLAYER_LEVEL_CHANGED" then
        pendingLevelUp = true
        -- PLAYER_LEVEL_UP carries the new level; PLAYER_LEVEL_CHANGED is (old, new)
        -- and also fires on a drop, which is no occasion for a picture.
        if event == "PLAYER_LEVEL_UP" then
            pcall(LevelUpScreenshot, arg1)
        else
            local ok, up = pcall(function() return arg2 > arg1 end)
            if ok and up then pcall(LevelUpScreenshot, arg2) end
        end
        C_Timer.After(0.5, function() ApplyGrind(SampleXP()); Update() end)
    elseif event == "UNIT_LEVEL" then
        if arg1 == "player" then C_Timer.After(0.5, Update) end
    else
        Update()
    end
end)

-- Belt and braces: the level events above are only as reliable as this build's
-- event list, and an event that doesn't exist here fails to register silently
-- (SafeRegister swallows the throw). A cheap poll means the quest levels follow
-- your character within a couple of seconds no matter which events survived.
local sinceCheck, lastSeenLevel = 0, nil
frame:SetScript("OnUpdate", function(_, elapsed)
    sinceCheck = sinceCheck + (elapsed or 0)
    if sinceCheck < 2 then return end
    sinceCheck = 0
    local level = PlayerLevel()
    if level ~= lastSeenLevel then
        lastSeenLevel = level
        Update()
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_GRAYQUESTLEVEL1 = "/gql"
SlashCmdList.GRAYQUESTLEVEL = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")

    if cmd == "lock" then
        GrayQuestLevelDB.locked = not GrayQuestLevelDB.locked
        Say("|cff40c040Gray Quest Level|r: " .. (GrayQuestLevelDB.locked and "locked" or "unlocked"))
    elseif cmd == "reset" then
        GrayQuestLevelCharDB.pos = nil
        GrayQuestLevelCharDB.posMigrated = true -- don't re-seed from the old account value
        ApplyPosition()
    elseif cmd == "hide" then
        frame:Hide()
    elseif cmd == "show" then
        frame:Show(); Update()
    elseif cmd == "calibrate" then
        -- "the highest gray level I can actually see in my log is N"
        local observed = tonumber(rest)
        if rest == "off" or rest == "reset" then
            GrayQuestLevelDB.offset = 0
            Update()
            Say("|cff40c040Gray Quest Level|r: offset cleared.")
        elseif not observed then
            Say("|cff40c040Gray Quest Level|r: usage /gql calibrate <highest gray level you see>,"
                .. " or /gql calibrate off")
        else
            GrayQuestLevelDB.offset = 0
            local _, _, computed, source = Compute()
            if not computed then
                Say("|cff40c040Gray Quest Level|r: nothing to calibrate against on this client.")
            elseif source == "colors" and computed ~= observed then
                -- Don't paper over this. The colour API is what the quest log
                -- colours with, so a disagreement is a real finding, not
                -- something to hide behind a fudge factor.
                Say(("|cff40c040Gray Quest Level|r: the game's own colour API says gray %d, you see gray %d.")
                    :format(computed, observed))
                Say("  That shouldn't happen - please report it. Offset NOT applied.")
            elseif source == "colors" then
                Say("|cff40c040Gray Quest Level|r: already matches your quest log, nothing to correct.")
            else
                GrayQuestLevelDB.offset = observed - computed
                Update()
                Say(("|cff40c040Gray Quest Level|r: %s calibrated, offset %+d.")
                    :format(tostring(source), GrayQuestLevelDB.offset))
            end
        end
    elseif cmd == "exp" then
        -- Signed: /gql exp 100 adds, /gql exp -767 removes.
        local n = tonumber(rest)
        if rest == "" then
            Say(("|cff40c040Gray Quest Level|r: stored EXP %d, grinding %s.")
                :format(StoredXP(), Grinding() and "on" or "off"))
        elseif not n then
            Say("|cff40c040Gray Quest Level|r: usage /gql exp <+/-amount>")
        else
            local before = StoredXP()
            local after = SetStoredXP(before + n)
            Update()
            Say(("|cff40c040Gray Quest Level|r: stored EXP %d %+d -> |cffffd100%d|r.")
                :format(before, n, after))
            if after == 0 and before + n < 0 then
                Say("  (clamped at zero)")
            end
        end
    elseif cmd == "quest" then
        -- "the quest I just handed in was really worth <n>" -- store the shortfall.
        local full = tonumber(rest)
        local awarded = tonumber(GrayQuestLevelCharDB.lastQuestXP)
        if not full then
            Say("|cff40c040Gray Quest Level|r: usage /gql quest <full XP the quest is worth>")
            if awarded then
                Say(("  last hand-in paid %d XP%s"):format(awarded,
                    GrayQuestLevelCharDB.lastQuestLevel
                        and (" (level %d)"):format(GrayQuestLevelCharDB.lastQuestLevel) or ""))
            end
        elseif not awarded then
            Say("|cff40c040Gray Quest Level|r: no quest hand-in recorded yet - use /gql exp <n> instead.")
        elseif GrayQuestLevelCharDB.lastQuestSettled then
            -- The value was already known, so the debt is already stored.
            -- Counting it again here would double it.
            Say("|cff40c040Gray Quest Level|r: that hand-in was already settled from the quest-XP table.")
            Say("  Use /gql exp <n> if the stored amount needs correcting.")
        elseif full - awarded <= 0 then
            Say(("|cff40c040Gray Quest Level|r: %d is not more than the %d already paid - nothing owed.")
                :format(full, awarded))
        else
            local owed = full - awarded
            local after = SetStoredXP(StoredXP() + owed)
            GrayQuestLevelCharDB.lastQuestSettled = true
            Update()
            Say(("|cff40c040Gray Quest Level|r: %d full - %d paid = |cffffd100%d|r stored (total %d).")
                :format(full, awarded, owed, after))
            -- Counted for this hand-in only; nothing is written back.
            if GrayQuestLevelCharDB.lastQuestID then
                Say(("  Add |cffffd100[%s] = %d|r to QuestXP.lua to keep it.")
                    :format(tostring(GrayQuestLevelCharDB.lastQuestID), full))
            end
        end
    elseif cmd == "xpdb" then
        if rest == "" then
            Say(("|cff40c040Gray Quest Level|r: QuestXP.lua holds |cffffd100%d|r quest values.")
                :format(CountQuestXP()))
            Say("  /gql xpdb <questID> to look one up. Edits to the file need a /reload.")
        else
            local id = tonumber(rest)
            local full = KnownQuestXP(id)
            if not id then
                Say("|cff40c040Gray Quest Level|r: usage /gql xpdb [questID]")
            elseif full then
                Say(("|cff40c040Gray Quest Level|r: quest %d is worth %d XP."):format(id, full))
            else
                Say(("|cff40c040Gray Quest Level|r: quest %d is not in QuestXP.lua."):format(id))
            end
        end
    elseif cmd == "grind" then
        GrayQuestLevelCharDB.grinding = not Grinding()
        Update()
        if Grinding() then
            Say(("|cff40c040Gray Quest Level|r: grinding ON - XP now pays off the %d stored.")
                :format(StoredXP()))
        else
            Say("|cff40c040Gray Quest Level|r: grinding OFF - stored EXP frozen.")
        end
    elseif cmd == "chat" then
        local windows = ChatWindows()
        if rest == "default" or rest == "reset" then
            SetChatFrame(nil)
            Say("|cff40c040Gray Quest Level|r: printing to the default chat window.")
        elseif rest == "" then
            Say(("|cff40c040Gray Quest Level|r: printing to |cffffd100%s|r. Windows:")
                :format(ChatTargetName()))
            if #windows == 0 then
                Say("  none readable on this client - the default window is all there is.")
            end
            for _, w in ipairs(windows) do
                Say(("  %d: %s%s"):format(w.index, w.name, w.open and "" or " (closed)"))
            end
            Say("  /gql chat <number> | /gql chat default")
        elseif not tonumber(rest) then
            Say("|cff40c040Gray Quest Level|r: usage /gql chat <number> | default")
        elseif not ChatFrameFor(rest) then
            Say(("|cff40c040Gray Quest Level|r: there is no chat window %s."):format(rest))
        else
            SetChatFrame(rest)
            -- Said in the new window, so it doubles as proof the routing works.
            Say(("|cff40c040Gray Quest Level|r: now printing here (%s)."):format(ChatTargetName()))
        end
    elseif cmd == "screenshot" then
        SetScreenshotOnLevel(not ScreenshotOnLevel())
        Say("|cff40c040Gray Quest Level|r: screenshot on level-up "
            .. (ScreenshotOnLevel() and "ON" or "OFF") .. " for this character.")
    elseif cmd == "options" or cmd == "config" then
        if not OpenOptions() then
            Say("|cff40c040Gray Quest Level|r: no options panel on this client - use /gql chat.")
        end
    elseif cmd == "source" then
        if rest == "auto" or rest == "table" or rest == "range" or rest == "colors" then
            GrayQuestLevelDB.source = rest
            Update()
            local _, lowestGreen, highestGray = Compute()
            Say(("|cff40c040Gray Quest Level|r: source %s -> green %s+, gray %s-")
                :format(rest, tostring(lowestGreen), tostring(highestGray)))
        else
            Say("|cff40c040Gray Quest Level|r: usage /gql source auto | table | range | colors")
            Say(("  currently: %s"):format(tostring(GrayQuestLevelDB.source or "auto")))
        end
    elseif cmd == "debug" then
        local level = PlayerLevel()
        Say(("|cff40c040Gray Quest Level|r debug - player level %d"):format(level))
        Say(("  UnitLevel: %s | UnitEffectiveLevel: %s"):format(
            tostring(SafeNumber(UnitLevel, "player")),
            tostring(SafeNumber(UnitEffectiveLevel, "player"))))
        for i = 1, #RANGE_FUNCS do
            local name = RANGE_FUNCS[i]
            Say(("  %s: %s"):format(name,
                type(_G[name]) ~= "function" and "absent" or tostring(SafeNumber(_G[name], "player"))))
        end
        Say(("  GetQuestDifficultyColor: %s"):format(
            type(GetQuestDifficultyColor) == "function" and "present" or "absent"))
        local _, lowestGreen, highestGray, source, byTable, byRange, byColors = Compute()
        Say(("  table says gray %s (green %s+)"):format(
            tostring(byTable), byTable and tostring(byTable + 1) or "?"))
        Say(("  range says gray %s (green %s+)"):format(
            tostring(byRange), byRange and tostring(byRange + 1) or "?"))
        Say(("  colors say gray %s (green %s+)"):format(
            tostring(byColors), byColors and tostring(byColors + 1) or "?"))
        if (byRange and byRange ~= byTable) or (byColors and byColors ~= byTable) then
            Say("  |cffff8800they DISAGREE - whichever matches your quest log is the right one|r")
            Say("  |cffff8800switch with /gql source table | range | colors|r")
        end
        Say(("  QuestXP.lua entries: %d"):format(CountQuestXP()))
        Say(("  chat: %s | options panel: %s"):format(
            ChatTargetName(), optionsCategory and "registered" or "unavailable"))
        Say(("  offset: %d | preference: %s"):format(
            tonumber(GrayQuestLevelDB.offset) or 0, tostring(GrayQuestLevelDB.source or "auto")))
        Say(("  using %s -> green %s+, gray %s-"):format(
            tostring(source), tostring(lowestGreen), tostring(highestGray)))
    elseif cmd == "xp" then
        local n = tonumber(rest)
        if n and n > 0 then
            lastGain = n
            GrayQuestLevelDB.lastGain = n
            Update()
            Say(("|cff40c040Gray Quest Level|r: using %d XP per kill until the next XP gain."):format(n))
        else
            Say("|cff40c040Gray Quest Level|r: usage /gql xp <number>")
        end
    else
        local level, lowestGreen, highestGray = Compute()
        if lowestGreen and highestGray >= 1 then
            Say(("|cff40c040Gray Quest Level|r: you are %d, green down to %d, gray at %d and below.")
                :format(level, lowestGreen, highestGray))
        elseif lowestGreen then
            Say(("|cff40c040Gray Quest Level|r: you are %d, nothing is gray yet."):format(level))
        else
            Say("|cff40c040Gray Quest Level|r: couldn't read the quest range on this client.")
        end

        local kills, remaining, gain = ComputeKills()
        if kills then
            Say(("  %d XP to go, last gain %d, about %d kills."):format(remaining, gain, kills))
        elseif remaining == "max level" then
            Say("  At max level.")
        elseif remaining == "xp off" then
            Say("  XP gain is turned off for this character.")
        elseif remaining == "no xp data" then
            Say("  This client won't hand over the XP values.")
        else
            Say("  No XP gain seen yet this session - kill something, or use /gql xp <number>.")
        end
        if StoredXP() > 0 or Grinding() then
            Say(("  Stored EXP: %d, grinding %s."):format(StoredXP(), Grinding() and "ON" or "off"))
        end
        Say("  /gql grind | exp <+/-n> | quest <full> | lock | reset | hide | show")
        Say("  /gql xp <n> | calibrate <n> | source <s> | chat <n> | xpdb | screenshot | options | debug")
    end
end
