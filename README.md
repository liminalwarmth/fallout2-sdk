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
  - Player stats, skills, perks, HP, AP, position, inventory, and equipment
  - Visible map objects (NPCs, items, scenery) with positions and properties
  - Combat state (turn order, AP, target info, available actions)
  - Dialogue trees (NPC text, available response options)
  - World map state (known locations, current position, travel status)
  - Active quests and global variable state

- **Accepts input commands** via a command file, supporting:
  - Movement (hex tile targets, world map destinations)
  - Combat actions (attack, use item, end turn, target selection)
  - Dialogue choices (select response by index)
  - Inventory management (use, equip, drop, give)
  - Skill usage (lockpick, repair, speech, etc.)

Key engine integration points:
- **Main loop hook** (`game.cc`) — emits state and reads commands each tick
- **Input injection** (`input.cc`) — translates AI commands into synthetic input events
- **Sfall opcode extensions** — custom opcodes for AI-specific queries
- **Ticker callback** — registered via the engine's ticker system for periodic state dumps

## Project Status

Early development. Not yet playable.

## License

This project is licensed under the [MIT License](LICENSE).

**Note:** The Fallout 2 CE engine (in `engine/fallout2-ce/`) is licensed under the [Sustainable Use License](https://github.com/alexbatalov/fallout2-ce/blob/main/LICENSE). Fallout 2 game data files are copyrighted by Interplay/Bethesda and require a legal copy of the game.
