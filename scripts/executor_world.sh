# executor_world.sh — Movement, navigation, exploration, interaction, and healing
#
# Sourced by executor.sh. Depends on: cmd, py, field, context, last_debug,
# wait_idle, wait_tick_advance, wait_context, wait_context_prefix, muse,
# note, game_log, dismiss_options_menu, GAME_DIR, STATE, CMD.

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
    if [ "$hand" != "left" ] && [ "$hand" != "right" ]; then
        echo "Usage: equip_and_use <item_pid> [left|right] [timer_seconds]"
        return 1
    fi

    # 1. Equip item to specified hand
    cmd "{\"type\":\"equip_item\",\"item_pid\":$item_pid,\"hand\":\"$hand\"}"
    sleep 0.5
    wait_tick_advance 5

    # 2. Ensure that hand is active
    local current_hand=$(field "inventory.active_hand")
    [ "$current_hand" = "null" ] && current_hand=$(field "combat.active_hand")
    if [ "$current_hand" = "null" ] || [ -z "$current_hand" ]; then
        echo "WARN: couldn't read active hand; attempting use without switch"
    elif [ "$current_hand" != "$hand" ]; then
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
    # Apply a skill to an object, or self if object id omitted.
    # Args: $1 = skill name, $2 = object id (optional)
    local skill="$1" obj_id="${2:-}"
    if [ -z "$skill" ]; then
        echo "Usage: use_skill <skill> [object_id]"
        return 1
    fi
    if [ -n "$obj_id" ]; then
        _walk_to_object "$obj_id" || true
        cmd "{\"type\":\"use_skill\",\"skill\":\"$skill\",\"object_id\":$obj_id}"
    else
        cmd "{\"type\":\"use_skill\",\"skill\":\"$skill\"}"
    fi
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

heal_companion() {
    # Use a healing item on a companion/NPC by object id.
    # Usage: heal_companion <object_id> [item_pid]
    local obj_id="${1:-}" item_pid="${2:-}"
    if [ -z "$obj_id" ]; then
        echo "Usage: heal_companion <object_id> [item_pid]"
        return 1
    fi

    if [ -z "$item_pid" ]; then
        item_pid=$(py "
inv = d.get('inventory', {}).get('items', [])
for pid in (40, 81, 144):  # Stimpak, Healing Powder, Super Stimpak
    for it in inv:
        if it.get('pid') == pid and it.get('quantity', 0) > 0:
            print(pid)
            raise SystemExit(0)
for it in inv:
    name = (it.get('name') or '').lower()
    if ('stim' in name or 'healing powder' in name) and it.get('quantity', 0) > 0:
        print(it.get('pid', 0))
        raise SystemExit(0)
print(0)
")
    fi

    if [ "${item_pid:-0}" -le 0 ] 2>/dev/null; then
        echo "No companion-healing item available"
        return 1
    fi

    echo "Using item pid=$item_pid on companion id=$obj_id"
    use_item_on "$item_pid" "$obj_id"
    echo "Debug: $(last_debug)"
}

doctor_companion() {
    # Apply Doctor skill to a companion/NPC by object id.
    # Usage: doctor_companion <object_id>
    local obj_id="${1:-}"
    if [ -z "$obj_id" ]; then
        echo "Usage: doctor_companion <object_id>"
        return 1
    fi
    use_skill "doctor" "$obj_id"
    echo "Debug: $(last_debug)"
}

party_status() {
    # Compact summary of party HP/status/weapon/ammo.
    py "
party = d.get('party_members', [])
if not party:
    print('No party members')
else:
    for m in party:
        hp = m.get('hp', '?')
        max_hp = m.get('max_hp', '?')
        dead = ' DEAD' if m.get('dead') else ''
        status = ','.join(m.get('status_effects', [])) or 'ok'
        weapon = m.get('weapon', 'unarmed')
        wi = m.get('weapon_info', {})
        ammo = ''
        if isinstance(wi, dict) and wi.get('ammo_capacity', 0):
            ammo = f\" ammo={wi.get('ammo_count', 0)}/{wi.get('ammo_capacity', 0)}\"
        print(f\"{m.get('name','?')} id={m.get('id')} HP:{hp}/{max_hp}{dead} dist={m.get('distance','?')} status={status} weapon={weapon}{ammo}\")
"
}

sneak_on() {
    local sneaking=$(field "player.is_sneaking")
    if [ "$sneaking" = "true" ] || [ "$sneaking" = "True" ]; then
        echo "Sneak already ON"
        return 0
    fi
    cmd '{"type":"toggle_sneak"}'
    sleep 0.3
    wait_tick_advance 5
    echo "$(last_debug)"
}

sneak_off() {
    local sneaking=$(field "player.is_sneaking")
    if [ "$sneaking" = "false" ] || [ "$sneaking" = "False" ]; then
        echo "Sneak already OFF"
        return 0
    fi
    cmd '{"type":"toggle_sneak"}'
    sleep 0.3
    wait_tick_advance 5
    echo "$(last_debug)"
}

check_ammo() {
    # Show currently active weapon ammo and compatible inventory ammo.
    py "
inv = d.get('inventory', {})
items = inv.get('items', [])
equipped = inv.get('equipped', {})
active = inv.get('active_hand', 'right')
slot = 'right_hand' if active == 'right' else 'left_hand'
eq = equipped.get(slot) or {}
if not eq:
    print(f'No item equipped in {slot}')
    raise SystemExit(0)

pid = eq.get('pid')
name = eq.get('name', '?')
ammo_count = eq.get('ammo_count')
ammo_cap = eq.get('ammo_capacity')
ammo_name = eq.get('ammo_name', '?')
ammo_pid = eq.get('ammo_pid')

ws = None
for it in items:
    if it.get('pid') == pid and it.get('type') == 'weapon':
        ws = it.get('weapon_stats', {})
        break

if ammo_cap is None:
    print(f'Active hand: {active} | {name} (no ammo)')
    raise SystemExit(0)

caliber = ws.get('ammo_caliber') if isinstance(ws, dict) else None
print(f'Active hand: {active} | {name} ammo={ammo_count}/{ammo_cap} loaded={ammo_name} pid={ammo_pid} caliber={caliber}')

compatible = []
for it in items:
    if it.get('type') != 'ammo' or it.get('quantity', 0) <= 0:
        continue
    istat = it.get('ammo_stats', {})
    if caliber is not None and istat.get('caliber') != caliber:
        continue
    compatible.append(it)

if not compatible:
    print('Compatible ammo in inventory: none')
else:
    print('Compatible ammo in inventory:')
    compatible.sort(key=lambda it: it.get('name', ''))
    for it in compatible:
        print(f\"  {it.get('name','?')} x{it.get('quantity',0)} pid={it.get('pid')}\")
"
}

reload() {
    # Reload active weapon. Optional argument picks specific ammo PID.
    # Usage: reload [ammo_pid]
    local ammo_pid="${1:-}"
    if [ -n "$ammo_pid" ]; then
        cmd "{\"type\":\"reload_weapon\",\"ammo_pid\":$ammo_pid}"
    else
        cmd '{"type":"reload_weapon"}'
    fi
    sleep 0.5
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

# ─── Map Transition Hook ─────────────────────────────────────────────

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
