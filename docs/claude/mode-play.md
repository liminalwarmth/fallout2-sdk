# Play Mode — Gameplay

Briefing for gameplay sessions. You are playing Fallout 2 via file-based IPC in `game/`.

## Play Mode Rules

- NEVER enable test mode during normal gameplay (`teleport`, `give_item`, `map_transition` map>=0 are gated)
- NEVER metagame — explore, loot, examine, and reason from in-game clues only
- NEVER edit files in `src/` or `engine/` — play mode is read-only for source code
- ALWAYS `source scripts/executor.sh` first — it has the full action reference and information boundaries in its header
- Reference `docs/gameplay-guide.md` for general game mechanics (skills, combat strategy, etc.)

## Command Quick Reference

Full argument signatures are in `scripts/executor.sh` header. Commands require `{"commands":[...]}` wrapper.

**Exploration:** `move_to`, `run_to`, `use_object`, `pick_up`, `look_at`, `use_skill`, `use_item_on`, `talk_to`, `open_container`, `enter_combat`
**Inventory:** `equip_item`, `unequip_item`, `use_item`, `use_equipped_item`, `reload_weapon`, `drop_item`, `switch_hand`, `cycle_attack_mode`
**Combat:** `attack`, `combat_move`, `end_turn`, `use_combat_item`, `flee_combat`
**Dialogue:** `select_dialogue`
**Loot:** `loot_take`, `loot_take_all`, `loot_close`
**Barter:** `barter_offer`, `barter_remove_offer`, `barter_request`, `barter_remove_request`, `barter_confirm`, `barter_talk`, `barter_cancel`
**World map:** `worldmap_travel`, `worldmap_enter_location`, `map_transition` (map=-2 only)
**Level-up (editor open):** `skill_add`, `skill_sub`, `perk_add`
**Interface:** `rest`, `pip_boy`, `character_screen`, `inventory_open`, `skilldex`, `center_camera`
**Save/Load:** `quicksave`, `quickload`, `save_slot`, `load_slot`
**Navigation:** `find_path`, `tile_objects`
**Menu/Movies:** `main_menu`, `skip`

## Interaction Patterns

Every game interaction follows a predictable sequence. Plan these as step lists, then execute them as a script. Don't fumble through one command at a time.

**Door (unlocked):**
1. `run_to <door_tile>` or `move_and_wait <adjacent_tile>` — get close
2. `use_object_and_wait <door_id>` — open the door
3. `move_and_wait <tile_beyond_door>` — walk through before it auto-closes

**Door (locked):**
1. `move_and_wait <adjacent_tile>` — get close
2. `use_skill_and_wait lockpick <door_id>` — attempt lockpick (may need multiple tries)
3. If unlocked: `use_object_and_wait <door_id>` → `move_and_wait <tile_beyond>`

**Container:** Use `loot_all <container_id>` — handles open, take all, close in one call.

**Ground item:** `move_and_wait <item_tile>` → `pick_up <item_id>` (or use `explore_area` to grab everything nearby).

**NPC dialogue:** `talk_and_choose <npc_id> <option1> <option2> ...` — walks to NPC, initiates dialogue, selects options in sequence.

**Combat encounter:** `enter_combat` (if hostiles nearby) → `do_combat 60` — handles targeting, movement, attacking, and turn management automatically.

**Exit grid / map transition:** `exit_through "<destination_name>"` — finds matching exit grids and runs to them. Use `exit_through "any"` if you don't care which exit.

**Explosive obstacle:** `arm_and_detonate <target_id> <safe_tile>` — walks adjacent, equips explosive to hand, uses it (sets timer), flees to safe tile, waits for detonation. Uses `equip_and_use` internally for player-like item flow.

**Exploring a new area:** `objects_near` to survey → `muse` your assessment → `explore_area` to loot everything → check for doors/exits → proceed.

**Long-distance movement (>20 tiles):** Break into waypoints — `move_and_wait <midpoint>` then `move_and_wait <destination>`. Pathfinding fails silently beyond ~20 hexes.

**Dismissing the options menu:** Call `dismiss_options_menu` after skipping movies. It auto-checks for game_mode 8/24 and dismisses leaked escape keys.

**Character creation (all button events):**
1. `cmd '{"type":"main_menu","action":"new_game"}'` — start new game
2. Skip movies with `cmd '{"type":"skip"}'` (may need 2-3 times)
3. `cmd '{"type":"char_selector_select","option":"create_custom"}'`
4. Set SPECIAL: `cmd '{"type":"adjust_stat","stat":"<name>","direction":"up/down"}'` — one at a time, 0.5-1s pauses
5. Set traits: `cmd '{"type":"toggle_trait","trait":"gifted"}'` — one at a time
6. Tag skills: `cmd '{"type":"toggle_skill_tag","skill":"speech"}'` — one at a time
7. Set name: `cmd '{"type":"set_name","name":"Kael"}'`
8. Finish: `cmd '{"type":"editor_done"}'` — skip the intro movie after

**World map travel:**
1. `cmd '{"type":"worldmap_travel","area_id":2}'` — initiates walking (not instant teleport)
2. Poll state for `is_walking == false` — party walks with real travel time and random encounters
3. `cmd '{"type":"worldmap_enter_location","area_id":2}'` — enter the local map

**Level-up (character editor must be open):**
1. Open character screen: `cmd '{"type":"character_screen"}'`
2. Add skill points: `cmd '{"type":"skill_add","skill":"small_guns"}'` — one point per command via editor button
3. Select perk (when `has_free_perk` is true): `cmd '{"type":"perk_add","perk_id":42}'` — selects in perk dialog

## Executor Functions

Source with `source scripts/executor.sh` for high-level helpers:

