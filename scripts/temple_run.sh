#!/usr/bin/env bash
# Temple of Trials — Full Autonomous Playthrough
# Creates a character and navigates through the Temple of Trials legitimately:
#   ARTEMPLE → ARCAVES (elev 0: ants + locked door)
#              → ARCAVES (elev 1: find explosives, blow sealed door)
#              → ARCAVES (elev 2: Cameron dialogue/fight)
#              → Exit (vault suit movie → ARVILLAG)
#
# Usage: ./scripts/temple_run.sh
#        Game must be running with AGENT_BRIDGE=ON.

set -uo pipefail

GAME_DIR="$(cd "$(dirname "$0")/../game" && pwd)"
STATE_FILE="$GAME_DIR/agent_state.json"
CMD_FILE="$GAME_DIR/agent_cmd.json"
CMD_TMP="$GAME_DIR/agent_cmd.tmp"

# Ensure game window has focus (needed for SDL event processing)
ensure_focus() {
    osascript -e 'tell application "Fallout II Community Edition" to activate' 2>/dev/null || true
}

# ─── Core Helpers ───────────────────────────────────────────────────

send_cmd() {
    echo "$1" > "$CMD_TMP"
    mv "$CMD_TMP" "$CMD_FILE"
}

cmd() {
    # Send single command: cmd '{"type":"foo",...}'
    send_cmd "{\"commands\":[$1]}"
}

py() {
    # Run Python snippet with state loaded as 'd'
    python3 -c "
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
$1
" 2>/dev/null
}

field() {
    py "
keys = '$1'.split('.')
val = d
for k in keys:
    if isinstance(val, list):
        val = val[int(k)]
    else:
        val = val.get(k, 'MISSING')
if isinstance(val, (dict, list)):
    import json as j
    print(j.dumps(val))
else:
    print(val)
"
}

ctx()  { field "context"; }
tick() { field "tick"; }
tile() { field "player.tile"; }
elev() { field "map.elevation"; }
mmap() { field "map.name"; }

wait_ctx() {
    local target="$1" timeout="${2:-30}" elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local c=$(ctx)
        if [[ "$c" == $target* ]]; then return 0; fi
        sleep 0.5; elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT waiting for $target (at $(ctx))" >&2; return 1
}

wait_idle() {
    local timeout="${1:-20}" elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local busy=$(field "player.animation_busy" 2>/dev/null || echo "true")
        local wp=$(field "player.movement_waypoints_remaining" 2>/dev/null || echo "0")
        if [[ "$busy" == [Ff]alse ]] && [ "${wp:-0}" = "0" ]; then return 0; fi
        sleep 0.3; elapsed=$((elapsed + 1))
    done
}

skip_movies() {
    local n=0
    while [ "$(ctx)" = "movie" ] && [ $n -lt 20 ]; do
        cmd '{"type":"skip"}'
        sleep 1; n=$((n + 1))
    done
}

dismiss_options() {
    local gm=$(field "game_mode" 2>/dev/null || echo "0")
    if [ "$gm" = "8" ] || [ "$gm" = "24" ]; then
        cmd '{"type":"key_press","key":"escape"}'
        sleep 1
    fi
}

# ─── Movement & Interaction ─────────────────────────────────────────

goto() {
    # Move to tile, wait for arrival
    local t=$1 mode="${2:-run_to}"
    echo "  → $mode to tile $t"
    cmd "{\"type\":\"$mode\",\"tile\":$t}"
    sleep 0.5
    wait_idle 25
    sleep 0.3
}

interact() {
    local id=$1
    echo "  → use_object $id"
    cmd "{\"type\":\"use_object\",\"object_id\":$id}"
    sleep 1.5
    wait_idle 10
}

lockpick() {
    local id=$1
    echo "  → lockpick $id"
    cmd "{\"type\":\"use_skill\",\"skill\":\"lockpick\",\"object_id\":$id}"
    sleep 2
    wait_idle 10
    echo "    $(field last_command_debug)"
}

