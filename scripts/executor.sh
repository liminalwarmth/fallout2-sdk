#!/usr/bin/env bash
# executor.sh — Tactical execution helpers for Claude Code gameplay
#
# Provides functions for common gameplay loops (combat, movement, exploration,
# looting) that can be called from Claude Code to avoid expensive
# polling round-trips.
#
# Usage: source scripts/executor.sh
#        Then call functions like: do_combat, move_and_wait, explore_area, etc.
#        Run 'executor_help' for full function listing.
#
# ═══════════════════════════════════════════════════════════════════════════
# PLAYER ACTION REFERENCE
# ═══════════════════════════════════════════════════════════════════════════
#
# Everything below is an action a PLAYER can perform (or observe). The agent
# should only act within these bounds — no engine cheats, no metagaming.
#
# EXPLORATION (gameplay_exploration context)
#   move_to <tile>          — walk to tile (pathfinding, max ~20 hexes)
#   run_to <tile>           — run to tile (faster, same pathfind limit)
#   use_object <id>         — interact with doors, switches, ladders, etc.
#   pick_up <id>            — pick up a ground item
#   look_at <id>            — examine an object (reads description)
#   use_skill <skill> <id>  — apply a skill (lockpick, traps, repair, etc.)
#   use_item_on <pid> <id>  — use an inventory item on a world object
#   talk_to <id>            — initiate dialogue with an NPC
#   open_container <id>     — open a container for looting
#   enter_combat            — initiate combat (if hostiles nearby)
#
# INVENTORY (gameplay_inventory or any gameplay_* context)
#   equip_item <pid> <hand> — equip weapon/armor
#   unequip_item <hand>     — unequip from hand slot
#   use_item <pid>          — use a consumable (stimpak, etc.)
#   reload_weapon           — reload current weapon's ammo
#   drop_item <pid>         — drop item on the ground
#   use_equipped_item [timer]— use item in active hand (explosives, flares, etc.)
#   switch_hand             — toggle active hand (left/right)
#   cycle_attack_mode       — cycle weapon's attack mode
#
# COMBAT (gameplay_combat context — your turn only)
#   attack <target_id>      — attack with current weapon/hand
#   combat_move <tile>      — move during combat (costs AP)
#   end_turn                — end your turn
#   use_combat_item <pid>   — use item during combat (stimpak, etc.)
#   flee_combat             — attempt to flee (must be near map edge)
#
# DIALOGUE (gameplay_dialogue context)
#   select_dialogue <index> — pick a dialogue option by index
#
# CONTAINERS/LOOT (gameplay_loot context)
#   loot_take <pid> [qty]   — take specific item from container
#   loot_take_all           — take everything from container
#   loot_close              — close the loot screen
#
# BARTER (gameplay_barter context)
#   barter_offer <pid>      — offer your item to merchant
#   barter_request <pid>    — request merchant's item
#   barter_remove_offer/request <pid> — remove from offer/request
#   barter_confirm          — confirm the trade
#   barter_cancel           — cancel barter
#   barter_talk             — return to dialogue from barter
#
# WORLD MAP (gameplay_worldmap context)
#   worldmap_travel <area>  — initiate walking to area (travel time + encounters)
#   worldmap_enter_location <area> [entrance] — enter local map
#
# NAVIGATION (use carefully)
#   (use exit grids to leave maps — walk to the map edge)
#   find_path <tile>        — check if path exists (no movement)
#   tile_objects <tile>     — inspect objects at a specific tile
#   center_camera           — re-center camera on player
#
# INTERFACE
#   rest                    — rest to heal (time passes)
#   pip_boy                 — open Pip-Boy (quest/map/status)
#   character_screen        — open character sheet
#   inventory_open          — open inventory screen
#   skilldex                — open skilldex (skill selection)
#   quicksave / quickload   — save/load game
#   save_slot / load_slot   — save/load to specific slot
#   skip                    — skip movie/cutscene
#
# LEVEL-UP (character editor must be open)
#   skill_add <skill>       — add 1 skill point (via editor button)
#   skill_sub <skill>       — remove 1 skill point (via editor button)
#   perk_add <perk_id>      — select a perk (via perk dialog)
#
# TEST MODE ONLY (cheats — disabled by default)
#   set_test_mode true/false — enable/disable cheat commands
#   teleport <tile>          — instant move (requires test mode)
#   give_item <pid> [qty]    — spawn items (requires test mode)
#   map_transition           — direct map warp (requires test mode, NOT for gameplay)
#
# ═══════════════════════════════════════════════════════════════════════════
# INFORMATION BOUNDARIES
# ═══════════════════════════════════════════════════════════════════════════
#
# OBSERVABLE (always available in agent_state.json):
#   - Current map name, elevation, player tile
#   - Nearby objects: critters (name, HP, distance), scenery (type, locked,
#     open, item_count), exit grids (destination), ground items (name, pid)
#   - Player stats: HP, AP, level, XP, skills, perks, inventory
#   - Combat state: hostiles, AP, weapon info, hit chances
#   - Dialogue: speaker name, reply text, available options
#   - Message log: recent game messages (skill results, combat text)
#   - Quest log: active quests, descriptions, completion status
#
# REQUIRES INTERACTION (must act to learn):
#   - Container contents → open_container to see items inside
#   - Object descriptions → look_at to read the description
#   - NPC information → talk_to to learn what they know
#   - Locked status details → try lockpick to see if it's possible
#   - Item properties → examine or equip to see full stats
#   - Map layout beyond visible range → walk there to discover
#   - What's on other elevations → find stairs/ladders and go there
#
# NO METAGAMING:
#   - Do NOT assume item locations without exploring containers first
#   - Do NOT know NPC dialogue trees before talking to them
#   - Do NOT know which key opens which door without clues
#   - Do NOT use specific tile numbers from previous playthroughs
#   - DO explore systematically: loot containers, examine objects, talk to NPCs
#   - DO reason from in-game clues (dialogue hints, descriptions, quest text)
#   - DO try skills on interactive-looking objects
#   - DO reference docs/gameplay-guide.md for general mechanics knowledge
#
# ═══════════════════════════════════════════════════════════════════════════
# INTERACTION TACTICS
# ═══════════════════════════════════════════════════════════════════════════
#
# Common gameplay patterns — combine these tools to solve situations:
#
# LOCKED DOOR:    save_before → use_skill lockpick <id> → interact → walk through
#                 Alt: equip_and_use <explosive_pid> right <timer> + move away
#                 Alt: find key elsewhere and use_item_on <key_pid> <door_id>
# TRAPPED:        use_skill traps <id> to disarm, or just trigger and heal
# DESTRUCTIBLE:   equip_and_use <explosive_pid> right <timer>, then move_and_wait away
# ITEMS ON WORLD: use_item_on <pid> <id> (rope on well, key on door, etc.)
# HEALING:        heal_to_full → rest (no hostiles) → use_skill first_aid <self>
# COMBAT:         do_combat [timeout] — fully autonomous targeting + movement
# LOOTING:        loot <id> (single container) or explore_area (sweep all nearby)
# NPC:            talk <id> <opt1> <opt2> ... — exhaust dialogue for quest info
# NAVIGATION:     move_and_wait <tile>, exit_through "<dest>"
# SAVE:           save_before "label" — always before lockpick, combat, explosives
# LEVEL-UP:       character_screen → skill_add per point → perk_add if available
# CHAR CREATE:    main_menu new_game → skip movies → char_selector_select →
#                 set SPECIAL/traits/skills/name → editor_done
# WORLD MAP:      worldmap_travel → poll is_walking → worldmap_enter_location
#
# ═══════════════════════════════════════════════════════════════════════════
# GOTCHAS (scripts don't auto-handle these)
# ═══════════════════════════════════════════════════════════════════════════
#
# ESCAPE MENU:    Movie-skip escape leaks into gameplay → opens Options menu.
#                 Usually auto-dismissed; manual: dismiss_options_menu
# WEAPON HAND:    Weapons equip to right hand, but left hand is active by default.
#                 equip_and_use handles switching; manual: switch_hand
# REST+HOSTILES:  rest fails silently when hostile critters are on the map.
#                 Clear enemies or leave map first.
# OBJECT TILES:   move_and_wait to a scenery/NPC tile will fail — the object
#                 blocks it. Use loot/talk/interact (auto-walk) or a neighbor tile.
# MUSE BATCHING:  Always muse "text"; sleep 1; <action> in ONE Bash call.
#                 The async float_response.sh hook can clobber muse otherwise.
#
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

GAME_DIR="${FALLOUT2_GAME_DIR:-/Users/alexis.radcliff/fallout2-sdk/game}"
STATE="$GAME_DIR/agent_state.json"
CMD="$GAME_DIR/agent_cmd.json"
TMP="$GAME_DIR/agent_cmd.tmp"

