-- Offline regression tests for GrayQuestLevel.
--
--   lua5.1 scripts/test.lua          (exits non-zero if anything fails)
--
-- The WoW API cannot be reached outside the game, so this stubs the parts the
-- addon touches and loads the real GrayQuestLevel.lua against them. It covers
-- arithmetic and state transitions: gray-level bands, the stored-EXP debt, and
-- where things are saved.
--
-- It proves nothing about whether the frame actually draws, whether the events
-- exist on this build, or whether the client agrees with the gray-level table.
-- A green run is not a substitute for loading the addon and typing /reload.
--
-- UnitQuestTrivialLevelRange is stubbed as a flat 5 on purpose: that is what
-- the Forever beta really returns, and the `range` source being wrong at
-- level 20 is one of the things under test.

-- This file deliberately defines the globals it is stubbing, and uses the parts
-- of the Lua stdlib (io, os, loadfile) that the WoW sandbox does not have, so
-- the language server's undefined-global check cannot say anything useful here.
---@diagnostic disable: undefined-global

local SCRIPT_DIR = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local ADDON_FILE = SCRIPT_DIR .. "/../GrayQuestLevel.lua"

local out = io.write

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

local checks, failures = 0, 0

local function check(label, got, want)
    checks = checks + 1
    if got == want then
        out(("  ok    %s\n"):format(label))
    else
        failures = failures + 1
        out(("  FAIL  %s\n          got:  %s\n          want: %s\n")
            :format(label, tostring(got), tostring(want)))
    end
end

local function section(name)
    out(("\n%s\n"):format(name))
end

