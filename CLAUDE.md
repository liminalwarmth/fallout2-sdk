# CLAUDE.md

## Critical Rules

- ALWAYS use Codex for code execution: `codex exec "your prompt here"` (model: `gpt-5.3-codex`, path: `/opt/homebrew/bin/codex`)
- Commands MUST use `{"commands":[...]}` wrapper — bare objects are silently ignored
- ALWAYS `source scripts/executor.sh` for game interaction — has full action reference + info boundaries in header
- ALWAYS codesign after deploying .app on macOS: `codesign --sign - --force --deep`
- ALWAYS test bridge changes in the running game (build → deploy → launch → verify JSON)
- ALWAYS verify state survives context transitions (char editor temp arrays, map transitions corrupt items)
- ALWAYS regenerate engine patches after modifying `engine/fallout2-ce/`: `./scripts/generate-patches.sh`
- NEVER commit directly to `engine/fallout2-ce/` — use the patch workflow below
- NEVER add changelog-style entries to this file — keep it under 250 lines
- NEVER enable test mode during normal gameplay (`teleport`, `give_item`, `detonate_at`, `map_transition`, etc. are gated)
- NEVER warp between maps — always walk to exit grids to leave a map, like a player would
- NEVER metagame — explore, loot, examine, and reason from in-game clues only
- NEVER edit `src/` or `engine/` during gameplay — play mode is read-only for source code
- NEVER use subagents for gameplay — play directly in the main context (full reasoning power needed)
- Gotchas are in MEMORY.md (always loaded) — check there first, add new ones there
- ALWAYS implement game interactions the way a player would: equip items to hand slots, use them from the game screen, press keys, select dialogue options — not by directly calling internal engine methods or hacking game state. Only bypass a UI element (e.g., a blocking modal dialog) when there is no scriptable alternative, and document why.
- Reference `docs/gameplay-guide.md` for general game mechanics (skills, combat strategy, etc.)

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

## Bridge & Engine Reference

**Bridge files:** `src/agent_bridge.h` (public API), `src/agent_bridge_internal.h` (shared internals), `src/agent_bridge.cc` (core/tick/context), `src/agent_state.cc` (state emission), `src/agent_commands.cc` (command handlers).

**Engine hooks:** `game.cc` (main loop tick), `combat.cc` (turn-based), `game_dialog.cc` (dialogue), `input.cc` (synthetic input), `inventory.cc` (items/barter), `worldmap.cc` (travel), `character_editor.cc` (SPECIAL/skills/perks). Context hooks in `mainmenu.cc`, `character_selector.cc`, `character_editor.cc`, `main.cc`.

**Engine modifications:** `game_dialog.h/cc` (6 accessors), `display_monitor.h/cc` (2 accessors), `combat.h/cc` (extern + 3 accessors), `loadsave.h/cc` (save/load), `pipboy.h/cc` (quest accessors), `worldmap.h/cc` (area accessors), `CMakeLists.txt` (bridge sources).

## Command Reference

Full argument signatures are in `scripts/executor.sh` header. Commands require `{"commands":[...]}` wrapper.

**Exploration:** `move_to`, `run_to`, `use_object`, `pick_up`, `look_at`, `use_skill`, `use_item_on`, `talk_to`, `open_container`, `enter_combat`
**Inventory:** `equip_item`, `unequip_item`, `use_item`, `use_equipped_item`, `reload_weapon`, `drop_item`, `switch_hand`, `cycle_attack_mode`
**Combat:** `attack`, `combat_move`, `end_turn`, `use_combat_item`, `flee_combat`
**Dialogue:** `select_dialogue`
**Loot:** `loot_take`, `loot_take_all`, `loot_close`
**Barter:** `barter_offer`, `barter_remove_offer`, `barter_request`, `barter_remove_request`, `barter_confirm`, `barter_talk`, `barter_cancel`
**World map:** `worldmap_travel`, `worldmap_enter_location`
**Level-up:** `skill_add`, `skill_sub`, `perk_add` (editor must be open)
**Interface:** `rest`, `pip_boy`, `character_screen`, `inventory_open`, `skilldex`, `center_camera`
**Save/Load:** `quicksave`, `quickload`, `save_slot`, `load_slot`
**Navigation:** `find_path`, `tile_objects`
**Menu/Movies:** `main_menu`, `skip`

## Interaction Patterns

Plan interactions as step sequences, then execute via executor scripts. Don't micro-manage individual commands.

