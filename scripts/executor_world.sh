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

_report_nearby_obstacles() {
    # Report nearby scenery (doors, containers) when movement stops short.
    # Args: $1=current_tile, $2=target_tile
    py "
objs = d.get('objects', {}).get('scenery', [])
nearby = [s for s in objs if s.get('distance', 999) <= 5]
nearby.sort(key=lambda s: s.get('distance', 999))
parts = []
for s in nearby:
    name = s.get('name', '?')
    sid = s.get('id', '?')
    tile = s.get('tile', '?')
    stype = s.get('scenery_type', '?')
    extra = ''
    if stype == 'door':
        extra = f' locked={s.get(\"locked\", \"?\")} open={s.get(\"open\", \"?\")}'
    elif s.get('item_count', 0) > 0:
        extra = f' items={s.get(\"item_count\")}'
    parts.append(f'{name} id={sid} tile={tile} type={stype}{extra}')
msg = f'BLOCKED at tile $1 (target $2).'
if parts:
    msg += ' Nearby: ' + '; '.join(parts)
print(msg)
"
}

move_and_wait() {
    # Unified movement function.
    #   move_and_wait <tile>              — move to a specific tile
    #   move_and_wait exit [dest_filter]  — find nearest exit grid, move to it
    #
    # Returns: 0=arrived/transitioned, 1=failed, 2=combat interrupt
    local _ds=$(_dbg_ts)

    # ── Exit mode ──
    if [ "$1" = "exit" ]; then
        local dest_filter="${2:-any}"
        _dbg_start "move_and_wait" "exit $dest_filter"
        local cur_map=$(field "map.name")
        local cur_elev=$(field "map.elevation")

        echo "=== MOVE EXIT: looking for exit to '$dest_filter' (current: $cur_map elev=$cur_elev) ==="

        # Get exit grids sorted by distance
        local exits=$(py "
exits = d.get('objects', {}).get('exit_grids', [])
dest = '''$dest_filter'''
if dest != 'any':
    exits = [e for e in exits if dest.lower() in e.get('destination_map_name', '').lower()]
exits.sort(key=lambda e: e.get('distance', 999))
for e in exits:
    print(f\"{e.get('tile')}\t{e.get('destination_map_name', '?')}\t{e.get('distance', 999)}\")
")

        if [ -z "$exits" ]; then
            echo "  No exit grids found matching '$dest_filter'"
            _dbg_end "move_and_wait" "no_exits" "$_ds"
            return 1
        fi

        local attempt=0
        while IFS=$'\t' read -r exit_tile dest_name dist; do
            [ $attempt -ge 5 ] && break
            attempt=$((attempt + 1))

            echo "  Attempt $attempt: exit tile $exit_tile -> $dest_name (dist=$dist)"

            # Use tile-mode movement (recursive call)
            move_and_wait "$exit_tile"
            local result=$?

            # Check if map changed
            local new_map=$(field "map.name")
            local new_elev=$(field "map.elevation")
            if [ "$new_map" != "$cur_map" ] || [ "$new_elev" != "$cur_elev" ]; then
                echo "=== MOVE EXIT: transitioned to $new_map elev=$new_elev ==="
                _end_status
                _dbg_end "move_and_wait" "exit_ok" "$_ds"
                return 0
            fi

            if [ $result -eq 2 ]; then
                _dbg_end "move_and_wait" "exit_combat" "$_ds"
                return 2
            fi

            [ $result -ne 0 ] && echo "  Exit tile $exit_tile: failed, trying next..."
        done <<< "$exits"

        echo "=== MOVE EXIT: FAILED after $attempt attempts (still on $cur_map) ==="
        _dbg_end "move_and_wait" "exit_fail" "$_ds"
        return 1
    fi

    # ── Tile mode ──
    local tile="$1"
    _dbg_start "move_and_wait" "$tile"
    local start_map=$(field "map.name")
    local start_elev=$(field "map.elevation")
    local cur_tile=$(field "player.tile")

    if [ "$cur_tile" = "$tile" ]; then
        echo "Already at tile $tile"
        _dbg_end "move_and_wait" "already_there" "$_ds"
        return 0
    fi

    # Issue the move command — engine handles full A* pathfinding + waypoint segmentation
    cmd "{\"type\":\"run_to\",\"tile\":$tile}"
    sleep 0.3

    # Check immediate failure
    local dbg=$(last_debug)
    if [[ "$dbg" == *"no path"* ]]; then
        echo "No path to tile $tile: $dbg"
        _report_nearby_obstacles "$cur_tile" "$tile"
        _dbg_end "move_and_wait" "no_path" "$_ds"
        return 1
    fi

    # Poll loop: max 60s (120 x 0.5s)
    local last_tile="$cur_tile"
    local stuck_count=0
    local max_wait=120

    for i in $(seq 1 $max_wait); do
        # Check for map transition (exit grids)
        local cur_map=$(field "map.name")
        local cur_elev=$(field "map.elevation")
        if [ "$cur_map" != "$start_map" ] || [ "$cur_elev" != "$start_elev" ]; then
            echo "MAP TRANSITION: $start_map elev=$start_elev -> $cur_map elev=$cur_elev (tile $(field 'player.tile'))"
            post_transition_hook
            _dbg_end "move_and_wait" "transition" "$_ds"
            return 0
        fi

        # Check for combat interrupt
        local ctx=$(context)
        if [[ "$ctx" == gameplay_combat* ]]; then
            cur_tile=$(field "player.tile")
            echo "COMBAT INTERRUPT at tile $cur_tile (target was $tile)"
            _dbg_end "move_and_wait" "combat" "$_ds"
            return 2
        fi

        # Check if we've arrived
        cur_tile=$(field "player.tile")
        if [ "$cur_tile" = "$tile" ]; then
            echo "Arrived at tile $tile"
            _end_status
            _dbg_end "move_and_wait" "ok" "$_ds"
            return 0
        fi

        # Check if movement stopped (not busy + no waypoints remaining)
        local busy=$(field "player.animation_busy")
        local remaining=$(field "player.movement_waypoints_remaining")
        if [ "$busy" = "false" ] && { [ "$remaining" = "null" ] || [ "$remaining" = "0" ]; }; then
            # Movement done but not at target — blocked
            _report_nearby_obstacles "$cur_tile" "$tile"
            _dbg_end "move_and_wait" "blocked" "$_ds"
            return 1
        fi

        # Stuck detection: same tile for 10s (20 x 0.5s)
        if [ "$cur_tile" = "$last_tile" ]; then
            stuck_count=$((stuck_count + 1))
            if [ $stuck_count -ge 20 ]; then
                echo "STUCK at tile $cur_tile for 10s (target $tile)"
                _report_nearby_obstacles "$cur_tile" "$tile"
                _dbg_end "move_and_wait" "stuck" "$_ds"
                return 1
            fi
        else
            stuck_count=0
            last_tile="$cur_tile"
        fi

        sleep 0.5
    done

    echo "TIMEOUT (60s) at tile $(field 'player.tile') (target $tile)"
    _dbg_end "move_and_wait" "timeout" "$_ds"
    return 1
}

# ─── Equip & Use ─────────────────────────────────────────────────────

equip_and_use() {
    local _ds=$(_dbg_ts)
    _dbg_start "equip_and_use" "$*"
    if [ -z "$1" ]; then
        echo "Usage: equip_and_use <item_pid> [hand] [timer_seconds]"
        _dbg_end "equip_and_use" "bad_args" "$_ds"
        return 1
    fi
    local item_pid="$1" hand="${2:-right}" timer_seconds="${3:-}"
    if [ "$hand" != "left" ] && [ "$hand" != "right" ]; then
        echo "Usage: equip_and_use <item_pid> [left|right] [timer_seconds]"
        _dbg_end "equip_and_use" "bad_args" "$_ds"
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
    _end_status
    _dbg_end "equip_and_use" "ok" "$_ds"
}

# ─── Exploration ─────────────────────────────────────────────────────

explore_area() {
    local _ds=$(_dbg_ts)
    _dbg_start "explore_area" "${1:-25}"
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
        _dbg_end "explore_area" "empty" "$_ds"
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
            cmd "{\"type\":\"pick_up\",\"object_id\":$obj_id}"
            sleep 0.5
            wait_idle 20
            picked=$((picked + 1))
        fi
    done <<< "$targets"

    echo "=== EXPLORE_AREA: looted $looted containers, picked up $picked items ==="
    _end_status
    if [ $((looted + picked)) -gt 0 ]; then
        local _loot_quips=("Not bad. Not bad at all." "The wasteland provides." "Shopping spree complete." "Every bit counts out here.")
        muse "${_loot_quips[$((RANDOM % ${#_loot_quips[@]}))]}"
        sleep 1
    else
        muse "Nothing worth taking. Disappointing."
        sleep 1
    fi
    _dbg_end "explore_area" "ok" "$_ds"
}

# ─── Interaction ──────────────────────────────────────────────────────

examine() {
    local _ds=$(_dbg_ts)
    _dbg_start "examine" "$1"
    local obj_id="$1"

    _walk_to_object "$obj_id" || true
    cmd "{\"type\":\"look_at\",\"object_id\":$obj_id}"
    sleep 1
    wait_tick_advance 10

    # Prefer bridge-captured look_at_result (engine examine callback output).
    local result=$(field "look_at_result")
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        result=$(py "
msgs = d.get('message_log', [])
if msgs:
    for m in msgs[-3:]:
        print(m)
")
    fi
    local dbg=$(last_debug)
    echo "Examine result: $result"
    echo "Debug: $dbg"
    _dbg_end "examine" "ok" "$_ds"
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
    local _ds=$(_dbg_ts)
    _dbg_start "interact" "$1"
    local obj_id="$1"
    cmd "{\"type\":\"use_object\",\"object_id\":$obj_id}"
    sleep 1
    wait_idle
    _end_status
    _dbg_end "interact" "ok" "$_ds"
}

use_skill() {
    local _ds=$(_dbg_ts)
    _dbg_start "use_skill" "$1 ${2:-}"
    local skill="$1" obj_id="${2:-}"
    if [ -z "$skill" ]; then
        echo "Usage: use_skill <skill> [object_id]"
        _dbg_end "use_skill" "bad_args" "$_ds"
        return 1
    fi
    if [ -n "$obj_id" ]; then
        cmd "{\"type\":\"use_skill\",\"skill\":\"$skill\",\"object_id\":$obj_id}"
    else
        cmd "{\"type\":\"use_skill\",\"skill\":\"$skill\"}"
    fi
    sleep 1.5
    wait_idle
    _end_status
    _dbg_end "use_skill" "ok" "$_ds"
}

use_item_on() {
    local _ds=$(_dbg_ts)
    _dbg_start "use_item_on" "$1 $2"
    local item_pid="$1" obj_id="$2"
    cmd "{\"type\":\"use_item_on\",\"item_pid\":$item_pid,\"object_id\":$obj_id}"
    sleep 1.5
    wait_idle
    _end_status
    _dbg_end "use_item_on" "ok" "$_ds"
}

# ─── Loot ─────────────────────────────────────────────────────────────

loot() {
    local _ds=$(_dbg_ts)
    _dbg_start "loot" "$1"
    local obj_id="$1"

    # Snapshot inventory BEFORE looting
    local inv_before=$(py "
inv = d.get('inventory', {}).get('items', [])
print(','.join(f\"{i['pid']}:{i.get('quantity',1)}\" for i in inv))
")

    cmd "{\"type\":\"open_container\",\"object_id\":$obj_id}"
    sleep 1.5
    if ! wait_context "gameplay_loot" 20; then
        _dbg_end "loot" "no_loot_ctx" "$_ds"
        return 1
    fi

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
    _end_status
    _dbg_end "loot" "ok" "$_ds"
}

# ─── Healing ─────────────────────────────────────────────────────────

heal_to_full() {
    local _ds=$(_dbg_ts)
    _dbg_start "heal_to_full" ""
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
            _end_status
            _dbg_end "heal_to_full" "ok" "$_ds"
            return 0
        fi
        if [ "$heal_pid" = "0" ] || [ -z "$heal_name" ]; then
            echo "No healing items (HP $hp/$max_hp)"
            _dbg_end "heal_to_full" "no_items" "$_ds"
            return 1
        fi

        echo "Using $heal_name (HP $hp/$max_hp)"
        cmd "{\"type\":\"use_item\",\"item_pid\":$heal_pid}"
        sleep 1
        wait_tick_advance 5
        i=$((i + 1))
    done
    echo "Heal loop limit reached"
    _dbg_end "heal_to_full" "limit" "$_ds"
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

# ─── Engine-native wrappers ──────────────────────────────────────────

rest() {
    # Rest in-place for N hours (1..24). Engine handles interruptions.
    local hours="${1:-1}"
    cmd "{\"type\":\"rest\",\"hours\":$hours}"
    sleep 0.5
    wait_tick_advance 30 || true
    echo "$(last_debug)"
    _end_status
}

worldmap_travel() {
    # Start worldmap walking to area id.
    local area_id="${1:?Usage: worldmap_travel <area_id>}"
    cmd "{\"type\":\"worldmap_travel\",\"area_id\":$area_id}"
    sleep 0.3
    wait_tick_advance 10 || true
    echo "$(last_debug)"
}

worldmap_enter_location() {
    # Enter area by id and optional entrance index.
    local area_id="${1:?Usage: worldmap_enter_location <area_id> [entrance]}"
    local entrance="${2:-0}"
    cmd "{\"type\":\"worldmap_enter_location\",\"area_id\":$area_id,\"entrance\":$entrance}"
    sleep 0.3
    wait_tick_advance 10 || true
    echo "$(last_debug)"
}

worldmap_wait() {
    # Wait until worldmap walking completes or context changes.
    local timeout="${1:-300}"
    local i=0
    while [ $i -lt "$timeout" ]; do
        local ctx=$(context)
        if [[ "$ctx" != gameplay_worldmap* ]]; then
            echo "Context changed to $ctx"
            _end_status
            return 0
        fi
        local walking=$(field "worldmap.is_walking")
        if [ "$walking" != "true" ] && [ "$walking" != "True" ]; then
            echo "Worldmap walking complete"
            _end_status
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "WARN: worldmap_wait timeout (${timeout}s)"
    return 1
}

find_path() {
    # Query path existence/length and waypoint list.
    local to_tile="${1:?Usage: find_path <to_tile> [from_tile]}"
    local from_tile="${2:-}"
    if [ -n "$from_tile" ]; then
        cmd "{\"type\":\"find_path\",\"from\":$from_tile,\"to\":$to_tile}"
    else
        cmd "{\"type\":\"find_path\",\"to\":$to_tile}"
    fi
    sleep 0.2
    wait_tick_advance 5 || true
    py "
q = d.get('query_result', {})
if not isinstance(q, dict) or q.get('type') != 'find_path':
    print('No find_path query result; debug: ' + str(d.get('last_command_debug', 'none')))
else:
    if q.get('path_exists'):
        print(f\"Path exists: len={q.get('path_length', '?')} waypoints={q.get('waypoints', [])}\")
    else:
        print(f\"No path (len={q.get('path_length', 0)})\")
"
}

tile_objects() {
    # Query objects around a tile.
    local tile="${1:?Usage: tile_objects <tile> [radius]}"
    local radius="${2:-2}"
    cmd "{\"type\":\"tile_objects\",\"tile\":$tile,\"radius\":$radius}"
    sleep 0.2
    wait_tick_advance 5 || true
    py "
q = d.get('query_result', {})
if not isinstance(q, dict) or q.get('type') != 'tile_objects':
    print('No tile_objects query result; debug: ' + str(d.get('last_command_debug', 'none')))
else:
    objs = q.get('objects', [])
    if not objs:
        print('No objects found')
    else:
        for o in objs:
            print(f\"{o.get('type','?')} id={o.get('id')} pid={o.get('pid')} tile={o.get('tile')} dist={o.get('distance')} name={o.get('name','?')}\")
"
}

find_item() {
    # Query item PID matches on map/inventory/containers.
    local pid="${1:?Usage: find_item <pid>}"
    cmd "{\"type\":\"find_item\",\"pid\":$pid}"
    sleep 0.2
    wait_tick_advance 5 || true
    py "
q = d.get('query_result', {})
if not isinstance(q, dict) or q.get('type') != 'find_item':
    print('No find_item query result; debug: ' + str(d.get('last_command_debug', 'none')))
else:
    matches = q.get('matches', [])
    print(f\"Matches: {q.get('match_count', 0)}\")
    for m in matches:
        print(m)
"
}

list_all_items() {
    # Query sampled world/container items on current elevation.
    cmd '{"type":"list_all_items"}'
    sleep 0.2
    wait_tick_advance 5 || true
    py "
q = d.get('query_result', {})
if not isinstance(q, dict) or q.get('type') != 'list_all_items':
    print('No list_all_items query result; debug: ' + str(d.get('last_command_debug', 'none')))
else:
    print(f\"Entries: {q.get('entry_count', 0)}\")
    for e in q.get('entries', []):
        print(e)
"
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
