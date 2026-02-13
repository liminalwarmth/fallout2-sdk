# CLAUDE.md

## Critical Rules

- Commands MUST use `{"commands":[...]}` wrapper — bare objects are silently ignored
- ALWAYS `source scripts/executor.sh` for game interaction — has full action reference + info boundaries in header
- ALWAYS codesign after deploying .app on macOS: `codesign --sign - --force --deep`
- ALWAYS test bridge changes in the running game (build → deploy → launch → verify JSON)
- ALWAYS verify state survives context transitions (char editor temp arrays, map transitions corrupt items)
- ALWAYS regenerate engine patches after modifying `engine/fallout2-ce/`: `./scripts/generate-patches.sh`
- NEVER commit directly to `engine/fallout2-ce/` — use the patch workflow below
- NEVER add changelog-style entries to this file — keep it under 150 lines
- Gotchas are in MEMORY.md (always loaded) — check there first, add new ones there
- ALWAYS implement game interactions the way a player would: equip items to hand slots, use them from the game screen, press keys, select dialogue options — not by directly calling internal engine methods or hacking game state. Only bypass a UI element (e.g., a blocking modal dialog) when there is no scriptable alternative, and document why.
- For gameplay, read `docs/claude/mode-play.md` then play directly in the main context (do NOT use subagents — gameplay needs full reasoning power)

## Architecture

```
Claude Code (CLI)
    ↓ reads game/agent_state.json
    ↓ writes game/agent_cmd.json
Agent Bridge (C++ in fallout2-ce)
    ↓
fallout2-ce Engine + SDL2
```

**Agent Bridge** (C++, in engine) — hooks into engine decision points, serializes game state to JSON, translates commands to engine calls.

**Claude Code** (the agent) — reads `game/agent_state.json`, writes `game/agent_cmd.json`. Uses bash/python for file I/O.

**Engine mod strategy:** fallout2-ce is a submodule at `engine/fallout2-ce/`. Bridge code lives in `src/` as patches. Minimal engine changes for accessor functions only.

Status: Temple of Trials cleared, Klamath reached, all major systems functional (exploration, combat, dialogue, inventory, barter, world map, quests, level-up, party, save/load).

## Build & Deploy

```bash
cd engine/fallout2-ce/build
cmake .. -DAGENT_BRIDGE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make -j$(sysctl -n hw.ncpu)
cp -R "Fallout II Community Edition.app" ../../../game/
codesign --sign - --force --deep ../../../game/"Fallout II Community Edition.app"
cd ../../../game && open "Fallout II Community Edition.app"
```

Test scripts: `scripts/agent_test.sh` (smoke test), `scripts/test_character_creation.sh` (full flow).

## Code Style

WebKit style via clang-format: 4 spaces, UTF-8, LF. `AllowShortIfStatementsOnASingleLine: WithoutElse`. Follow for all C++ in `src/`.

## Project Layout

- `engine/fallout2-ce/` — upstream engine submodule (never commit here directly)
- `src/` — agent bridge C++ (patches on top of CE)
- `scripts/` — setup, test, and executor scripts
- `game/` — game data + runtime JSON files (git-ignored)
- `game/knowledge/` — persistent gameplay knowledge files
- `game/persona.md` — active character persona (runtime, git-ignored)
- `game/thought_log.md` — append-only reasoning log (runtime, git-ignored)
- `docs/` — technical spec, gameplay guide, journal
- `docs/default-persona.md` — default persona template (copied to `game/persona.md` on first session)
- `docs/claude/mode-play.md` — play-mode briefing (read before gameplay sessions)

## Engine Patches

Modifications to `engine/fallout2-ce/` are stored as patches in `engine/patches/`.

```bash
# After cloning / pulling:
git submodule update --init --recursive
./scripts/apply-patches.sh

# After modifying engine files:
./scripts/generate-patches.sh
git add engine/patches/
git commit -m "Update engine patches"

# Updating upstream:
cd engine/fallout2-ce && git stash && git pull && git stash pop && cd ../..
./scripts/generate-patches.sh
```

## Agent Bridge Files

| File | Purpose |
|------|---------|
| `src/agent_bridge.h` | Public API: init/exit/tick/setContext, context constants |
| `src/agent_bridge_internal.h` | Shared declarations: json alias, extern globals, helper decls |
| `src/agent_bridge.cc` | Core: init/exit, ticker, context detection, name-to-ID maps, globals |
| `src/agent_state.cc` | All state emission: character, inventory, map/objects, combat, dialogue |
| `src/agent_commands.cc` | All command handlers: creation, exploration, inventory, combat, dialogue |

## Key Engine Source Files

| File | System | Hook Point |
|------|--------|------------|
| `game.cc` | Main loop | Per-tick state emission and command reading |
| `combat.cc` | Combat | Turn-based loop, AP, attack resolution |
| `game_dialog.cc` | Dialogue | NPC dialogue trees, response options |
| `input.cc` | Input | Synthetic input injection |
| `inventory.cc` | Inventory | Item management, equipment, barter |
| `worldmap.cc` | World map | Travel, encounters, location discovery |
| `character_editor.cc` | Character | SPECIAL, skills, perks, level-up |

Engine hooks: `mainmenu.cc`, `character_selector.cc`, `character_editor.cc`, `main.cc` (before both `mainLoop()` calls).

## Engine Modifications

| File | Change |
|------|--------|
| `game_dialog.h/cc` | 6 accessor functions (`agentGetDialog*`, `agentGetBarter*`) |
| `display_monitor.h/cc` | 2 accessors for message log reading |
| `combat.h/cc` | `extern _combat_free_move`, 3 turn order accessors |
| `loadsave.h/cc` | `agentQuickSave/Load()`, `agentSaveToSlot/LoadFromSlot()` |
| `pipboy.h/cc` | `agentInitQuestData()`, 12 quest/holodisk accessors |
| `worldmap.h/cc` | 8 world map area/entrance accessors |
| `CMakeLists.txt` | Added bridge source files to `AGENT_BRIDGE` target |

## Testing & Review

1. Build, deploy to `game/`, and launch
2. Send commands via `agent_cmd.json` and read back `agent_state.json`
3. Verify state survives context transitions (editor temp arrays, map transitions)
4. Leave game running for visual confirmation

After significant changes: `codex exec "Review the git diff of the last N commits (git diff HEAD~N..HEAD) for bugs, logic errors, and issues."`

Session journal: `docs/journal.md`

## Dependencies

CMake 3.13+, C++17 compiler, SDL2 (bundled via `FALLOUT_VENDORED`), nlohmann/json (CMake FetchContent), Python 3.