**Door (unlocked):** `run_to <door_tile>` → `use_object_and_wait <door_id>` → `move_and_wait <tile_beyond_door>` (walk through before auto-close)
**Door (locked):** `move_and_wait <adjacent>` → `use_skill_and_wait lockpick <door_id>` → if unlocked: open and walk through
**Container:** `loot_all <id>` — walks to container, opens, takes all, closes
**Ground item:** `move_and_wait <tile>` → `pick_up <id>` (or `explore_area` for everything nearby)
**NPC dialogue:** `talk_and_choose <npc_id> <opt1> <opt2> ...`
**Combat:** `enter_combat` → `do_combat 60` (auto-targets, moves, attacks, manages turns)
**Exit grid:** `exit_through "<dest_name>"` or `exit_through "any"`
**Explosive obstacle:** `arm_and_detonate <target_id> <safe_tile>` (equip → use → flee → wait)
**New area:** `objects_near` → `muse` assessment → `explore_area` → check doors/exits → proceed
**Long distance (>20 tiles):** Break into waypoints — `move_and_wait <midpoint>` then `move_and_wait <dest>`
**Options menu dismiss:** `dismiss_options_menu` after skipping movies
**Character creation:** `main_menu` new_game → skip movies → `char_selector_select` create_custom → set SPECIAL/traits/skills/name → `editor_done`
**World map travel:** `worldmap_travel` (initiates walking) → poll `is_walking == false` → `worldmap_enter_location`
**Level-up:** `character_screen` → `skill_add` per point → `perk_add` if `has_free_perk`

## Executor Functions

Source with `source scripts/executor.sh`. Key functions:

| Function | Description |
|----------|-------------|
| `do_combat [timeout] [heal%]` | Full combat loop with timeout and failure detection |
| `exit_through <dest\|any>` | Walk onto exit grids for natural map transitions |
| `equip_and_use <pid> [hand] [timer]` | Equip item to hand, switch, and use it |
| `arm_and_detonate <id> <tile> [pid]` | Full explosive workflow (equip → use → flee) |
| `explore_area [max_dist]` | Walk to and loot all containers, pick up ground items |
| `move_and_wait <tile>` | Move to tile, wait for arrival (auto-retries) |
| `loot_all <id>` | Walk to container, open, take all, close |
| `talk_and_choose <id> <opt1> ...` | Talk to NPC with dialogue sequence |
| `snapshot` / `objects_near` / `inventory_summary` | State inspection |
| `examine_object <id>` / `check_inventory_for <kw>` | Object/inventory queries |
| `muse "text"` | Floating thought above player (no log) |
| `think <title> <...>` | Logged reasoning + thought bubble |
| `use_skill_tracked <skill> <id> [max]` | Skill with attempt counter (gives up after max) |

## Persona & Decisions

Read `game/persona.md` at session start. Consult persona before decisions with moral weight (dialogue, fight/flee/negotiate, quests, factions).

**Decision flow:** `read_persona` → identify values → `think` to log reasoning → act → `evolve_persona` if experience shifts values (rare).

**Muse system:** Use `muse "text"` frequently for inner monologue (orange floating text above player). Write in character voice. Scale complexity to INT stat (INT 1-3: simple fragments, INT 9-10: eloquent prose). Reference recent actions and current objectives — maintain continuity of experience.

**Execution style:** Plan approach, execute via executor scripts (`do_combat`, `exit_through`, `explore_area`), sprinkle `muse` calls between actions to narrate.

## Gameplay Gotchas

- **Escape = Options menu** after movie skips (game_mode 8/24). Always `dismiss_options_menu` after entering gameplay.
- **Weapon hand**: Defaults to left (punch). Weapons equip to right. Must `switch_hand` to use.
- **Long pathfinding limit**: >20 hexes fails silently. Use intermediate waypoints.
- **Door tiles block pathfinding**: Move to tile beyond/through the door, not the door tile itself.
- **Commands need tick gap**: One command at a time, ~1s between. Use `*_and_wait` helpers.
- **Unarmed range = 1**: Must `combat_move` to close distance first.
- **Equip-then-use for usable items**: Explosives/flares → equip to hand → `use_equipped_item` (or `equip_and_use`).
- **Rest requires no hostiles**: Fails silently with enemies on map. Check `last_debug`.

## Knowledge Management

Use `game-note`, `game-recall`, `game-log` skills, or executor helpers:

| Helper | Usage |
|--------|-------|
| `note <category> "<text>"` | Append to knowledge file (locations/characters/quests/strategies/items/world) |
| `recall "<keyword>"` | Search all knowledge files and game log |
| `game_log "<text>"` | Append timestamped entry to game log |

**Files:** `game/knowledge/{locations,characters,quests,strategies,items,world}.md`
**Decision log:** `game/game_log.md` — append-only, search with `recall`, never load fully

## Code Style & Dependencies

WebKit style via clang-format: 4 spaces, UTF-8, LF. `AllowShortIfStatementsOnASingleLine: WithoutElse`.

CMake 3.13+, C++17 compiler, SDL2 (bundled via `FALLOUT_VENDORED`), nlohmann/json (CMake FetchContent), Python 3.

## Testing

1. Build, deploy to `game/`, and launch
2. Send commands via `agent_cmd.json` and read back `agent_state.json`
3. Verify state survives context transitions
4. Leave game running for visual confirmation

Session journal: `docs/journal.md`
