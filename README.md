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
├── src/                    # SDK engine modifications (patches applied on top of CE)
├── scripts/                # Setup and utility scripts
├── game/                   # Local Fallout 2 game data (NOT committed — see Setup)
├── docs/                   # Architecture and design documentation
├── sdk.cfg.example         # Example configuration
├── sdk.cfg                 # Local configuration (git-ignored)
└── build/                  # Build output (git-ignored)
```

## Prerequisites

- **Fallout 2** — A legal copy from [GOG](https://www.gog.com/game/fallout_2), [Steam](https://store.steampowered.com/app/38410/Fallout_2_A_Post_Nuclear_Role_Playing_Game/), or other retailer
- **CMake** 3.13+
- **C++17 compiler** (Clang on macOS, MSVC on Windows, GCC on Linux)
- **SDL2** (bundled with the CE build by default)
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
  - Player stats, skills, traits, HP, AP, position, level, and experience
  - Map info (name, index, elevation) and player tile position
  - Nearby objects: critters (with HP/dead status), ground items, scenery (doors with locked/open state), and exit grids (with destinations)
  - Inventory: all carried items with type/weight, equipped items (both hands + armor), carry capacity
  - Combat state: current/max AP, free move, active weapon stats, hostiles with per-location hit chances
  - Dialogue state: speaker name/ID, NPC reply text, and all selectable response options
  - Fine-grained context detection: `gameplay_exploration`, `gameplay_combat`, `gameplay_combat_wait`, `gameplay_dialogue`, `gameplay_inventory`, `gameplay_loot`

- **Accepts input commands** via a command file, supporting:
  - Movement: `move_to`, `run_to` (pathfinding + animation, triggers combat/traps/exit grids)
  - Exploration: `use_object`, `pick_up`, `use_skill`, `talk_to`, `use_item_on`, `look_at`
  - Inventory: `equip_item`, `unequip_item`, `use_item`
  - Combat: `attack` (with hit mode + aimed location), `combat_move`, `end_turn`, `use_combat_item`
  - Dialogue: `select_dialogue` (by option index)
  - Character creation: `set_special`, `select_traits`, `tag_skills`, `set_name`, `finish_character_creation`, `adjust_stat`, `toggle_trait`, `toggle_skill_tag`
  - Raw input: `mouse_move`, `mouse_click`, `key_press`, `key_release`
  - Menu navigation: `main_menu_select`, `char_selector_select`

Key engine integration points:
- **Ticker callback** — registered via the engine's ticker system for per-tick state emission and command reading
- **Context hooks** — manual hooks in `mainmenu.cc`, `character_selector.cc`, `character_editor.cc`, and `main.cc`
- **Animation system** — all movement/interaction commands go through `reg_anim_begin`/`animationRegisterMoveToTile`/`reg_anim_end` so triggers fire normally
- **Action system** — `actionPickUp`, `actionUseSkill`, `actionTalk`, etc. handle walk-to + interact
- **Dialogue accessors** — custom `agentGetDialogOptionCount/Text/ReplyText` functions expose static dialogue state

## Project Status

Active development. The agent bridge supports character creation and full Temple of Trials gameplay (exploration, combat, inventory, dialogue). See [`docs/fallout2-sdk-technical-spec.md`](docs/fallout2-sdk-technical-spec.md) for the full technical spec.

## License

This project is licensed under the [MIT License](LICENSE).

**Note:** The Fallout 2 CE engine (in `engine/fallout2-ce/`) is licensed under the [Sustainable Use License](https://github.com/alexbatalov/fallout2-ce/blob/main/LICENSE). Fallout 2 game data files are copyrighted by Interplay/Bethesda and require a legal copy of the game.
