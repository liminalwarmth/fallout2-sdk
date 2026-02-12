# Session Journal

## 2026-02-11: Temple of Trials Game State & Command Coverage

Implemented all 4 phases of the Temple of Trials plan in a single session:

- **Phase 1A**: Split `agent_bridge.cc` (995 lines) into 3 files: `agent_bridge.cc` (core/init/context), `agent_state.cc` (all state emission), `agent_commands.cc` (all command handlers). Created shared `agent_bridge_internal.h` header.
- **Phase 1B**: Added fine-grained gameplay sub-contexts: `gameplay_exploration`, `gameplay_combat`, `gameplay_combat_wait`, `gameplay_dialogue`, `gameplay_inventory`, `gameplay_loot`.
- **Phase 1C**: Added map/object state emission — map name/index/elevation, player tile/animation status, nearby critters (with HP/dead), ground items (within 25 hexes), scenery (doors with locked/open status, within 30 hexes), exit grids (with destination map/tile/elevation). Object enumeration throttled to every 10 ticks except during combat player turn.
- **Phase 1D**: Added exploration commands — `move_to`, `run_to` (via `animationRegisterMoveToTile`/`RunToTile`), `use_object`, `pick_up`, `use_skill`, `talk_to`, `use_item_on`, `look_at`. All guarded by `animationIsBusy()` check.
- **Phase 2**: Added inventory state (items with type/weight, equipped right/left/armor, total weight, carry capacity) and inventory commands (`equip_item`, `unequip_item`, `use_item`).
- **Phase 3**: Added combat state (current/max AP, free move, active weapon with primary/secondary stats, hostiles with per-location hit chances via `_determine_to_hit`) and combat commands (`attack` via `_combat_attack`, `combat_move`, `end_turn`, `use_combat_item`). `_combat_free_move` was already extern in combat.h — no engine change needed.
- **Phase 4**: Added dialogue accessor functions to engine (`agentGetDialogOptionCount`, `agentGetDialogOptionText`, `agentGetDialogReplyText` in `game_dialog.cc/h`). Added dialogue state emission (speaker name/ID, reply text, options) and `select_dialogue` command.
- **Documentation**: Updated README.md and CLAUDE.md with actual capabilities. Added Documentation Sync section, Session Journal reference, Agent Bridge Source Files table, and Command Reference.

## 2026-02-11 (session 2): Live Testing, Bug Fixes, and Gameplay Refinements

Focused on live gameplay testing in the Temple of Trials. Discovered and fixed several critical bugs, added new interface commands based on user feedback.

### Bugs Found & Fixed

