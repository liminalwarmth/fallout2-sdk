# fallout2-sdk

A Claude Code Gameplay Enablement Project that allows [Claude](https://claude.ai/) to play Fallout 2.

## Overview

fallout2-sdk bridges Claude Code and Fallout 2 by modifying the [Fallout 2 Community Edition (CE)](https://github.com/alexbatalov/fallout2-ce) open-source engine to emit structured game state information that Claude can read and act upon. This enables Claude to observe the game world, reason about it, and issue commands — effectively playing Fallout 2 autonomously.

## How It Works

1. **Game State Emission** — A modified Fallout 2 CE build exports game state (map, inventory, dialogue, combat, NPCs, etc.) as JSON to a known file path each tick.
2. **Claude Code Integration** — Claude reads the emitted game state, reasons about objectives and tactics, and writes input commands to a command file that the engine picks up.
3. **Gameplay Loop** — The observe → reason → act loop runs continuously, allowing Claude to navigate the wasteland, engage in dialogue, manage inventory, and fight through encounters.

## Project Structure

```
fallout2-sdk/
├── engine/fallout2-ce/     # Fallout 2 CE (git submodule) — upstream engine
├── src/                    # C++ agent bridge (patches applied on top of CE)
│   ├── agent_bridge.cc     # Core: init/exit, ticker, context detection
│   ├── agent_bridge.h      # Public API
│   ├── agent_bridge_internal.h  # Shared internals
│   ├── agent_state.cc      # All state emission (character, map, combat, dialogue, etc.)
│   └── agent_commands.cc   # All command handlers (50+ commands)
├── scripts/                # Setup and test scripts
├── game/                   # Local Fallout 2 game data (NOT committed — see Setup)
│   ├── agent_state.json    # Game state output (written every tick by bridge)
│   └── agent_cmd.json      # Command input (read and consumed by bridge)
├── docs/                   # Architecture docs, technical spec, session journal
└── CLAUDE.md               # Claude Code project instructions
```

## Prerequisites

- **Fallout 2** — A legal copy from [GOG](https://www.gog.com/game/fallout_2), [Steam](https://store.steampowered.com/app/38410/Fallout_2_A_Post_Nuclear_Role_Playing_Game/), or other retailer
- **CMake** 3.13+
- **C++17 compiler** (Clang on macOS, MSVC on Windows, GCC on Linux)
- **SDL2** (bundled with the CE build by default)
- **Python 3** (for JSON state parsing in shell helpers)
- **Git**

## Setup

### 1. Clone the repository

```bash
git clone --recurse-submodules https://github.com/liminalwarmth/fallout2-sdk.git
cd fallout2-sdk
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 2. Provide Fallout 2 game data

The SDK needs the original Fallout 2 data files (`master.dat`, `critter.dat`, `patch000.dat`, etc.). These are copyrighted and **not included** in this repository.

#### Option A: Setup script (recommended)

```bash
# Interactive — will prompt you for the source
./scripts/setup.sh

# From an existing installation directory
./scripts/setup.sh --from /path/to/fallout2/install

# From a GOG macOS DMG
./scripts/setup.sh --from-dmg ~/Downloads/fallout_2_2.0.0.4.dmg
```

#### Option B: Manual copy

Copy the following from your Fallout 2 installation into `game/`:

| File / Directory | Required |
|---|---|
| `master.dat` | Yes |
| `critter.dat` | Yes |
| `patch000.dat` | Yes |
| `fallout2.cfg` | Optional (generated if missing) |
| `data/` | Optional (override data) |
| `sound/music/` | Optional (music files) |

#### Where to find your game files

**macOS (GOG):**
Right-click the app, choose "Show Package Contents", then navigate to:
```
Contents/Resources/game/Fallout 2.app/Contents/Resources/drive_c/Program Files/GOG.com/Fallout 2/
```

**Windows (GOG):**
```
C:\GOG Games\Fallout 2\
```

**Windows (Steam):**
```
C:\Program Files (x86)\Steam\steamapps\common\Fallout 2\
```

**Linux (GOG via Wine):**
```
~/.wine/drive_c/GOG Games/Fallout 2/
```

### 3. Verify setup

After copying game files, check that the required files are in place:

```bash
ls -lh game/master.dat game/critter.dat game/patch000.dat
```

You should see `master.dat` (~318 MB), `critter.dat` (~159 MB), and `patch000.dat` (~2.2 MB).

## Architecture

The SDK modifies the Fallout 2 CE engine to add an **AI bridge layer** that:

- **Emits game state** as structured JSON after each game tick, covering:
  - Player stats, skills, traits, perks, HP, AP, position, level, experience, karma, town reputations, addictions
  - Map info (name, index, elevation) and player tile/rotation/neighbors with walkability
  - Nearby objects: critters (HP, team, party membership), ground items, scenery (doors, containers), exit grids (with destination map names)
  - Inventory: all carried items with type/weight, equipped items (both hands + armor with ammo/damage stats), carry capacity
  - Combat state: current/max AP, free move, active weapon stats for current hand, hostiles with per-location hit chances, attack pre-validation
  - Dialogue state: speaker name/unique ID, NPC reply text, all selectable response options
  - Loot/container state: target info, container items with quantities
  - Barter state: merchant inventory with costs, offer/request tables, trade value estimation
  - World map state: position, known areas with entrances, walking/car status
  - Quest tracking: 110 quests with location, description, completion status
  - Party members: HP, equipment, position, dead status
  - Message log: recent skill checks, combat messages, area entry text
  - Game time: hour, day, month, year
  - 11 fine-grained contexts: `movie`, `main_menu`, `character_selector`, `character_editor`, `gameplay_exploration`, `gameplay_combat`, `gameplay_combat_wait`, `gameplay_dialogue`, `gameplay_inventory`, `gameplay_loot`, `gameplay_worldmap`, `gameplay_barter`

- **Accepts 50+ input commands** via a command file, supporting:
  - Movement: `move_to`, `run_to` (multi-waypoint pathfinding), `combat_move`
  - Exploration: `use_object`, `pick_up`, `use_skill`, `talk_to`, `use_item_on`, `look_at`
  - Inventory: `equip_item`, `unequip_item`, `use_item`, `reload_weapon`, `drop_item`, `arm_explosive`
  - Combat: `attack` (with hit mode + aimed location), `end_turn`, `use_combat_item`, `enter_combat`, `flee_combat`
  - Dialogue: `select_dialogue` (by option index)
  - Containers: `open_container`, `loot_take`, `loot_take_all`, `loot_close`
  - Barter: `barter_offer`, `barter_remove_offer`, `barter_request`, `barter_remove_request`, `barter_confirm`, `barter_talk`, `barter_cancel`
  - Level-up: `skill_add`, `skill_sub`, `perk_add`
  - World map: `worldmap_travel`, `worldmap_enter_location`, `map_transition`
  - Interface: `switch_hand`, `cycle_attack_mode`, `center_camera`, `rest`, `pip_boy`, `character_screen`, `inventory_open`, `skilldex`, `toggle_sneak`
  - Save/Load: `quicksave`, `quickload`, `save_slot`, `load_slot`
  - Character creation: `set_special`, `select_traits`, `tag_skills`, `set_name`, `editor_done`, `adjust_stat`, `toggle_trait`, `toggle_skill_tag`
  - Menu navigation: `main_menu`, `main_menu_select`, `char_selector_select`, `skip`
  - Debug: `find_path`, `tile_objects`, `find_item`, `teleport` (test mode only), `give_item` (test mode only)

### Claude Code Integration

Claude Code interacts with the game via simple file I/O:

```bash
# Read game state
python3 -c "import json; d=json.load(open('game/agent_state.json')); print(d['context'])"

# Send a command (atomic write)
echo '{"commands":[{"type":"move_to","tile":15887}]}' > game/agent_cmd.tmp && mv game/agent_cmd.tmp game/agent_cmd.json
```

See `CLAUDE.md` for the full set of shell helper patterns.

Key engine integration points:
- **Ticker callback** — registered via the engine's ticker system for per-tick state emission and command reading
- **Context hooks** — manual hooks in `mainmenu.cc`, `character_selector.cc`, `character_editor.cc`, and `main.cc`
- **Animation system** — all movement/interaction commands go through `reg_anim_begin`/`animationRegisterMoveToTile`/`reg_anim_end` so triggers fire normally
- **Action system** — `actionPickUp`, `actionUseSkill`, `actionTalk`, etc. handle walk-to + interact
- **Dialogue accessors** — custom `agentGetDialogOptionCount/Text/ReplyText` functions expose static dialogue state

## Project Status

Active development. The agent bridge has been validated through:

- **Temple of Trials** — fully cleared legitimately by Claude Code (character creation, 3 dungeon levels, combat, lockpicking, explosive puzzle, Cameron's unarmed test, vault suit movie)
- **Klamath** — world map travel, NPC dialogue trees, barter trading, ranged combat with ammo tracking, container looting, Sulik recruitment
- **All major gameplay systems** functional: exploration, combat, dialogue, inventory, barter, world map, quests, level-up, party, save/load

See [`docs/fallout2-sdk-technical-spec.md`](docs/fallout2-sdk-technical-spec.md) for the full technical spec and [`docs/journal.md`](docs/journal.md) for session-by-session development history.

## License

This project is licensed under the [MIT License](LICENSE).

**Note:** The Fallout 2 CE engine (in `engine/fallout2-ce/`) is licensed under the [Sustainable Use License](https://github.com/alexbatalov/fallout2-ce/blob/main/LICENSE). Fallout 2 game data files are copyrighted by Interplay/Bethesda and require a legal copy of the game.
