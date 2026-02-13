#!/usr/bin/env bash
# executor.sh — Tactical execution helpers for Claude Code gameplay
#
# Provides functions for common gameplay loops (combat, movement, exploration,
# explosives, looting) that can be called from Claude Code to avoid expensive
# polling round-trips.
#
# Usage: source scripts/executor.sh
#        Then call functions like: do_combat, move_and_wait, explore_area, etc.
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

set -uo pipefail

GAME_DIR="${FALLOUT2_GAME_DIR:-/Users/alexis.radcliff/fallout2-sdk/game}"
STATE="$GAME_DIR/agent_state.json"
CMD="$GAME_DIR/agent_cmd.json"
TMP="$GAME_DIR/agent_cmd.tmp"

# ─── Reflection timer ─────────────────────────────────────────────────
# Prints a reminder every 3 minutes to pause and reflect on progress.

LAST_REFLECTION_TIME=$(date +%s)

check_reflection_due() {
    local now=$(date +%s)
    if (( now - LAST_REFLECTION_TIME >= 180 )); then
        echo "=== REFLECTION DUE ($(( (now - LAST_REFLECTION_TIME) / 60 ))m since last) ==="
        echo "    Pause and assess: What have I accomplished? What's my current goal?"
        echo "    Am I making progress or stuck in a loop?"
        LAST_REFLECTION_TIME=$now
        return 0
    fi
    return 1
}

# ─── Core I/O ─────────────────────────────────────────────────────────

send() {
    echo "$1" > "$TMP" && mv "$TMP" "$CMD"
}

cmd() {
    send "{\"commands\":[$1]}"
}