# Navigate to a target tile, handling doors and combat along the way
navigate_to() {
    local target=$1 max_attempts=${2:-20}
    local attempt=0 no_door_retries=0
    echo "  Navigating to tile $target..."

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))

        # Check for combat first
        local c=$(ctx)
        if [[ "$c" == *combat* ]]; then combat_loop; sleep 1; fi

        # Check elevation change (may have transitioned via exit grid)
        local cur_elev=$(elev)
        local cur_map=$(mmap)

        local cur=$(tile)
        if [ "$cur" = "$target" ]; then echo "  Arrived at tile $target"; return 0; fi

        # Try direct movement
        goto $target
        sleep 0.5
        local after=$(tile)

        # Check for map/elev change (exit grid triggered)
        local new_elev=$(elev)
        local new_map=$(mmap)
        if [ "$new_elev" != "$cur_elev" ] || [ "$new_map" != "$cur_map" ]; then
            echo "  → Map=$new_map Elev=$new_elev Tile=$after"
            return 0
        fi

        # Did we move?
        if [ "$after" != "$cur" ]; then
            # Check if we arrived or triggered combat
            c=$(ctx)
            if [[ "$c" == *combat* ]]; then combat_loop; sleep 1; fi
            if [ "$(tile)" = "$target" ]; then echo "  Arrived at tile $target"; return 0; fi
            no_door_retries=0  # reset since we made progress
            continue
        fi

        # Didn't move — probably blocked by a door or obstacle
        echo "  Blocked at tile $cur (attempt $attempt)"

        # Find nearest closed door
        local door_info=$(py "
import json
doors = []
for s in d.get('objects',{}).get('scenery',[]):
    if s.get('scenery_type') == 'door' and not s.get('open'):
        doors.append(s)
if doors:
    doors.sort(key=lambda x: x['distance'])
    d0 = doors[0]
    print(json.dumps(d0))
")
        if [ -z "$door_info" ] || [ "$door_info" = "" ]; then
            no_door_retries=$((no_door_retries + 1))
            if [ $no_door_retries -ge 3 ]; then
                echo "  No closed doors found — cannot navigate further"
                return 1
            fi
            echo "  No doors, retrying ($no_door_retries/3)..."
            sleep 2
            continue
        fi

        no_door_retries=0
        local did=$(echo "$door_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        local dtile=$(echo "$door_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['tile'])")
        local dlocked=$(echo "$door_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('locked') else 'no')")
        local ddist=$(echo "$door_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['distance'])")
        local dname=$(echo "$door_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
        echo "  Door: $dname tile=$dtile d=$ddist locked=$dlocked"

        # Move close to door if needed
        if [ "$ddist" -gt 3 ] 2>/dev/null; then
            goto $dtile
            sleep 0.5
            c=$(ctx)
            if [[ "$c" == *combat* ]]; then combat_loop; sleep 1; fi
        fi

        # Wait for movement animation to finish
        sleep 1.5

        # Lockpick if locked
        if [ "$dlocked" = "yes" ]; then
            local lp_attempt=0
            while [ $lp_attempt -lt 5 ]; do
                lockpick $did
                sleep 2
                local still_locked=$(py "
for s in d.get('objects',{}).get('scenery',[]):
    if str(s.get('id','')) == '$did' or s.get('tile') == $dtile:
        if s.get('scenery_type') == 'door':
            print('yes' if s.get('locked') else 'no'); exit()
print('unknown')
")
                if [ "$still_locked" != "yes" ]; then break; fi
                lp_attempt=$((lp_attempt + 1))
                echo "  Lockpick attempt $lp_attempt failed, retrying..."
                sleep 2
            done
        fi

        # Open the door
        interact $did
        sleep 1.5
    done

    echo "  Could not reach tile $target after $max_attempts attempts"
    return 1
}

# Try to explore toward a target tile by walking to intermediate tiles
explore_toward() {
    local target=$1 max_steps=${2:-10}
    local step=0
    echo "  Exploring toward tile $target..."

    while [ $step -lt $max_steps ]; do
        step=$((step + 1))
        local cur=$(tile)

        # Check combat
        local c=$(ctx)
        if [[ "$c" == *combat* ]]; then combat_loop; sleep 1; fi

        # Try to find walkable neighbors heading toward target
        # Use the engine's tile system — try running to scenery/critter tiles
        # that are closer to the target than we are
        local next_tile=$(py "
import math
cur = d['player']['tile']
target = $target
# Row/col from tile (200 tiles per row)
def tile_rc(t):
    return (t // 200, t % 200)
cr, cc = tile_rc(cur)
tr, tc = tile_rc(target)

# Try all scenery and critter tiles — find one that's closer to target
candidates = []
for s in d.get('objects',{}).get('scenery',[]):
    sr, sc = tile_rc(s['tile'])
    cur_dist = math.sqrt((cr-tr)**2 + (cc-tc)**2)
    new_dist = math.sqrt((sr-tr)**2 + (sc-tc)**2)
    if new_dist < cur_dist and s['distance'] < 60:
        candidates.append((new_dist, s['tile']))

# Also check exit grids in the target direction
for g in d.get('objects',{}).get('exit_grids',[]):
    gr, gc = tile_rc(g['tile'])
    cur_dist = math.sqrt((cr-tr)**2 + (cc-tc)**2)
    new_dist = math.sqrt((gr-tr)**2 + (gc-tc)**2)
    if new_dist < cur_dist:
        candidates.append((new_dist, g['tile']))

if candidates:
    candidates.sort()
    print(candidates[0][1])
else:
    print(-1)
")
        if [ "$next_tile" = "-1" ] || [ -z "$next_tile" ]; then
            echo "  No intermediate tiles found"
            return 1
        fi

        echo "  Step $step: moving to tile $next_tile"
        goto $next_tile
        sleep 0.5

        # Check if we got closer
        local new=$(tile)
        if [ "$new" = "$cur" ]; then
            echo "  Stuck at tile $cur"
            return 1
        fi
    done
}

# ─── Survey ─────────────────────────────────────────────────────────

survey() {
    py "
print(f'  Map={d[\"map\"][\"name\"]} Elev={d[\"map\"][\"elevation\"]} Tile={d[\"player\"][\"tile\"]}')
cs = d.get('character',{}).get('derived_stats',{})
print(f'  HP={cs.get(\"current_hp\",\"?\")}/{cs.get(\"max_hp\",\"?\")}')

crits = [c for c in d.get('objects',{}).get('critters',[]) if not c.get('dead')]
if crits:
    print(f'  Critters ({len(crits)}):')
    for c in sorted(crits, key=lambda x:x['distance'])[:8]:
        flags = []
        if c.get('hostile'): flags.append('HOSTILE')
        if c.get('enemy_team'): flags.append('enemy')
        if c.get('is_party_member'): flags.append('party')
        print(f'    {c[\"name\"]:18s} d={c[\"distance\"]:2d} hp={c.get(\"hp\",\"?\")}/{c.get(\"max_hp\",\"?\")} tile={c[\"tile\"]} id={c[\"id\"]} {\" \".join(flags)}')

scen = d.get('objects',{}).get('scenery',[])
if scen:
    print(f'  Scenery ({len(scen)}):')
    for s in sorted(scen, key=lambda x:x['distance']):
        extras = []
        if s.get('locked'): extras.append('LOCKED')
        if s.get('open'): extras.append('open')
        if s.get('item_count',0)>0: extras.append(f'items={s[\"item_count\"]}')
        print(f'    {s[\"name\"]:18s} d={s[\"distance\"]:2d} type={s.get(\"scenery_type\",\"?\")} tile={s[\"tile\"]} id={s[\"id\"]} {\" \".join(extras)}')

items = d.get('objects',{}).get('ground_items',[])
if items:
    print(f'  Ground items ({len(items)}):')
    for i in sorted(items, key=lambda x:x['distance'])[:10]:
        print(f'    {i[\"name\"]:18s} d={i[\"distance\"]:2d} pid={i[\"pid\"]} tile={i[\"tile\"]} id={i[\"id\"]}')

grids = d.get('objects',{}).get('exit_grids',[])
if grids:
    print(f'  Exit grids ({len(grids)}):')
    for g in sorted(grids, key=lambda x:x['distance'])[:8]:
        nm = g.get('destination_map_name', str(g.get('destination_map','?')))
        print(f'    tile={g[\"tile\"]} d={g[\"distance\"]:2d} → {nm} elev={g.get(\"destination_elevation\",\"?\")}')
"
}

# ─── Combat Loop ────────────────────────────────────────────────────

combat_loop() {
    echo "  ⚔ COMBAT"
    local rounds=0 max=80 prev_dist=999 stuck_count=0
    while [ $rounds -lt $max ]; do
        local c=$(ctx)
        if [[ "$c" != *combat* ]]; then echo "  ⚔ Combat ended ($rounds rounds)"; return 0; fi
        if [ "$c" = "gameplay_combat_wait" ]; then sleep 0.5; rounds=$((rounds+1)); continue; fi
        if [ "$c" != "gameplay_combat" ]; then sleep 0.5; rounds=$((rounds+1)); continue; fi

        # Get combat state (ap, target info, weapon ap cost)
        local info=$(py "
c = d.get('combat', {})
ap = c.get('current_ap', 0)
hostiles = sorted(c.get('hostiles', []), key=lambda x: x['distance'])
h = hostiles[0] if hostiles else None
hp = d.get('character',{}).get('derived_stats',{}).get('current_hp','?')
# Get weapon AP cost (primary attack)
weap = c.get('active_weapon', {})
atk_cost = 3  # fallback: unarmed punch cost
if weap:
    prim = weap.get('primary', {})
    if prim:
        atk_cost = prim.get('ap_cost', 3)
if h:
    print(f'{ap}|{h[\"id\"]}|{h[\"distance\"]}|{h.get(\"hp\",\"?\")}|{h[\"name\"]}|{hp}|{h[\"tile\"]}|{atk_cost}')
else:
    print(f'{ap}|0|99|0|none|{hp}|0|{atk_cost}')
")
        IFS='|' read -r ap tid tdist thp tname php ttile atk_cost <<< "$info"
        echo "  ⚔ R$rounds: AP=$ap HP=$php vs $tname(hp=$thp d=$tdist) [cost=$atk_cost]"

        if [ "$tname" = "none" ]; then
            echo "    No hostiles — end turn"
            cmd '{"type":"end_turn"}'; sleep 1.5; rounds=$((rounds+1)); prev_dist=999; stuck_count=0; continue
        fi

        if [ "${ap:-0}" -le 0 ] 2>/dev/null; then
            echo "    No AP — end turn"
            cmd '{"type":"end_turn"}'; sleep 1.5; rounds=$((rounds+1)); prev_dist=999; stuck_count=0; continue
        fi

        # Move closer if needed (melee range = ~2)
        if [ "$tdist" -gt 2 ] 2>/dev/null; then
            # Check if we're making progress toward the target
            if [ "$tdist" -ge "$prev_dist" ] 2>/dev/null; then
                stuck_count=$((stuck_count + 1))
            else
                stuck_count=0
            fi
            prev_dist="$tdist"

            if [ "$stuck_count" -ge 2 ]; then
                echo "    Can't close distance ($tdist >= $prev_dist) — end turn"
                cmd '{"type":"end_turn"}'; sleep 1.5; rounds=$((rounds+1)); stuck_count=0; continue
            fi

            echo "    Moving closer..."
            cmd "{\"type\":\"combat_move\",\"tile\":$ttile}"
            sleep 1.5; rounds=$((rounds+1)); continue
        fi

        # In range — reset tracking
        prev_dist=999; stuck_count=0

        # Check if we have enough AP to attack
        if [ "${ap:-0}" -lt "${atk_cost:-3}" ] 2>/dev/null; then
            echo "    Not enough AP ($ap < $atk_cost) — end turn"
            cmd '{"type":"end_turn"}'; sleep 1.5; rounds=$((rounds+1)); continue
        fi

        # Attack
        cmd "{\"type\":\"attack\",\"target_id\":$tid,\"hit_mode\":\"primary\",\"hit_location\":\"uncalled\"}"
        sleep 1.5
        rounds=$((rounds+1))
    done
    echo "  ⚔ Max rounds hit"
}

# ─── Loot all containers in view ────────────────────────────────────

loot_containers() {
    local containers=$(py "
import json
scen = d.get('objects',{}).get('scenery',[])
for s in scen:
    if s.get('item_count',0) > 0:
        print(json.dumps(s))
")
    if [ -z "$containers" ]; then return; fi
    while IFS= read -r cont; do
        local cid=$(echo "$cont" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        local cname=$(echo "$cont" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
        local ctile=$(echo "$cont" | python3 -c "import json,sys; print(json.load(sys.stdin)['tile'])")
        local cdist=$(echo "$cont" | python3 -c "import json,sys; print(json.load(sys.stdin)['distance'])")
        echo "  📦 $cname at tile $ctile (d=$cdist)"
        if [ "$cdist" -gt 1 ] 2>/dev/null; then goto $ctile; fi
        cmd "{\"type\":\"open_container\",\"object_id\":$cid}"
        sleep 1.5
        if [ "$(ctx)" = "gameplay_loot" ]; then
            py "
for i in d.get('loot',{}).get('container_items',[]):
    print(f'    {i[\"name\"]} pid={i[\"pid\"]} qty={i.get(\"quantity\",1)}')
"
            cmd '{"type":"loot_take_all"}'
            sleep 0.5
            cmd '{"type":"loot_close"}'
            sleep 0.5
        fi
    done <<< "$containers"
}

# ─── Pick up ground items ───────────────────────────────────────────

pickup_items() {
    local items=$(py "
import json
for i in d.get('objects',{}).get('ground_items',[]):
    if i.get('distance',99) <= 25:
        print(json.dumps(i))
")
    if [ -z "$items" ]; then return; fi
    while IFS= read -r item; do
        local iid=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        local iname=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
        local itile=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['tile'])")
        echo "  ⬆ Picking up $iname (tile $itile)"
        cmd "{\"type\":\"pick_up\",\"object_id\":$iid}"
        sleep 1.5
        wait_idle 10
    done <<< "$items"
}

# ─── Open/unlock doors ──────────────────────────────────────────────

handle_doors() {
    local doors=$(py "
import json
for s in d.get('objects',{}).get('scenery',[]):
    if s.get('scenery_type') == 'door':
        print(json.dumps(s))
")
    if [ -z "$doors" ]; then return; fi
    while IFS= read -r door; do
        local did=$(echo "$door" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        local dtile=$(echo "$door" | python3 -c "import json,sys; print(json.load(sys.stdin)['tile'])")
        local dlocked=$(echo "$door" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('locked') else 'no')")
        local dopen=$(echo "$door" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('open') else 'no')")
        local ddist=$(echo "$door" | python3 -c "import json,sys; print(json.load(sys.stdin)['distance'])")

        if [ "$dopen" = "yes" ]; then continue; fi  # Already open
        echo "  🚪 Door tile=$dtile d=$ddist locked=$dlocked"

        # Move close if needed
        if [ "$ddist" -gt 3 ] 2>/dev/null; then goto $dtile; fi

        if [ "$dlocked" = "yes" ]; then
            lockpick $did
            sleep 0.5
        fi

        interact $did
        sleep 0.5
    done <<< "$doors"
}

# ─── Check if we have item by PID ──────────────────────────────────

has_pid() {
    py "
for i in d.get('inventory',{}).get('items',[]):
    if i.get('pid') == $1:
        print('yes'); exit()
print('no')
"
}

# ─── Find exit grid going forward (by name filter or elevation) ─────

exit_grid_tile() {
    # Usage: exit_grid_tile <target_elev> [name_contains] [name_excludes]
    # e.g.: exit_grid_tile 1 "Hallway" "Entrance"
    local target_elev="${1:--1}"
    local name_contains="${2:-}"
    local name_excludes="${3:-Entrance}"
    py "
grids = d.get('objects',{}).get('exit_grids',[])
name_contains = '$name_contains'.lower()
name_excludes = '$name_excludes'.lower()

# First: filter by name match (if specified) and elevation
for g in sorted(grids, key=lambda x:x['distance']):
    dest_name = g.get('destination_map_name','').lower()
    if name_excludes and name_excludes in dest_name:
        continue
    if name_contains and name_contains not in dest_name:
        continue
    if $target_elev >= 0 and g.get('destination_elevation') != $target_elev:
        continue
    print(g['tile']); exit()

# Second: filter by elevation only, still excluding backward exits
for g in sorted(grids, key=lambda x:x['distance']):
    dest_name = g.get('destination_map_name','').lower()
    if name_excludes and name_excludes in dest_name:
        continue
    if $target_elev >= 0 and g.get('destination_elevation') != $target_elev:
        continue
    print(g['tile']); exit()

# Third: any forward-looking grid (not Entrance)
for g in sorted(grids, key=lambda x:x['distance']):
    dest_name = g.get('destination_map_name','').lower()
    if name_excludes and name_excludes in dest_name:
        continue
    if g.get('destination_map',-1) >= 0:
        print(g['tile']); exit()

print(-1)
"
}

# ═══════════════════════════════════════════════════════════════════
# MAIN SCRIPT
# ═══════════════════════════════════════════════════════════════════

echo "╔══════════════════════════════════════════════╗"
echo "║  TEMPLE OF TRIALS — Autonomous Playthrough  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ─── Phase 0: Game ready ────────────────────────────────────────────
echo "═══ Phase 0: Game Ready ═══"
if [ ! -f "$STATE_FILE" ]; then
    echo "  Launching game..."
    cd "$GAME_DIR" && open "Fallout II Community Edition.app"
    for i in $(seq 1 30); do [ -f "$STATE_FILE" ] && break; sleep 1; done
fi
[ -f "$STATE_FILE" ] || { echo "FAIL: No state file"; exit 1; }
echo "  tick=$(tick) ctx=$(ctx)"
echo ""

# ─── Phase 1: New Game → Character Selector ─────────────────────────
ensure_focus
sleep 1
echo "═══ Phase 1: New Game ═══"
skip_movies
C=$(ctx)
case "$C" in
    character_selector) echo "  Already at char selector" ;;
    main_menu)
        echo "  Starting new game..."
        cmd '{"type":"main_menu","action":"new_game"}'
        wait_ctx "character_selector" 15
        ;;
    gameplay*)
        echo "  Already in gameplay — checking if at temple..."
        ;;
    *)
        cmd '{"type":"main_menu","action":"new_game"}'
        wait_ctx "character_selector" 15
        ;;
esac
echo ""

# ─── Phase 2: Take premade character ────────────────────────────────
echo "═══ Phase 2: Take Premade (Narg) ═══"
C=$(ctx)
if [ "$C" = "character_selector" ]; then
    cmd '{"type":"char_selector_select","option":"take_premade"}'
    sleep 2

    # Wait for gameplay (skip movies, dismiss options)
    for i in $(seq 1 40); do
        C=$(ctx)
        if [[ "$C" == gameplay* ]]; then break; fi
        if [ "$C" = "movie" ]; then cmd '{"type":"skip"}'; fi
        dismiss_options
        sleep 1
    done
fi

C=$(ctx)
if [[ "$C" != gameplay* ]]; then
    echo "  ✗ Not in gameplay (ctx=$C)"
    exit 1
fi
echo "  ✓ In gameplay"
dismiss_options
sleep 1
survey
echo ""

# Equip spear and switch to right hand
echo "  Equipping spear..."
cmd '{"type":"equip_item","item_pid":7,"hand":"right"}'
sleep 0.5
cmd '{"type":"switch_hand"}'
sleep 0.5

# Quick save
cmd '{"type":"quicksave","description":"temple_start"}'
sleep 1

# ─── Phase 3: ARTEMPLE ──────────────────────────────────────────────
ensure_focus
echo "═══ Phase 3: ARTEMPLE ═══"
MAP=$(mmap)
echo "  Map: $MAP"

# Handle doors & combat
handle_doors
C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi

# Loot containers & pickup items
loot_containers
pickup_items

# Find exit grid to ARCAVES (any exit, no backward filtering needed in ARTEMPLE)
ET=$(exit_grid_tile -1 "" "")
if [ "$ET" = "-1" ]; then
    echo "  ⚠ No exit grid found, rescanning..."
    survey
    ET=$(py "
grids = d.get('objects',{}).get('exit_grids',[])
if grids:
    print(sorted(grids, key=lambda x:x['distance'])[0]['tile'])
else:
    print(-1)
")
fi

if [ "$ET" != "-1" ]; then
    echo "  Exit grid at tile $ET"
    goto $ET
    sleep 2

    # Handle combat if triggered on the way
    C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi
fi

sleep 2
echo "  → Map=$(mmap) Elev=$(elev) Tile=$(tile)"
echo ""

# ─── Phase 4: ARCAVES Elevation 0 ───────────────────────────────────
echo "═══ Phase 4: ARCAVES Elevation 0 ═══"
survey

# Fight any ants first
C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi

# Find the forward exit grid (to "Temple: Hallway", elevation 1)
ET=$(exit_grid_tile 1 "Hallway" "Entrance")
echo "  Target exit to Hallway: tile $ET"

if [ "$ET" != "-1" ]; then
    # Navigate there, handling doors and combat along the way
    navigate_to $ET 25
    sleep 2
fi

# Check if we transitioned
CUR_ELEV=$(elev)
echo "  → Map=$(mmap) Elev=$CUR_ELEV Tile=$(tile)"

# If still on elev 0, try explicit door handling and retry
if [ "$CUR_ELEV" = "0" ]; then
    echo "  Still on elev 0 — exploring toward exit..."
    loot_containers
    pickup_items
    sleep 1

    ET=$(exit_grid_tile 1 "Hallway" "Entrance")
    if [ "$ET" != "-1" ]; then
        # Try explore_toward to get closer, then navigate
        explore_toward $ET 8
        sleep 1
        # Now we might be closer and see doors
        navigate_to $ET 20
        sleep 2
    fi
    CUR_ELEV=$(elev)
    echo "  → Elev=$CUR_ELEV"
fi

# Final check — if still on elev 0, something went wrong
if [ "$(elev)" = "0" ] && [[ "$(mmap)" == *ARCAVES* ]]; then
    echo "  ⚠ STILL on elev 0 — last resort: explore + handle doors"
    survey
    handle_doors
    sleep 1
    ET=$(exit_grid_tile 1 "Hallway" "Entrance")
    if [ "$ET" != "-1" ]; then
        navigate_to $ET 25
        sleep 2
    fi
    echo "  → Elev=$(elev) Tile=$(tile)"
fi

cmd '{"type":"quicksave","description":"arcaves_e0_done"}'
sleep 1
echo ""

# ─── Phase 5: ARCAVES Elevation 1 (Explosives) ──────────────────────
CUR_ELEV=$(elev)
if [ "$CUR_ELEV" != "1" ]; then
    echo "═══ Phase 5: SKIPPED (not on elev 1, currently elev=$CUR_ELEV) ═══"
    echo ""
else
echo "═══ Phase 5: ARCAVES Elevation 1 ═══"
ensure_focus
survey

# Fight any enemies
C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi

# Handle doors
handle_doors

# Use find_item to locate plastic explosives (PID 85) and dynamite (PID 51)
echo ""
echo "  🔍 Searching for explosives on map..."

# Diagnostic: list all items/containers on this elevation
cmd '{"type":"list_all_items"}'
sleep 1
echo "  All items on elev: $(field last_command_debug)"

# Step 1: Use find_item to locate plastic explosives (PID 85) or dynamite (PID 51)
cmd '{"type":"find_item","pid":85}'
sleep 1
FIND_85=$(field last_command_debug)
echo "  PID 85: $FIND_85"

cmd '{"type":"find_item","pid":51}'
sleep 1
FIND_51=$(field last_command_debug)
echo "  PID 51: $FIND_51"

# Extract tile from find_item result
EXPLOSIVE_TILE=$(python3 -c "
import re
r85 = '$FIND_85'
r51 = '$FIND_51'
for r in [r85, r51]:
    m = re.search(r'tile=(\d+)', r)
    if m and 'NONE FOUND' not in r:
        print(m.group(1)); exit()
print('-1')
")
echo "  Explosive at tile: $EXPLOSIVE_TILE"

HAS_EX=$(has_pid 85)
HAS_DYN=$(has_pid 51)

# Step 2: Navigate to the explosive container and loot it
if [ "$EXPLOSIVE_TILE" != "-1" ] && [ "$HAS_EX" = "no" ] && [ "$HAS_DYN" = "no" ]; then
    echo "  Navigating to explosives at tile $EXPLOSIVE_TILE"
    navigate_to $EXPLOSIVE_TILE 20
    sleep 1
    C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi

    # Find the container object near our position
    CONT_ID=$(py "
items = d.get('objects',{}).get('ground_items',[])
for i in sorted(items, key=lambda x:x['distance']):
    nm = i.get('name','').lower()
    if (i.get('item_count',0) > 0 or nm in ['pot','chest','bag','locker','footlocker']):
        if i['distance'] <= 8:
            print(i['id']); exit()
print('')
")
    echo "  Container ID: ${CONT_ID:-NONE}"
    if [ -n "$CONT_ID" ]; then
        echo "  Opening container $CONT_ID via open_container..."
        cmd "{\"type\":\"open_container\",\"object_id\":$CONT_ID}"
        sleep 3
        echo "  Context after open: $(ctx)"
        echo "  Debug: $(field last_command_debug)"

        if [ "$(ctx)" = "gameplay_loot" ]; then
            py "
for i in d.get('loot',{}).get('container_items',[]):
    print(f'    {i[\"name\"]} pid={i[\"pid\"]} qty={i.get(\"quantity\",1)}')
"
            cmd '{"type":"loot_take_all"}'
            sleep 1
            echo "  Take all: $(field last_command_debug)"
            cmd '{"type":"loot_close"}'
            sleep 1
        else
            # Fallback: try use_object (which uses _action_use_an_object)
            echo "  open_container didn't enter loot — trying use_object..."
            cmd "{\"type\":\"use_object\",\"object_id\":$CONT_ID}"
            sleep 3
            if [ "$(ctx)" = "gameplay_loot" ]; then
                cmd '{"type":"loot_take_all"}'
                sleep 1
                cmd '{"type":"loot_close"}'
                sleep 1
            else
                echo "  Still no loot interface — trying pick_up..."
                cmd "{\"type\":\"pick_up\",\"object_id\":$CONT_ID}"
                sleep 2
            fi
        fi
    else
        echo "  No container found nearby — listing ground items..."
        py "
items = d.get('objects',{}).get('ground_items',[])
for i in sorted(items, key=lambda x:x['distance'])[:10]:
    print(f'    {i[\"name\"]} d={i[\"distance\"]} tile={i[\"tile\"]} id={i[\"id\"]} ic={i.get(\"item_count\",0)}')
"
        # Try to loot all visible containers
        NEARBY=$(py "
items = d.get('objects',{}).get('ground_items',[])
for i in sorted(items, key=lambda x:x['distance']):
    if i.get('item_count',0) > 0 and i['distance'] <= 15:
        print(i['id']); exit()
")
        if [ -n "$NEARBY" ]; then
            echo "  Trying nearby container $NEARBY..."
            cmd "{\"type\":\"open_container\",\"object_id\":$NEARBY}"
            sleep 3
            if [ "$(ctx)" = "gameplay_loot" ]; then
                cmd '{"type":"loot_take_all"}'
                sleep 1
                cmd '{"type":"loot_close"}'
                sleep 1
            fi
        fi
    fi
    sleep 1
fi

# Step 3: Also loot all other nearby containers (healing powder, antidote)
echo "  Looting other containers in range..."
CONTAINER_LIST=$(py "
items = d.get('objects',{}).get('ground_items',[])
for i in sorted(items, key=lambda x:x['distance']):
    if i.get('item_count',0) > 0 and i['distance'] <= 50:
        print(f'{i[\"tile\"]}|{i[\"id\"]}|{i[\"name\"]}')
")
if [ -n "$CONTAINER_LIST" ]; then
    while IFS='|' read -r ct cid cname; do
        echo "    → $cname at tile $ct"
        navigate_to $ct 10
        C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi
        cmd "{\"type\":\"open_container\",\"object_id\":$cid}"
        sleep 3
        if [ "$(ctx)" = "gameplay_loot" ]; then
            cmd '{"type":"loot_take_all"}'
            sleep 1
            cmd '{"type":"loot_close"}'
            sleep 1
        fi
    done <<< "$CONTAINER_LIST"
fi
loot_containers
pickup_items

# Dismiss any loot screen that might have opened during pickup
if [ "$(ctx)" = "gameplay_loot" ]; then
    echo "  Closing loot screen..."
    cmd '{"type":"loot_take_all"}'
    sleep 1
    cmd '{"type":"loot_close"}'
    sleep 1
fi

# Make sure we're back in exploration mode
sleep 1

HAS_EX=$(has_pid 85)
HAS_DYN=$(has_pid 51)
echo "  Have plastic explosives: $HAS_EX"
echo "  Have dynamite: $HAS_DYN"

# Determine which explosive to use (prefer plastic)
EXPLOSIVE_PID=0
if [ "$HAS_EX" = "yes" ]; then
    EXPLOSIVE_PID=85
elif [ "$HAS_DYN" = "yes" ]; then
    EXPLOSIVE_PID=51
fi

# Find the impenetrable/sealed door
SEALED=$(py "
import json
for s in d.get('objects',{}).get('scenery',[]):
    nm = s.get('name','').lower()
    if 'impenetrable' in nm or 'sealed' in nm:
        print(json.dumps(s)); exit()
# Also check for locked doors
for s in d.get('objects',{}).get('scenery',[]):
    if s.get('scenery_type') == 'door' and s.get('locked'):
        print(json.dumps(s)); exit()
")

if [ -n "$SEALED" ] && [ "$SEALED" != "" ] && [ "$EXPLOSIVE_PID" -gt 0 ] 2>/dev/null; then
    SEAL_ID=$(echo "$SEALED" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    SEAL_TILE=$(echo "$SEALED" | python3 -c "import json,sys; print(json.load(sys.stdin)['tile'])")
    SEAL_NAME=$(echo "$SEALED" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
    echo ""
    echo "  🧨 $SEAL_NAME at tile $SEAL_TILE (id=$SEAL_ID)"

    # Move next to the sealed door
    navigate_to $SEAL_TILE 15
    C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi
    echo "  Player at tile $(tile), door dist=$(py "
for s in d.get('objects',{}).get('scenery',[]):
    if str(s.get('id','')) == '$SEAL_ID':
        print(s.get('distance','?')); exit()
print('?')
")"

    # Wait for animation to finish before using item
    sleep 2

    # Use explosives ON the door (triggers the door's use_obj_p_proc script)
    echo "  💣 Using explosive PID $EXPLOSIVE_PID on door $SEAL_ID..."
    for use_try in $(seq 1 5); do
        cmd "{\"type\":\"use_item_on\",\"item_pid\":$EXPLOSIVE_PID,\"object_id\":$SEAL_ID}"
        sleep 2
        DBG=$(field last_command_debug)
        echo "  $DBG"
        if [[ "$DBG" != *"animation busy"* ]]; then break; fi
        echo "  Retrying use_item_on ($use_try/5)..."
        sleep 2
    done

    # Wait for the script timer to trigger
    echo "  ⏰ Waiting for explosion..."
    for ewait in $(seq 1 30); do
        sleep 2
        # Check if door is gone
        DOOR_STILL=$(py "
for s in d.get('objects',{}).get('scenery',[]):
    if str(s.get('id','')) == '$SEAL_ID':
        print('yes'); exit()
print('no')
")
        if [ "$DOOR_STILL" = "no" ]; then
            echo "  Door destroyed! (after ${ewait}x2s)"
            break
        fi
        # Also check if we can see a different scenery state
        C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi
    done

    echo "  Checking door status..."
    survey

    # If door still there, try arm_explosive as backup
    DOOR_STILL=$(py "
for s in d.get('objects',{}).get('scenery',[]):
    nm = s.get('name','').lower()
    if 'impenetrable' in nm or 'sealed' in nm:
        print('yes'); exit()
print('no')
")
    if [ "$DOOR_STILL" = "yes" ] && [ "$(has_pid $EXPLOSIVE_PID)" = "yes" ]; then
        echo "  Door still there — trying arm_explosive as backup..."
        cmd "{\"type\":\"arm_explosive\",\"item_pid\":$EXPLOSIVE_PID,\"seconds\":10}"
        sleep 1
        echo "  $(field last_command_debug)"
        # Move away from blast
        goto $(py "print(d['player']['tile'] + 400)")
        sleep 12
        echo "  Checking door status after arm_explosive..."
        survey
    fi
elif [ "$EXPLOSIVE_PID" -eq 0 ] 2>/dev/null; then
    echo ""
    echo "  ⚠ No explosives found! Trying to proceed without them..."
    # Navigate toward the area anyway — maybe we can find another path
fi

# Find exit to elevation 2 (exclude Entrance exits)
echo ""
echo "  Looking for exit to elevation 2..."
ET=$(exit_grid_tile 2 "" "Entrance")
echo "  Exit to elev 2: tile $ET"
if [ "$ET" != "-1" ]; then
    navigate_to $ET 15
    sleep 2
    C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi
fi

sleep 2
CUR_ELEV=$(elev)
echo "  → Elev=$CUR_ELEV Tile=$(tile)"

# If still on elev 1, the sealed door may not have been blown — try lockpick
if [ "$CUR_ELEV" = "1" ]; then
    echo "  Still on elev 1, trying to find and open remaining doors..."
    handle_doors
    sleep 1
    ET=$(exit_grid_tile 2 "" "Entrance")
    if [ "$ET" != "-1" ]; then
        navigate_to $ET 10
        sleep 2
    fi
    CUR_ELEV=$(elev)
    echo "  → Elev=$CUR_ELEV"
fi

cmd '{"type":"quicksave","description":"arcaves_e1_done"}'
sleep 1
echo ""
fi  # End Phase 5 elevation guard

# ─── Phase 6: ARCAVES Elevation 2 (Cameron) ─────────────────────────
CUR_ELEV=$(elev)
if [ "$CUR_ELEV" != "2" ]; then
    echo "═══ Phase 6: SKIPPED (not on elev 2, currently elev=$CUR_ELEV map=$(mmap)) ═══"
    echo ""
else
echo "═══ Phase 6: ARCAVES Elevation 2 (Cameron) ═══"
survey

# Fight any ants
C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi

# Handle doors
handle_doors

# Find Cameron
CAMERON_ID=$(py "
for c in d.get('objects',{}).get('critters',[]):
    if any(w in c.get('name','').lower() for w in ['cameron','warrior']):
        print(c['id']); exit()
print('')
")

if [ -n "$CAMERON_ID" ]; then
    CAMERON_TILE=$(py "
for c in d.get('objects',{}).get('critters',[]):
    if str(c['id']) == '$CAMERON_ID':
        print(c['tile']); break
")
    echo ""
    echo "  👤 Cameron at tile $CAMERON_TILE"

    # Navigate close to Cameron
    navigate_to $CAMERON_TILE 15
    C=$(ctx); if [[ "$C" == *combat* ]]; then combat_loop; sleep 1; fi

    # Use healing items if HP is low
    CUR_HP=$(py "print(d.get('character',{}).get('derived_stats',{}).get('current_hp',0))")
    MAX_HP=$(py "print(d.get('character',{}).get('derived_stats',{}).get('max_hp',0))")
    echo "  HP: $CUR_HP/$MAX_HP"
    if [ "${CUR_HP:-0}" -lt "${MAX_HP:-99}" ] 2>/dev/null; then
        if [ "$(has_pid 273)" = "yes" ]; then
            echo "  Using Healing Powder..."
            cmd '{"type":"use_item","item_pid":273}'
            sleep 2
        fi
    fi

    # Unequip weapons for unarmed combat (Cameron requires it)
    echo "  Unequipping weapons..."
    cmd '{"type":"unequip_item","hand":"right"}'
    sleep 1
    cmd '{"type":"unequip_item","hand":"left"}'
    sleep 1

    # Talk to Cameron
    echo "  💬 Talking to Cameron..."
    cmd "{\"type\":\"talk_to\",\"object_id\":$CAMERON_ID}"
    sleep 3

    # Handle dialogue
    DIALOGUE_N=0
    while [ "$(ctx)" = "gameplay_dialogue" ] && [ $DIALOGUE_N -lt 20 ]; do
        REPLY=$(field "dialogue.reply_text" 2>/dev/null || echo "")
        echo "  Cameron: \"${REPLY:0:80}...\""

        # Show options
        py "
opts = d.get('dialogue',{}).get('options',[])
for o in opts:
    print(f'    [{o[\"index\"]}] {o[\"text\"]}')
"

        # Choose: prefer fight/challenge, then first option
        CHOICE=$(py "
opts = d.get('dialogue',{}).get('options',[])
# Prefer to accept the fight challenge
for o in opts:
    t = o.get('text','').lower()
    if any(w in t for w in ['fight','ready','challenge','prove','combat','bring']):
        print(o['index']); exit()
# Try speech option
for o in opts:
    t = o.get('text','').lower()
    if 'speech' in t:
        print(o['index']); exit()
# Default: first
if opts:
    print(opts[0]['index'])
else:
    print(0)
")
        echo "  → Option $CHOICE"
        cmd "{\"type\":\"select_dialogue\",\"index\":$CHOICE}"
        sleep 2
        DIALOGUE_N=$((DIALOGUE_N + 1))
    done

    # Cameron fight (unarmed)
    sleep 2
    C=$(ctx)
    if [[ "$C" == *combat* ]]; then
        echo ""
        echo "  ⚔ CAMERON FIGHT (unarmed)"
        # Make sure we're using unarmed (switch hand if needed)
        cmd '{"type":"switch_hand"}'
        sleep 0.5
        combat_loop
    fi
else
    echo "  Cameron not found nearby — exploring elev 2..."
    # Walk toward any visible critters or doors
    handle_doors
    sleep 1
    # Try again after exploring
    CAMERON_ID=$(py "
for c in d.get('objects',{}).get('critters',[]):
    if any(w in c.get('name','').lower() for w in ['cameron','warrior']):
        print(c['id']); exit()
print('')
")
    if [ -n "$CAMERON_ID" ]; then
        CAMERON_TILE=$(py "
for c in d.get('objects',{}).get('critters',[]):
    if str(c['id']) == '$CAMERON_ID':
        print(c['tile']); break
")
        echo "  Found Cameron at tile $CAMERON_TILE"
        cmd '{"type":"unequip_item","hand":"right"}'
        sleep 0.3
        cmd '{"type":"unequip_item","hand":"left"}'
        sleep 0.5
        cmd "{\"type\":\"talk_to\",\"object_id\":$CAMERON_ID}"
        sleep 3
    else
        echo "  ⚠ Cameron still not found"
        survey
    fi
fi

# After Cameron, look for exit
sleep 2
echo ""
echo "  Looking for temple exit..."
survey

# Find exit (any exit that isn't back to Hallway)
ET=$(exit_grid_tile -1 "" "Hallway")
if [ "$ET" = "-1" ]; then
    # Try any exit
    ET=$(exit_grid_tile -1 "" "")
fi
if [ "$ET" != "-1" ]; then
    echo "  Exit at tile $ET"
    navigate_to $ET 10
    sleep 3
fi

# Skip vault suit movie (may play multiple movies)
for movie_try in $(seq 1 10); do
    C=$(ctx)
    if [ "$C" = "movie" ]; then
        cmd '{"type":"skip"}'
        sleep 2
    elif [[ "$C" == gameplay* ]] || [[ "$C" == main_menu ]]; then
        break
    fi
    dismiss_options
    sleep 1
done
fi  # End Phase 6 elevation guard

# ─── Result ──────────────────────────────────────────────────────────
echo ""
echo "═══ RESULT ═══"
C=$(ctx)
M=$(mmap 2>/dev/null || echo "?")
echo "  Context: $C"
echo "  Map: $M"

if [[ "$M" == *"VILLAG"* ]] || [[ "$M" == *"villag"* ]] || [[ "$M" == *"ARVIL"* ]]; then
    echo ""
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║  ✓ TEMPLE OF TRIALS CLEARED!          ║"
    echo "  ║    Arrived at Arroyo Village           ║"
    echo "  ╚═══════════════════════════════════════╝"
elif [ "$C" = "movie" ]; then
    echo "  🎬 Movie playing (vault suit?)"
    skip_movies
    sleep 3
    echo "  Final: ctx=$(ctx) map=$(mmap 2>/dev/null || echo '?')"
fi

cmd '{"type":"quicksave","description":"temple_cleared"}'
sleep 1
echo ""
echo "Done!"