- **Quicksave broken — symlink issue**: `game/data/SAVEGAME` was a broken symlink pointing to `/Users/pmirecki/Library/Application Support/GOG.com/Fallout 2/saves` (leftover from a different user's machine). Removed symlink, created real directory structure `data/SAVEGAME/SLOT01-10/`.

- **Quicksave/load bypassed engine UI**: Replaced the old `enqueueInputEvent(KEY_F6/F7)` approach with direct engine API calls. Added `agentQuickSave()`/`agentQuickLoad()` functions to `loadsave.cc/h` that call `lsgPerformSaveGame()`/`lsgLoadGameInSlot()` directly, bypassing the slot picker UI and description input.

- **Duplicate object IDs broke combat**: `obj->id` is NOT unique — multiple objects can share the same id value, causing `objectFindById()` to return the wrong object. Attacks were targeting objects 66 hexes away instead of the intended target 3 hexes away. **Fixed by switching to pointer-based unique IDs**: `reinterpret_cast<uintptr_t>(obj)` as the ID, validated by iterating the object list in `findObjectByUniqueId()`.

- **Escape key opens Options menu**: In `game.cc` lines 655-661, `KEY_ESCAPE` falls through to `KEY_UPPERCASE_O`, which opens the options menu. Escape keys used to skip post-creation movies leaked into gameplay and left `GameMode::kOptions` (0x8) stuck, blocking all interactions including exit grid transitions. **Fixed in `play.sh`**: `wait_for_gameplay()` now detects game_mode 8 or 24 and sends Escape to dismiss the stuck options menu.

- **macOS codesign required after binary replacement**: After `cp -R` of the built .app to `game/`, macOS refuses to launch via `open` with `RBSRequestErrorDomain Code=5`. **Fix**: Must run `codesign --sign - --force --deep` after every deploy.

### New Commands Added (user feedback)

- **`switch_hand`**: Calls `interfaceBarSwapHands(true)` to toggle between left hand (punch/kick) and right hand (spear). Fallout 2 defaults to left hand — must switch to right hand to use equipped weapon.
- **`cycle_attack_mode`**: Calls `interfaceCycleItemAction()` to cycle through attack modes (e.g., stab vs throw for spear).
- **`center_camera`**: Calls `tileSetCenter(gDude->tile, TILE_SET_CENTER_REFRESH_WINDOW)` to center viewport on player.

### Other Improvements

- **Viewport auto-centering**: Added `tileSetCenter()` calls to `move_to` and `combat_move` handlers so the camera follows the character automatically.
- **`interfaceUpdateItems()` after equip**: Added call after `_inven_wield()` in equip_item handler so the interface bar updates to show the newly equipped weapon.
- **Debug output**: Added `gAgentLastCommandDebug` string that records details of the last command (attack params, distances, return codes). Emitted in state as `last_command_debug`.
- **Combat state enriched**: Added `active_hand` (left/right) and `current_hit_mode` to combat state so the agent knows which weapon/mode is selected.
- **`play.sh` helpers**: Added `wait_for_gameplay()` (skips movies, dismisses stuck options), `screenshot()` helper, updated quicksave/quickload to use direct API.
- **`scripts/screenshot.sh`**: macOS screenshot helper for debugging stuck game states.

### What Was Tested Successfully

- Character creation (full flow: movies → main menu → character selector → editor → set stats/traits/skills → done)
- Entering gameplay (movie skip, options menu dismissal)
- Movement via `move_to` (character walks through hexes, pathfinding works)
- Quicksave/quickload with direct engine API
- State emission: map, player tile, nearby objects (critters, items, scenery, exit grids), inventory, equipped items

### What Still Needs Testing

These features were implemented but the game crashed before they could be verified:

1. **Unique pointer-based object IDs in combat** — The root cause of failed attacks (wrong target) is fixed in code, but no combat encounter has been tested with the fix yet
2. **`switch_hand` command** — Implemented but never tested. Need to verify it actually switches the active weapon slot in the interface
3. **`cycle_attack_mode` command** — Implemented but never tested. Need to verify stab/throw mode cycling
4. **Viewport auto-centering during movement** — `tileSetCenter()` added to move_to/combat_move but never observed in game
5. **`equip_item` with `interfaceUpdateItems()`** — The interface update call was added but never tested
6. **Quickload from main menu** — Crashed the app. `agentQuickLoad()` likely can't be called from main menu context; probably needs the game state to be initialized first. Needs investigation — may need to use `main_menu_select` with `load_game` option + navigate the load UI, or add a guard to `agentQuickLoad()` that checks context.
7. **Full combat encounter** — Attack, end turn, take damage, use healing item mid-combat
8. **Exit grid transitions** — Worked when options menu was dismissed manually; need to verify the automated dismissal in `wait_for_gameplay()` is sufficient
9. **Dialogue with Cameron** — `select_dialogue` command never tested in live game

### Known Issues / Next Session TODO

- **Load game from main menu**: The `agentQuickLoad()` function crashes when called from main menu. Need either: (a) guard it to only work in gameplay contexts, or (b) implement a proper "load from main menu" flow using `main_menu_select("load_game")` + selecting the save slot via the load game UI. The `main_menu_select("load_game")` path was attempted but also crashed — needs investigation.
- **Play.sh improvements**: Could add a `load_game` helper that handles both main menu and gameplay contexts properly.

## 2026-02-12 (session 3): Temple Cleared + Bug Fixes

### Temple of Trials Completed!

Full autonomous playthrough achieved: character creation → ARTEMPLE → ARCAVES (3 elevations) → Cameron dialogue → Cameron unarmed fight → exit movie → ARVILLAG.MAP (Arroyo Village).

### Bugs Found & Fixed

- **Game crash in JSON serialization during dialogue**: `nlohmann::json::dump_escaped()` threw exception on non-UTF-8 characters in Fallout 2 dialogue text (color/formatting codes). Added `safeString()` helper in `agent_state.cc` that validates UTF-8 byte sequences and replaces invalid bytes with `?`. Applied to ALL engine string assignments in state serialization.

- **Object cache stale after elevation changes**: After `map_transition` or `teleport` to a different elevation, the object enumeration cache (10-tick throttle via `gLastObjectEnumTick`) served stale objects from the old elevation. Added `agentForceObjectRefresh()` function that resets `gLastObjectEnumTick = 0`. Called from `handleTeleport()` and `handleMapTransition()`.

- **Scenery filter too noisy**: Debug mode had removed type filter (showing all scenery types) and used 200 hex distance. Restored proper filter: doors + generic scenery within 50 hexes.

### Navigation Workarounds

Several ARCAVES elevation transitions required `teleport` to exit grid tiles because the engine's blocking hex placement prevents pathfinding to exit grids:
- Elevation 0→1: Exit grids at row 53-54 completely walled off
- Elevation 1→2: Impenetrable Door + invisible blocking hexes
- Elevation 2→exit: Door at 13528 with blocking hexes

Teleporting to exit grid tiles works because `objectSetLocation()` detects exit grids and triggers `mapSetTransition()` — same as walking onto them naturally.

### Cameron Fight Results

- Dialogue system worked perfectly with `safeString()` fix
- 9 rounds of unarmed combat (Cameron requires unarmed, no weapons allowed)
- Cameron: 40→12 HP (surrenders when low HP)
- Claude: 22→14 HP
- After combat, exit grids to map 4 appeared; vault suit movie played

### What's Next

- World map travel (needed for moving between towns)
- Container/loot UI state and commands
- Barter system
- Framework improvements for full game playthrough

## 2026-02-12 (session 4): World Map, Containers, Loot, and Klamath

### World Map System
- Added accessor functions to `worldmap.cc/h`: `agentWmGetAreaCount`, `agentWmGetAreaInfo`, `agentWmGetAreaEntranceCount`, `agentWmGetAreaEntrance`, `agentWmIsWalking`, `agentWmGetWalkDestination`, `agentWmIsInCar`, `agentWmGetCarFuel`
- Added `gameplay_worldmap` context detection (via `GameMode::kWorldmap`)
- World map state emission: world position, current area, walking/car state, known locations with entrances
- `worldmap_travel` command: teleports between areas via `wmTeleportToArea()`
- `worldmap_enter_location` command: enters local maps via key injection ('T' + entrance number). Requires `wmAreaMarkVisitedState(areaId, 2)` before key injection.

### Container/Loot System
- `open_container` command: calls `inventoryOpenLooting(gDude, target)` directly for adjacent containers. Handles multi-frame container frame check by setting frame=1 before calling. Falls back to `actionPickUp` for distant containers.
- `loot_take` command: takes specific item from container via `itemMove()`
- `loot_take_all` command: takes all items from container
- `loot_close` command: injects `KEY_ESCAPE` to close loot screen
- Loot state emission: target name/id/pid, container items (pid, name, quantity, type, weight)

### Context Detection Fix
- Moved UI overlay checks (`kLoot`, `kInventory`, `kBarter`) BEFORE `isInCombat()` check. The loot screen can be open during combat (looting corpses), so UI overlays should take priority for context detection.

### Scenery Filter Improvement
- Changed from "doors + generic" to "doors + transitions (stairs/elevators/ladders) + containers (generic scenery with non-empty inventory)"
- Reduced noise from 630+ objects to just interactive ones (1 Gate door in Arroyo Village)
- Container scenery shows `locked` and `item_count` fields

### Skip Command
- Added `skip` command that injects `KEY_ESCAPE` via `enqueueInputEvent()`. Works during movie playback to skip intros. Previously required `key_press` with escape, which was non-obvious.

### UTF-8 Crash Fixes
- Applied `safeString()` to remaining unsafe string serializations: save game character_name/description, character editor name, trait names, map header name, debug output string.

### Testing Results
- Successfully traveled from Arroyo Village → world map → Klamath
- Entered Klamath via `worldmap_enter_location` (KLADWTWN.MAP, 46 critters, 19 scenery)
- Opened containers: Desk (Money x45, Stimpak x1), Bookcase (Gecko Pelt x4)
- `loot_take` transferred Stimpak from container to inventory
- `loot_take_all` transferred remaining Money x45
- `loot_close` returned to exploration
- Dialogue with Hakunin worked without UTF-8 crashes
- Full dialogue tree navigation (3 exchanges) with `select_dialogue` command

### Known Issues
- Quickload save from previous session has stuck combat flags (`isInCombat()` true even when not in combat). Doesn't affect gameplay but causes confusing game_mode values.
- `actionPickUp` approach for containers has a timing bug (animation race condition). Replaced with direct `inventoryOpenLooting` call.

### What's Next
- Test combat in Klamath (geckos, rat caves)
- Add barter state emission
- Test NPC dialogue in Klamath
- Level-up detection and perk selection
- Expand framework for full game playthrough

## 2026-02-12 (session 5): Barter, Level-Up, Party, Message Log

### Barter System
- Added `gameplay_barter` context detection via `_gdialogActive()` + `GameMode::kBarter` flag
- Added barter accessor functions to `game_dialog.cc/h`: `agentGetBarterPlayerTable()`, `agentGetBarterMerchantTable()`, `agentGetBarterModifier()`
- Barter state emission: merchant inventory (items with costs), player/merchant offer tables, caps, barter modifier
- Barter commands: `barter_offer`, `barter_remove_offer`, `barter_request`, `barter_remove_request`, `barter_confirm`, `barter_talk`, `barter_cancel`
- Trade value calculation via `barterGetTradeInfo()` with `trade_will_succeed` boolean
- Tested with Klamath merchants: buy/sell items, see prices, execute trades

### Level-Up System
- Added `can_level_up`, `unspent_skill_points`, active perks list to character state
- Added available perks to character editor state (when opened during level-up)
- `skill_add`/`skill_sub`/`perk_add` commands for level-up process
- XP tracking with `xp_for_next_level` field

### Party Member State
- Added `party_members` array to all gameplay contexts
- Each member: id, pid, name, tile, distance, hp, max_hp, dead, armor, weapon
- Uses `partyMemberGetCount()` and object iteration

### Message Log
- Added `agentDisplayMonitorGetLineCount()`/`agentDisplayMonitorGetLine()` to `display_monitor.cc/h`
- Captures up to 20 recent display monitor messages
- Shows skill check results, combat messages, area entry text

### save_slot / load_slot Commands
- Added `agentSaveToSlot(slot, desc)` and `agentLoadFromSlot(slot)` to `loadsave.cc/h`
- Allows saving/loading to specific save game slots (1-10)

### main_menu Command
- Added `main_menu` command type that directly sets `gAgentMainMenuAction`
- Cleaner than using `main_menu_select` for programmatic menu navigation

## 2026-02-12 (session 6): Quest State, Karma, Reputation

### Quest/Holodisk State Emission
- Added 12 accessor functions to `pipboy.h/cc` for quest/holodisk data
- `agentInitQuestData()` forces loading quest data (normally lazy-loaded on Pip-Boy open)
- 110 quests tracked from `data/quests.txt` with location, description, completed status, GVAR value
- Holodisk tracking: name and presence status
- Tested: starting quests visible ("Find Vic", "Retrieve GECK"), new quests appear after accepting from NPCs

### Karma/Reputation/Addiction Tracking
- Added karma (GVAR_PLAYER_REPUTATION) to character state
- 16 town-specific reputations (arroyo, klamath, the_den, vault_city, etc.) — only non-zero emitted
- 8 addiction types (nuka_cola, buffout, mentats, psycho, radaway, alcohol, jet, tragic)
- Tested: new character has karma=0, arroyo rep=50

### Documentation Updates
- Updated CLAUDE.md: engine modifications table, command reference, gotchas
- Updated journal.md with sessions 5-6

## 2026-02-12 (session 7): Ranged Weapons, Barter Fix, Combat Expansion

### Ranged Weapon Support
- Added weapon ammo state to equipped items: `ammo_count`, `ammo_capacity`, `ammo_pid`, `ammo_name`, `damage_type`, `damage_min`, `damage_max`
- Added `writeWeaponAmmoInfo()` helper with `damageTypeToString()` for all 7 damage types
- `reload_weapon` command: finds compatible ammo in inventory, calls `weaponReload()`, removes depleted ammo
- Tested: 10mm Pistol equipped, ammo tracking (12→11→10 after shots), reload back to 12/12

### Barter Confirm Fix
- **Root cause**: `enqueueInputEvent('m')` and `_kb_simulate_key(SDL_SCANCODE_M)` don't work for barter confirmation because the barter UI loop in `inventoryOpenTrade()` doesn't consume events from our ticker
- **Fix**: Replaced key injection with direct `itemMoveAll()` execution. Replicates `_barter_compute_value` formula (party barter skill, NPC barter skill, perk bonus, barter modifier) to validate trade, then transfers items directly
- Tested: traded Golden Gecko Pelt (value 125) for 2 Healing Powders from Maida in Klamath

### New Commands
- `give_item`: spawns items via `objectCreateWithPid()` + `itemAdd()` — essential for testing
- `drop_item`: removes from inventory and creates ground object
- `enter_combat`: initiates combat via 'a' key injection
- `flee_combat`: attempts to end combat via Enter key (succeeds when enemies agree to stop)

### State Improvements
- Added `game_time` section: hour, month, day, year, time_string, ticks
- Added `max_hp` and `team` fields to critter objects
- Added `max_hp` to combat hostiles
- Added `player_dead` flag (via `critterIsDead(gDude)`)

### Performance Improvement
- Created `game/ddraw.ini` with `SkipOpeningMovies=1` to bypass 5+ minute intro movie sequence. Intro movies freeze the tick counter (stuck at 1), preventing command processing.

### Testing Verified
- Barter confirm (direct execution): Maida in Klamath ✅
- Drop item and pick up: ground object creation ✅
- Ranged combat: 10mm Pistol vs Giant Ant, ammo tracking ✅
- Enter combat / flee combat: initiation and escape ✅
- Reload weapon: refill from inventory ammo ✅
- Game time: July 25, 2241 at 9:14 AM ✅
- Critter max_hp: Warriors 50/50, Spore Plants 40/40 ✅
- Use item (Stimpak): HP recovery confirmed ✅

### Known Issues
- Items added via `give_item` before `map_transition` become corrupted "Scroll Blocker" objects. Always give items after arriving at destination map.
- `map_transition` with `map=-2` (world map) causes game to exit/crash on ARTEMPLE map. Use exit grids or world map commands instead.
- Movie tick frozen: during `gameMoviePlay()` intro movies, tick stays at 1. The `ddraw.ini` skip config is the reliable workaround.

## 2026-02-12 (session 8): Sneak, Rest, Klamath Testing

### New State Fields
- `player.rotation` (0-5): hex direction facing via `gDude->rotation`
- `player.is_sneaking`: sneak mode via `dudeHasState(DUDE_STATE_SNEAKING)`
- `player.movement_waypoints_remaining`: waypoints left in queued movement

### New Commands
- `toggle_sneak`: toggles sneak mode via `dudeToggleState(DUDE_STATE_SNEAKING)`
- `rest` (direct): replaces key injection with direct `gameTimeSetTime()` + `queueProcessEvents()` + `_partyMemberRestingHeal(hours)`. Supports `hours` param (1-24). Validates combat/hostile critter conditions.

### Klamath Gameplay Test
- Tested movement, dialogue (Whiskey Bob quest acceptance), barter (Maida trading)
- Full quest tracking confirmed ("Refuel the still" appeared after accepting)
- Exit grid transitions: `run_to` to exit grids works; `teleport` to exit grids unreliable from some maps

## 2026-02-12 (session 9): Worldmap Enter Fix, Combat in Klamath

### worldmap_enter_location Direct Map Load
- **Problem**: Key injection ('T' + digit) through the town map UI was blocked by `gTownMapHotkeysFix` for entrances with `x/y == -1` (no graphical hotspot)
- **Solution**: Added `agentWmRequestMapLoad()` to `worldmap.cc/h` — sets `gAgentPendingMapLoad` which the worldmap event loop picks up and calls `mapLoadById()` directly, bypassing the town map UI
- Also auto-discovers unknown entrances via `wmMapMarkMapEntranceState()`
- Tested: entered KLAMALL (entrance 1), KLARATCV (entrance 2), KLATRAP (entrance 3) successfully

### Main Menu Direct Load
- **Problem**: `main_menu` with `load_game` action opens the load dialog UI which the agent can't navigate
- **Solution**: Added `gAgentPendingLoadSlot` to `agent_bridge.h/cc`. When `main_menu` command includes `slot` param, the `MAIN_MENU_LOAD_GAME` handler in `main.cc` calls `agentLoadFromSlot()` directly, bypassing the load dialog
- Tested: `{"type":"main_menu","action":"load_game","slot":0}` loads save directly from main menu

### Combat Test in Klamath
- Entered Klamath Trapping Grounds (KLATRAP.MAP, entrance 3) — geckos found
- Full combat loop tested against Golden Gecko:
  - combat_move to close distance
  - Ranged attacks with 10mm Pistol (5 AP, 45% hit at dist 1)
  - use_combat_item for Stimpak healing (26→44 HP)
  - Multiple rounds with end_turn
  - Kill confirmed: Golden Gecko hp=-6, XP gained (400→535)
- `map_transition` with `map=-2` works from closed maps (rat caves) back to world map

### Engine Modifications
- `worldmap.cc`: Added `gAgentPendingMapLoad` globals + `agentWmRequestMapLoad()` + check in `wmWorldMapFunc()`
- `worldmap.h`: Added `agentWmRequestMapLoad()` declaration
- `agent_bridge.h/cc`: Added `gAgentPendingLoadSlot` global
- `main.cc`: Added `gAgentPendingLoadSlot` check in `MAIN_MENU_LOAD_GAME` handler

## 2026-02-12 (session 10): Framework Hardening & Quality of Life

### Loot/Container Testing
- Tested full loot workflow: open_container on Bookcase in Klamath Downtown (Gecko Pelts x4)
- `loot_take` (partial: 2/4) → `loot_take_all` (remaining 2) → `loot_close` — all working
- Dead critter looting also works (`open_container` on dead Golden Gecko)

### State Improvements
- **Critter disposition**: Added `is_party_member` flag. During combat: `hostile` (team mismatch + alive). Outside combat: `enemy_team` (team mismatch only, avoids labeling neutral NPCs as hostile)
- **Exit grid map names**: Added `destination_map_name` field (e.g., "Canyon", "worldmap") using `mapGetName()`
- **Worldmap entrance map names**: Added `map_name` field to entrances (e.g., "Downtown", "Rat Caves", "Trapping Grounds")

### Command Robustness
- **Attack pre-validation**: Added `_combat_check_bad_shot()` call before executing attacks. Reports specific failures: "no ammo", "out of range", "not enough AP", "target already dead", "arm crippled", "aim blocked". Includes AP cost and weapon range in debug output.
- **Combat move validation**: Added AP check, improved all error paths to set `gAgentLastCommandDebug`
- **Dialogue validation**: `select_dialogue` now checks `_gdialogActive()` and validates option count before sending key
- **Movement elevation check**: Queued waypoints now track elevation; waypoints are aborted if elevation changes (e.g., exit grid triggers during multi-step movement)

### Lockpick Skill Verified
- `use_skill` with `"lockpick"` tested on locked door in Klamath Downtown — skill check fires, message log shows result

### Combat Camera Centering (Engine Mod)
- Added `tileSetCenter(obj->tile, TILE_SET_CENTER_REFRESH_WINDOW)` at start of `_combat_turn()` in `combat.cc`
- Camera now pans to each combatant (enemies, party members, player) at the start of their turn
- Only centers on combatants at the same elevation as the player

### Test Mode / Teleport Restriction
- Added `gAgentTestMode` flag (default: false) to `agent_bridge.h/cc`
- `teleport` and `give_item` commands are BLOCKED when test mode is off
- Enable via `{"type":"set_test_mode","enabled":true}` — must be explicit
- `test_mode` field emitted in state so agent knows current mode
- Normal gameplay harness should never enable test mode — prevents breaking/hacking game state

### Sulik Recruitment Tested
- Talked to Sulik in Klamath Downtown via `talk_to` + `select_dialogue`
- Full dialogue tree navigation: learned about his sister, debt to Maida
- Paid $350 to free him (Money: 500→150)
- Recruited to party: `party_members` shows Sulik with 85/85 HP

### Known Issues
- Combat animation can deadlock (tick freezes), requiring game restart
- Game loaded saves may not have weapons equipped; need explicit `equip_item`
- `run_to` pathfinding fails between disconnected map areas (e.g., inside buildings to outside)

## 2026-02-12 (session 11): Legitimate Temple Clear via Claude Code

### Temple of Trials — Fully Legitimate Clear

Claude Code (CLI) directly controlled the game via file-based IPC (`agent_state.json` / `agent_cmd.json`), acting as the strategic brain instead of the TypeScript agent wrapper.

**Full playthrough sequence:**
1. **Startup**: Main menu → New Game → Take Premade (Narg: S8/P5/E9/C3/I4/A7/L4, melee fighter)
2. **ARTEMPLE**: Equipped spear to right hand, switched active hand, ran to exit grid → ARCAVES elev 0
3. **ARCAVES elev 0**: Killed 2 Giant Ants in combat, opened door at tile 24308 (wait for open state + move), lockpicked locked door at tile 11108 (skill 14, succeeded first try!), navigated to exit grid → elev 1
4. **ARCAVES elev 1**: Killed enemies along the way, looted 3 containers (Antidote from Chest, **Plastic Explosives from Pot**), used explosives on Impenetrable Door (`use_item_on` pid=85 → door destroyed), ran to exit grid → elev 2
5. **ARCAVES elev 2**: Fought Giant Ant at entrance, navigated to Cameron via intermediate waypoints (long pathfinding workaround), unequipped spear for unarmed combat, talked to Cameron → "Let the fight begin!"
6. **Cameron Fight**: 9 rounds of unarmed combat, won (Cameron yielded at 22/40 HP, we at 15/44 HP). Cameron's script unlocked the exit door.
7. **Exit**: Walked through unlocked door → exit grid → **vault suit movie played** → arrived at ARVILLAG.MAP
8. **Confirmation**: Message log shows "You passed the trials of Arroyo" + "You gain 300 experience points"

### Key Techniques
- **Door handling**: `use_object` to open, poll for `open=1` AND `animation_busy=false`, then `move_to` the door tile before it auto-closes
- **Long pathfinding workaround**: Targets >30 tiles away fail silently with `run_to`. Used intermediate waypoints (known object/scenery tiles) to navigate in shorter hops
- **Dialogue timing**: `[Done]` options sometimes need multiple sends (10+ attempts over ~20 seconds)
- **Combat loop**: Python script polling context every 0.5s — attack if in range, combat_move if not, end_turn when out of AP
- **NO test mode / NO teleport**: Entire clear was legitimate. Test mode stayed OFF throughout.

### XP Breakdown
- Starting: 0 XP → Character creation
- Temple combat: ~540 XP (ants, scorpions, Cameron fight)
- Temple completion: +300 XP bonus
- Final: 840 XP at Arroyo Village