| Function | Description |
|----------|-------------|
| `do_combat [timeout] [heal%]` | Full combat loop with timeout and failure detection |
| `exit_through <dest\|any>` | Walk onto exit grids for natural map transitions |
| `equip_and_use <pid> [hand] [timer_secs]` | Equip item to hand, switch, and use it |
| `arm_and_detonate <id> <safe_tile> [pid] [timer_secs]` | Full explosive workflow (equip → use → flee) |
| `explore_area [max_dist]` | Loot all containers and pick up ground items |
| `move_and_wait <tile>` | Move to tile, wait for arrival (auto-retries on failure) |
| `dismiss_options_menu` | Auto-dismiss leaked Options menu after movie skips |
| `loot_all <id>` | Open container, take all, close |
| `talk_and_choose <id> <opt1> ...` | Talk to NPC with dialogue sequence |
| `snapshot` | Compact state summary |
| `objects_near` | Nearby objects for planning |
| `inventory_summary` | Full inventory listing |
| `examine_object <id>` | Look at object and report result |
| `check_inventory_for <keyword>` | Search inventory by keyword |
| `muse "text"` | Quick floating thought above player (no log entry) |
| `think <title> <...>` | Log reasoning + show thought bubble above player |
| `read_persona [section]` | Read full persona or a specific section |
| `evolve_persona <title> <happened> <changed>` | Record a persona shift |

## Persona & Decision-Making

Read `game/persona.md` at the start of each session to understand who you are. Your persona defines how you approach the world — consult it before decisions with moral weight.

**When to consult the persona:**
- Dialogue with moral weight (slavery, betrayal, faction allegiance)
- Fight, flee, or negotiate decisions
- Accepting or refusing jobs/quests
- Faction encounters and alignment choices
- How to approach a quest (stealthy, diplomatic, violent)

**Decision flow:**
1. Read relevant persona sections: `read_persona "Values"`, `read_persona "Combat Approach"`, etc.
2. Identify which values or tendencies apply to the situation
3. Log your reasoning: `think "title" "situation" "factors" "options" "reasoning" "decision"` — this also shows the decision as floating text above the player's head in-game
4. Act on the decision using game commands
5. If the experience shifts your values: `evolve_persona "title" "what happened" "what changed"`

**Streaming your thoughts in-game:**
- Use `muse "text"` frequently to show your moment-to-moment reasoning as floating text above the player — observations, tactical assessments, reactions, plans. This is your inner monologue made visible. Text renders in orange above the player's head.
- **Persona voice**: Always write muse text in your character's voice and personality. Read `game/persona.md` to know your character's speech patterns, vocabulary, and temperament. A gruff tribal speaks differently from a smooth-talking diplomat.
- **INT scaling**: Scale muse complexity to the character's Intelligence stat. INT 1-3: simple words, short fragments, concrete observations ("Big bug. Hit it."). INT 4-6: normal speech, basic reasoning ("That door looks locked. Might need a key."). INT 7-8: articulate, analytical ("The guard rotation suggests a gap at the east gate."). INT 9-10: eloquent, abstract, multi-layered ("The irony of a vault designed to preserve humanity becoming its own tomb is not lost on me."). Check `intelligence` from `agent_state.json` character stats.
- **Context awareness**: Before musing, consider what you just did and what you know. Don't express surprise or disappointment about things you caused — if you looted a container, you know why it's empty. Reference your recent actions ("Got what I needed from that footlocker"), current objectives ("Still need to find the village elder"), and surroundings ("Three radscorpions between me and the exit") rather than reacting as if seeing things for the first time. Your character has continuity of experience.
- Use `muse` when: assessing a room, reacting to damage, spotting loot, planning a route, noting something interesting, before/after combat, any time you'd naturally pause and reflect.
- Use `think` for major decisions that should be logged permanently (moral choices, quest approaches, faction decisions).
- Use `evolve_persona` rarely — only when experiences genuinely shift values.

**Execution style:**
- Plan your approach, then execute via executor scripts (`do_combat`, `exit_through`, `explore_area`, etc.) — don't micro-manage individual commands unless something unexpected happens.
- Sprinkle `muse` calls between actions to narrate what you're doing and why.
- The audience should see a stream of thoughts above the player's head as they watch the game play itself.

## Gameplay Gotchas

- **Escape = Options menu**: After skipping movies, escape keys leak into gameplay and open the Options dialog (game_mode 8 or 24). Always check and dismiss after entering gameplay.
- **Weapon hand**: Fallout 2 defaults to left hand (punch/kick). Weapons equip to right hand. Must `switch_hand` to use equipped weapons.
- **Long pathfinding limit**: `move_to`/`run_to` fails silently beyond ~20 hexes. Use intermediate waypoints.
- **Door tiles block pathfinding**: Even when a door is open, you often can't path TO the door tile. Move to the tile beyond/through the door instead.
- **Commands need tick gap**: Send one command, wait ~1 second for it to be processed, then send the next. Rapid-fire commands overwrite each other.
- **animation_busy gating**: Most actions require `animation_busy=false`. Use `wait_idle` or the `*_and_wait` helpers.
- **Unarmed range = 1**: Must be adjacent to target. Use `combat_move` to close distance first.
- **Equip-then-use for usable items**: Explosives, flares, and grenades should be equipped to a hand slot first, then used via `use_equipped_item` (or `equip_and_use` helper). This goes through the real engine item-use path. Don't use `use_item_on` for equippable items.
- **No stimpaks at start**: Temple of Trials has no healing items. Don't expect `do_combat` to heal — fight smart and conserve HP.
- **Rest requires no hostiles**: `rest` fails silently when hostile critters are on the map. Always check `last_debug` after resting — it will say `"rest: cannot rest here"` if blocked. You cannot rest between fights in dungeons with live enemies.

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