# ─── Core I/O ─────────────────────────────────────────────────────────

send() {
    echo "$1" > "$TMP" && mv "$TMP" "$CMD"
}

cmd() {
    send "{\"commands\":[$1]}"
}

py() {
    python3 -c "
import json
with open('$STATE') as f:
    d = json.load(f)
$1
" 2>/dev/null
}

field() {
    py "
val = d
for key in '$1'.split('.'):
    val = val.get(key) if isinstance(val, dict) else None
if val is None: print('null')
elif isinstance(val, (dict, list)): print(json.dumps(val))
else: print(val)
"
}

last_debug() { field "last_command_debug"; }
context() { field "context"; }
tick() { field "tick"; }

# ─── Waiting ──────────────────────────────────────────────────────────

wait_idle() {
    # Wait for animation_busy=false, max ~15s
    local max="${1:-30}"
    for i in $(seq 1 $max); do
        local busy=$(field "player.animation_busy")
        [ "$busy" = "false" ] || [ "$busy" = "False" ] && return 0
        sleep 0.5
    done
    echo "WARN: wait_idle timeout" >&2
    return 1
}

wait_context() {
    local target="$1" max="${2:-60}"
    for i in $(seq 1 $max); do
        local ctx=$(context)
        [ "$ctx" = "$target" ] && return 0
        sleep 0.5
    done
    echo "WARN: wait_context timeout for '$target' (got '$(context)')" >&2
    return 1
}

wait_context_prefix() {
    local prefix="$1" max="${2:-60}"
    for i in $(seq 1 $max); do
        local ctx=$(context)
        [[ "$ctx" == ${prefix}* ]] && return 0
        # Auto-skip movies
        [ "$ctx" = "movie" ] && cmd '{"type":"skip"}' && sleep 1 && continue
        sleep 0.5
    done
    echo "WARN: wait_context_prefix timeout for '$prefix' (got '$(context)')" >&2
    return 1
}

wait_tick_advance() {
    # Wait for tick to advance past current value (confirms command was processed)
    local cur_tick=$(tick)
    local max="${1:-30}"
    for i in $(seq 1 $max); do
        local t=$(tick)
        [ "$t" != "$cur_tick" ] && return 0
        sleep 0.3
    done
    return 1
}

# ─── Walk-to-object helper ───────────────────────────────────────────

