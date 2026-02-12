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
#   worldmap_travel <area>  — travel to a known area
#   worldmap_enter_location <area> [entrance] — enter local map
#
# NAVIGATION (use carefully)
#   map_transition map=-2   — enter world map (legitimate player action)
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
# LEVEL-UP (when can_level_up is true)
#   skill_add <skill> [pts] — add skill points
#   skill_sub <skill> [pts] — remove skill points
#   perk_add <perk>         — select a perk
#
# TEST MODE ONLY (cheats — disabled by default)
#   set_test_mode true/false — enable/disable cheat commands
#   teleport <tile>          — instant move (requires test mode)
#   give_item <pid> [qty]    — spawn items (requires test mode)
#   map_transition map>=0    — direct map jump (requires test mode)
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
    # Move to tile, wait for arrival. Returns 0 on success.
    local tile="$1" mode="${2:-run_to}"
    cmd "{\"type\":\"$mode\",\"tile\":$tile}"
    sleep 0.3
    wait_idle
    # Check if we actually arrived near the target
    local cur=$(field "player.tile")
    echo "Moved to tile $cur (target was $tile)"
}

# ─── Combat ───────────────────────────────────────────────────────────

do_combat() {
    # Run a full combat loop with wall-clock timeout and failure detection.
    # Args: $1 = timeout_secs (default 60), $2 = min_hp_pct to heal (default 40)
    local timeout_secs="${1:-60}" heal_pct="${2:-40}"
    local start_time=$(date +%s) action_count=0 consec_fail=0 round=0

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
}, separators=(',',':')))
")
        # Parse all fields from one JSON blob
        local ap hp max_hp n_alive n_id n_dist n_tile n_name n_hp free_move
        eval $(echo "$info" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k,v in d.items():
    if isinstance(v, str):
        print(f\"{k}='{v}'\")
    else:
        print(f'{k}={v}')
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

        echo "  Round $round: AP=$ap(+${free_move}fm) HP=$hp/$max_hp vs $n_name($n_hp hp, dist=$n_dist) [$n_alive alive]"

        # Heal if low HP
        if [ "$max_hp" -gt 0 ]; then
            local hp_pct=$((hp * 100 / max_hp))
            if [ $hp_pct -lt $heal_pct ] && [ "$ap" -ge 2 ]; then
                echo "    Healing (HP $hp_pct%)"
                cmd "{\"type\":\"use_combat_item\",\"item_pid\":40}"
                sleep 1
                wait_tick_advance 10
                action_count=$((action_count + 1))
                consec_fail=0
                continue
            fi
        fi

        # Out of AP? End turn
        if [ "$ap" -lt 3 ] && [ "$free_move" -lt 1 ]; then
            echo "    End turn (AP=$ap)"
            cmd '{"type":"end_turn"}'
            sleep 1
            wait_tick_advance 20
            round=$((round + 1))
            consec_fail=0
            continue
        fi

        # Need to close distance? (unarmed range = 1)
        if [ "$n_dist" -gt 1 ]; then
            # If too far to reach this turn, end turn and let enemies come to us
            if [ "$n_dist" -gt $((ap + free_move + 2)) ]; then
                echo "    Too far ($n_dist hexes), ending turn"
                cmd '{"type":"end_turn"}'
                sleep 1
                wait_tick_advance 20
                round=$((round + 1))
                consec_fail=0
                continue
            fi
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
            sleep 1
            wait_tick_advance 15
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
    # Tries all exit grids matching the destination (closest first).
    # Args: $1 = destination map name (substring match) or "any"
    #       $2 = max attempts (default 6)
    # Returns 0 on successful transition, 1 on failure.
    local dest="${1:-any}" max_attempts="${2:-6}"
    local cur_map=$(field "map.name")

    echo "=== EXIT_THROUGH: looking for exit to '$dest' (current map: $cur_map) ==="

    # Get exit grid tiles sorted by distance
    local exits=$(py "
import json
exits = d.get('objects', {}).get('exit_grids', [])
dest = '$dest'
if dest != 'any':
    exits = [e for e in exits if dest.lower() in e.get('destination_map_name', '').lower()]
exits.sort(key=lambda e: e.get('distance', 999))
for e in exits:
    print(f\"{e.get('tile')} {e.get('destination_map_name', '?')}\")
")

    if [ -z "$exits" ]; then
        echo "  No exit grids found matching '$dest'"
        return 1
    fi

    local attempt=0
    while IFS=' ' read -r tile dest_name; do
        [ $attempt -ge $max_attempts ] && break
        attempt=$((attempt + 1))

        echo "  Attempt $attempt: run_to exit tile $tile -> $dest_name"
        cmd "{\"type\":\"run_to\",\"tile\":$tile}"
        sleep 0.5
        wait_idle 30

        # Check if map changed
        local new_map=$(field "map.name")
        if [ "$new_map" != "$cur_map" ]; then
            echo "=== EXIT_THROUGH: transitioned to $new_map ==="
            return 0
        fi

        # Try move_to as fallback (sometimes run_to fails where move_to works)
        echo "  Attempt $attempt (move_to): tile $tile"
        cmd "{\"type\":\"move_to\",\"tile\":$tile}"
        sleep 0.5
        wait_idle 30

        new_map=$(field "map.name")
        if [ "$new_map" != "$cur_map" ]; then
            echo "=== EXIT_THROUGH: transitioned to $new_map ==="
            return 0
        fi
    done <<< "$exits"

    echo "=== EXIT_THROUGH: FAILED after $attempt attempts (still on $cur_map) ==="
    return 1
}

# ─── Arm & Detonate ──────────────────────────────────────────────────

arm_and_detonate() {
    # Full explosive workflow as a player would do it:
    #   1. Walk adjacent to target
    #   2. Arm explosive with short timer
    #   3. Run away from blast radius
    #   4. Wait for detonation
    #   5. Report result
    #
    # Args: $1 = target object id
    #       $2 = explosive pid (85=Plastic Explosives, 51=Dynamite)
    #       $3 = safe tile to run to (should be 6+ hexes away)
    #       $4 = timer ticks (default 100 = ~10 seconds)
    local target_id="$1" explosive_pid="${2:-85}" safe_tile="$3" timer="${4:-100}"

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

    # Step 3: Arm the explosive (use_skill traps on the explosive item)
    echo "  Arming explosive (pid=$explosive_pid, timer=$timer ticks)..."
    cmd "{\"type\":\"use_item_on\",\"item_pid\":$explosive_pid,\"object_id\":$target_id}"
    sleep 1
    wait_tick_advance 10

    local dbg=$(last_debug)
    echo "  Arm result: $dbg"

    # Step 4: Run to safe distance
    echo "  Running to safe tile $safe_tile..."
    cmd "{\"type\":\"run_to\",\"tile\":$safe_tile}"
    sleep 0.5
    wait_idle 30

    # Step 5: Wait for detonation
    local wait_secs=$((timer / 10 + 5))
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
        # Check message log for explosion evidence
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

        if [ "$obj_type" = "container" ]; then
            echo "  Looting $obj_name (id=$obj_id, dist=$obj_dist)..."
            loot_all "$obj_id" && looted=$((looted + 1))
            sleep 0.5
        elif [ "$obj_type" = "ground_item" ]; then
            echo "  Picking up $obj_name (id=$obj_id, dist=$obj_dist)..."
            cmd "{\"type\":\"pick_up\",\"object_id\":$obj_id}"
            sleep 0.5
            wait_idle 20
            picked=$((picked + 1))
        fi
    done <<< "$targets"

    echo "=== EXPLORE_AREA: looted $looted containers, picked up $picked items ==="
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
kw = '$keyword'.lower()
found = [i for i in inv if kw in i.get('name', '').lower()]
if found:
    print(f'Found {len(found)} matching items:')
    for i in found:
        print(f\"  {i.get('name','?')} x{i.get('quantity',1)} pid={i.get('pid')} type={i.get('type','?')}\")
else:
    print(f'No items matching \"{keyword}\" in inventory')
"
}

# ─── Loot ─────────────────────────────────────────────────────────────

loot_all() {
    # Open container, take all, close. Args: $1 = object id
    local obj_id="$1"
    cmd "{\"type\":\"open_container\",\"object_id\":$obj_id}"
    sleep 1.5
    wait_context "gameplay_loot" 20 || return 1
    # Read what's in the container
    local items=$(py "
loot = d.get('loot', {})
items = loot.get('items', [])
for it in items:
    print(f\"  {it.get('name','?')} x{it.get('quantity',1)} (pid={it.get('pid')})\")
")
    echo "Container contents:"
    echo "$items"
    cmd '{"type":"loot_take_all"}'
    sleep 0.5
    cmd '{"type":"loot_close"}'
    sleep 0.5
    wait_context_prefix "gameplay_" 10
    echo "Looted and closed"
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

echo "executor.sh loaded. Functions:"
echo "  CORE:       cmd, cmds, send, field, context, tick, last_debug"
echo "  WAIT:       wait_idle, wait_context, wait_context_prefix, wait_tick_advance"
echo "  MOVE:       move_and_wait"
echo "  COMBAT:     do_combat [timeout_secs] [heal_pct]"
echo "  EXIT:       exit_through <dest_name|any> [max_attempts]"
echo "  EXPLOSIVE:  arm_and_detonate <target_id> [explosive_pid] <safe_tile> [timer]"
echo "  EXPLORE:    explore_area [max_dist], examine_object <id>, check_inventory_for <keyword>"
echo "  LOOT:       loot_all <id>"
echo "  INTERACT:   use_object_and_wait, use_skill_and_wait, use_item_on_and_wait, talk_and_choose"
echo "  STATE:      snapshot, objects_near, inventory_summary"
echo "  KNOWLEDGE:  game_log <text>, recall <keyword>, note <category> <text>"
