# Play Mode — Gameplay

Briefing for gameplay subagents. You are playing Fallout 2 via file-based IPC in `game/`.

## Play Mode Rules

- NEVER enable test mode during normal gameplay (`teleport`, `give_item`, `map_transition` map>=0 are gated)
- NEVER metagame — explore, loot, examine, and reason from in-game clues only
- NEVER edit files in `src/` or `engine/` — play mode is read-only for source code
- ALWAYS `source scripts/executor.sh` first — it has the full action reference and information boundaries in its header
- Reference `docs/gameplay-guide.md` for general game mechanics (skills, combat strategy, etc.)

## Command Quick Reference

Full argument signatures are in `scripts/executor.sh` header. Commands require `{"commands":[...]}` wrapper.

**Exploration:** `move_to`, `run_to`, `use_object`, `pick_up`, `look_at`, `use_skill`, `use_item_on`, `talk_to`, `open_container`, `enter_combat`
**Inventory:** `equip_item`, `unequip_item`, `use_item`, `reload_weapon`, `drop_item`, `switch_hand`, `cycle_attack_mode`
**Combat:** `attack`, `combat_move`, `end_turn`, `use_combat_item`, `flee_combat`
**Dialogue:** `select_dialogue`
**Loot:** `loot_take`, `loot_take_all`, `loot_close`
**Barter:** `barter_offer`, `barter_remove_offer`, `barter_request`, `barter_remove_request`, `barter_confirm`, `barter_talk`, `barter_cancel`
**World map:** `worldmap_travel`, `worldmap_enter_location`, `map_transition` (map=-2 only)
**Level-up:** `skill_add`, `skill_sub`, `perk_add`
**Interface:** `rest`, `pip_boy`, `character_screen`, `inventory_open`, `skilldex`, `center_camera`
**Save/Load:** `quicksave`, `quickload`, `save_slot`, `load_slot`
**Navigation:** `find_path`, `tile_objects`
**Menu/Movies:** `main_menu`, `skip`

## Executor Functions

Source with `source scripts/executor.sh` for high-level helpers:

| Function | Description |
|----------|-------------|
| `do_combat [timeout] [heal%]` | Full combat loop with timeout and failure detection |
| `exit_through <dest\|any>` | Walk onto exit grids for natural map transitions |
| `arm_and_detonate <id> <safe_tile> [pid] [timer]` | Full explosive workflow |
| `explore_area [max_dist]` | Loot all containers and pick up ground items |
| `move_and_wait <tile>` | Move to tile, wait for arrival |
| `loot_all <id>` | Open container, take all, close |
| `talk_and_choose <id> <opt1> ...` | Talk to NPC with dialogue sequence |
| `snapshot` | Compact state summary |
| `objects_near` | Nearby objects for planning |
| `inventory_summary` | Full inventory listing |
| `examine_object <id>` | Look at object and report result |
| `check_inventory_for <keyword>` | Search inventory by keyword |

## Knowledge Management

Take notes as you play — use `game-note`, `game-recall`, `game-log` skills, or the executor helpers:

**When to note:** After exploring a new map, meeting an NPC, receiving a quest/clue, combat, finding items, learning lore, or at major decision points.

| Helper | Usage |
|--------|-------|
| `note <category> "<text>"` | Append to knowledge file (locations/characters/quests/strategies/items/world) |
| `recall "<keyword>"` | Search all knowledge files and game log |
| `game_log "<text>"` | Append timestamped entry to game log |

**Files:** `game/knowledge/locations.md`, `characters.md`, `quests.md`, `strategies.md`, `items.md`, `world.md`
**Decision log:** `game/game_log.md` — append-only, NEVER load fully, always search/grep

Update existing entries rather than duplicating. Keep knowledge files under 150 lines by consolidating.
