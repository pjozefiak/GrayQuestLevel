-- Full (un-reduced) quest XP, keyed by quest ID.
--
-- Entries can be added by hand -- Wowhead lists the XP, and the quest ID is in
-- the URL (.../forever/quest=437/the-dead-fields -> 437) -- or imported a zone
-- at a time from a saved Wowhead quest-listing page:
--
--     lua5.1 scripts/import-questxp.lua "wowhead-dump/<zone> Quests.html"
--
-- The importer merges: it never overwrites a value already here, and reports
-- any disagreement instead.
--
-- Entries are grouped by zone, in the order the zones were first imported, and
-- sorted by quest ID within each zone. The `-- <Zone> (zone <id>)` headers are
-- not decoration -- the importer reads them back to work out where each entry
-- belongs, so keep the format if you add a group by hand. Entries added above
-- the first header are left ungrouped until a zone import claims them.
--
-- This is the only source of full quest values. The addon never writes to it,
-- and never caches a value anywhere else: hand in a gray quest that is missing
-- from here and it tells you the quest ID and what the quest paid, so you can
-- add the entry.
--
-- Read at load, so a /reload is needed after editing. `/gql xpdb` reports how
-- many entries are here; `/gql xpdb <questID>` looks one up.

GrayQuestLevelQuestXP = {
    -- Silverpine Forest (zone 130)
    [99] = 1350,  -- Arugal's Folly (15)
    [421] = 840,  -- Prove Your Worth (10)
    [422] = 880,  -- Arugal's Folly (11)
    [423] = 980,  -- Arugal's Folly (14)
    [424] = 1050,  -- Arugal's Folly (15)
    [425] = 680,  -- Ivar the Foul (12)
    [428] = 225,  -- Lost Deathstalkers (12)
    [429] = 440,  -- Wild Hearts (11)
    [430] = 660,  -- Return to Quinn (11)
    [435] = 880,  -- Escorting Erland (11)
    [437] = 980,  -- The Dead Fields (14)
    [438] = 880,  -- The Decrepit Ferry (16)
    [439] = 290,  -- Rot Hide Clues (16)
    [440] = 580,  -- The Engraved Ring (16)
    [441] = 580,  -- Raleigh and the Undercity (16)
    [442] = 1950,  -- Assault on Fenris Isle (24)
    [443] = 1250,  -- Rot Hide Ichor (17)
    [444] = 315,  -- Rot Hide Origins (17)
    [446] = 290,  -- Thule Ravenclaw (16)
    [447] = 910,  -- A Recipe For Death (12)
    [448] = 580,  -- Report to Hadrec (16)
    [449] = 440,  -- The Deathstalkers' Report (11)
    [450] = 1350,  -- A Recipe For Death (15)
    [451] = 2050,  -- A Recipe For Death (18)
    [452] = 1350,  -- Pyrewood Ambush (15)
    [460] = 630,  -- Resting in Pieces (17)
    [461] = 680,  -- The Hidden Niche (18)
    [477] = 980,  -- Border Crossings (14)
    [478] = 740,  -- Maps and Runes (14)
    [479] = 1150,  -- Ambermill Investigations (16)
    [480] = 1750,  -- The Weaver (22)
    [481] = 100,  -- Dalar's Analysis (14)
    [482] = 100,  -- Dalaran's Intentions (14)
    [491] = 1700,  -- Wand to Bethor (18)
    [493] = 1150,  -- Journey to Hillsbrad Foothills (20)
    [516] = 1250,  -- Beren's Peril (21)
    [530] = 1550,  -- A Husband's Revenge (20)
	[788] = 170, -- Cutting Teeth (2)
	[789] = 250, -- Sting of the Scorpid (3)
    [3221] = 90,  -- Speak with Renferrel (12)
	[4641] = 50, -- Your Place in the World (1)
    [6321] = 210,  -- Supplying the Sepulcher (10)
    [6322] = 210,  -- Michael Garrett (10)
    [6323] = 420,  -- Ride to the Undercity (10)
    [6324] = 1050,  -- Return to Podrig (10)
    [91920] = 440,  -- Wild Eyes (11)
    [91921] = 660,  -- Return to Quinn (Again) (11)
    [95883] = 1400,  -- The Tortured Soul (23)
    [95884] = 185,  -- The Offering Stone (23)
    [95885] = 1850,  -- The Offering of Blood (23)
    [95981] = 1550,  -- Watching the Roads (20)
	[97279] = 170, -- Wayward Weapons (2)
    [98298] = 1150,  -- Arugal's Folly (16)
    [98299] = 1550,  -- Stop the Spread (20)
}