cmds() {
    # Send multiple commands: cmds '{"type":"a"}' '{"type":"b"}'
    local joined=""
    for c in "$@"; do
        [ -n "$joined" ] && joined="$joined,"
        joined="$joined$c"
    done
    send "{\"commands\":[$joined]}"
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
    check_reflection_due
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
        if [ "$busy" = "false" ] && [ "${remaining:-0}" = "0" ]; then
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

exit_map() {
    # Navigate to the nearest exit grid and walk through it.
    # The engine pathfinder computes the full route; navigate_to monitors
    # for the map transition when the player walks onto the exit grid.
    # Args: $1 = destination filter (substring match) or "any" (default)
    #       $2 = max exit grids to try (default 5)
    # Returns 0 on successful map transition, 1 on failure.
    local dest="${1:-any}" max_tries="${2:-5}"
    local cur_map=$(field "map.name")
    local cur_elev=$(field "map.elevation")

    echo "=== EXIT_MAP: looking for exit to '$dest' (current: $cur_map elev=$cur_elev) ==="

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
            echo "=== EXIT_MAP: transitioned to $new_map elev=$new_elev ==="
            return 0
        fi

        [ $result -ne 0 ] && echo "  Exit tile $tile: no path or stuck, trying next..."
    done <<< "$exits"

    echo "=== EXIT_MAP: FAILED after $attempt attempts (still on $cur_map) ==="
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
    local stuck_rounds=0 last_n_alive=999 last_total_hp=999999 round_actions=0

    _combat_heal_failed=0
    echo "=== COMBAT START (timeout=${timeout_secs}s) ==="
    while true; do
        # Wall-clock timeout
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        if [ $elapsed -ge $timeout_secs ]; then
            echo "=== COMBAT TIMEOUT (${elapsed}s, actions=$action_count, rounds=$round) ==="
            check_reflection_due
            return 1
        fi

        local ctx=$(context)

        # Combat over?
        if [ "$ctx" != "gameplay_combat" ] && [ "$ctx" != "gameplay_combat_wait" ]; then
            echo "=== COMBAT END (context: $ctx, rounds: $round, actions: $action_count, ${elapsed}s) ==="
            check_reflection_due
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
print(json.dumps({
    'ap': c.get('current_ap', 0),
    'free_move': c.get('free_move', 0),
    'hp': ch.get('current_hp', 0),
    'max_hp': ch.get('max_hp', 0),
    'n_alive': len(alive),
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
        local ap=0 hp=0 max_hp=0 n_alive=0 n_id=0 n_dist=999 n_tile=0 n_name='?' n_hp=0 total_hp=0 free_move=0 w_range=1 w_ap=3 w_name='unarmed'
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

        echo "  Round $round: AP=$ap(+${free_move}fm) HP=$hp/$max_hp [weapon: $w_name rng=$w_range] vs $n_name($n_hp hp, dist=$n_dist) [$n_alive alive]"

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
        round_actions=0

        # If stuck for 8+ rounds with no progress, flee combat
        if [ $stuck_rounds -ge 8 ]; then
            echo "    STUCK for $stuck_rounds rounds, fleeing combat"
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
    # Walk onto exit grid tiles to trigger a natural map transition.
    # Uses navigate_to for long-distance pathfinding to exit grids.
    # Args: $1 = destination map name (substring match) or "any"
    #       $2 = max exits to try (default 5)
    # Returns 0 on successful transition, 1 on failure.
    # NOTE: Prefer exit_map() which is an alias with the same behavior.
    exit_map "$@"
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

arm_and_detonate() {
    # Full explosive workflow using the player-like equip → use flow:
    #   1. Walk adjacent to target
    #   2. Equip explosive, switch hand, use it (timer bypass)
    #   3. Run away from blast radius
    #   4. Wait for detonation
    #   5. Report result
    #
    # Usage: arm_and_detonate <target_id> <safe_tile> [explosive_pid] [timer_secs]
    local target_id="$1" safe_tile="$2" explosive_pid="${3:-85}" timer_secs="${4:-30}"

    echo "=== ARM_AND_DETONATE: target=$target_id explosive=pid$explosive_pid ==="

    # Step 1: Check we have the explosive
    local have=$(py "
inv = d.get('inventory', {}).get('items', [])
found = [i for i in inv if i.get('pid') == $explosive_pid]
print(len(found))
")
    if [ "$have" = "0" ]; then
        echo "  ERROR: No explosive with pid=$explosive_pid in inventory"
        return 1
    fi

    # Step 2: Walk adjacent to target
    local target_tile=$(py "
import json
for cat in ['scenery', 'critters', 'ground_items']:
    for obj in d.get('objects', {}).get(cat, []):
        if obj.get('id') == $target_id:
            print(obj.get('tile', 0))
            break
    else:
        continue
    break
else:
    print(0)
")
    if [ "$target_tile" = "0" ]; then
        echo "  ERROR: Cannot find target object $target_id"
        return 1
    fi

    echo "  Walking to target tile $target_tile..."
    cmd "{\"type\":\"run_to\",\"tile\":$target_tile}"
    sleep 0.5
    wait_idle 30

    # Step 3: Equip and use explosive (player-like flow)
    echo "  Equipping and using explosive (pid=$explosive_pid, timer=${timer_secs}s)..."
    equip_and_use $explosive_pid right $timer_secs

    local dbg=$(last_debug)
    echo "  Use result: $dbg"

    # Step 4: Run to safe distance
    echo "  Running to safe tile $safe_tile..."
    cmd "{\"type\":\"run_to\",\"tile\":$safe_tile}"
    sleep 0.5
    wait_idle 30

    # Step 5: Wait for detonation
    local wait_secs=$((timer_secs + 5))
    echo "  Waiting ${wait_secs}s for detonation..."
    sleep $wait_secs

    # Step 6: Check if target was destroyed
    local still_there=$(py "
import json
for cat in ['scenery', 'critters', 'ground_items']:
    for obj in d.get('objects', {}).get(cat, []):
        if obj.get('id') == $target_id:
            print('yes')
            break
    else:
        continue
    break
else:
    print('no')
")

    if [ "$still_there" = "no" ]; then
        echo "=== ARM_AND_DETONATE: SUCCESS — target destroyed ==="
        return 0
    else
        echo "=== ARM_AND_DETONATE: target still present (may have changed state) ==="
        local msgs=$(py "
msgs = d.get('message_log', [])
for m in msgs[-5:]:
    print(m)
")
        echo "  Recent messages: $msgs"
        return 1
    fi
}

# ─── Exploration ─────────────────────────────────────────────────────

explore_area() {
    # Systematically loot containers and pick up ground items within range.
    # Args: $1 = max distance to consider (default 25)
    local max_dist="${1:-25}"

    echo "=== EXPLORE_AREA (max_dist=$max_dist) ==="

    # Get containers (scenery with items) and ground items
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
            'items': s.get('item_count', 0)
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
    print(json.dumps(r, separators=(',',':')))
")

    if [ -z "$targets" ]; then
        echo "  No containers or ground items within $max_dist hexes"
        return 0
    fi

    local looted=0 picked=0
    while IFS= read -r line; do
        local obj_type=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['type'])")
        local obj_id=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        local obj_name=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
        local obj_dist=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['dist'])")

        local obj_tile=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['tile'])")

        if [ "$obj_type" = "container" ]; then
            echo "  Looting $obj_name (id=$obj_id, dist=$obj_dist)..."
            # loot_all already walks to container
            loot_all "$obj_id" && looted=$((looted + 1))
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
    check_reflection_due
}

examine_object() {
    # Look at an object and report the result from message_log.
    # Args: $1 = object id
    local obj_id="$1"

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

check_inventory_for() {
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

# ─── Loot ─────────────────────────────────────────────────────────────

loot_all() {
    # Walk to container, open, take all, close. Args: $1 = object id
    local obj_id="$1"

    # Find container tile from current objects and walk there first
    local container_tile=$(py "
objs = d.get('objects', {})
for cat in ['scenery', 'ground_items', 'items']:
    for o in objs.get(cat, []):
        if str(o.get('id')) == '$obj_id':
            print(o.get('tile', ''))
            break
")
    if [ -n "$container_tile" ] && [ "$container_tile" != "None" ]; then
        move_and_wait "$container_tile" || echo "  WARN: couldn't reach container tile $container_tile, trying anyway"
    fi

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

use_healing() {
    # Use healing items outside combat. Tries Healing Powder (pid=81), then Stimpak (pid=40).
    local hp=$(py "ds=d.get('character',{}).get('derived_stats',{}); print(ds.get('current_hp',0))")
    local max_hp=$(py "ds=d.get('character',{}).get('derived_stats',{}); print(ds.get('max_hp',0))")
    hp="${hp:-0}"; max_hp="${max_hp:-0}"

    if [ "$hp" -ge "$max_hp" ] 2>/dev/null; then
        echo "HP full ($hp/$max_hp)"
        return 0
    fi

    for pid in 81 40; do
        local has=$(py "
inv = d.get('inventory', {}).get('items', [])
found = [i for i in inv if i.get('pid') == $pid]
print(found[0].get('name','?') if found else '')
")
        if [ -n "$has" ]; then
            echo "Using $has (HP $hp/$max_hp)"
            cmd "{\"type\":\"use_item\",\"item_pid\":$pid}"
            sleep 1
            wait_tick_advance 5
            local new_hp=$(py "ds=d.get('character',{}).get('derived_stats',{}); print(ds.get('current_hp',0))")
            echo "HP: $hp -> $new_hp / $max_hp"
            return 0
        fi
    done
    echo "No healing items (HP $hp/$max_hp)"
    return 1
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

# ─── Interaction ──────────────────────────────────────────────────────

use_object_and_wait() {
    local obj_id="$1"
    cmd "{\"type\":\"use_object\",\"object_id\":$obj_id}"
    sleep 1
    wait_idle
}

use_skill_and_wait() {
    local skill="$1" obj_id="$2"
    cmd "{\"type\":\"use_skill\",\"skill\":\"$skill\",\"object_id\":$obj_id}"
    sleep 1.5
    wait_idle
}

# Skill attempt tracking — prevents infinite retry loops
typeset -A SKILL_ATTEMPTS 2>/dev/null || declare -A SKILL_ATTEMPTS

use_skill_tracked() {
    # Use a skill with attempt tracking. Gives up after max attempts.
    # Args: $1=skill $2=object_id $3=max_attempts(default 5)
    local skill="$1" obj_id="$2" max="${3:-5}"
    local key="${skill}_${obj_id}"
    local count=${SKILL_ATTEMPTS[$key]:-0}
    if (( count >= max )); then
        echo "WARN: $skill on object $obj_id failed $count times, giving up"
        return 1
    fi
    SKILL_ATTEMPTS[$key]=$((count + 1))
    use_skill_and_wait "$skill" "$obj_id"
}

reset_skill_attempts() {
    SKILL_ATTEMPTS=()
}

use_item_on_and_wait() {
    local item_pid="$1" obj_id="$2"
    cmd "{\"type\":\"use_item_on\",\"item_pid\":$item_pid,\"object_id\":$obj_id}"
    sleep 1.5
    wait_idle
}

talk_and_choose() {
    # Talk to NPC, then select dialogue options in sequence
    # Usage: talk_and_choose <obj_id> <option1> [option2] [option3] ...
    local obj_id="$1"; shift
    cmd "{\"type\":\"talk_to\",\"object_id\":$obj_id}"
    sleep 1.5
    for opt in "$@"; do
        wait_context "gameplay_dialogue" 15 || return 1
        sleep 0.3
        cmd "{\"type\":\"select_dialogue\",\"index\":$opt}"
        sleep 1
    done
    # Auto-capture dialogue info when conversation ends
    post_dialogue_hook
}

# ─── State Snapshot ───────────────────────────────────────────────────

snapshot() {
    # Print a compact summary of current state for Claude to reason about
    py "
import json
ctx = d.get('context', '?')
tick = d.get('tick', 0)
result = {'context': ctx, 'tick': tick}

if 'player' in d:
    p = d['player']
    result['tile'] = p.get('tile')
    result['busy'] = p.get('animation_busy', False)

if 'map' in d:
    m = d['map']
    result['map'] = m.get('name', '?')
    result['elevation'] = m.get('elevation', 0)

if 'character' in d:
    ch = d['character']
    ds = ch.get('derived_stats', {})
    result['hp'] = f\"{ds.get('current_hp', '?')}/{ds.get('max_hp', '?')}\"
    poison = ds.get('poison_level', 0)
    if poison:
        result['poison'] = poison
    result['level'] = ch.get('level', 1)
    result['xp'] = ch.get('experience', 0)

if 'combat' in d:
    c = d['combat']
    result['ap'] = c.get('current_ap')
    hostiles = [h for h in c.get('hostiles', []) if h.get('hp', 0) > 0]
    result['hostiles'] = len(hostiles)

if 'objects' in d:
    o = d['objects']
    result['critters'] = len(o.get('critters', []))
    result['exits'] = len(o.get('exit_grids', []))
    result['scenery'] = len(o.get('scenery', []))
    result['ground_items'] = len(o.get('ground_items', []))

if 'inventory' in d:
    inv = d['inventory']
    result['items'] = len(inv.get('items', []))

if 'message_log' in d:
    msgs = d.get('message_log', [])
    if msgs:
        result['last_msg'] = msgs[-1] if len(msgs[-1]) < 80 else msgs[-1][:77] + '...'

if 'party_members' in d:
    result['party'] = len(d['party_members'])

print(json.dumps(result, indent=2))
"
}

objects_near() {
    # Print objects near player for strategic planning
    py "
import json
objs = d.get('objects', {})
critters = objs.get('critters', [])
scenery = objs.get('scenery', [])
exits = objs.get('exit_grids', [])
ground = objs.get('ground_items', [])

if critters:
    print('CRITTERS:')
    for c in sorted(critters, key=lambda x: x.get('distance', 999)):
        hp_str = f\"hp={c.get('hp')}/{c.get('max_hp')}\" if 'hp' in c else ''
        print(f\"  {c.get('name','?')} id={c.get('id')} tile={c.get('tile')} dist={c.get('distance')} {hp_str} team={c.get('team',0)}\")

if scenery:
    print('SCENERY:')
    for s in sorted(scenery, key=lambda x: x.get('distance', 999)):
        extra = ''
        if s.get('scenery_type') == 'door':
            extra = f\" open={s.get('open')} locked={s.get('locked')}\"
        elif s.get('item_count', 0) > 0:
            extra = f\" items={s.get('item_count')}\"
        print(f\"  {s.get('name','?')} id={s.get('id')} tile={s.get('tile')} dist={s.get('distance')} type={s.get('scenery_type','?')}{extra}\")

if exits:
    print('EXIT GRIDS:')
    for e in sorted(exits, key=lambda x: x.get('distance', 999)):
        print(f\"  tile={e.get('tile')} dist={e.get('distance')} -> {e.get('destination_map_name','?')} (map={e.get('destination_map')}, elev={e.get('destination_elevation')})\")

if ground:
    print('GROUND ITEMS:')
    for g in sorted(ground, key=lambda x: x.get('distance', 999)):
        print(f\"  {g.get('name','?')} id={g.get('id')} tile={g.get('tile')} dist={g.get('distance')} pid={g.get('pid')}\")
"
}

inventory_summary() {
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
    local map=$(field "map.name" 2>/dev/null || echo "unknown")
    local ctx=$(context 2>/dev/null || echo "unknown")
    local tile=$(field "player.tile" 2>/dev/null || echo "?")
    local hp=$(py "ds=d.get('character',{}).get('derived_stats',{}); print(f\"{ds.get('current_hp','?')}/{ds.get('max_hp','?')}\")" 2>/dev/null || echo "?/?")
    local level=$(field "character.level" 2>/dev/null || echo "?")

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
    # Call this after confirming a map transition has occurred.
    local map_name=$(field "map.name")
    local elevation=$(field "map.elevation")
    local tile=$(field "player.tile")

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
exits = [e.get('destination','?') for e in objs.get('exit_grids', [])]
parts = []
if critters: parts.append('NPCs: ' + ', '.join(set(critters)))
if scenery[:5]: parts.append('Scenery: ' + ', '.join(set(scenery[:5])))
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
    # Use for moment-to-moment reflections, tactical observations, reactions.
    # Usage: muse "text to display"
    if [ $# -lt 1 ] || [ -z "$1" ]; then return; fi
    local text="$1"
    local escaped=$(echo "$text" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
    cmd "{\"type\":\"float_thought\",\"text\":$escaped}"
}

think() {
    # Log a structured thought entry + display it above player's head in-game.
    #
    # Full form:
    #   think "title" "situation" "factors" "options" "reasoning" "decision" ["impact"]
    # Quick form:
    #   think "title" "reasoning_text"
    #
    # Auto-captures: timestamp, map, HP, level from game state.
    if [ $# -lt 2 ]; then
        echo "Usage: think <title> <reasoning> (quick) or think <title> <situation> <factors> <options> <reasoning> <decision> [impact]"
        return 1
    fi

    local title="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M')
    local map=$(field "map.name" 2>/dev/null || echo "unknown")
    local hp=$(field "player.hp" 2>/dev/null || echo "?")
    local max_hp=$(field "player.max_hp" 2>/dev/null || echo "?")
    local level=$(field "player.level" 2>/dev/null || echo "?")

    local entry=""
    local float_text=""

    if [ $# -eq 2 ]; then
        # Quick form
        local reasoning="$2"
        entry="---

### [$timestamp] $map — $title
**Map:** $map | **HP:** $hp/$max_hp | **Level:** $level

$reasoning
"
        float_text="$reasoning"
    else
        # Full form
        local situation="$2"
        local factors="$3"
        local options="$4"
        local reasoning="$5"
        local decision="$6"
        local impact="${7:-No immediate persona impact.}"
        entry="---

### [$timestamp] $map — $title
**Map:** $map | **HP:** $hp/$max_hp | **Level:** $level

**Situation:** $situation

**Persona factors:**
$factors

**Options:**
$options

**Reasoning:** $reasoning

**Decision:** $decision

**Persona impact:** $impact
"
        float_text="$decision"
    fi

    echo "$entry" >> "$THOUGHT_LOG"
    echo "Thought logged: $title"

    # Show condensed thought above player's head in-game
    if [ -n "$float_text" ]; then
        # Truncate to ~80 chars for readability as floating text
        local short_text="${float_text:0:80}"
        local escaped=$(echo "$short_text" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
        cmd "{\"type\":\"float_thought\",\"text\":$escaped}"
    fi
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

    # Insert before the last line of the Evolution Log section (or append if empty)
    PERSONA_PATH="$PERSONA_FILE" EVOLUTION_ENTRY="$evolution_entry" python3 -c "
import sys, os
persona_path = os.environ['PERSONA_PATH']
evolution_entry = os.environ['EVOLUTION_ENTRY']
with open(persona_path, 'r') as f:
    content = f.read()
marker = '## Evolution Log'
idx = content.find(marker)
if idx == -1:
    content += '\n## Evolution Log\n\n'
    idx = content.find(marker)
# Find end of the Evolution Log section header
header_end = content.index('\n', idx) + 1
# Skip any blank line after header
while header_end < len(content) and content[header_end] == '\n':
    header_end += 1
# If the section just has a placeholder comment, replace it
placeholder = '(Entries added when experiences shift'
p_idx = content.find(placeholder, idx)
if p_idx != -1 and p_idx < len(content):
    # Find end of placeholder line
    p_end = content.index('\n', p_idx) + 1
    content = content[:p_idx] + evolution_entry + '\n' + content[p_end:]
else:
    # Append to end of section
    # Find next ## or end of file
    next_section = content.find('\n## ', idx + len(marker))
    if next_section == -1:
        content = content.rstrip() + '\n' + evolution_entry + '\n'
    else:
        content = content[:next_section] + evolution_entry + '\n' + content[next_section:]
with open(persona_path, 'w') as f:
    f.write(content)
"

    echo "Persona evolved: $title"

    # Also log to thought log
    think "$title (Evolution)" "Experience shifted my values. $happened Changed: $changed"
}

# Auto-initialize persona on source
init_persona

echo "executor.sh loaded. Functions:"
echo "  CORE:       cmd, cmds, send, field, context, tick, last_debug"
echo "  WAIT:       wait_idle, wait_context, wait_context_prefix, wait_tick_advance"
echo "  MOVE:       move_and_wait <tile>, navigate_to <tile> [mode]"
echo "  COMBAT:     do_combat [timeout_secs] [heal_pct]"
echo "  EXIT:       exit_map <dest|any>, exit_through (alias)"
echo "  EQUIP+USE:  equip_and_use <pid> [hand] [timer_secs]"
echo "  EXPLOSIVE:  arm_and_detonate <target_id> <safe_tile> [explosive_pid] [timer_secs]"
echo "  EXPLORE:    explore_area [max_dist], examine_object <id>, check_inventory_for <keyword>"
echo "  LOOT:       loot_all <id>"
echo "  HEALING:    use_healing"
echo "  UI:         dismiss_options_menu"
echo "  INTERACT:   use_object_and_wait, use_skill_and_wait, use_skill_tracked, use_item_on_and_wait, talk_and_choose"
echo "  STATE:      snapshot, objects_near, inventory_summary"
echo "  KNOWLEDGE:  game_log <text>, recall <keyword>, note <category> <text>"
echo "  HOOKS:      post_transition_hook, post_dialogue_hook, check_reflection_due"
echo "  PERSONA:    init_persona, read_persona [section], muse, think, evolve_persona"
