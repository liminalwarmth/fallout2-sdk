# fallout2-sdk

A Claude Code Gameplay Enablement Project that allows [Claude](https://claude.ai/) to play Fallout 2.

## Overview

fallout2-sdk bridges Claude Code and Fallout 2 by modifying the [Fallout 2 Community Edition (CE)](https://github.com/alexbatalov/fallout2-ce) open-source engine to emit structured game state and accept input commands via JSON files. Claude observes the game world each tick, reasons about objectives and tactics, and issues commands — playing Fallout 2 autonomously through an observe → reason → act loop.

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

## Building

Apply engine patches (required after cloning or pulling), then build:

```bash
./scripts/apply-patches.sh

cd engine/fallout2-ce
mkdir -p build && cd build
cmake .. -DAGENT_BRIDGE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make -j$(sysctl -n hw.ncpu)

# Deploy and launch (macOS)
cp -R "Fallout II Community Edition.app" ../../../game/
codesign --sign - --force --deep ../../../game/"Fallout II Community Edition.app"
cd ../../../game && open "Fallout II Community Edition.app"
```

CMake presets in `engine/fallout2-ce/CMakePresets.json` support cross-platform builds (macOS, Windows, Linux, iOS, Android).

## Architecture

The agent bridge hooks into the Fallout 2 CE engine to provide two-way JSON communication:

- **State emission** (`game/agent_state.json`) — player stats/skills/perks, map/objects, inventory, combat (AP, hostiles, hit chances), dialogue, barter, world map, quests, party, message log, game time — across 11 fine-grained contexts
- **Command input** (`game/agent_cmd.json`) — 50+ commands for exploration, combat, dialogue, inventory, barter, world map, level-up, save/load, and character creation

Key integration points: ticker callback (per-tick state/commands), context hooks (`mainmenu.cc`, `character_selector.cc`, `character_editor.cc`, `main.cc`), animation system (`reg_anim_*`), action system (`actionPickUp`, `actionUseSkill`, etc.), and custom accessor functions for static engine state.

See [`CLAUDE.md`](CLAUDE.md) for development instructions, [`docs/claude/`](docs/claude/) for mode-specific guides, and [`docs/fallout2-sdk-technical-spec.md`](docs/fallout2-sdk-technical-spec.md) for the full technical spec.

## Project Status

Active development. The agent bridge has been validated through:

- **Temple of Trials** — fully cleared legitimately by Claude Code (character creation, 3 dungeon levels, combat, lockpicking, explosive puzzle, Cameron's unarmed test, vault suit movie)
- **Klamath** — world map travel, NPC dialogue trees, barter trading, ranged combat with ammo tracking, container looting, Sulik recruitment
- **All major gameplay systems** functional: exploration, combat, dialogue, inventory, barter, world map, quests, level-up, party, save/load

See [`docs/journal.md`](docs/journal.md) for session-by-session development history.

## License

This project is licensed under the [MIT License](LICENSE).

**Note:** The Fallout 2 CE engine (in `engine/fallout2-ce/`) is licensed under the [Sustainable Use License](https://github.com/alexbatalov/fallout2-ce/blob/main/LICENSE). Fallout 2 game data files are copyrighted by Interplay/Bethesda and require a legal copy of the game.
