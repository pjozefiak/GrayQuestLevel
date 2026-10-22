-- luacheck config for a World of Warcraft addon (Lua 5.1 sandbox)
std = "lua51"
max_line_length = 120

-- The addon's own namespace comes in through the ... vararg of each file,
-- so the only true globals are the ones the client exposes.
ignore = {
	"212/self",         -- unused self in methods
	"431",              -- shadowing an upvalue
	"542",              -- empty if branch
	"211/ADDON_NAME",   -- `local ADDON_NAME = ...` is the standard addon header
}

-- The offline test harness defines the client API it is stubbing, so the WoW
-- globals list above (which makes those names read-only) must not apply to it.
-- allow_defined lets it assign anything it also declares in the file.
files["scripts/test.lua"] = {
	read_globals = {},
	globals = { "print" }, -- captured so assertions can read what the addon said
	allow_defined = true,
	ignore = {
		"131", -- stubs are read by the addon under test, never by this file
	},
}

exclude_files = {
	".luacheckrc",
	"Libs/**",      -- vendored libraries (Ace3, LibStub, ...)
	"libs/**",
	".vscode/**",
}

-- Globals the addon may read but must not write.
read_globals = {
	-- namespaces / tables
	"C_AddOns", "C_ChatInfo", "C_Container", "C_CVar", "C_Item", "C_Map",
	"C_MythicPlus", "C_ChallengeMode", "C_Spell", "C_Timer", "C_Texture", "C_QuestLog",
	"C_UnitAuras", "Enum", "Settings", "LibStub", "Constants",

	-- frames / UI
	"UIParent", "WorldFrame", "CreateFrame", "GameTooltip", "GameFontNormal",
	"GameFontHighlight", "GameFontNormalLarge", "GameFontHighlightSmall",
	"ChatFrame1", "DEFAULT_CHAT_FRAME", "NUM_CHAT_WINDOWS", "GetChatWindowInfo",
	"UIDropDownMenu_Initialize", "UIDropDownMenu_SetWidth",
	"UIDropDownMenu_AddButton", "UIDropDownMenu_SetText",
	"InterfaceOptions_AddCategory", "StaticPopup_Show", "StaticPopupDialogs",

	-- player / unit info
	"UnitName", "UnitGUID", "UnitClass", "UnitRace", "UnitLevel", "UnitExists",
	"UnitIsPlayer", "UnitIsDeadOrGhost", "UnitHealth", "UnitHealthMax",
	"UnitPower", "UnitPowerMax", "UnitAffectingCombat", "UnitInParty",
	"UnitInRaid", "UnitGroupRolesAssigned", "GetNumGroupMembers",
	"IsInGroup", "IsInRaid", "IsInInstance", "GetRealmName", "GetNormalizedRealmName",
	"UnitEffectiveLevel",

	-- XP / levelling
	"UnitXP", "UnitXPMax", "IsXPUserDisabled",
	"GetMaxPlayerLevel", "GetMaxLevelForPlayerExpansion",

	-- quest difficulty. UnitQuestTrivialLevelRange and GetQuestGreenRange are
	-- reached through _G[name] (they may be absent), so luacheck never sees
	-- them -- listed here as documentation of what the addon probes for.
	"GetQuestDifficultyColor", "QuestDifficultyColors",
	"UnitQuestTrivialLevelRange", "GetQuestGreenRange",

	-- misc API
	"GetTime", "GetServerTime", "GetLocale", "GetAddOnMetadata",
	"GetSpellInfo", "GetItemInfo", "GetMoney", "GetInstanceInfo",
	"GetCVar", "SetCVar", "IsAddOnLoaded", "ReloadUI", "print", "Screenshot",
	"hooksecurefunc", "securecall", "issecurevariable", "wipe", "tContains",
	"tInvert", "CopyTable", "Mixin", "CreateFromMixins", "bit",

	-- WoW's global aliases for stdlib functions
	"strsplit", "strjoin", "strtrim", "strlen", "strsub", "strupper", "strlower",
	"strfind", "strmatch", "strrep", "gsub", "format", "tinsert", "tremove",
	"abs", "ceil", "floor", "sqrt", "max", "min", "date", "time",
}

-- Globals the addon is allowed to create or overwrite (saved variables, etc.).
globals = {
	"GrayQuestLevelDB",      -- ## SavedVariables in the .toc
	"GrayQuestLevelCharDB",  -- ## SavedVariablesPerCharacter in the .toc
	"GrayQuestLevelQuestXP", -- the shipped quest-XP table, set by QuestXP.lua
	"SLASH_GRAYQUESTLEVEL1", -- how /gql is registered
	"SlashCmdList",          -- the handler is installed as a field on it
}