_walk_to_object() {
    # Walk toward an object by its ID. Looks up tile and distance from state.
    # Skips walk if already within 5 tiles (engine commands handle final approach).
    # NOTE: Targets the object's tile directly. For blocking objects (doors, containers),
    # move_and_wait will stop at the nearest reachable tile after retries.
    # This is intentional — engine commands (use_object, talk_to, etc.) handle adjacency.
    local obj_id="$1"
    local info=$(py "
for cat in ['critters', 'scenery', 'ground_items', 'exit_grids', 'items']:
    for o in d.get('objects', {}).get(cat, []):
        if str(o.get('id')) == '$obj_id':
            print(f\"{o.get('tile','')}\t{o.get('distance',999)}\")
            break
    else:
        continue
    break
")
    local obj_tile="${info%%	*}"
    local dist="${info##*	}"

    if [ -z "$obj_tile" ] || [ "$obj_tile" = "None" ] || [ "$obj_tile" = "" ]; then
        echo "WARN: can't find object $obj_id in state" >&2
        return 1
    fi

    if [ "$dist" != "None" ] && [ "$dist" -le 5 ] 2>/dev/null; then
        return 0
    fi

    move_and_wait "$obj_tile"
}

# ─── Movement ─────────────────────────────────────────────────────────

move_and_wait() {
    # Move to tile, wait for arrival. Returns 0 on success, 1 on timeout.
    # Automatically retries up to 3 times on failure (pathfinding limit ~20 hexes).
    # Detects map transitions (exit grids) and reports them.
    local tile="$1" mode="${2:-run_to}" max_retries="${3:-3}"
    local attempt=0
    local start_map=$(field "map.name")
    local start_elev=$(field "map.elevation")

    while [ $attempt -le $max_retries ]; do
        local before=$(field "player.tile")
        cmd "{\"type\":\"$mode\",\"tile\":$tile}"
        sleep 0.3
        if ! wait_idle; then
            echo "WARN: move_and_wait timed out moving to tile $tile" >&2
            return 1
        fi

        # Check for map transition FIRST
        local cur_map=$(field "map.name")
        local cur_elev=$(field "map.elevation")
        if [ "$cur_map" != "$start_map" ] || [ "$cur_elev" != "$start_elev" ]; then
            echo "MAP TRANSITION: $start_map elev=$start_elev -> $cur_map elev=$cur_elev (tile $(field 'player.tile'))"
            post_transition_hook
            return 0
        fi

        local cur=$(field "player.tile")
        if [ "$cur" = "$tile" ]; then
            echo "Arrived at tile $cur"
            return 0
        fi

        # Check if we moved at all
        if [ "$cur" = "$before" ]; then
            if [ $attempt -lt $max_retries ]; then
                attempt=$((attempt + 1))
                echo "  Move failed (stuck at $cur), retry $attempt/$max_retries..."
                sleep 0.5
                continue
            else
                echo "WARN: move_and_wait stuck at $cur after $max_retries retries (target $tile)" >&2
                return 1
            fi
        fi

        # We moved but didn't reach target — retry from new position
        if [ $attempt -lt $max_retries ]; then
            attempt=$((attempt + 1))
            echo "  Partial move to $cur (target $tile), retry $attempt/$max_retries..."
            sleep 0.3
            continue
        else
            echo "Moved to tile $cur (target was $tile, close enough after $max_retries retries)"
            return 0
        fi
    done
    echo "WARN: move_and_wait failed after $max_retries retries (at tile $(field 'player.tile'), target $tile)" >&2
    return 1
}

navigate_to() {
    # Navigate to a tile using the engine's built-in pathfinding and waypoint system.
    # The engine A* (8000-node limit) computes the full path, then move_to/run_to
    # automatically queues waypoints and walks the entire route.
    # Monitors for map transitions (exit grids) and stuck states.
    #
    # Usage: navigate_to <tile> [mode]
    #   tile: destination tile number
    #   mode: "run_to" (default) or "move_to"
    # Returns 0 on success (or map transition), 1 on failure (no path / stuck).
    local dest_tile="$1" mode="${2:-run_to}"
    local start_map=$(field "map.name")
    local start_elev=$(field "map.elevation")
    local cur_tile=$(field "player.tile")

    if [ "$cur_tile" = "$dest_tile" ]; then
        echo "Already at tile $dest_tile"
        return 0
    fi

    echo "=== NAVIGATE: $cur_tile -> $dest_tile (mode=$mode) ==="

    # Issue the move command — the engine computes the full A* path internally
    # and queues waypoints (~16 tiles per segment) for the animation system.
    cmd "{\"type\":\"$mode\",\"tile\":$dest_tile}"
    sleep 0.3

    # Check if path was found
    local dbg=$(last_debug)
    if [[ "$dbg" == *"no path"* ]]; then
        echo "  No path: $dbg"
        return 1
    fi

    echo "  Path found: $dbg"

    # Wait for the movement to complete, monitoring for map transitions and stuck states.
    local last_tile="$cur_tile"
    local stuck_count=0
    local max_wait=120  # 120 half-second polls = 60 seconds max

    for i in $(seq 1 $max_wait); do
        # Check for map transition (exit grids)
        local cur_map=$(field "map.name")
        local cur_elev=$(field "map.elevation")
        if [ "$cur_map" != "$start_map" ] || [ "$cur_elev" != "$start_elev" ]; then
            echo "  MAP TRANSITION: $start_map -> $cur_map elev=$cur_elev (tile $(field 'player.tile'))"
            post_transition_hook
            return 0
        fi

        # Check if we've arrived
        cur_tile=$(field "player.tile")
        if [ "$cur_tile" = "$dest_tile" ]; then
            echo "=== NAVIGATE: arrived at $dest_tile ==="
            return 0
        fi

        # Check if still moving
        local busy=$(field "player.animation_busy")
        local remaining=$(field "player.movement_waypoints_remaining")
        if [ "$busy" = "false" ] && { [ "$remaining" = "null" ] || [ "$remaining" = "0" ]; }; then
            # Movement stopped — check if we made it
            if [ "$cur_tile" = "$dest_tile" ]; then
                echo "=== NAVIGATE: arrived at $dest_tile ==="
                return 0
            fi
            # Stopped but not at destination — path was blocked or partial
            echo "  Movement stopped at $cur_tile (target $dest_tile)"
            echo "  Debug: $(last_debug)"
            return 1
        fi

        # Stuck detection: same tile for too long
        if [ "$cur_tile" = "$last_tile" ]; then
            stuck_count=$((stuck_count + 1))
            if [ $stuck_count -ge 20 ]; then  # 10 seconds stuck
                echo "  STUCK at tile $cur_tile for 10s"
                return 1
            fi
        else
            stuck_count=0
            last_tile="$cur_tile"
        fi

        sleep 0.5
    done

    echo "  TIMEOUT (60s) at tile $(field 'player.tile')"
    return 1
}

# ─── Combat ───────────────────────────────────────────────────────────

wait_my_turn() {
    # After ending turn in combat, wait until it's our turn again.
    # Watches for context to become gameplay_combat (not _wait).
    # Also handles combat ending (context changes to exploration).
    local max_wait="${1:-30}" elapsed=0
    # First, give the engine time to register end_turn and start enemy turns
    sleep 1.5
    elapsed=2
    while [ $elapsed -lt $max_wait ]; do
        local ctx=$(context)
        if [ "$ctx" = "gameplay_combat" ]; then
            # Verify it's actually our turn by checking AP > 0
            local ap=$(py "print(d.get('combat',{}).get('current_ap',0))")
            if [ "${ap:-0}" -gt 0 ]; then
                return 0
            fi
        fi
        if [ "$ctx" = "gameplay_exploration" ] || [ "$ctx" = "gameplay_dialogue" ]; then
            # Combat ended
            return 0
        fi
        sleep 0.8
        elapsed=$((elapsed + 1))
    done
    return 1
}

do_combat() {
    # Run a full combat loop with wall-clock timeout and failure detection.
    # Args: $1 = timeout_secs (default 60), $2 = min_hp_pct to heal (default 40)
    local timeout_secs="${1:-60}" heal_pct="${2:-40}"
    local start_time=$(date +%s) action_count=0 consec_fail=0 round=0
    local stuck_rounds=0 last_n_alive=999 last_total_hp=999999

    _combat_heal_failed=0
    _combat_quip_tick=0    # throttle quips to one per ~3 rounds
    _combat_kills=0
    _combat_last_hp=0
    local _combat_started=0
    echo "=== COMBAT START (timeout=${timeout_secs}s) ==="
    while true; do
        # Wall-clock timeout
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        if [ $elapsed -ge $timeout_secs ]; then
            echo "=== COMBAT TIMEOUT (${elapsed}s, actions=$action_count, rounds=$round) ==="
            return 1
        fi

        local ctx=$(context)

        # Combat over?
        if [ "$ctx" != "gameplay_combat" ] && [ "$ctx" != "gameplay_combat_wait" ]; then
            echo "=== COMBAT END (context: $ctx, rounds: $round, actions: $action_count, ${elapsed}s) ==="
            # Win quip runs synchronously (not background) so it completes before we return
            combat_quip_sync win "$_combat_kills kills in $round rounds"
            return 0
        fi

        # Not our turn? Wait.
        if [ "$ctx" = "gameplay_combat_wait" ]; then
            sleep 0.8
            continue
        fi

        # Our turn — get all combat info in one python call
        local info=$(py "
import json
c = d.get('combat', {})
ch = d.get('character', {}).get('derived_stats', {})
hostiles = c.get('hostiles', [])
alive = [h for h in hostiles if h.get('hp', 0) > 0]
alive.sort(key=lambda h: h.get('distance', 999))
n = alive[0] if alive else None
w = c.get('active_weapon', {})
wp = w.get('primary', {})
total_hp = sum(h.get('hp', 0) for h in alive)
# Count nearby combatants (within 15 tiles) as 'engaged' — distant ones are bystanders
nearby = [h for h in alive if h.get('distance', 999) <= 15]
n_engaged = len(nearby) if nearby else len(alive)
# Names of engaged enemies for quip context
engaged_names = list(set(h.get('name','?') for h in (nearby if nearby else alive)))
print(json.dumps({
    'ap': c.get('current_ap', 0),
    'free_move': c.get('free_move', 0),
    'hp': ch.get('current_hp', 0),
    'max_hp': ch.get('max_hp', 0),
    'n_alive': len(alive),
    'n_engaged': n_engaged,
    'engaged_names': ', '.join(engaged_names[:3]),
    'n_id': n['id'] if n else 0,
    'n_dist': n.get('distance', 999) if n else 999,
    'n_tile': n.get('tile', 0) if n else 0,
    'n_name': n.get('name', '?') if n else '?',
    'n_hp': n.get('hp', 0) if n else 0,
    'total_hp': total_hp,
    'w_range': wp.get('range', 1),
    'w_ap': wp.get('ap_cost', 3),
    'w_name': w.get('name', c.get('active_hand', 'unarmed')),
}, separators=(',',':')))
")
        # Parse all fields from one JSON blob (shlex.quote to prevent injection)
        if [ -z "$info" ]; then
            echo "    WARN: failed to read combat state, retrying..."
            sleep 0.5
            continue
        fi
        local ap=0 hp=0 max_hp=0 n_alive=0 n_engaged=0 engaged_names='' n_id=0 n_dist=999 n_tile=0 n_name='?' n_hp=0 total_hp=0 free_move=0 w_range=1 w_ap=3 w_name='unarmed'
        eval $(echo "$info" | python3 -c "
import json, sys, shlex
d = json.load(sys.stdin)
for k,v in d.items():
    print(f'{k}={shlex.quote(str(v))}')
")

        # No hostiles? End turn to exit
        if [ "$n_alive" = "0" ]; then
            echo "  Round $round: No hostiles, ending turn"
            cmd '{"type":"end_turn"}'
            sleep 1
            wait_tick_advance 10
            round=$((round + 1))
            continue
        fi

        echo "  Round $round: AP=$ap(+${free_move}fm) HP=$hp/$max_hp [weapon: $w_name rng=$w_range] vs $n_name($n_hp hp, dist=$n_dist) [$n_engaged engaged, $n_alive total]"

        # Combat quips at key moments — use n_engaged (actual combatants) not n_alive
        if [ "$_combat_started" -eq 0 ]; then
            _combat_started=1
            _combat_quip_tick=0  # always quip at start
            combat_quip start
            _combat_last_hp=$hp
            sleep 1
        fi
        # Detect kills (enemy count dropped)
        if [ $round -gt 0 ] && [ "$n_alive" -lt "$last_n_alive" ] 2>/dev/null; then
            local killed=$((last_n_alive - n_alive))
            _combat_kills=$((_combat_kills + killed))
            _combat_quip_tick=0  # always quip on kills
            combat_quip kill "Round $round, $_combat_kills total kills"
            sleep 1
        fi
        # Detect taking damage — big_hurt if >25% max HP lost, else hurt
        if [ "$_combat_last_hp" -gt 0 ] && [ "$hp" -lt "$_combat_last_hp" ]; then
            local dmg_taken=$((_combat_last_hp - hp))
            if [ "$max_hp" -gt 0 ] && [ $((dmg_taken * 100 / max_hp)) -ge 25 ]; then
                _combat_quip_tick=0  # force quip on big hurt
                combat_quip big_hurt "Took $dmg_taken damage in round $round"
            else
                combat_quip hurt "Took $dmg_taken damage in round $round"
            fi
            sleep 1
        fi
        _combat_last_hp=$hp

        # Stuck detection: count rounds where no enemies died AND total enemy HP didn't drop
        if [ $round -gt 0 ]; then
            if [ "$n_alive" -lt "$last_n_alive" ] 2>/dev/null || [ "$total_hp" -lt "$last_total_hp" ] 2>/dev/null; then
                stuck_rounds=0
            else
                stuck_rounds=$((stuck_rounds + 1))
            fi
        fi
        last_n_alive=$n_alive
        last_total_hp=$total_hp

        # If stuck for 8+ rounds with no progress, flee combat
        if [ $stuck_rounds -ge 8 ]; then
            echo "    STUCK for $stuck_rounds rounds, fleeing combat"
            _combat_quip_tick=0
            combat_quip flee "Stuck $stuck_rounds rounds, round $round"
            sleep 1
            cmd '{"type":"flee_combat"}'
            sleep 2
            wait_tick_advance 20
            local flee_ctx=$(context)
            if [ "$flee_ctx" != "gameplay_combat" ] && [ "$flee_ctx" != "gameplay_combat_wait" ]; then
                echo "=== COMBAT FLED (stuck, ${round} rounds) ==="
                return 1
            fi
            # If flee failed, try ending turn
            cmd '{"type":"end_turn"}'
            sleep 1
            wait_tick_advance 10
            round=$((round + 1))
            continue
        fi

        # CRITICAL HP CHECK: flee if below 20%
        if [ "$max_hp" -gt 0 ]; then
            local hp_pct=$((hp * 100 / max_hp))
            if [ $hp_pct -lt 20 ]; then
                echo "    CRITICAL HP ($hp_pct%), fleeing!"
                _combat_quip_tick=0  # force quip
                combat_quip critical_hp "Round $round"
                sleep 1
                cmd '{"type":"flee_combat"}'
                sleep 2
                wait_tick_advance 20
                local flee_ctx=$(context)
                if [ "$flee_ctx" != "gameplay_combat" ] && [ "$flee_ctx" != "gameplay_combat_wait" ]; then
                    echo "=== COMBAT FLED (critical HP, ${round} rounds) ==="
                    return 1
                fi
                # Flee failed, try end turn
                cmd '{"type":"end_turn"}'
                wait_my_turn
                round=$((round + 1))
                continue
            fi
        fi

        # Heal if low HP (only if we have stimpaks)
        if [ "$max_hp" -gt 0 ]; then
            local hp_pct=$((hp * 100 / max_hp))
            if [ $hp_pct -lt $heal_pct ] && [ "$ap" -ge 2 ] && [ "${_combat_heal_failed:-0}" -eq 0 ]; then
                echo "    Healing (HP $hp_pct%)"
                local hp_before=$hp
                cmd "{\"type\":\"use_combat_item\",\"item_pid\":40}"
                sleep 1
                wait_tick_advance 10
                local hp_after=$(py "print(d.get('character',{}).get('derived_stats',{}).get('current_hp',0))" 2>/dev/null)
                if [ "${hp_after:-0}" -le "$hp_before" ]; then
                    echo "    Heal failed (no stimpaks?) — skipping further heal attempts"
                    _combat_heal_failed=1
                else
                    action_count=$((action_count + 1))
                    consec_fail=0
                    continue
                fi
            fi
        fi

        # Out of AP? End turn
        if [ "$ap" -lt "$w_ap" ] && [ "$free_move" -lt 1 ]; then
            echo "    End turn (AP=$ap)"
            cmd '{"type":"end_turn"}'
            wait_my_turn
            round=$((round + 1))
            consec_fail=0
            continue
        fi

        # Need to close distance?
        if [ "$n_dist" -gt "$w_range" ]; then
            # Move toward nearest hostile using available AP
            # Only give up if there's no AP to spend on movement
            local prev_ap=$ap
            echo "    Moving toward $n_name (dist=$n_dist, tile=$n_tile)"
            cmd "{\"type\":\"combat_move\",\"tile\":$n_tile}"
            sleep 1
            wait_tick_advance 15
            action_count=$((action_count + 1))
            # Check if move actually worked (AP should have decreased)
            local new_ap=$(py "print(d.get('combat',{}).get('current_ap',0))")
            if [ "$new_ap" = "$prev_ap" ]; then
                consec_fail=$((consec_fail + 1))
                echo "    Move failed (path blocked?) [consec_fail=$consec_fail]"
                if [ $consec_fail -ge 3 ]; then
                    echo "    Too many failures, ending turn to reset"
                    cmd '{"type":"end_turn"}'
                    sleep 1
                    wait_tick_advance 10
                    round=$((round + 1))
                    consec_fail=0
                fi
            else
                consec_fail=0
            fi
            continue
        fi

        # In range — attack!
        if [ "$n_id" != "0" ]; then
            local target_hp_before=$n_hp
            echo "    Attacking $n_name"
            cmd "{\"type\":\"attack\",\"target_id\":$n_id}"
            sleep 0.5
            wait_idle 20
            wait_tick_advance 5
            action_count=$((action_count + 1))

            # Check for attack failure in debug output
            local dbg=$(last_debug)
            if [[ "$dbg" == *"REJECTED"* ]] || [[ "$dbg" == *"no path"* ]] || [[ "$dbg" == *"failed"* ]] || [[ "$dbg" == *"busy"* ]]; then
                consec_fail=$((consec_fail + 1))
                echo "    Attack issue: $dbg [consec_fail=$consec_fail]"
                if [ $consec_fail -ge 3 ]; then
                    echo "    Too many failures, ending turn to reset"
                    cmd '{"type":"end_turn"}'
                    sleep 1
                    wait_tick_advance 10
                    round=$((round + 1))
                    consec_fail=0
                fi
            else
                consec_fail=0
                # Detect big hits — check target HP after attack
                local target_hp_after=$(py "
import json
c = d.get('combat', {})
for h in c.get('hostiles', []):
    if h.get('id') == $n_id:
        print(h.get('hp', 0))
        break
else:
    print(0)
" 2>/dev/null)
                target_hp_after=${target_hp_after:-0}
                if [ "$target_hp_before" -gt 0 ] && [ "$target_hp_after" -lt "$target_hp_before" ]; then
                    local dmg_dealt=$((target_hp_before - target_hp_after))
                    # Big hit: dealt >15 damage or killed the target
                    if [ "$dmg_dealt" -ge 15 ] || [ "$target_hp_after" -le 0 ]; then
                        _combat_quip_tick=0  # force quip on big hit
                        combat_quip big_hit "Dealt $dmg_dealt damage in round $round"
                        sleep 0.5
                    fi
                fi
            fi
        else
            cmd '{"type":"end_turn"}'
            sleep 1
            wait_tick_advance 10
            round=$((round + 1))
        fi
    done
}

# ─── Exit Through ────────────────────────────────────────────────────

exit_through() {
    # Navigate to the nearest exit grid and walk through it.
    # The engine pathfinder computes the full route; navigate_to monitors
    # for the map transition when the player walks onto the exit grid.
    # Args: $1 = destination filter (substring match) or "any" (default)
    #       $2 = max exit grids to try (default 5)
    # Returns 0 on successful map transition, 1 on failure.
    local dest="${1:-any}" max_tries="${2:-5}"
    local cur_map=$(field "map.name")
    local cur_elev=$(field "map.elevation")

    echo "=== EXIT_THROUGH: looking for exit to '$dest' (current: $cur_map elev=$cur_elev) ==="

    # Get exit grids sorted by distance
    local exits=$(py "
import json
exits = d.get('objects', {}).get('exit_grids', [])
dest = '''$dest'''
if dest != 'any':
    exits = [e for e in exits if dest.lower() in e.get('destination_map_name', '').lower()]
exits.sort(key=lambda e: e.get('distance', 999))
for e in exits:
    print(f\"{e.get('tile')}\t{e.get('destination_map_name', '?')}\t{e.get('distance', 999)}\")
")

    if [ -z "$exits" ]; then
        echo "  No exit grids found matching '$dest'"
        return 1
    fi

    local attempt=0
    while IFS=$'\t' read -r tile dest_name dist; do
        [ $attempt -ge $max_tries ] && break
        attempt=$((attempt + 1))

        echo "  Attempt $attempt: navigate to exit tile $tile -> $dest_name (dist=$dist)"
        navigate_to "$tile"
        local result=$?

        # Check if map changed (navigate_to detects this too, but double-check)
        local new_map=$(field "map.name")
        local new_elev=$(field "map.elevation")
        if [ "$new_map" != "$cur_map" ] || [ "$new_elev" != "$cur_elev" ]; then
            echo "=== EXIT_THROUGH: transitioned to $new_map elev=$new_elev ==="
            return 0
        fi

        [ $result -ne 0 ] && echo "  Exit tile $tile: no path or stuck, trying next..."
    done <<< "$exits"

    echo "=== EXIT_THROUGH: FAILED after $attempt attempts (still on $cur_map) ==="
    return 1
}

# ─── Equip & Use ─────────────────────────────────────────────────────

equip_and_use() {
    # Equip an item to a hand slot, switch to that hand, and use it —
    # the player-like way to use any equippable item (explosives, flares, etc.)
    #
    # Usage: equip_and_use <item_pid> [hand] [timer_seconds]
    #   hand: "left" or "right" (default: right)
    #   timer_seconds: only for explosives (10-180, default: 30)
    if [ -z "$1" ]; then
        echo "Usage: equip_and_use <item_pid> [hand] [timer_seconds]"
        return 1
    fi
    local item_pid="$1" hand="${2:-right}" timer_seconds="${3:-}"

    # 1. Equip item to specified hand
    cmd "{\"type\":\"equip_item\",\"item_pid\":$item_pid,\"hand\":\"$hand\"}"
    sleep 0.5
    wait_tick_advance 5

    # 2. Ensure that hand is active
    local target_hand=$( [ "$hand" = "left" ] && echo 0 || echo 1 )
    local current_hand=$(field "active_hand_index")
    if [ "$current_hand" != "$target_hand" ]; then
        cmd '{"type":"switch_hand"}'
        sleep 0.3
        wait_tick_advance 3
    fi

    # 3. Use the equipped item
    if [ -n "$timer_seconds" ]; then
        cmd "{\"type\":\"use_equipped_item\",\"timer_seconds\":$timer_seconds}"
    else
        cmd '{"type":"use_equipped_item"}'
    fi
    sleep 0.5
    wait_tick_advance 5
}

# ─── Exploration ─────────────────────────────────────────────────────

explore_area() {
    # Systematically loot containers and pick up ground items within range.
    # Args: $1 = max distance to consider (default 25)
    local max_dist="${1:-25}"

    echo "=== EXPLORE_AREA (max_dist=$max_dist) ==="
    local _explore_quips=("Time to see what the wasteland left behind." "Loot run. My favorite cardio." "Everything not nailed down is technically salvage." "Finder's keepers. Wasteland rules.")
    muse "${_explore_quips[$((RANDOM % ${#_explore_quips[@]}))]}"
    sleep 1

    # Get containers (scenery with items) and ground items — tab-delimited for perf
    local targets=$(py "
import json
objs = d.get('objects', {})
scenery = objs.get('scenery', [])
ground = objs.get('ground_items', [])
results = []

# Containers: scenery with item_count > 0 or container-like names
container_names = ['chest', 'pot', 'shelf', 'locker', 'desk', 'bookshelf',
                   'dresser', 'footlocker', 'table', 'cabinet', 'crate', 'box']
for s in scenery:
    if s.get('distance', 999) > $max_dist:
        continue
    name = s.get('name', '').lower()
    if s.get('item_count', 0) > 0 or any(cn in name for cn in container_names):
        results.append({
            'type': 'container',
            'id': s.get('id'),
            'name': s.get('name', '?'),
            'tile': s.get('tile', 0),
            'dist': s.get('distance', 999),
            'pid': 0
        })

# Ground items
for g in ground:
    if g.get('distance', 999) > $max_dist:
        continue
    results.append({
        'type': 'ground_item',
        'id': g.get('id'),
        'name': g.get('name', '?'),
        'tile': g.get('tile', 0),
        'dist': g.get('distance', 999),
        'pid': g.get('pid', 0)
    })

results.sort(key=lambda r: r['dist'])
for r in results:
    print(f\"{r['type']}\t{r['id']}\t{r['name']}\t{r['dist']}\t{r['tile']}\t{r['pid']}\")
")

    if [ -z "$targets" ]; then
        echo "  No containers or ground items within $max_dist hexes"
        return 0
    fi

    local looted=0 picked=0
    while IFS=$'\t' read -r obj_type obj_id obj_name obj_dist obj_tile obj_pid; do
        if [ "$obj_type" = "container" ]; then
            echo "  Looting $obj_name (id=$obj_id, dist=$obj_dist)..."
            loot "$obj_id" && looted=$((looted + 1))
            sleep 0.5
        elif [ "$obj_type" = "ground_item" ]; then
            echo "  Picking up $obj_name (id=$obj_id, dist=$obj_dist)..."
            if [ -n "$obj_tile" ] && [ "$obj_tile" != "0" ]; then
                move_and_wait "$obj_tile" || { echo "    WARN: couldn't reach $obj_name, skipping"; continue; }
            fi
            cmd "{\"type\":\"pick_up\",\"object_id\":$obj_id}"
            sleep 0.5
            wait_idle 20
            picked=$((picked + 1))
        fi
    done <<< "$targets"

    echo "=== EXPLORE_AREA: looted $looted containers, picked up $picked items ==="
    if [ $((looted + picked)) -gt 0 ]; then
        local _loot_quips=("Not bad. Not bad at all." "The wasteland provides." "Shopping spree complete." "Every bit counts out here.")
        muse "${_loot_quips[$((RANDOM % ${#_loot_quips[@]}))]}"
        sleep 1
    else
        muse "Nothing worth taking. Disappointing."
        sleep 1
    fi
}

# ─── Interaction ──────────────────────────────────────────────────────

examine() {
    # Auto-walk to object, look at it, and report the result from message_log.
    # Args: $1 = object id
    local obj_id="$1"

    _walk_to_object "$obj_id" || true
    cmd "{\"type\":\"look_at\",\"object_id\":$obj_id}"
    sleep 1
    wait_tick_advance 10

    # Read look_at result from message_log (usually the last entry)
    local result=$(py "
msgs = d.get('message_log', [])
if msgs:
    # Last few messages may contain the look_at result
    for m in msgs[-3:]:
        print(m)
")
    local dbg=$(last_debug)
    echo "Examine result: $result"
    echo "Debug: $dbg"
}

check_inventory() {
    # Search inventory for items matching a keyword (case-insensitive).
    # Args: $1 = keyword to search for
    local keyword="$1"

    py "
import json
inv = d.get('inventory', {}).get('items', [])
kw = '''$keyword'''.lower()
found = [i for i in inv if kw in i.get('name', '').lower()]
if found:
    print(f'Found {len(found)} matching items:')
    for i in found:
        print(f\"  {i.get('name','?')} x{i.get('quantity',1)} pid={i.get('pid')} type={i.get('type','?')}\")
else:
    print(f'No items matching \"{kw}\" in inventory')
"
}

interact() {
    # Auto-walk to object, use it, and wait for idle.
    # Args: $1 = object id
    local obj_id="$1"
    _walk_to_object "$obj_id" || true
    cmd "{\"type\":\"use_object\",\"object_id\":$obj_id}"
    sleep 1
    wait_idle
}

use_skill() {
    # Auto-walk to object, apply a skill, and wait for idle.
    # Args: $1 = skill name, $2 = object id
    local skill="$1" obj_id="$2"
    _walk_to_object "$obj_id" || true
    cmd "{\"type\":\"use_skill\",\"skill\":\"$skill\",\"object_id\":$obj_id}"
    sleep 1.5
    wait_idle
}

use_item_on() {
    # Auto-walk to object, use an inventory item on it, and wait for idle.
    # Args: $1 = item pid, $2 = object id
    local item_pid="$1" obj_id="$2"
    _walk_to_object "$obj_id" || true
    cmd "{\"type\":\"use_item_on\",\"item_pid\":$item_pid,\"object_id\":$obj_id}"
    sleep 1.5
    wait_idle
}

talk() {
    # Auto-walk to NPC, initiate dialogue, then select options in sequence.
    # Usage: talk <obj_id> <option1> [option2] [option3] ...
    local obj_id="$1"; shift
    _walk_to_object "$obj_id" || true
    cmd "{\"type\":\"talk_to\",\"object_id\":$obj_id}"
    sleep 1.5
    for opt in "$@"; do
        wait_context "gameplay_dialogue" 15 || return 1
        sleep 0.5
        cmd "{\"type\":\"select_dialogue\",\"index\":$opt}"
        sleep 1
    done
    # Auto-capture dialogue info when conversation ends
    post_dialogue_hook
}

# ─── Loot ─────────────────────────────────────────────────────────────

loot() {
    # Auto-walk to container, open, take all, close. Args: $1 = object id
    local obj_id="$1"

    _walk_to_object "$obj_id" || echo "  WARN: couldn't reach container, trying anyway"

    # Snapshot inventory BEFORE looting
    local inv_before=$(py "
inv = d.get('inventory', {}).get('items', [])
print(','.join(f\"{i['pid']}:{i.get('quantity',1)}\" for i in inv))
")

    cmd "{\"type\":\"open_container\",\"object_id\":$obj_id}"
    sleep 1.5
    wait_context "gameplay_loot" 20 || return 1

    # Wait one tick for loot state to fully populate
    wait_tick_advance 3

    # Read container contents (correct field name: container_items)
    local items=$(py "
loot = d.get('loot', {})
items = loot.get('container_items', [])
for it in items:
    print(f\"  {it.get('name','?')} x{it.get('quantity',1)} (pid={it.get('pid')})\")
if not items:
    print('  (empty)')
")
    echo "Container contents:"
    echo "$items"

    cmd '{"type":"loot_take_all"}'
    sleep 0.5
    cmd '{"type":"loot_close"}'
    sleep 0.5
    wait_context_prefix "gameplay_" 10

    # Compare inventory to report what was gained
    local gained=$(py "
inv = d.get('inventory', {}).get('items', [])
before_tokens = '$inv_before'.split(',') if '$inv_before' else []
after_map = {}
for i in inv:
    key = str(i['pid'])
    after_map[key] = after_map.get(key, 0) + i.get('quantity', 1)
before_map = {}
for b in before_tokens:
    if ':' in b:
        pid, qty = b.split(':', 1)
        before_map[pid] = before_map.get(pid, 0) + int(qty)
# Find new or increased items
gained = []
for i in inv:
    pid = str(i['pid'])
    before_qty = before_map.get(pid, 0)
    after_qty = after_map.get(pid, 0)
    if after_qty > before_qty:
        gained.append(f\"{i.get('name','?')} x{after_qty - before_qty} (pid={i['pid']})\")
        before_map[pid] = after_qty  # Don't double-count
if gained:
    print('Gained: ' + ', '.join(gained))
else:
    print('Nothing gained')
")
    echo "$gained"
}

# ─── Healing ─────────────────────────────────────────────────────────

heal_to_full() {
    # Loop healing until HP=max or no items left.
    # Tries Healing Powder (pid=81, cheaper) then Stimpak (pid=40) each iteration.
    # Single py() call per iteration for performance.
    local max_loops=10
    local i=0
    while [ $i -lt $max_loops ]; do
        local info=$(py "
ds = d.get('character', {}).get('derived_stats', {})
hp, max_hp = ds.get('current_hp', 0), ds.get('max_hp', 0)
inv = d.get('inventory', {}).get('items', [])
powder = next((it for it in inv if it.get('pid') == 81), None)
stimpak = next((it for it in inv if it.get('pid') == 40), None)
heal = powder or stimpak
pid = heal.get('pid', 0) if heal else 0
name = heal.get('name', '?') if heal else ''
print(f\"{hp}\t{max_hp}\t{pid}\t{name}\")
")
        local hp="${info%%	*}"; info="${info#*	}"
        local max_hp="${info%%	*}"; info="${info#*	}"
        local heal_pid="${info%%	*}"
        local heal_name="${info##*	}"

        if [ "$hp" -ge "$max_hp" ] 2>/dev/null; then
            echo "HP full ($hp/$max_hp)"
            return 0
        fi
        if [ "$heal_pid" = "0" ] || [ -z "$heal_name" ]; then
            echo "No healing items (HP $hp/$max_hp)"
            return 1
        fi

        echo "Using $heal_name (HP $hp/$max_hp)"
        cmd "{\"type\":\"use_item\",\"item_pid\":$heal_pid}"
        sleep 1
        wait_tick_advance 5
        i=$((i + 1))
    done
    echo "Heal loop limit reached"
}

# ─── Save/Load ───────────────────────────────────────────────────────

quicksave() {
    cmd '{"type":"quicksave"}'
    sleep 1
    wait_tick_advance 5
    echo "Quicksaved"
}

quickload() {
    cmd '{"type":"quickload"}'
    sleep 2
    wait_tick_advance 10
    echo "Quickloaded"
}

save_before() {
    # Quicksave + game_log entry. Use before risky actions (lockpick, combat, explosives).
    local label="${1:-risky action}"
    quicksave
    game_log "**SAVE POINT:** $label"
}

# ─── UI Fixes ────────────────────────────────────────────────────────

dismiss_options_menu() {
    # After movie skips, escape keys leak into gameplay and open the Options
    # dialog (game_mode 8 or 24). This checks and dismisses it.
    local gm=$(field "game_mode")
    if [ "$gm" = "8" ] || [ "$gm" = "24" ]; then
        echo "Dismissing leaked Options menu (game_mode=$gm)"
        cmd '{"type":"key_press","key":"escape"}'
        sleep 0.5
        wait_tick_advance 5
    fi
}

# ─── State Inspection ────────────────────────────────────────────────

status() {
    # Ultra-compact one-liner: HP, tile, map, context, object counts.
    py "
ch = d.get('character', {}).get('derived_stats', {})
hp = ch.get('current_hp', '?')
max_hp = ch.get('max_hp', '?')
m = d.get('map', {})
tile = d.get('player', {}).get('tile', '?')
ctx = d.get('context', '?')
lvl = d.get('character', {}).get('level', '?')
xp = d.get('character', {}).get('experience', '?')
objs = d.get('objects', {})
parts = []
n_critters = len(objs.get('critters', []))
n_scenery = len(objs.get('scenery', []))
n_exits = len(objs.get('exit_grids', []))
n_ground = len(objs.get('ground_items', []))
if n_critters: parts.append(f'{n_critters} critters')
if n_scenery: parts.append(f'{n_scenery} scenery')
if n_exits: parts.append(f'{n_exits} exits')
if n_ground: parts.append(f'{n_ground} ground')
obj_str = ', '.join(parts) if parts else 'empty'
poison = ch.get('poison_level', 0)
extra = f' POISON:{poison}' if poison else ''
print(f\"HP:{hp}/{max_hp} Lv:{lvl} Tile:{tile} {m.get('name','?')} {ctx} [{obj_str}]{extra}\")
"
}

look_around() {
    # Print objects near player for strategic planning.
    # Falls back to approximate hex distance when engine distance is null.
    py "
import json
objs = d.get('objects', {})
critters = objs.get('critters', [])
scenery = objs.get('scenery', [])
exits = objs.get('exit_grids', [])
ground = objs.get('ground_items', [])
ptile = d.get('player', {}).get('tile', 0)

def approx_dist(tile):
    if not tile or not ptile: return '?'
    r1, c1 = divmod(ptile, 200)
    r2, c2 = divmod(tile, 200)
    return max(abs(r1 - r2), abs(c1 - c2))

def get_dist(obj):
    dist = obj.get('distance')
    if dist is None:
        dist = approx_dist(obj.get('tile', 0))
    return dist

def sort_key(obj):
    dist_val = obj.get('distance')
    if dist_val is None:
        dist_val = approx_dist(obj.get('tile', 0))
    return dist_val if isinstance(dist_val, (int, float)) else 999

if critters:
    print('CRITTERS:')
    for c in sorted(critters, key=sort_key):
        hp_str = f\"hp={c.get('hp')}/{c.get('max_hp')}\" if 'hp' in c else ''
        print(f\"  {c.get('name','?')} id={c.get('id')} tile={c.get('tile')} dist={get_dist(c)} {hp_str} team={c.get('team',0)}\")

if scenery:
    print('SCENERY:')
    for s in sorted(scenery, key=sort_key):
        extra = ''
        if s.get('scenery_type') == 'door':
            extra = f\" open={s.get('open')} locked={s.get('locked')}\"
        elif s.get('item_count', 0) > 0:
            extra = f\" items={s.get('item_count')}\"
        print(f\"  {s.get('name','?')} id={s.get('id')} tile={s.get('tile')} dist={get_dist(s)} type={s.get('scenery_type','?')}{extra}\")

if exits:
    print('EXIT GRIDS:')
    for e in sorted(exits, key=sort_key):
        print(f\"  tile={e.get('tile')} dist={get_dist(e)} -> {e.get('destination_map_name','?')} (map={e.get('destination_map')}, elev={e.get('destination_elevation')})\")

if ground:
    print('GROUND ITEMS:')
    for g in sorted(ground, key=sort_key):
        print(f\"  {g.get('name','?')} id={g.get('id')} tile={g.get('tile')} dist={get_dist(g)} pid={g.get('pid')}\")
"
}

inventory() {
    # Print equipped items and inventory list.
    py "
inv = d.get('inventory', {})
items = inv.get('items', [])
equipped = inv.get('equipped', {})
print(f\"Weight: {inv.get('total_weight', 0)}/{inv.get('carry_capacity', 0)}\")
for slot in ['right_hand', 'left_hand', 'armor']:
    eq = equipped.get(slot)
    if eq:
        print(f\"Equipped {slot}: {eq.get('name','?')} (pid={eq.get('pid')})\")
if items:
    print('Inventory:')
    for it in sorted(items, key=lambda x: x.get('name', '')):
        print(f\"  {it.get('name','?')} x{it.get('quantity',1)} pid={it.get('pid')} type={it.get('type','?')}\")
"
}

# ─── Knowledge Management ────────────────────────────────────────────

KNOWLEDGE_DIR="$GAME_DIR/knowledge"
LOG_FILE="$GAME_DIR/game_log.md"

game_log() {
    # Append a timestamped entry to the game log with current game state context.
    # Usage: game_log "**Decision:** ...\n**Action:** ...\n**Result:** ...\nTags: ..."
    local text="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M')
    # Single py() call for all metadata (5x fewer subprocesses)
    local meta=$(py "
ch = d.get('character', {})
ds = ch.get('derived_stats', {})
print(f\"{d.get('map',{}).get('name','unknown')}\t{d.get('context','unknown')}\t{d.get('player',{}).get('tile','?')}\t{ds.get('current_hp','?')}/{ds.get('max_hp','?')}\t{ch.get('level','?')}\")
" 2>/dev/null || echo "unknown	unknown	?	?/?	?")
    local map="${meta%%	*}"; meta="${meta#*	}"
    local ctx="${meta%%	*}"; meta="${meta#*	}"
    local tile="${meta%%	*}"; meta="${meta#*	}"
    local hp="${meta%%	*}"
    local level="${meta##*	}"

    {
        echo ""
        echo "## [$timestamp] $map — $ctx"
        echo "HP: $hp | Level: $level | Tile: $tile"
        echo "$text"
        echo "---"
    } >> "$LOG_FILE"
    echo "Logged to game_log.md"
}

recall() {
    # Search game log and all knowledge files for a keyword.
    # Usage: recall "keyword"
    local keyword="$1"

    echo "=== RECALL: '$keyword' ==="

    # Search knowledge files (use -F for literal string match)
    if [ -d "$KNOWLEDGE_DIR" ]; then
        for f in "$KNOWLEDGE_DIR"/*.md; do
            [ -f "$f" ] || continue
            local matches=$(grep -iF -n "$keyword" "$f" 2>/dev/null)
            if [ -n "$matches" ]; then
                echo "--- $(basename "$f") ---"
                echo "$matches"
            fi
        done
    fi

    # Search game log (last 20 matches with context)
    if [ -f "$LOG_FILE" ]; then
        local log_matches=$(grep -iF -B2 -A3 "$keyword" "$LOG_FILE" 2>/dev/null | tail -60)
        if [ -n "$log_matches" ]; then
            echo "--- game_log.md ---"
            echo "$log_matches"
        fi
    fi
}

note() {
    # Append text to a knowledge file.
    # Usage: note "category" "text to append"
    # Categories: locations, characters, quests, strategies, items, world
    local category="$1"
    local text="$2"
    local file="$KNOWLEDGE_DIR/${category}.md"

    if [ ! -f "$file" ]; then
        echo "ERROR: Unknown category '$category'. Available: locations, characters, quests, strategies, items, world"
        return 1
    fi

    echo "" >> "$file"
    echo "$text" >> "$file"
    echo "Note added to $category.md"
}

# ─── Auto-knowledge capture hooks ─────────────────────────────────────

LAST_MAP_NAME=""
LAST_MAP_ELEVATION=""

post_transition_hook() {
    # Auto-record location + nearby objects after a map transition.
    # Also auto-dismisses leaked Options menu from movie skips.
    # Call this after confirming a map transition has occurred.
    local map_name=$(field "map.name")
    local elevation=$(field "map.elevation")
    local tile=$(field "player.tile")

    # Auto-dismiss leaked options menu after transitions
    dismiss_options_menu

    # Skip if we haven't actually transitioned
    if [ "$map_name" = "$LAST_MAP_NAME" ] && [ "$elevation" = "$LAST_MAP_ELEVATION" ]; then
        return 0
    fi
    LAST_MAP_NAME="$map_name"
    LAST_MAP_ELEVATION="$elevation"

    local nearby=$(py "
objs = d.get('objects', {})
critters = [c.get('name','?') for c in objs.get('critters', []) if c.get('distance', 999) <= 20]
scenery = [s.get('name','?') for s in objs.get('scenery', []) if s.get('distance', 999) <= 15]
exits = [e.get('destination_map_name','?') for e in objs.get('exit_grids', [])]
parts = []
if critters: parts.append('NPCs: ' + ', '.join(set(critters)))
if scenery: parts.append('Scenery: ' + ', '.join(list(set(scenery))[:5]))
if exits: parts.append('Exits: ' + ', '.join(set(exits)))
print('; '.join(parts) if parts else 'empty area')
")

    local entry="- **${map_name}** (elev ${elevation}, tile ${tile}): ${nearby}"
    note "locations" "$entry" 2>/dev/null
    game_log "Entered $map_name elev=$elevation — $nearby" 2>/dev/null
    echo "AUTO-NOTE: $entry"
}

post_dialogue_hook() {
    # Auto-record NPC name + key dialogue lines after a conversation ends.
    # Call this after confirming dialogue context has ended.
    local npc_name=$(py "print(d.get('dialogue', {}).get('speaker_name', 'Unknown'))")
    local reply=$(py "
reply = d.get('dialogue', {}).get('reply_text', '')
print(reply[:120] if reply else '')
")

    if [ -n "$npc_name" ] && [ "$npc_name" != "Unknown" ] && [ "$npc_name" != "null" ]; then
        local map_name=$(field "map.name")
        local entry="- **${npc_name}** (${map_name}): ${reply}"
        note "characters" "$entry" 2>/dev/null
        echo "AUTO-NOTE: Talked to $npc_name"
    fi
}


# ─── Persona & Thought Log ────────────────────────────────────────────

PERSONA_FILE="$GAME_DIR/persona.md"
THOUGHT_LOG="$GAME_DIR/thought_log.md"
PROJECT_ROOT="$(cd "$GAME_DIR/.." && pwd)"
DEFAULT_PERSONA="$PROJECT_ROOT/docs/default-persona.md"

init_persona() {
    # Copy default persona template if none exists; create thought log header
    if [ ! -f "$PERSONA_FILE" ]; then
        if [ -f "$DEFAULT_PERSONA" ]; then
            cp "$DEFAULT_PERSONA" "$PERSONA_FILE"
            echo "Persona initialized from default template"
        else
            echo "WARN: Default persona not found at $DEFAULT_PERSONA" >&2
        fi
    fi
    if [ ! -f "$THOUGHT_LOG" ]; then
        cat > "$THOUGHT_LOG" << 'HEADER'
# Thought Log

Append-only reasoning log. Each entry captures the character's decision-making process.

HEADER
        echo "Thought log initialized"
    fi
}

muse() {
    # Quick floating thought above the player's head — no log entry.
    # Spin-waits before and after dispatch to avoid clobbering pending/next commands.
    # Sanitizes Unicode to ASCII 32-126 (Fallout 2 font range).
    # Usage: muse "text to display"
    if [ $# -lt 1 ] || [ -z "$1" ]; then return; fi
    local text="$1"
    local escaped=$(echo "$text" | python3 -c "
import sys, json
SUBS = {
    '\u2014': '--', '\u2013': '-', '\u2018': \"'\", '\u2019': \"'\",
    '\u201c': '\"', '\u201d': '\"', '\u2026': '...', '\u2022': '*',
    '\u00b7': '*', '\u2010': '-', '\u2011': '-', '\u00a0': ' ',
    '\u200b': '', '\u2032': \"'\", '\u2033': '\"', '\u00d7': 'x',
    '\u2192': '->', '\u2190': '<-', '\u2264': '<=', '\u2265': '>=',
    '\u2260': '!=',
}
text = sys.stdin.read().strip()
for old, new in SUBS.items():
    text = text.replace(old, new)
text = ''.join(c if 32 <= ord(c) <= 126 or c == '\n' else '' for c in text)
print(json.dumps(text))
")
    for i in 1 2 3 4 5; do [ ! -f "$CMD" ] && break; sleep 0.1; done
    cmd "{\"type\":\"float_thought\",\"text\":$escaped}"
    for i in 1 2 3 4 5; do [ ! -f "$CMD" ] && break; sleep 0.1; done
}

_combat_quip_generate() {
    # Generate a combat quip using Sonnet + full game state + character persona.
    # Args: $1=event  $2=extra context (optional)
    # Reads agent_state.json directly for full combat awareness.
    local event="$1" extra="${2:-}"

    # Build full combat context from live game state + persona
    local prompt
    prompt=$(python3 -c "
import json, re, sys

event = '$event'
extra = '''$extra'''

# Read game state
try:
    with open('$STATE') as f:
        d = json.load(f)
except:
    print(''); sys.exit(0)

# Read persona
persona = 'sarcastic, witty, audacious rogue with main-character energy'
try:
    with open('$GAME_DIR/persona.md') as f:
        text = f.read()
    parts = []
    for section in ['Personality', 'Combat Approach']:
        m = re.search(r'## ' + section + r'\n(.*?)(?=\n## |\Z)', text, re.DOTALL)
        if m:
            parts.append(m.group(1).strip())
    if parts:
        persona = ' | '.join(parts)
except:
    pass

# Build combat snapshot
c = d.get('combat', {})
ch = d.get('character', {}).get('derived_stats', {})
hp = ch.get('current_hp', 0)
max_hp = ch.get('max_hp', 1)
hp_pct = int(hp * 100 / max_hp) if max_hp > 0 else 100
ap = c.get('current_ap', 0)
weapon = c.get('active_weapon', {})
w_name = weapon.get('name', c.get('active_hand', 'unarmed'))

# Enemies — nearby vs distant
hostiles = c.get('hostiles', [])
alive = [h for h in hostiles if h.get('hp', 0) > 0]
alive.sort(key=lambda h: h.get('distance', 999))
nearby = [h for h in alive if h.get('distance', 999) <= 15]
enemies_str = ''
for h in alive[:5]:
    dist = h.get('distance', '?')
    marker = ' [CLOSE]' if dist <= 15 else ''
    enemies_str += f\"  - {h.get('name','?')} HP:{h.get('hp',0)}/{h.get('max_hp','?')} dist:{dist}{marker}\n\"

# Recent combat messages
msgs = d.get('message_log', [])[:8]
msgs_str = ' | '.join(msgs) if msgs else 'none'

# Map info
map_name = d.get('map', {}).get('name', '?')

# Event description
event_desc = {
    'start': 'Combat just began',
    'kill': 'Just killed an enemy',
    'hurt': 'Just took damage',
    'big_hurt': 'Just took a MASSIVE hit',
    'big_hit': 'Just landed a devastating blow',
    'critical_hp': 'HP critically low, about to flee',
    'flee': 'Fleeing from combat',
    'win': 'Just won the fight',
}.get(event, event)

situation = f'''EVENT: {event_desc}
{f'Detail: {extra}' if extra else ''}
Location: {map_name}
Player: HP {hp}/{max_hp} ({hp_pct}%), AP {ap}, Weapon: {w_name}
Enemies ({len(nearby)} close, {len(alive)} total):
{enemies_str if enemies_str else '  none'}
Recent combat log: {msgs_str}'''

prompt = f'''You are Vex, a wasteland character. Your voice: {persona}

Write ONLY a short in-character combat quip (under 20 words). No quotes around it, no narration tags, no stage directions, no explanation. Just the raw quip as inner monologue.

{situation}'''

print(prompt)
" 2>/dev/null)

    [ -z "$prompt" ] && return

    local quip
    quip=$(unset CLAUDECODE && claude -p --model sonnet "$prompt" 2>/dev/null)
    if [ -n "$quip" ] && [ ${#quip} -ge 5 ]; then
        for _i in 1 2 3 4 5 6 7 8 9 10; do [ ! -f "$CMD" ] && break; sleep 0.1; done
        muse "$quip"
    fi
}

combat_quip() {
    # Generate a dynamic, context-aware combat quip via Sonnet in the BACKGROUND.
    # Reads full game state for rich context. Throttled to avoid spam.
    # Args: $1=event  $2=extra context (optional)
    # Throttle: skip if too recent (round-based counter)
    if [ "$(( _combat_quip_tick ))" -gt 0 ]; then
        _combat_quip_tick=$((_combat_quip_tick - 1))
        return
    fi
    _combat_quip_tick=2  # ~3 rounds between quips

    local event="${1:-}"
    local extra="${2:-}"
    case "$event" in
        start|kill|hurt|big_hurt|big_hit|critical_hp|flee|win) ;;
        *) return ;;
    esac

    # Fire-and-forget in background so combat loop isn't blocked (~3-5s LLM latency)
    ( _combat_quip_generate "$event" "$extra" ) &
}

combat_quip_sync() {
    # Same as combat_quip but SYNCHRONOUS — blocks until quip is delivered.
    # Use for events where the caller is about to exit (e.g., combat victory).
    _combat_quip_generate "${1:-win}" "${2:-}"
}

think() {
    # Log a reasoning entry + display it above player's head in-game.
    # Usage: think "title" "reasoning_text"
    # Auto-captures: timestamp, map, HP, level from game state.
    if [ $# -lt 2 ]; then
        echo "Usage: think <title> <reasoning>"
        return 1
    fi

    local title="$1"
    local reasoning="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M')
    # Single py() call for all metadata
    local meta=$(py "
ch = d.get('character', {})
ds = ch.get('derived_stats', {})
print(f\"{d.get('map',{}).get('name','unknown')}\t{ds.get('current_hp','?')}\t{ds.get('max_hp','?')}\t{ch.get('level','?')}\")
" 2>/dev/null || echo "unknown	?	?	?")
    local map="${meta%%	*}"; meta="${meta#*	}"
    local hp="${meta%%	*}"; meta="${meta#*	}"
    local max_hp="${meta%%	*}"
    local level="${meta##*	}"

    {
        echo "---"
        echo ""
        echo "### [$timestamp] $map — $title"
        echo "**Map:** $map | **HP:** $hp/$max_hp | **Level:** $level"
        echo ""
        echo "$reasoning"
    } >> "$THOUGHT_LOG"
    echo "Thought logged: $title"

    # Show condensed thought above player's head in-game
    local short_text="${reasoning:0:80}"
    muse "$short_text"
}

read_persona() {
    # Read full persona or a specific section by heading.
    # Usage: read_persona              — prints full persona
    #        read_persona "Values"     — prints just the ## Values section
    if [ ! -f "$PERSONA_FILE" ]; then
        echo "No persona file found. Run init_persona first."
        return 1
    fi

    if [ $# -eq 0 ]; then
        cat "$PERSONA_FILE"
    else
        local section="$1"
        PERSONA_PATH="$PERSONA_FILE" SECTION="$section" python3 -c "
import re, sys, os
with open(os.environ['PERSONA_PATH']) as f:
    content = f.read()
section = os.environ['SECTION']
pattern = r'(## ' + re.escape(section) + r'\b.*?)(?=\n## |\Z)'
m = re.search(pattern, content, re.DOTALL)
if m:
    print(m.group(1).strip())
else:
    print(f'Section \"{section}\" not found')
    sys.exit(1)
"
    fi
}

evolve_persona() {
    # Record a persona evolution — when experiences shift values.
    # Usage: evolve_persona "title" "what happened" "what changed" ["new rule"]
    # Appends to persona's Evolution Log section AND logs to thought log.
    if [ $# -lt 3 ]; then
        echo "Usage: evolve_persona <title> <what_happened> <what_changed> [new_rule]"
        return 1
    fi

    local title="$1"
    local happened="$2"
    local changed="$3"
    local new_rule="${4:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M')

    # Append evolution entry to persona file
    local evolution_entry="- **[$timestamp] $title:** $happened → $changed"
    if [ -n "$new_rule" ]; then
        evolution_entry="$evolution_entry. *New rule: $new_rule*"
    fi

    # Append evolution entry to the Evolution Log section of persona file
    PERSONA_PATH="$PERSONA_FILE" EVOLUTION_ENTRY="$evolution_entry" python3 -c "
import os
path = os.environ['PERSONA_PATH']
entry = os.environ['EVOLUTION_ENTRY']
with open(path, 'r') as f:
    content = f.read()
marker = '## Evolution Log'
idx = content.find(marker)
if idx == -1:
    content = content.rstrip() + '\n\n## Evolution Log\n\n' + entry + '\n'
else:
    next_sec = content.find('\n## ', idx + len(marker))
    if next_sec == -1:
        content = content.rstrip() + '\n' + entry + '\n'
    else:
        content = content[:next_sec] + entry + '\n' + content[next_sec:]
with open(path, 'w') as f:
    f.write(content)
"

    echo "Persona evolved: $title"

    # Also log to thought log
    think "$title (Evolution)" "Experience shifted my values. $happened Changed: $changed"
}

# ─── Help ─────────────────────────────────────────────────────────────

executor_help() {
    echo "═══ EXECUTOR FUNCTIONS ═══"
    echo ""
    echo "SURVEY (read game state):"
    echo "  status                          — compact one-liner (HP, tile, map, context)"
    echo "  look_around                     — nearby objects by category"
    echo "  inventory                       — equipped + inventory list"
    echo "  examine <id>                    — auto-walk + examine object"
    echo "  check_inventory <keyword>       — search inventory by name"
    echo ""
    echo "ACT (goal-oriented):"
    echo "  explore_area [dist]             — sweep + loot all nearby"
    echo "  do_combat [timeout] [heal%]     — autonomous combat loop"
    echo "  exit_through <dest|any>         — leave map via exit grids"
    echo "  heal_to_full                    — loop healing until HP=max"
    echo "  loot <id>                       — auto-walk + open + take all + close"
    echo "  interact <id>                   — auto-walk + use object"
    echo "  talk <id> [opt1 opt2 ...]       — auto-walk + dialogue"
    echo "  use_skill <skill> <id>          — auto-walk + apply skill"
    echo "  use_item_on <pid> <id>          — auto-walk + use item on object"
    echo "  equip_and_use <pid> [hand] [t]  — equip + switch hand + use"
    echo "  move_and_wait <tile>            — walk to tile (positioning)"
    echo ""
    echo "SAVE/LOAD:"
    echo "  quicksave / quickload           — save/load game"
    echo "  save_before <label>             — quicksave + log entry"
    echo ""
    echo "COMMENTARY + KNOWLEDGE:"
    echo "  muse \"text\"                     — floating thought"
    echo "  think <title> <text>            — logged reasoning + thought"
    echo "  game_log \"text\"                 — log event"
    echo "  note <category> \"text\"          — record knowledge"
    echo "  recall \"keyword\"                — search knowledge"
    echo ""
    echo "PERSONA:"
    echo "  read_persona [section]          — read character persona"
    echo "  evolve_persona                  — update after significant events"
    echo ""
    echo "UI:"
    echo "  dismiss_options_menu            — dismiss leaked options dialog"
}

# Auto-initialize persona on source
init_persona

echo "executor.sh loaded — run 'executor_help' for commands"