-- Font strings and chat lines keep their colour escapes; strip before matching.
local function plain(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- ---------------------------------------------------------------------------
-- Stubbed client
-- ---------------------------------------------------------------------------

local playerLevel, currentXP = 20, 1000
-- The single quest sitting in the stubbed log; sections set these directly.
local questLogID, questLogLevel = 437, 14
local questLogTitle
local storedShown = false
local fontStrings = {}
local theFrame

-- Any method we did not bother stubbing is a no-op returning the widget.
local function widget(extra)
    return setmetatable(extra or {}, {
        __index = function(t) return function() return t end end,
    })
end

local function fontstring()
    local index = #fontStrings + 1
    local fs = widget({
        text = "",
        SetText = function(self, s) self.text = s end,
        GetStringWidth = function() return 100 end,
        -- storedText is created first; the others never hide.
        Show = function(self) if index == 1 then storedShown = true end return self end,
        Hide = function(self) if index == 1 then storedShown = false end return self end,
    })
    fontStrings[index] = fs
    return fs
end

UIParent = widget()
GameTooltip = widget()
GameFontHighlight = "GameFontHighlight"
SlashCmdList = {}
C_Timer = { After = function(_, fn) if fn then fn() end end }

-- Entries the options dropdown offered, captured by the stub below.
local menuEntries = {}

local function dropdownStub()
    return widget({
        SetupMenu = function(self, generator)
            menuEntries = {}
            generator(self, {
                CreateRadio = function(_, text, isSelected, setSelected)
                    menuEntries[#menuEntries + 1] =
                        { text = text, isSelected = isSelected, setSelected = setSelected }
                end,
            })
            return self
        end,
        SetDefaultText = function(self, t) self.label = t return self end,
    })
end

-- The options panel's screenshot checkbox, captured so tests can click it.
local checkbox

local function checkboxStub()
    checkbox = widget({
        scripts = {},
        SetScript = function(self, k, fn) self.scripts[k] = fn end,
        SetChecked = function(self, on) self.checked = on and true or false end,
        GetChecked = function(self) return self.checked end,
    })
    return checkbox
end

function CreateFrame(_, _, _, template)
    if template == "WowStyle1DropdownTemplate" then return dropdownStub() end
    if template == "UICheckButtonTemplate" then return checkboxStub() end

    local f = widget({
        scripts = {},
        SetScript = function(self, k, fn) self.scripts[k] = fn end,
        SetHeight = function(self, h) self.height = h end,
        CreateTexture = function() return widget() end,
        CreateFontString = function() return fontstring() end,
        GetPoint = function() return "CENTER", nil, "CENTER", 10, 20 end,
    })
    -- The options panel also creates a Frame; only the first one is the addon's.
    if not theFrame then theFrame = f end
    return f
end

function UnitLevel() return playerLevel end
function UnitEffectiveLevel() return playerLevel end
function UnitQuestTrivialLevelRange() return 5 end -- the broken flat value
function UnitXP() return currentXP end
function UnitXPMax() return 50000 end
function GetMaxPlayerLevel() return 60 end

local screenshots = 0
function Screenshot() screenshots = screenshots + 1 end

QuestDifficultyColors = {
    trivial = { r = 0.61, g = 0.61, b = 0.61 },
    standard = { r = 0.25, g = 0.75, b = 0.25 },
}

-- Retail's comparison (`-levelDiff <= range`) against the flat range, which is
-- why `colors` lands one below `range` rather than agreeing with either.
function GetQuestDifficultyColor(level)
    if -(level - playerLevel) <= 5 then return QuestDifficultyColors.standard end
    return QuestDifficultyColors.trivial
end

C_QuestLog = {
    GetNumQuestLogEntries = function() return 1 end,
    GetInfo = function(i)
        if i ~= 1 then return nil end
        return { questID = questLogID, level = questLogLevel, title = questLogTitle, isHeader = false }
    end,
}

-- Three chat windows, each collecting whatever gets routed to it.
local chatWindowNames = { "General", "Combat Log", "Loot" }
local chatFrames = {}
NUM_CHAT_WINDOWS = #chatWindowNames

for i, name in ipairs(chatWindowNames) do
    chatFrames[i] = widget({
        name = name,
        messages = {},
        AddMessage = function(self, m) self.messages[#self.messages + 1] = plain(m) end,
    })
    _G["ChatFrame" .. i] = chatFrames[i]
end

-- name, fontSize, r, g, b, alpha, shown, locked, docked
function GetChatWindowInfo(i)
    return chatWindowNames[i] or "", 12, 1, 1, 1, 1, true, false, true
end

-- Chat goes into a buffer so tests can assert on what the addon said.
local chat = {}
local lastPrinted -- as sent, colour codes and all; `chat` holds it stripped

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    lastPrinted = table.concat(parts, " ")
    chat[#chat + 1] = (lastPrinted:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- ---------------------------------------------------------------------------
-- Load the addon. The account-wide position is pre-seeded so the migration to
-- per-character positions, which runs at file scope, can be observed.
-- ---------------------------------------------------------------------------

GrayQuestLevelDB = { pos = { "LEFT", "LEFT", 42, -7 } }

-- Both files the .toc lists, in .toc order.
for _, path in ipairs({ SCRIPT_DIR .. "/../QuestXP.lua", ADDON_FILE }) do
    local chunk, err = loadfile(path)
    if not chunk then
        out(("cannot load %s: %s\n"):format(path, tostring(err)))
        os.exit(1)
    end
    chunk("GrayQuestLevel")
end

local storedText, questText = fontStrings[1], fontStrings[2]

-- The real QuestXP.lua grows as zones are imported, so the behavioural tests
-- run against fixtures instead of its contents. The shipped table is kept aside
-- and checked for shape only.
local shippedQuestXP = GrayQuestLevelQuestXP
GrayQuestLevelQuestXP = {}

-- ---------------------------------------------------------------------------
-- Helpers that drive the addon the way the client would
-- ---------------------------------------------------------------------------

local function fire(event, a, b)
    chat = {}
    theFrame.scripts.OnEvent(theFrame, event, a, b)
end

local function run(cmd)
    chat = {}
    SlashCmdList.GRAYQUESTLEVEL(cmd)
end

local function refresh()
    fire("ENABLE_XP_GAIN") -- falls through to a plain Update()
end

-- The highest gray level the box is currently showing.
local function displayedGray()
    refresh()
    if questText.text:find("no gray yet") then return 0 end
    return tonumber(questText.text:match("Gray (%d+)%-"))
end

local function stored() return GrayQuestLevelCharDB.storedXP or 0 end

local function gainXP(amount)
    currentXP = currentXP + amount
    fire("PLAYER_XP_UPDATE")
end

local function chatMatches(pattern)
    for _, line in ipairs(chat) do
        if line:find(pattern) then return true end
    end
    return false
end

local function posOf(p)
    return p and ("%s/%s %d,%d"):format(p[1], p[2], p[3], p[4]) or "default"
end


fire("PLAYER_ENTERING_WORLD") -- XP baseline + quest level cache, as login does

-- ---------------------------------------------------------------------------
section("gray-level table (the default source)")
-- ---------------------------------------------------------------------------
-- The two bands confirmed against the real client, then the published formulas.
-- 8 and 20 are the measured readings; the rest guard the band boundaries.

local expected = {
    [1] = 0, [5] = 0,       -- nothing is trivial this early
    [6] = 1, [8] = 3,       -- 8 -> 3 was measured in game
    [9] = 4, [10] = 4,
    [19] = 13, [20] = 13,   -- 20 -> 13 was measured in game (level 14 still green)
    [21] = 14,              -- and 14 goes gray here, per Wowhead
    [39] = 31, [40] = 31,   -- the 6-39 / 40-59 bands meet
    [59] = 47, [60] = 51,   -- discontinuous at 60; that is how the tables read
}
for _, level in ipairs({ 1, 5, 6, 8, 9, 10, 19, 20, 21, 39, 40, 59, 60 }) do
    playerLevel = level
    check(("player %d -> gray %d"):format(level, expected[level]),
        displayedGray(), expected[level])
end

-- ---------------------------------------------------------------------------
section("the other two sources are wrong at level 20")
-- ---------------------------------------------------------------------------
-- Pinned so a future change to the source-selection logic cannot quietly make
-- one of these the default again.

playerLevel = 20
GrayQuestLevelDB.source = "range"
check("forced range says 15 (flat trivial range, missing floor(level/10))", displayedGray(), 15)
GrayQuestLevelDB.source = "colors"
check("forced colors says 14 (Retail's extra -1 on the same wrong range)", displayedGray(), 14)
GrayQuestLevelDB.source = nil
check("auto falls back to the table", displayedGray(), 13)

-- ---------------------------------------------------------------------------
section("stored EXP: manual adjustment")
-- ---------------------------------------------------------------------------

run("exp 500")
check("/gql exp 500 adds", stored(), 500)
run("exp -120")
check("/gql exp -120 subtracts", stored(), 380)
run("exp -10000")
check("cannot go negative", stored(), 0)
run("exp abc")
check("rejects non-numbers", chatMatches("usage /gql exp"), true)

-- ---------------------------------------------------------------------------
section("grind mode")
-- ---------------------------------------------------------------------------

run("exp 1000")
check("grinding starts off", GrayQuestLevelCharDB.grinding, nil)
gainXP(300)
check("XP does not touch the debt while grinding is off", stored(), 1000)

run("grind")
check("/gql grind toggles on", GrayQuestLevelCharDB.grinding, true)
gainXP(300)
check("XP now pays the debt down", stored(), 700)
gainXP(800)
check("overpaying clamps at zero", stored(), 0)
check("and says so", chatMatches("stored EXP cleared"), true)

run("grind")
check("/gql grind toggles back off", GrayQuestLevelCharDB.grinding, false)

-- ---------------------------------------------------------------------------
section("quest hand-in")
-- ---------------------------------------------------------------------------

run("grind") -- back on for the exclusion test below

questLogLevel = 14
fire("QUEST_ACCEPTED")
fire("QUEST_TURNED_IN", 437, 350)
check("a level-14 quest at player 20 is green, so no prompt", #chat, 0)

-- A different quest, so the green hand-in above (which learns 437's value)
-- cannot settle this one for us; this section is about the manual path.
questLogID, questLogLevel = 438, 10
fire("QUEST_ACCEPTED")
fire("QUEST_TURNED_IN", 438, 350)
check("a level-10 quest is gray, so the addon prompts", chatMatches("gray quest 438 %(level 10%) paid 350 XP"), true)
check("and records what it paid", GrayQuestLevelCharDB.lastQuestXP, 350)

run("quest 1050")
check("/gql quest 1050 stores 1050 - 350", stored(), 700)
run("quest 100")
check("a full value below what was paid owes nothing", stored(), 700)

-- The hand-in's own XP must not pay off the debt it just created.
gainXP(350)
check("quest XP is excluded from grinding", stored(), 700)
gainXP(200)
check("the next kill is not", stored(), 500)

-- ---------------------------------------------------------------------------
section("quest-XP table: shipped values, learning, and alts")
-- ---------------------------------------------------------------------------

check("QuestXP.lua loaded and defined the table", type(shippedQuestXP), "table")
check("nothing is ever written to saved variables", GrayQuestLevelDB.questXP, nil)

-- The real file is hand-edited and machine-appended, so check its shape: a bad
-- key or a stray string would break the arithmetic at a hand-in.
local badEntries, entryCount = {}, 0
for id, xp in pairs(shippedQuestXP or {}) do
    entryCount = entryCount + 1
    if type(id) ~= "number" or id ~= math.floor(id) or id <= 0
        or type(xp) ~= "number" or xp ~= math.floor(xp) or xp <= 0 then
        badEntries[#badEntries + 1] = tostring(id) .. "=" .. tostring(xp)
    end
end
check(("every one of the %d shipped entries is a positive integer pair"):format(entryCount),
    #badEntries == 0 and "clean" or table.concat(badEntries, ", "), "clean")

run("exp -100000") -- start from no debt
GrayQuestLevelQuestXP = { [500] = 900 }

-- A gray quest that IS in the file: calculated and stored, no questions asked.
questLogID, questLogLevel = 500, 10
fire("QUEST_ACCEPTED")
fire("QUEST_TURNED_IN", 500, 300)
check("a known gray quest is settled automatically", stored(), 600)
check("showing the arithmetic", chatMatches("900 full %- 300 paid = 600 stored"), true)
check("and no prompt to add anything", chatMatches("not in QuestXP.lua"), false)
check("still nothing written to saved variables", GrayQuestLevelDB.questXP, nil)

-- Handing it in again must not be double-counted via /gql quest.
run("quest 900")
check("/gql quest refuses an already-settled hand-in", stored(), 600)
check("and explains why", chatMatches("already settled"), true)

-- A gray quest that is NOT in the file: the one case that prompts.
run("exp -100000")
questLogID, questLogTitle = 503, "The Dead Fields"
fire("QUEST_ACCEPTED")
fire("QUEST_TURNED_IN", 503, 250)
check("a missing gray quest is reported", chatMatches("gray quest 503 %(level 10%) paid 250 XP"), true)
check("naming the file", chatMatches("not in QuestXP.lua"), true)
check("with a paste-ready line", chatMatches("%[503%] = <full XP>"), true)
check("and no debt guessed at", stored(), 0)

-- The manual path still works, and tells you what to put in the file.
run("quest 1000")
check("/gql quest stores the difference", stored(), 750)
check("and prints the entry bare, ready to paste", lastPrinted, "[503] = 1000, -- The Dead Fields (10)")
local pasted = loadstring("return {\n" .. lastPrinted .. "\n}")
check("which is valid in the table", pasted and pasted()[503], 1000)
check("without writing it anywhere", GrayQuestLevelDB.questXP, nil)

-- A hand-in the log never showed us has no title or level, but is still pasteable.
run("exp -100000")
questLogTitle = nil
fire("QUEST_TURNED_IN", 504, 250)
run("quest 1000")
check("an unseen quest still gets an entry, minus the comment", lastPrinted, "[504] = 1000,")
run("exp -100000")

-- Non-gray hand-ins are silent and do nothing at all.
run("exp -100000")
questLogID, questLogLevel = 501, 19 -- green at player 20 (gray is 13-)
fire("QUEST_ACCEPTED")
fire("QUEST_TURNED_IN", 501, 1200)
check("a green hand-in says nothing", #chat, 0)
check("and creates no debt", stored(), 0)
check("and learns nothing", GrayQuestLevelDB.questXP, nil)

-- Lookups.
run("xpdb 500")
check("/gql xpdb <id> finds a known quest", chatMatches("quest 500 is worth 900 XP"), true)
run("xpdb 999")
check("and reports a missing one", chatMatches("quest 999 is not in QuestXP.lua"), true)
run("xpdb")
check("/gql xpdb counts the file", chatMatches("holds 1 quest values"), true)

-- ---------------------------------------------------------------------------
section("the stored-EXP row appears and disappears")
-- ---------------------------------------------------------------------------

run("exp 500") -- this section owns its own debt, not a leftover one
refresh()
check("row is shown while a debt exists", storedShown, true)
check("three rows are 54px tall", theFrame.height, 54)
check("the row shows the amount", plain(storedText.text):find("Stored EXP: 500") ~= nil, true)

run("exp -100000")
refresh()
check("row is hidden at zero", storedShown, false)
check("two rows are 38px tall", theFrame.height, 38)

-- ---------------------------------------------------------------------------
section("chat output routing")
-- ---------------------------------------------------------------------------

local function windowLines(i) return #chatFrames[i].messages end
local function clearWindows()
    for _, f in ipairs(chatFrames) do f.messages = {} end
end

clearWindows()
run("exp 5")
check("by default output goes to the default window, not a specific one", #chat > 0, true)
check("and no chat frame received it directly", windowLines(1) + windowLines(2) + windowLines(3), 0)

run("chat")
check("/gql chat lists the windows it found", chatMatches("2: Combat Log"), true)
check("and names the current target", chatMatches("printing to default"), true)

clearWindows()
run("chat 2")
check("/gql chat 2 is stored per character", GrayQuestLevelCharDB.chatFrame, 2)
check("the confirmation lands in the chosen window", windowLines(2), 1)
check("and not in the default one", #chat, 0)

clearWindows()
run("exp 5")
check("subsequent output follows the setting", windowLines(2) > 0, true)
check("window 1 is untouched", windowLines(1), 0)

run("chat 99")
check("a window that does not exist is rejected", GrayQuestLevelCharDB.chatFrame, 2)
check("with a message", chatMatches("no chat window 99") or
    plain(table.concat(chatFrames[2].messages, "\n")):find("no chat window 99") ~= nil, true)

run("chat abc")
check("so is a non-number", GrayQuestLevelCharDB.chatFrame, 2)

-- A chosen window can be closed by the user between sessions.
local saved = _G.ChatFrame2
_G.ChatFrame2 = nil
clearWindows()
run("exp 5")
check("output falls back to default if the chosen window has gone", #chat > 0, true)
_G.ChatFrame2 = saved

run("chat default")
check("/gql chat default clears the setting", GrayQuestLevelCharDB.chatFrame, nil)

-- ---------------------------------------------------------------------------
section("options panel")
-- ---------------------------------------------------------------------------
-- The panel itself cannot be verified offline -- real templates and a real
-- Settings implementation are needed for that. What is checked here is the
-- logic around it: that a client without Settings.* loses nothing but the
-- panel, and that the menu it generates offers the right entries.

run("debug")
check("no panel registered when Settings.* is missing", chatMatches("options panel: unavailable"), true)
run("options")
check("/gql options says so rather than erroring", chatMatches("no options panel on this client"), true)

local addonCategories = {}
Settings = {
    RegisterCanvasLayoutCategory = function(_, name)
        return { name = name, GetID = function() return 7 end }
    end,
    RegisterAddOnCategory = function(cat) addonCategories[#addonCategories + 1] = cat end,
    OpenToCategory = function() return true end,
}

fire("PLAYER_ENTERING_WORLD") -- BuildOptions runs again now that Settings exists
check("the category is registered in the AddOns tab", #addonCategories, 1)
check("under the addon's name", addonCategories[1] and addonCategories[1].name, "Gray Quest Level")

run("debug")
check("debug reports the panel", chatMatches("options panel: registered"), true)

check("the menu offers default plus one entry per window", #menuEntries, 4)
check("default first", menuEntries[1] and menuEntries[1].text, "Default chat window")
check("then the windows in order", menuEntries[3] and menuEntries[3].text, "Combat Log")

-- Picking an entry must set that entry's window -- not the last one the loop
-- saw, which is what a shared loop variable would give.
menuEntries[3].setSelected()
check("picking the third entry selects window 2", GrayQuestLevelCharDB.chatFrame, 2)
check("and that entry reports itself selected", menuEntries[3].isSelected(), true)
check("while its neighbour does not", menuEntries[2].isSelected(), false)
check("nor does the default entry", menuEntries[1].isSelected(), false)

menuEntries[1].setSelected()
check("picking default clears the setting", GrayQuestLevelCharDB.chatFrame, nil)
check("and default now reports selected", menuEntries[1].isSelected(), true)

-- ---------------------------------------------------------------------------
section("screenshot on level-up")
-- ---------------------------------------------------------------------------
-- Only the event handling and the setting are checked: whether Screenshot()
-- is allowed from an addon on this build is something only the client knows.

check("unset means on", GrayQuestLevelCharDB.screenshot, nil)
check("so the checkbox starts ticked", checkbox and checkbox.checked, true)

screenshots = 0
fire("PLAYER_LEVEL_UP", 21)
check("a level-up takes one screenshot", screenshots, 1)
fire("PLAYER_LEVEL_CHANGED", 20, 21)
check("the matching PLAYER_LEVEL_CHANGED does not take a second", screenshots, 1)
fire("PLAYER_LEVEL_CHANGED", 21, 22)
check("PLAYER_LEVEL_CHANGED alone is enough, for builds without PLAYER_LEVEL_UP", screenshots, 2)
fire("PLAYER_LEVEL_CHANGED", 22, 21)
check("a level going down is not a level-up", screenshots, 2)

checkbox:SetChecked(false)
checkbox.scripts.OnClick(checkbox)
check("unticking the box saves false per character", GrayQuestLevelCharDB.screenshot, false)
check("and nothing account-wide", GrayQuestLevelDB.screenshot, nil)
fire("PLAYER_LEVEL_UP", 23)
check("no screenshot while it is off", screenshots, 2)

run("screenshot")
check("/gql screenshot turns it back on", GrayQuestLevelCharDB.screenshot, true)
check("and ticks the box to match", checkbox.checked, true)
check("and says so", chatMatches("screenshot on level%-up ON"), true)
fire("PLAYER_LEVEL_UP", 24)
check("screenshots resume", screenshots, 3)

local realScreenshot = Screenshot
Screenshot = function() error("blocked") end
check("a Screenshot() that throws does not break the level-up handler",
    (pcall(fire, "PLAYER_LEVEL_UP", 25)), true)
Screenshot = nil
check("nor does one that is missing", (pcall(fire, "PLAYER_LEVEL_UP", 26)), true)
check("and neither took a picture", screenshots, 3)
Screenshot = realScreenshot

-- ---------------------------------------------------------------------------
section("the box position is per character")
-- ---------------------------------------------------------------------------

check("seeded once from the old account-wide value", posOf(GrayQuestLevelCharDB.pos), "LEFT/LEFT 42,-7")
check("and flagged as migrated", GrayQuestLevelCharDB.posMigrated, true)
check("the account value survives for characters not yet logged in",
    posOf(GrayQuestLevelDB.pos), "LEFT/LEFT 42,-7")

theFrame.scripts.OnDragStop(theFrame)
check("dragging writes to the character DB", posOf(GrayQuestLevelCharDB.pos), "CENTER/CENTER 10,20")
check("and never to the account DB", posOf(GrayQuestLevelDB.pos), "LEFT/LEFT 42,-7")

run("reset")
check("/gql reset clears the character position", GrayQuestLevelCharDB.pos, nil)
check("but keeps the flag, so login cannot re-seed it", GrayQuestLevelCharDB.posMigrated, true)

-- ---------------------------------------------------------------------------

out(("\n%d checks, %d failed\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
