# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file World of Warcraft addon (`GrayQuestLevel.lua`, loaded by `GrayQuestLevel.toc`)
that displays the green/gray quest-level boundary and kills-to-next-level. Lua 5.1, the
version the WoW client embeds. Target client is the **WoW Forever beta** (`_classic_beta_`),
which uses the Retail API — see `README.md` for its known quirks.

## Checking a change

```bash
./scripts/lint.sh          # luacheck + luac5.1 -p + the tests; must be clean, exits non-zero
lua5.1 scripts/test.lua    # just the tests
./scripts/package.sh       # build dist/GrayQuestLevel-<version>.zip from the .toc version
```

`.luacheckrc` is tuned for this addon, so **any** luacheck warning is a real finding — treat a
non-clean run as a regression. `lint.sh` deliberately does not run `stylua --check`; see Style.

`scripts/test.lua` stubs the WoW API and loads the real addon against it, covering the
gray-level bands, stored-EXP arithmetic, grind gating, row layout and where state is saved.
**Add a check there for any behaviour change** — the bands in particular are pinned to
readings measured in game, and a wrong formula still passes at levels 1–9 by coincidence,
which is how the v1.4 off-by-one survived.

What the tests cannot prove: that the frame draws, that these events exist on this build, or
that the client agrees with the gray-level table. So do **not** claim a change works — hand it
to the user to load in the client and `/reload`.

## Style

- 4-space indentation, matching the existing file.
- **Never run `stylua .` on `GrayQuestLevel.lua`.** `stylua.toml` is tuned to this file's style
  (spaces, collapsed simple statements) and it *still* rewrites ~120 lines: it unaligns the
  trailing comments and reflows the hand-wrapped `or` chains and `:format()` calls. The config
  exists for new files. Make formatting changes by hand.
- Keep lines under 120 characters (luacheck enforces this).
- The file uses `local _, _, x = f()` to skip positional returns; keep that idiom so luacheck
  stays quiet about unused variables.

## Client constraints that shape the code

These are deliberate, not defensive clutter. Preserve them:

- **Every API read goes through `SafeNumber`.** On this build an API may be absent, may throw,
  or may return a secret value that throws when compared. Anything touching the value stays
  inside `pcall`.
- **Event registration is wrapped in `pcall`** (`SafeRegister`). Registering an event this
  client doesn't know throws and aborts the whole file load.
- **`SavedVariables` work.** Earlier beta builds wrote them but never read them back; that is
  fixed. Two DBs, both initialised with the `X = X or {}` idiom at file scope (saved variables
  are loaded before the addon's Lua runs): `GrayQuestLevelDB` is account-wide (source, offset,
  lastGain) and `GrayQuestLevelCharDB` is per character (box position, challenge state). A new
  saved table needs a `## SavedVariables*` line in the `.toc` *and* a `.luacheckrc` entry.
  `GrayQuestLevelDB.pos` is a legacy key kept only to seed new characters once — don't read it
  for anything else.
- **Display-only addon** — no secure snippets, no combat log, no aura reads. Keep it that way;
  that's why Midnight-era restrictions don't apply.
- **Never call `print` directly — use `Say()`.** All output is routed through it so it can go to
  a chosen chat window (`/gql chat`, or the options panel). `Say` falls back to `print` when no
  window is set or the chosen one has been closed. The only `print` in the file is that fallback.
- **The options panel is optional by design.** `Settings.RegisterCanvasLayoutCategory` (10.0+)
  and `WowStyle1DropdownTemplate`/`SetupMenu` (11.0+) are both probed and `pcall`'d, with
  `UIDropDownMenu` as a fallback; if none exist the addon just has no panel and `/gql chat`
  still works. Don't make any feature depend on the panel being present.

## The gray-level boundary

Two sources, which disagree on this client, selectable via `/gql source`:

- `range` (default) — `playerLevel - UnitQuestTrivialLevelRange("player")`
- `colors` — walk `GetQuestDifficultyColor` down until it reports trivial

The arithmetic is `level - range`, **not** `level - range - 1`. Retail's own comparison implies
the extra `-1`; this client behaves as though it's `>=`. Verified at level 8. Don't "fix" this
to match Retail docs. `colors` was the v1.2 default and was demoted in v1.4 because it returned
the same boundary at level 8 and 9 — it didn't move when the character levelled.

`/gql calibrate` deliberately refuses to apply an offset when the active source is `colors` and
it disagrees with what the user sees — a disagreement there is a real finding, not something to
paper over.

## Quest XP values

Full (un-reduced) quest XP is not in the API. The single source is
`GrayQuestLevelQuestXP` in `QuestXP.lua`, maintained by hand and read at load (so edits need a
`/reload`). **Nothing is ever written back** — no learning, no saved-variable cache. That is a
deliberate decision: the user wants one file they control, not a hidden store that can drift
from it. Don't reintroduce caching of quest values.

A gray hand-in whose quest is missing from the file prints the quest ID and what it paid. The
only other hand-in prompt is for a quest whose level could not be read (so gray-ness is unknown):
it says so and prints the `/gql quest` command, rather than skipping silently. Quest levels are
cached on login, `QUEST_ACCEPTED` and `QUEST_COMPLETE` (the hand-in window), because
`QUEST_TURNED_IN` fires after the quest has left the log. `lastQuestSettled` guards against double-counting: when a
hand-in was settled from the file, `/gql quest` must refuse rather than add the debt again.

There is no file I/O in the WoW sandbox — data files must be `.lua` listed in the `.toc`. JSON
is not an option.

## When adding a global

`.luacheckrc` is the source of truth for what the client provides. A new WoW API call goes in
`read_globals`; a new global the addon *writes* (saved variables, `SLASH_*`, anything whose
fields it sets) goes in `globals`, or luacheck fails. APIs reached via `_G[name]` are invisible
to luacheck but are listed anyway as documentation of what the addon probes for.

## Not a git repository

This working copy has no `.git`. Don't run git commands or assume branch/PR conventions.
The user handles version bumps (`## Version:` in the `.toc`) and README updates.
