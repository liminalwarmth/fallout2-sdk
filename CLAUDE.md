# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

fallout2-sdk enables Claude Code to autonomously play Fallout 2 by instrumenting the [Fallout 2 Community Edition](https://github.com/alexbatalov/fallout2-ce) open-source engine. Claude Code acts as the strategic brain — reading game state, reasoning about objectives, and issuing commands — while the C++ agent bridge handles engine integration.

The full technical specification is in `docs/fallout2-sdk-technical-spec.md` (note: some sections describe the original RS-SDK-inspired design; the actual architecture is file-based IPC as described below).

## Architecture

```
Claude Code (CLI)
    ↓ reads game/agent_state.json
    ↓ writes game/agent_cmd.json
Agent Bridge (C++ module in fallout2-ce)
    ↓
fallout2-ce Engine + SDL2
```

**Two layers:**
1. **Agent Bridge** (C++, in engine) — hooks into engine decision points (combat turns, dialogue, movement), serializes game state to JSON, translates incoming commands to engine calls. Files: `agent_bridge.h/cc`, `agent_state.cc`, `agent_commands.cc`
2. **Claude Code** (the agent) — reads `game/agent_state.json` for game state, writes `game/agent_cmd.json` to issue commands. Uses bash/python for file I/O. No separate SDK or wrapper needed.

**Engine modification strategy:** fallout2-ce is a git submodule at `engine/fallout2-ce/`. Bridge modifications live in `src/` as patches applied on top, not as direct edits to the submodule. Minimal engine changes are made when necessary (e.g., dialogue accessor functions in `game_dialog.cc/h`). Key engine integration points: main loop hook (`game.cc`), input injection (`input.cc`), combat system (`combat.cc`), dialogue system (`game_dialog.cc`), world map (`worldmap.cc`).

## Build Commands

The engine uses CMake with C++17:

```bash
# Build fallout2-ce (from repo root)
cd engine/fallout2-ce
mkdir -p build && cd build
cmake ..
make -j$(sysctl -n hw.ncpu)
```

CMake presets exist in `engine/fallout2-ce/CMakePresets.json` for cross-platform builds (macOS, Windows, Linux, iOS, Android). macOS builds target both x86_64 and arm64.

## Setup

```bash
# Clone with submodule
git clone --recurse-submodules <repo-url>

# Or initialize submodule after clone
git submodule update --init --recursive

# Apply engine patches (required for agent bridge)
./scripts/apply-patches.sh

# Install game data (interactive or from source)
./scripts/setup.sh
./scripts/setup.sh --from /path/to/fallout2/install
./scripts/setup.sh --from-dmg ~/Downloads/fallout_2.dmg
```

Game data files (`master.dat`, `critter.dat`, `patch000.dat`) go in `game/` and are git-ignored. Configuration is in `sdk.cfg` (copied from `sdk.cfg.example`).

## Code Style

The engine uses WebKit style enforced by clang-format:
- **Style:** `BasedOnStyle: WebKit` with `AllowShortIfStatementsOnASingleLine: WithoutElse`
- **Indentation:** 4 spaces, UTF-8, LF line endings (see `engine/fallout2-ce/.editorconfig`)
- **CI checks:** clang-format validation and cppcheck static analysis run in GitHub Actions

Follow these conventions for any C++ code in `src/`.

## Key Directories

- `engine/fallout2-ce/` — upstream engine submodule (do not commit changes here directly)
- `engine/fallout2-ce/src/` — ~264 C++ source files comprising the full engine
- `src/` — agent bridge engine modifications (patches on top of CE)
- `scripts/` — setup and utility scripts
- `game/` — local Fallout 2 game data (git-ignored, ~500 MB), also where `agent_state.json` and `agent_cmd.json` live at runtime
- `game/knowledge/` — persistent gameplay knowledge files (locations, characters, quests, strategies, items, world)
- `game/game_log.md` — append-only decision/action log (search with grep, never load fully)
- `docs/` — architecture docs and technical spec

## Important Engine Source Files

When implementing the agent bridge, these are the key files to understand and hook into:

| File | System | Why It Matters |
|------|--------|----------------|
| `engine/fallout2-ce/src/game.cc` | Main loop | Hook point for per-tick state emission and command reading |
| `engine/fallout2-ce/src/combat.cc` | Combat | Turn-based combat loop, AP management, attack resolution |
| `engine/fallout2-ce/src/game_dialog.cc` | Dialogue | NPC dialogue trees, response option presentation |
| `engine/fallout2-ce/src/input.cc` | Input | Synthetic input injection for AI commands |
| `engine/fallout2-ce/src/inventory.cc` | Inventory | Item management, equipment, barter |
| `engine/fallout2-ce/src/worldmap.cc` | World map | Overland travel, random encounters, location discovery |
| `engine/fallout2-ce/src/character_editor.cc` | Character | SPECIAL stats, skills, perks, level-up |

## Project Status

Active development — the agent bridge is implemented and supports:
- **Character creation**: Full SPECIAL/traits/skills/name editing with both bulk-set and incremental button-event commands
- **Exploration**: Map/object state emission (critters, items, scenery doors/transitions/containers, exit grids), movement via pathfinding (`move_to`/`run_to`), object interaction (`use_object`, `pick_up`, `use_skill`, `talk_to`, `use_item_on`, `look_at`)
- **Inventory**: Full inventory state (items, equipped, weight/capacity), equip/unequip/use commands
- **Combat**: AP/weapon/hostile state with per-location hit chances, attack/move/end_turn/use_combat_item commands
- **Dialogue**: Speaker name, reply text, all response options with `select_dialogue` command
- **Containers/Loot**: `open_container` opens loot screen, `loot_take`/`loot_take_all`/`loot_close` for item management
- **World map**: Position/area/car/walking state, `worldmap_travel` (auto-discovers areas), `worldmap_enter_location` to enter local maps
- **Barter**: Full merchant inventory with item costs, offer/request/remove commands, trade value estimation with `trade_info` (merchant_wants, party/npc barter skills, trade_will_succeed), `barter_confirm`/`barter_talk`/`barter_cancel`
- **Level-up**: XP tracking, `can_level_up`, `unspent_skill_points`, active perks list, `skill_add`/`skill_sub`/`perk_add` commands, available perks in character editor
- **Party**: Party member state (HP, equipment, position, dead status) emitted in all gameplay contexts
- **Message log**: Captures recent display monitor messages (skill check results, combat messages, area entry text) in `message_log` array
- **Quests/Holodisks**: Active quest tracking (110 quests from data files) with location, description, completed status, GVAR value; holodisk inventory
- **Karma/Reputation**: Player karma, 16 town-specific reputations, 8 addiction types tracked in character state
- **Context detection**: Fine-grained sub-contexts (`gameplay_exploration`, `gameplay_combat`, `gameplay_combat_wait`, `gameplay_dialogue`, `gameplay_inventory`, `gameplay_loot`, `gameplay_worldmap`, `gameplay_barter`)
- **Ranged weapons**: Equipped weapon ammo state (ammo_count/capacity/pid/name), damage_type/min/max, `reload_weapon` command
- **Item management**: `give_item` (spawn items, **test mode only**), `drop_item` (drop to ground), `enter_combat` / `flee_combat`
- **Game time**: hour, month, day, year, time_string, ticks
- **Death detection**: `player_dead` flag in state when `critterIsDead(gDude)` is true
- **UI commands**: `rest`, `pip_boy`, `character_screen`, `inventory_open`, `skilldex`
- **Movie skip**: `skip` command to bypass intro/transition movies; `ddraw.ini` with `SkipOpeningMovies=1` skips intro movies on launch
- **Test mode**: `set_test_mode` command to enable/disable cheat commands (`teleport`, `give_item`). Defaults to OFF. State emits `test_mode` flag.
- **Combat camera**: Engine mod — camera centers on each combatant at start of their turn (enemies, party members, player)
- **Detailed item stats**: Weapon stats (damage, AP cost, range, strength req, ammo), armor stats (AC, DR/DT per damage type), ammo stats (caliber, modifiers), item descriptions for all inventory items
- **Combat turn order**: Full combatant list with turn_order array, current_combatant_index, combat_round counter
- **Character resistances**: poison_resistance, radiation_resistance, damage_resistance (7 types), damage_threshold (7 types), age, gender
- **Kill counts**: Per-type kill tracking (Man, Radscorpion, Rat, etc.)
- **Perk descriptions**: Full description text for all active perks in gameplay state
- **Difficulty settings**: game_difficulty and combat_difficulty (easy/normal/hard) in state
- **Hit mode names**: Human-readable attack mode names in combat and inventory state
- **Object descriptions**: Proto descriptions for critters, ground items, and scenery (when different from name)
- **Knowledge system**: Persistent gameplay knowledge in `game/knowledge/` (locations, characters, quests, strategies, items, world) with searchable decision log in `game/game_log.md`
- **Attack pre-validation**: `_combat_check_bad_shot()` rejects attacks with clear errors (no ammo, out of range, not enough AP, etc.)

The Temple of Trials has been fully cleared legitimately by Claude Code (character creation, 3 dungeon levels, combat, lockpicking, explosive puzzle, Cameron's unarmed test). The agent bridge has traveled to Klamath, executed barter trades with NPCs, recruited Sulik, and tested ranged combat with ammo tracking. All major gameplay systems are functional.

## Testing

Always test new agent bridge functionality in the actual running game. The workflow is:

```bash
# 1. Build
cd engine/fallout2-ce/build
cmake .. -DAGENT_BRIDGE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make -j$(sysctl -n hw.ncpu)

# 2. Deploy + codesign (macOS requires re-signing after binary replacement)
cp -R "Fallout II Community Edition.app" ../../../game/
codesign --sign - --force --deep ../../../game/"Fallout II Community Edition.app"

# 3. Launch
cd ../../../game && open "Fallout II Community Edition.app"

# 4. Test by reading agent_state.json and writing agent_cmd.json
# Or run a test script from scripts/
```

Test scripts live in `scripts/`:
- `scripts/agent_test.sh` — basic smoke test (state file, tick advancing, mouse move)
- `scripts/test_character_creation.sh` — full flow: skip movies, main menu, character selector, character editor, create character

When adding new state enrichment or commands, always verify them end-to-end in the running game:
1. Build, deploy to `game/`, and launch
2. Send commands via `agent_cmd.json` and read back `agent_state.json`
3. **Verify state survives context transitions** — e.g. character creation changes must persist into actual gameplay, not just be visible in the editor. The engine has internal temp arrays and save/restore logic that can silently discard changes.
4. Leave the game running so you (or the user) can visually confirm in-game

## Agent Bridge Source Files

| File | Purpose |
|------|---------|
| `src/agent_bridge.h` | Public API: init/exit/tick/setContext, context constants |
| `src/agent_bridge_internal.h` | Shared declarations: json alias, extern globals, helper function decls |
| `src/agent_bridge.cc` | Core: init/exit, ticker, context detection, name-to-ID map builders, shared globals |
| `src/agent_state.cc` | All state emission: character, inventory, map/objects, combat, dialogue |
| `src/agent_commands.cc` | All command handlers: character creation, exploration, inventory, combat, dialogue |

### Engine Modifications

| File | Change |
|------|--------|
| `engine/fallout2-ce/src/game_dialog.h` | Added 6 accessor declarations (3 dialogue + 3 barter) |
| `engine/fallout2-ce/src/game_dialog.cc` | Added 6 accessor implementations (`agentGetDialog*`, `agentGetBarter*`) |
| `engine/fallout2-ce/src/display_monitor.h` | Added 2 accessor declarations for message log reading |
| `engine/fallout2-ce/src/display_monitor.cc` | Added `agentDisplayMonitorGetLineCount/GetLine` implementations |
| `engine/fallout2-ce/src/combat.h` | Added `extern int _combat_free_move`, 3 turn order accessor declarations |
| `engine/fallout2-ce/src/combat.cc` | Removed `static` from `_combat_free_move`, added `agentGetCombatantCount/GetCombatant/GetCurrentCombatantIndex` |
| `engine/fallout2-ce/src/loadsave.cc` | Added `agentQuickSave()`/`agentQuickLoad()` functions |
| `engine/fallout2-ce/src/loadsave.h` | Added declarations for `agentQuickSave()`/`agentQuickLoad()`/`agentSaveToSlot()`/`agentLoadFromSlot()` |
| `engine/fallout2-ce/src/pipboy.h` | Added 12 accessor declarations for quest/holodisk data |
| `engine/fallout2-ce/src/pipboy.cc` | Added `agentInitQuestData()`, quest/holodisk accessor implementations (~90 lines) |
| `engine/fallout2-ce/src/worldmap.h` | Added 8 accessor declarations for world map area/entrance queries |
| `engine/fallout2-ce/CMakeLists.txt` | Added `agent_state.cc`, `agent_commands.cc`, `agent_bridge_internal.h` to AGENT_BRIDGE sources |

### Engine Patches

Engine modifications to `engine/fallout2-ce/` are stored as a patch file in `engine/patches/` and applied on top of the upstream submodule. This preserves our changes in version control without forking the upstream repo.

**After cloning / pulling:**
```bash
git submodule update --init --recursive
./scripts/apply-patches.sh
```

**After modifying engine files:**
When you change any file inside `engine/fallout2-ce/src/`, regenerate the patch:
```bash
./scripts/generate-patches.sh
git add engine/patches/
git commit -m "Update engine patches"
```

**Updating upstream:**
To pull new upstream changes and re-apply patches:
```bash
cd engine/fallout2-ce
git stash          # stash our modifications
git pull           # pull upstream
git stash pop      # re-apply (resolve conflicts if needed)
cd ../..
./scripts/generate-patches.sh  # regenerate patch
```

### Command Reference

**Exploration:** `move_to`, `run_to`, `use_object`, `pick_up`, `use_skill`, `talk_to`, `use_item_on`, `look_at`
**Inventory:** `equip_item`, `unequip_item`, `use_item`, `reload_weapon`, `drop_item`, `give_item`
**Combat:** `attack`, `end_turn`, `use_combat_item`, `enter_combat`, `flee_combat`
**Dialogue:** `select_dialogue`
**Barter:** `barter_offer`, `barter_remove_offer`, `barter_request`, `barter_remove_request`, `barter_confirm`, `barter_talk`, `barter_cancel`
**Level-up:** `skill_add`, `skill_sub`, `perk_add`
**Interface:** `switch_hand`, `cycle_attack_mode`, `center_camera`, `rest`, `pip_boy`, `character_screen`, `inventory_open`, `skilldex`
**Navigation:** `map_transition` (map=-2 only without test mode), `teleport` (test mode), `find_path`, `tile_objects`, `worldmap_travel`, `worldmap_enter_location`
**Containers:** `open_container`, `loot_take`, `loot_take_all`, `loot_close`
**Save/Load:** `quicksave`, `quickload`, `save_slot`, `load_slot` (direct engine API, no UI)
**Character creation:** `set_special`, `select_traits`, `tag_skills`, `set_name`, `finish_character_creation`, `adjust_stat`, `toggle_trait`, `toggle_skill_tag`, `editor_done`
**Raw input:** `mouse_move`, `mouse_click`, `input_event`, `skip` (escape key for movies)
**Menu:** `main_menu`, `main_menu_select`, `char_selector_select`

### Executor Functions (`scripts/executor.sh`)

Source with `source scripts/executor.sh` to get high-level gameplay helpers:

| Function | Description |
|----------|-------------|
| `do_combat [timeout] [heal%]` | Full combat loop with wall-clock timeout (default 60s) and failure detection |
| `exit_through <dest\|any>` | Walk onto exit grids to trigger natural map transitions (no cheating) |
| `arm_and_detonate <id> <safe_tile> [pid] [timer]` | Full explosive workflow: walk adjacent, arm, flee, wait for detonation |
| `explore_area [max_dist]` | Loot all containers and pick up ground items within range |
| `examine_object <id>` | Look at an object and report the result |
| `check_inventory_for <keyword>` | Search inventory by keyword |
| `move_and_wait <tile>` | Move to tile, wait for arrival |
| `loot_all <id>` | Open container, take all, close |
| `talk_and_choose <id> <opt1> ...` | Talk to NPC with dialogue option sequence |
| `snapshot` | Compact state summary |
| `objects_near` | Nearby objects for planning |
| `inventory_summary` | Full inventory listing |
| `game_log <text>` | Append timestamped entry to game log with auto game state header |
| `recall <keyword>` | Search all knowledge files and game log for keyword |
| `note <category> <text>` | Append text to a knowledge file (locations/characters/quests/strategies/items/world) |

### Information Boundaries & Fair Play

- **No metagaming**: The agent must explore, loot, examine, and reason from in-game clues — not assume hidden knowledge from previous playthroughs
- **No cheat commands in normal play**: `teleport`, `give_item`, and `map_transition` (map>=0) require test mode
- **Explosives must be armed properly**: Use `arm_explosive` through the engine's explosion system, not direct object destruction
- **Exit grids must be walked onto**: Use `exit_through` to naturally trigger transitions, not forced `map_transition`
- **General gameplay knowledge is OK**: Reference `docs/gameplay-guide.md` for mechanics (how skills work, combat strategy, etc.)

## Important Gotchas

- **Object IDs**: `obj->id` is NOT unique across objects. Multiple critters/objects can share the same id. We use pointer-based unique IDs (`reinterpret_cast<uintptr_t>(obj)`) instead, validated by iterating the object list in `findObjectByUniqueId()`.
- **Escape = Options menu**: In `game.cc`, `KEY_ESCAPE` falls through to `KEY_UPPERCASE_O`, opening the options menu. Escape keys from movie skipping can leak into gameplay and leave `GameMode::kOptions` stuck. Always check for and dismiss this after entering gameplay.
- **macOS codesign**: After `cp -R` of the built .app to `game/`, must run `codesign --sign - --force --deep` before launching with `open`, or macOS will refuse to launch it.
- **Quickload crashes from main menu**: `agentQuickLoad()` cannot be called from the main menu context — the game state isn't initialized enough. Need to either start a game first or use the main menu's load UI.
- **Weapon hand switching**: Fallout 2 defaults to left hand (punch/kick). The spear goes in the right hand slot. Must call `switch_hand` to select the right hand before attacking with the spear.
- **Character editor temp arrays**: See memory notes — the editor copies traits/skills into temp arrays at init and writes them back on close. Modifications must update both globals and temp arrays.
- **Command JSON format**: Commands MUST be wrapped in `{"commands":[...]}` array. Bare `{"type":"..."}` objects are silently ignored — `processCommands()` checks `doc.contains("commands")` and returns if missing.
- **Quest data lazy loading**: Quest/holodisk data only loads when the Pip-Boy is first opened (`questInit()` called inside `pipboyOpen()`). Use `agentInitQuestData()` to force-load for state emission.
- **World map entry**: Use `map_transition` with `map=-2` to enter the world map (triggers `wmWorldMap()` in `map.cc`). World map area IDs: 0=Arroyo, 1=Den, 2=Klamath, 3=Modoc, 4=Vault City, 5=Gecko, etc.
- **map_transition gated by test mode**: Direct map transitions (`map >= 0`) now require test mode, since players can't teleport between maps. Only `map=-2` (world map entry) is always allowed.
- **Explosives require arm_explosive, not use_item_on**: The old failsafe that directly destroyed scenery when using explosives has been removed. `use_item_on` with explosives will return `no_override`. Use `arm_explosive` (via the Traps skill) to properly arm, place, and detonate explosives through the engine's normal explosion system.
- **mainmenu.cc recompilation**: After modifying bridge globals (like `gAgentMainMenuAction`), `mainmenu.cc` may use stale object files. Run `touch ../src/mainmenu.cc` before building to force recompilation.
- **Barter confirm is direct**: `barter_confirm` uses direct `itemMoveAll()` instead of key injection because the barter UI loop's `inputGetInput()` doesn't consume events enqueued from our ticker. The implementation replicates `_barter_compute_value` formula.
- **Items don't survive map_transition**: Items added via `give_item`/`objectCreateWithPid` become corrupted "Scroll Blocker" after `map_transition`. Always give items AFTER arriving at the destination map.
- **Intro movies and tick freezing**: During intro movie playback (`gameMoviePlay`), the ticker fires from `inputGetInput()` but tick stays at 1. Use `ddraw.ini` with `SkipOpeningMovies=1` to bypass. For in-game movies, `skip` command works.
- **Load game from main menu**: Use `main_menu` action `load_game` (sets `gAgentMainMenuAction=2`), then `input_event` with `key_code=13` (Enter) to confirm the first save slot in the load dialog.

## Shell Helpers for Game Interaction

Claude Code interacts with the game via file-based IPC. These shell patterns are the standard way to read state and send commands:

```bash
GAME_DIR="/Users/alexis.radcliff/fallout2-sdk/game"
STATE_FILE="$GAME_DIR/agent_state.json"
CMD_FILE="$GAME_DIR/agent_cmd.json"
CMD_TMP="$GAME_DIR/agent_cmd.tmp"
```

### Send a command

Commands MUST be wrapped in a `{"commands":[...]}` array. Use atomic write (write to tmp, then rename) to avoid partial reads:

```bash
# Send a single command
echo '{"commands":[{"type":"move_to","tile":15887}]}' > "$CMD_TMP" && mv "$CMD_TMP" "$CMD_FILE"

# Send multiple commands in one batch
echo '{"commands":[
  {"type":"equip_item","item_pid":7,"hand":"right"},
  {"type":"switch_hand"}
]}' > "$CMD_TMP" && mv "$CMD_TMP" "$CMD_FILE"
```

### Read state fields

```bash
# Read a dotted field path from agent_state.json
python3 -c "
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
val = d
for key in 'player.tile'.split('.'):
    val = val.get(key) if isinstance(val, dict) else None
print(val if val is not None else 'null')
"

# Read full state as formatted JSON
python3 -m json.tool "$STATE_FILE"

# Read current context
python3 -c "import json; print(json.load(open('$STATE_FILE')).get('context','unknown'))"
```

### Wait for a context

```bash
# Wait for a specific context (with timeout)
for i in $(seq 1 60); do
    ctx=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('context',''))" 2>/dev/null)
    if [ "$ctx" = "gameplay_exploration" ]; then break; fi
    sleep 0.5
done

# Wait for any gameplay_* context
for i in $(seq 1 60); do
    ctx=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('context',''))" 2>/dev/null)
    if [[ "$ctx" == gameplay_* ]]; then break; fi
    sleep 0.5
done
```

### Dismiss stuck options menu

After skipping movies, escape keys can leak into gameplay and open the options menu. Check and dismiss:

```bash
gm=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('game_mode',0))" 2>/dev/null)
if [ "$gm" = "8" ] || [ "$gm" = "24" ]; then
    echo '{"commands":[{"type":"key_press","key":"escape"}]}' > "$CMD_TMP" && mv "$CMD_TMP" "$CMD_FILE"
    sleep 1
fi
```

## Documentation Sync

When making changes to the agent bridge (new commands, new state fields, engine modifications, file restructuring), always update:
1. This file (CLAUDE.md) — especially the Agent Bridge Source Files table, Command Reference, and Project Status
2. README.md — the Architecture section's state emission and command lists
3. Memory files — record any new gotchas or patterns in auto memory

## Code Review with Codex

Use OpenAI Codex CLI (installed at `/opt/homebrew/bin/codex`, model `gpt-5.3-codex`) for a second-opinion code review on significant changes. Run after committing:

```bash
codex exec "Review the git diff of the last N commits (git diff HEAD~N..HEAD) for bugs, logic errors, and issues. Report any problems found."
```

This catches cross-layer contract mismatches (e.g., SDK type fields not matching C++ bridge expectations) that single-perspective review often misses.

## Session Journal

See `docs/journal.md` for a log of what was done in each session.

## Knowledge Management

Claude maintains persistent gameplay knowledge in `game/knowledge/` and a decision log in `game/game_log.md`.

### When to Take Notes
- **After exploring a new map**: Record layout, NPCs, exits, containers found -> `locations.md`
- **After meeting an NPC**: Record name, role, key dialogue, quests -> `characters.md`
- **After receiving a quest or clue**: Record objectives, hints, strategy -> `quests.md`
- **After combat**: Record what worked, enemy weaknesses, HP/ammo spent -> `strategies.md`
- **After finding notable items**: Record what, where, possible uses -> `items.md`
- **After learning world lore**: Record factions, events, politics -> `world.md`
- **At every major decision point**: Log the decision + reasoning -> `game_log.md`

### How to Take Notes
- Use `source scripts/executor.sh && note <category> "<text>"`
- Update EXISTING entries rather than duplicating -- merge new info with old
- Keep knowledge files under 150 lines by consolidating
- Always include tags in game log entries for searchability

### How to Search
- Use `/game-recall <keyword>` (or `source scripts/executor.sh && recall "<keyword>"`)
- Read a specific knowledge file when you need full context on a topic
- NEVER load the full game_log.md -- always grep/search it

### File Locations
- `game/knowledge/locations.md` -- maps, exits, features
- `game/knowledge/characters.md` -- NPCs, dialogue, quests
- `game/knowledge/quests.md` -- objectives, clues, progress
- `game/knowledge/strategies.md` -- combat, skills, tactics
- `game/knowledge/items.md` -- notable items, equipment, keys
- `game/knowledge/world.md` -- factions, lore, economy
- `game/game_log.md` -- decision/action log (append-only, search-only)

## Dependencies

- CMake 3.13+, C++17 compiler, SDL2 (bundled by default via `FALLOUT_VENDORED` CMake option)
- nlohmann/json (fetched via CMake FetchContent for JSON serialization)
- Python 3 (for shell helper scripts that parse JSON state)
