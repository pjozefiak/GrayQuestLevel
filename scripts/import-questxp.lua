-- Merge one zone's quest XP values, pasted from Wowhead's "Copy all" option,
-- into QuestXP.lua.
--
--   lua5.1 scripts/import-questxp.lua quest_dump.txt "Ashenvale" 331
--   lua5.1 scripts/import-questxp.lua --dry-run quest_dump.txt "Ashenvale" 331   -- report, write nothing
--
-- The zone name and ID are not in the paste, so they are given here. The ID is
-- in the zone's Wowhead URL (.../forever/zone=331/ashenvale -> 331). Lists that
-- are not a zone use Wowhead's category ID: negative for class quests (Paladin
-- -141), and 0 is used here for Uncategorized.
--
-- Fully offline: it reads the file it is given and writes QuestXP.lua.
--
-- The paste is column-wise, not row-wise: one line per column, each a
-- comma-separated list with one item per quest, in the same order:
--
--   1. quest IDs      79192, 79007, 97003, ...
--   2. names          Stepping Stones, "Wrongly Blamed, Justly Corrected", ...
--   3. levels         24, 22, Elite 21, Dungeon 30, ...
--   4. XP rewards     1950, 1750, 2050, ...
--
-- A name containing a comma is quoted, so the lists are split CSV-style rather
-- than on every comma. All four must have the same length, and every ID and XP
-- must be a number; otherwise nothing is written, since one bad split would
-- shift every quest after it onto the wrong value.
--
-- Entries are kept in zone groups ordered by zone ID, sorted by quest ID within
-- each zone. The grouping is read back out of QuestXP.lua on each run.
-- Existing values are never overwritten; a disagreement is reported instead,
-- as is a quest already filed under a different zone (breadcrumbs appear in
-- more than one zone's list).

---@diagnostic disable: undefined-global

local SCRIPT_DIR = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local QUESTXP_FILE = SCRIPT_DIR .. "/../QuestXP.lua"

-- Negative IDs are Wowhead's non-zone categories, e.g. class quests (Paladin -141).
local ZONE_MARKER = "^%s*%-%-%s*(.+)%s+%(zone%s+(%-?%d+)%)%s*$"
local ENTRY_LINE = "^%s*%[(%d+)%]%s*=%s*(%d+)%s*,%s*(.*)$"

local dryRun = false
local positional = {}
for i = 1, #arg do
    if arg[i] == "--dry-run" then dryRun = true else positional[#positional + 1] = arg[i] end
end

local dumpPath, zoneName, zoneID = positional[1], positional[2], tonumber(positional[3] or "")
if not (dumpPath and zoneName and zoneName:match("%S") and zoneID) or #positional > 3 then
    io.write("usage: lua5.1 scripts/import-questxp.lua [--dry-run] <dump.txt> <zone name> <zone id>\n")
    io.write('       lua5.1 scripts/import-questxp.lua quest_dump.txt "Ashenvale" 331\n')
    os.exit(2)
end

-- ---------------------------------------------------------------------------
-- Read QuestXP.lua, keeping its zone grouping
-- ---------------------------------------------------------------------------
-- Parsed as text rather than executed, because the zone headers are comments
-- and would be lost by loading it. The result is checked against a real load
-- at the end, so a parsing slip cannot quietly drop entries.

local header = {}        -- preamble lines, reproduced verbatim
local groups = {}        -- { zone = id or nil, name = string, entries = { [id] = { xp, comment } } }
local groupByZone = {}
local zoneOf = {}        -- quest id -> group, for cross-zone duplicate detection
local droppedLines = {}

local function newGroup(zone, name, unattributed)
    local g = { zone = zone, name = name, entries = {}, unattributed = unattributed }
    groups[#groups + 1] = g
    if zone then groupByZone[zone] = g end
    return g
end

local function sortedIDs(entries)
    local ids = {}
    for id in pairs(entries) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

do
    local f = io.open(QUESTXP_FILE, "r")
    if not f then
        io.write(("cannot read %s\n"):format(QUESTXP_FILE))
        os.exit(1)
    end

    local inTable, current = false, nil
    for line in f:lines() do
        if not inTable then
            if line:match("^GrayQuestLevelQuestXP%s*=") then
                inTable = true
            else
                header[#header + 1] = line
            end
        elseif line:match("^}") then
            inTable = false
        else
            local name, zone = line:match(ZONE_MARKER)
            local id, xp, trailing = line:match(ENTRY_LINE)
            if zone then
                current = groupByZone[tonumber(zone)] or newGroup(tonumber(zone), name)
            elseif id then
                -- Entries above the first zone header were added by hand; a
                -- zone whose list includes them adopts them.
                current = current or newGroup(nil, "not attributed to a zone", true)
                id = tonumber(id)
                current.entries[id] = { xp = tonumber(xp), comment = trailing:match("^%-%-%s*(.*)$") }
                zoneOf[id] = current
            elseif line:match("%S") then
                droppedLines[#droppedLines + 1] = line
            end
        end
    end
    f:close()

    if #header == 0 then
        io.write(("cannot find the GrayQuestLevelQuestXP assignment in %s\n"):format(QUESTXP_FILE))
        os.exit(1)
    end
end

-- Rewriting would lose these, so stop rather than drop someone's edit.
if #droppedLines > 0 then
    io.write("QuestXP.lua has lines inside the table this script does not understand:\n")
    for _, l in ipairs(droppedLines) do io.write(("  %s\n"):format(l)) end
    io.write("fix or remove them first; nothing written\n")
    os.exit(1)
end

local existingCount = 0
for _ in pairs(zoneOf) do existingCount = existingCount + 1 end

-- ---------------------------------------------------------------------------
-- Read the paste
-- ---------------------------------------------------------------------------

-- Split one comma-separated list. A quoted item may contain commas, and ""
-- inside quotes is a literal quote.
local function splitList(line)
    local items, i, n = {}, 1, #line
    while true do
        while line:sub(i, i):match("^%s$") do i = i + 1 end
        local item
        if line:sub(i, i) == '"' then
            local buf, j = {}, i + 1
            while true do
                local c = line:sub(j, j)
                if c == "" then return nil, ("unterminated quote starting at character %d"):format(i) end
                if c == '"' then
                    if line:sub(j + 1, j + 1) ~= '"' then break end
                    buf[#buf + 1] = '"'
                    j = j + 2
                else
                    buf[#buf + 1] = c
                    j = j + 1
                end
            end
            item = table.concat(buf)
            i = j + 1
            while line:sub(i, i):match("^%s$") do i = i + 1 end
        else
            local comma = line:find(",", i, true) or (n + 1)
            item = line:sub(i, comma - 1):gsub("%s+$", "")
            i = comma
        end
        items[#items + 1] = item
        if i > n then return items end
        if line:sub(i, i) ~= "," then
            return nil, ("expected a comma at character %d after %q"):format(i, item)
        end
        i = i + 1
    end
end

local records, recordCount = {}, 0
do
    local f = io.open(dumpPath, "r")
    if not f then
        io.write(("cannot read %s\n"):format(dumpPath))
        os.exit(1)
    end
    local lines = {}
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line:match("%S") then lines[#lines + 1] = line end
    end
    f:close()

    if #lines ~= 4 then
        io.write(("%s: expected 4 non-empty lines (IDs, names, levels, XP), found %d\n")
            :format(dumpPath, #lines))
        os.exit(1)
    end

    local columns, labels = {}, { "IDs", "names", "levels", "XP" }
    for k = 1, 4 do
        local items, err = splitList(lines[k])
        if not items then
            io.write(("%s: line %d (%s): %s\n"):format(dumpPath, k, labels[k], err))
            os.exit(1)
        end
        columns[k] = items
    end

    local count = #columns[1]
    for k = 2, 4 do
        if #columns[k] ~= count then
            io.write(("%s: columns differ in length - %d IDs, %d names, %d levels, %d XP; nothing written\n")
                :format(dumpPath, #columns[1], #columns[2], #columns[3], #columns[4]))
            os.exit(1)
        end
    end

    local bad = {}
    for r = 1, count do
        local id, name, level, xp = columns[1][r], columns[2][r], columns[3][r], columns[4][r]
        local nid, nxp = tonumber(id:match("^%d+$") or ""), tonumber(xp:match("^%d+$") or "")
        if not (nid and nxp) then
            bad[#bad + 1] = ("  item %d: id %q, xp %q (%s)"):format(r, id, xp, name)
        elseif records[nid] then
            bad[#bad + 1] = ("  item %d: quest %d appears twice"):format(r, nid)
        else
            -- "Elite 21", "Dungeon 30": keep the number only, as the file does.
            records[nid] = { xp = nxp, name = name, level = level:match("(%-?%d+)%s*$") }
            recordCount = recordCount + 1
        end
    end
    if #bad > 0 then
        io.write(("%s: items that do not read as quests; nothing written\n"):format(dumpPath))
        for _, b in ipairs(bad) do io.write(b, "\n") end
        os.exit(1)
    end
end

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

local group = groupByZone[zoneID] or newGroup(zoneID, zoneName)
group.name = zoneName

local added, adopted, agreed = 0, 0, 0
local conflicts, elsewhere, zeroXP = {}, {}, {}

for _, id in ipairs(sortedIDs(records)) do
    local rec = records[id]
    local owner = zoneOf[id]
    local label = ("%s (%s)"):format(rec.name, rec.level or "?")

    if rec.xp == 0 then
        zeroXP[#zeroXP + 1] = ("[%d] %s"):format(id, rec.name)
    elseif owner == group then
        if owner.entries[id].xp == rec.xp then
            agreed = agreed + 1
        else
            conflicts[#conflicts + 1] = ("[%d] %s: file says %d, paste says %d")
                :format(id, rec.name, owner.entries[id].xp, rec.xp)
        end
    elseif owner and owner.unattributed then
        local kept = owner.entries[id]
        if kept.xp ~= rec.xp then
            conflicts[#conflicts + 1] = ("[%d] %s: file says %d, paste says %d")
                :format(id, rec.name, kept.xp, rec.xp)
        end
        owner.entries[id] = nil
        group.entries[id] = { xp = kept.xp, comment = kept.comment or label }
        zoneOf[id] = group
        adopted = adopted + 1
    elseif owner then
        elsewhere[#elsewhere + 1] = ("[%d] %s: already under %s, file says %d, paste says %d")
            :format(id, rec.name, owner.name, owner.entries[id].xp, rec.xp)
    else
        group.entries[id] = { xp = rec.xp, comment = label }
        zoneOf[id] = group
        added = added + 1
    end
end

io.write(("%s\n  %s (zone %d): %d quests, %d new%s, %d already present and agreeing\n"):format(
    dumpPath, zoneName, zoneID, recordCount, added,
    adopted > 0 and (", %d moved in from ungrouped"):format(adopted) or "", agreed))
io.write(("  %d entries in QuestXP.lua before\n"):format(existingCount))

for _, c in ipairs(conflicts) do io.write(("  CONFLICT %s - keeping the file's value\n"):format(c)) end
for _, c in ipairs(elsewhere) do io.write(("  SKIPPED  %s\n"):format(c)) end
for _, c in ipairs(zeroXP) do io.write(("  SKIPPED  %s: no XP listed\n"):format(c)) end

if added == 0 and adopted == 0 then
    io.write("  nothing to write\n")
    os.exit(0)
end

if dryRun then
    io.write("  --dry-run: not written\n")
    os.exit(0)
end

-- ---------------------------------------------------------------------------
-- Write it back out: ungrouped entries first, then zones by zone ID
-- ---------------------------------------------------------------------------

table.sort(groups, function(a, b)
    if a.unattributed ~= b.unattributed then return a.unattributed == true end
    return (a.zone or 0) < (b.zone or 0)
end)

local lines = {}
for _, l in ipairs(header) do lines[#lines + 1] = l end
while lines[#lines] and not lines[#lines]:match("%S") do lines[#lines] = nil end
lines[#lines + 1] = ""
lines[#lines + 1] = "GrayQuestLevelQuestXP = {"

local written, blocksWritten = 0, 0
for _, g in ipairs(groups) do
    local ids = sortedIDs(g.entries)
    -- A group can end up empty once its entries are adopted by a real zone.
    if #ids > 0 then
        blocksWritten = blocksWritten + 1
        if blocksWritten > 1 then lines[#lines + 1] = "" end
        -- Ungrouped entries get no header: a header line here would read back
        -- as a zone (or as an unknown line) on the next run.
        if g.zone then lines[#lines + 1] = ("    -- %s (zone %d)"):format(g.name, g.zone) end
        for _, id in ipairs(ids) do
            local e = g.entries[id]
            lines[#lines + 1] = ("    [%d] = %d,%s"):format(id, e.xp, e.comment and (" -- " .. e.comment) or "")
            written = written + 1
        end
    end
end

lines[#lines + 1] = "}"
lines[#lines + 1] = ""

local body = table.concat(lines, "\n")

-- Confirm the result is loadable and complete before replacing the file.
local chunk, err = loadstring(body, "QuestXP.lua")
if not chunk then
    io.write(("refusing to write: generated file does not parse (%s)\n"):format(tostring(err)))
    os.exit(1)
end
GrayQuestLevelQuestXP = nil
chunk()
local reloaded = 0
for _ in pairs(GrayQuestLevelQuestXP or {}) do reloaded = reloaded + 1 end
if reloaded ~= written then
    io.write(("refusing to write: generated %d entries but only %d survive a load\n")
        :format(written, reloaded))
    os.exit(1)
end

local out = assert(io.open(QUESTXP_FILE, "w"))
out:write(body)
out:close()
io.write(("  wrote %d entries across %d zone group(s)\n"):format(written, blocksWritten))
