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
# Sub-modules (sourced automatically):
#   executor_world.sh    — movement, navigation, exploration, interaction, healing
#   executor_combat.sh   — combat loop and quip generation
#   executor_dialogue.sh — dialogue, persona, and thought system
#
# ═══════════════════════════════════════════════════════════════════════════
# PLAYER ACTION REFERENCE
# ═══════════════════════════════════════════════════════════════════════════
#
# Everything below is an action a PLAYER can perform (or observe). The agent
# should only act within these bounds — no engine cheats, no metagaming.
#
# EXPLORATION (gameplay_exploration context)
#   move_to <tile>          — walk to tile (full A* pathfinding)
#   run_to <tile>           — run to tile (faster, same pathfinding)
#   use_object <id>         — interact with doors, switches, ladders, etc.
#   pick_up <id>            — pick up a ground item
#   look_at <id>            — examine an object (reads description)
#   use_skill <skill> [id]  — apply a skill (lockpick, traps, repair, etc.); omit id for self
#   use_item_on <pid> <id>  — use an inventory item on a world object
#   talk_to <id>            — initiate dialogue with an NPC
#   open_container <id>     — open a container for looting
#   enter_combat            — initiate combat (if hostiles nearby)
#
# INVENTORY (gameplay_inventory or any gameplay_* context)
#   equip_item <pid> <hand> — equip weapon/armor
#   unequip_item <hand>     — unequip from hand slot
#   use_item <pid>          — use a consumable (stimpak, etc.)
#   reload_weapon [ammo_pid]— reload current weapon (optionally with specific ammo)
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
# HEALING:        heal_to_full → rest (no hostiles) → use_skill first_aid
# COMBAT:         do_combat [timeout] — fully autonomous targeting + movement
# OPENING SHOT:   engage_ranged_opening <target_id|nearest> [opening_range] [auto|on|off]
#                 approach to ranged standoff, then enter combat and fire first shot
# LOOTING:        loot <id> (single container) or explore_area (sweep all nearby)
# NPC:            talk <id> → dialogue_assess → select_option <n> → dialogue_muse
#                 Or batch: talk <id> <opt1> <opt2> ... for quick dialogue
# NAVIGATION:     move_and_wait <tile>, move_and_wait exit "<dest>"
# SAVE:           save_before "label" — always before lockpick, combat, explosives
# LEVEL-UP:       level_up → add_skills skill=N → choose_perk "name" → finish_editor
# CHAR CREATE:    main_menu new_game → skip movies → char_selector_select →
#                 set_special S P E C I A L → set_traits → tag_skills → finish_editor
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

# Resolve repo root — works in both bash (BASH_SOURCE) and zsh ($0)
_executor_src="${BASH_SOURCE[0]:-$0}"
GAME_DIR="${FALLOUT2_GAME_DIR:-$(cd "$(dirname "$_executor_src")/.." && pwd)/game}"
unset _executor_src
STATE="$GAME_DIR/agent_state.json"
CMD="$GAME_DIR/agent_cmd.json"
TMP="$GAME_DIR/agent_cmd.tmp"

# ─── Debug Logging ────────────────────────────────────────────────────

DEBUG_DIR="$GAME_DIR/debug"
DEBUG_LOG="$DEBUG_DIR/executor.ndjson"

# Load zsh datetime module once at source time for EPOCHREALTIME
zmodload -s zsh/datetime 2>/dev/null

_dbg() {
    [ -d "$DEBUG_DIR" ] && echo "$1" >> "$DEBUG_LOG" 2>/dev/null
}

_dbg_ts() {
    printf '%d' $(( ${EPOCHREALTIME:-$(date +%s)} * 1000 ))
}

# Sanitize a string for safe JSON interpolation (strip quotes and backslashes)
_dbg_san() {
    printf '%s' "${1//[\"\\]/}"
}

_dbg_start() {
    _dbg "{\"ts\":$(_dbg_ts),\"event\":\"action_start\",\"fn\":\"$1\",\"args\":\"$(_dbg_san "${2:-}")\"}"
}

_dbg_end() {
    local _now=$(_dbg_ts)
    _dbg "{\"ts\":$_now,\"event\":\"action_end\",\"fn\":\"$1\",\"result\":\"$(_dbg_san "$2")\",\"duration_ms\":$(( _now - ${3:-0} ))}"
}

# ─── Process Liveness ────────────────────────────────────────────────

_game_pid() {
    pgrep -f "Fallout II Community Edition" 2>/dev/null | head -1
}

_require_game() {
    if ! _game_pid >/dev/null; then
        echo "ERROR: Game is not running. Launch it first." >&2
        return 1
    fi
}

game_running() {
    local pid=$(_game_pid)
    if [[ -n "$pid" ]]; then
        echo "Game running (PID $pid)"
        return 0
    else
        echo "Game is NOT running"
        return 1
    fi
}

# ─── Core I/O ─────────────────────────────────────────────────────────

send() {
    _require_game || return 1
    echo "$1" > "$TMP" && mv "$TMP" "$CMD"
}

cmd() {
    send "{\"commands\":[$1]}" || return 1
    local _type="?"
    [[ "$1" =~ '"type":"([^"]+)"' ]] && _type="${match[1]}"
    _dbg "{\"ts\":$(_dbg_ts),\"event\":\"cmd_sent\",\"caller\":\"${funcstack[2]:-direct}\",\"type\":\"$_type\"}"
}

py() {
    _require_game || return 1
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
    local _w_start=$(_dbg_ts)
    local max="${1:-30}"
    for i in $(seq 1 $max); do
        local busy=$(field "player.animation_busy")
        if [ "$busy" = "false" ] || [ "$busy" = "False" ]; then
            local _now=$(_dbg_ts)
            _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"idle\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"ok\"}"
            return 0
        fi
        sleep 0.5
    done
    local _now=$(_dbg_ts)
    _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"idle\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"timeout\"}"
    echo "WARN: wait_idle timeout" >&2
    return 1
}

wait_context() {
    local target="$1" max="${2:-60}"
    local _w_start=$(_dbg_ts)
    for i in $(seq 1 $max); do
        local ctx=$(context)
        if [ "$ctx" = "$target" ]; then
            local _now=$(_dbg_ts)
            _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"context\",\"target\":\"$target\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"ok\"}"
            return 0
        fi
        sleep 0.5
    done
    local _now=$(_dbg_ts)
    _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"context\",\"target\":\"$target\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"timeout\"}"
    echo "WARN: wait_context timeout for '$target' (got '$(context)')" >&2
    return 1
}

wait_context_prefix() {
    local prefix="$1" max="${2:-60}"
    local _w_start=$(_dbg_ts)
    for i in $(seq 1 $max); do
        local ctx=$(context)
        if [[ "$ctx" == ${prefix}* ]]; then
            local _now=$(_dbg_ts)
            _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"context_prefix\",\"target\":\"$prefix\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"ok\"}"
            return 0
        fi
        # Auto-skip movies
        [ "$ctx" = "movie" ] && cmd '{"type":"skip"}' && sleep 1 && continue
        sleep 0.5
    done
    local _now=$(_dbg_ts)
    _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"context_prefix\",\"target\":\"$prefix\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"timeout\"}"
    echo "WARN: wait_context_prefix timeout for '$prefix' (got '$(context)')" >&2
    return 1
}

wait_tick_advance() {
    # Wait for tick to advance past current value (confirms command was processed)
    local _w_start=$(_dbg_ts)
    local cur_tick=$(tick)
    local max="${1:-30}"
    for i in $(seq 1 $max); do
        local t=$(tick)
        if [ "$t" != "$cur_tick" ]; then
            local _now=$(_dbg_ts)
            _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"tick_advance\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"ok\"}"
            return 0
        fi
        sleep 0.3
    done
    local _now=$(_dbg_ts)
    _dbg "{\"ts\":$_now,\"event\":\"wait\",\"type\":\"tick_advance\",\"duration_ms\":$(( _now - _w_start )),\"result\":\"timeout\"}"
    return 1
}

# ─── Muse (core output primitive) ────────────────────────────────────

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
char = d.get('character', {})
if char.get('can_level_up'):
    extra += ' LEVEL UP!'
usp = char.get('unspent_skill_points', 0)
if usp and ctx != 'character_editor':
    extra += f' SP:{usp}'
print(f\"HP:{hp}/{max_hp} Lv:{lvl} Tile:{tile} {m.get('name','?')} {ctx} [{obj_str}]{extra}\")
"
}

_end_status() {
    # Print compact game state after action completion.
    local s=$(status 2>/dev/null)
    [ -n "$s" ] && echo "=> $s"
}

look_around() {
    # Print actionable objects near player, distance-capped and deduped.
    # Usage: look_around [max_dist]   (default: 25 tiles ≈ 1-2 screens)
    # Shows: all critters, doors, containers w/items, ground items, exits (1 per dest).
    # Skips: generic scenery (goo, rocks, walls) and empty containers.
    local max_dist="${1:-25}"
    py "
import json
objs = d.get('objects', {})
critters = objs.get('critters', [])
scenery = objs.get('scenery', [])
exits = objs.get('exit_grids', [])
ground = objs.get('ground_items', [])
ptile = d.get('player', {}).get('tile', 0)
MAX_DIST = $max_dist

def approx_dist(tile):
    if not tile or not ptile: return 999
    r1, c1 = divmod(ptile, 200)
    r2, c2 = divmod(tile, 200)
    return max(abs(r1 - r2), abs(c1 - c2))

def get_dist(obj):
    dist = obj.get('distance')
    if dist is None:
        dist = approx_dist(obj.get('tile', 0))
    return dist if isinstance(dist, (int, float)) else 999

def nearby(lst):
    return sorted([o for o in lst if get_dist(o) <= MAX_DIST], key=get_dist)

nc = nearby(critters)
if nc:
    print('CRITTERS:')
    for c in nc:
        hp_str = f\"hp={c.get('hp')}/{c.get('max_hp')}\" if 'hp' in c else ''
        dead = ' DEAD' if c.get('dead') else ''
        print(f\"  {c.get('name','?')} id={c.get('id')} tile={c.get('tile')} dist={get_dist(c)} {hp_str} team={c.get('team',0)}{dead}\")

# Scenery: only doors and containers with items
actionable = [s for s in scenery if s.get('scenery_type') == 'door' or s.get('item_count', 0) > 0]
ns = nearby(actionable)
if ns:
    print('SCENERY:')
    for s in ns:
        extra = ''
        if s.get('scenery_type') == 'door':
            extra = f\" open={s.get('open')} locked={s.get('locked')}\"
        if s.get('item_count', 0) > 0:
            extra += f\" items={s.get('item_count')}\"
        print(f\"  {s.get('name','?')} id={s.get('id')} tile={s.get('tile')} dist={get_dist(s)} type={s.get('scenery_type','?')}{extra}\")

# Exits: deduplicate by destination, keep closest
seen_dests = {}
for e in sorted(exits, key=get_dist):
    dest = e.get('destination_map_name', '?')
    if dest not in seen_dests:
        seen_dests[dest] = e
ne = [e for e in seen_dests.values() if get_dist(e) <= MAX_DIST]
if ne:
    print('EXITS:')
    for e in sorted(ne, key=get_dist):
        print(f\"  {e.get('destination_map_name','?')} tile={e.get('tile')} dist={get_dist(e)} (map={e.get('destination_map')})\")
# Always show exits beyond range as a summary
far_exits = [e for e in seen_dests.values() if get_dist(e) > MAX_DIST]
if far_exits:
    names = ', '.join(sorted(set(e.get('destination_map_name','?') for e in far_exits)))
    print(f'  (farther: {names})')

ng = nearby(ground)
if ng:
    print('GROUND ITEMS:')
    for g in ng:
        cnt = f' x{g[\"item_count\"]}' if g.get('item_count', 1) > 1 else ''
        ct = f' [{g[\"type\"]}]' if g.get('type') == 'container' else ''
        print(f\"  {g.get('name','?')}{cnt}{ct} id={g.get('id')} tile={g.get('tile')} dist={get_dist(g)} pid={g.get('pid')}\")

# Summary of what's beyond range
total_c = len(critters) - len(nc)
total_s = len(actionable) - len(ns)
total_g = len(ground) - len(ng)
beyond = []
if total_c > 0: beyond.append(f'{total_c} critters')
if total_s > 0: beyond.append(f'{total_s} scenery')
if total_g > 0: beyond.append(f'{total_g} ground items')
if beyond:
    print(f'(Beyond {MAX_DIST} tiles: {chr(44).join(beyond)} — use look_around <dist> to expand)')
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

objective() {
    # Track tactical sub-objectives.
    # Usage: objective add "text"     — add sub-objective
    #        objective list           — show current objectives
    #        objective done "text"    — remove matching objective (substring)
    #        objective clear          — clear all
    local action="${1:-list}"
    local obj_file="$GAME_DIR/objectives.md"

    case "$action" in
        add)
            local text="${2:?Usage: objective add \"text\"}"
            echo "$text" >> "$obj_file"
            echo "Objective added: $text"
            ;;
        list)
            if [ ! -f "$obj_file" ] || [ ! -s "$obj_file" ]; then
                echo "No active objectives"
                return 0
            fi
            echo "=== OBJECTIVES ==="
            cat -n "$obj_file"
            ;;
        done)
            local pattern="${2:?Usage: objective done \"pattern\"}"
            if [ ! -f "$obj_file" ]; then
                echo "No objectives file"
                return 1
            fi
            local before=$(wc -l < "$obj_file")
            grep -iv "$pattern" "$obj_file" > "${obj_file}.tmp" 2>/dev/null || true
            mv "${obj_file}.tmp" "$obj_file"
            local after=$(wc -l < "$obj_file")
            local removed=$((before - after))
            echo "Removed $removed objective(s) matching '$pattern'"
            ;;
        clear)
            > "$obj_file"
            echo "All objectives cleared"
            ;;
        *)
            echo "Usage: objective [add|list|done|clear] [text]"
            return 1
            ;;
    esac
}

# ─── Debug Queries ────────────────────────────────────────────────────

debug_tail() {
    # Tail last N entries from a debug log stream.
    # Usage: debug_tail [stream] [n]
    #   stream: bridge, executor, hook, all (default: all)
    #   n: number of entries (default: 20)
    local stream="${1:-all}" n="${2:-20}"
    local files=()
    case "$stream" in
        bridge)   files=("$DEBUG_DIR/bridge.ndjson") ;;
        executor) files=("$DEBUG_DIR/executor.ndjson") ;;
        hook)     files=("$DEBUG_DIR/hook.ndjson") ;;
        all)      files=("$DEBUG_DIR/bridge.ndjson" "$DEBUG_DIR/executor.ndjson" "$DEBUG_DIR/hook.ndjson") ;;
        *) echo "Usage: debug_tail [bridge|executor|hook|all] [n]"; return 1 ;;
    esac
    python3 -c "
import json, sys, os

files = sys.argv[1].split(',')
n = int(sys.argv[2])
lines = []
for f in files:
    if not os.path.isfile(f): continue
    src = os.path.basename(f).replace('.ndjson','')
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try:
                entry = json.loads(line)
                entry['_src'] = src
                lines.append(entry)
            except: pass

lines.sort(key=lambda e: e.get('ts', 0))
for entry in lines[-n:]:
    tick = entry.get('tick', '?')
    src = entry.get('_src', '?')
    event = entry.get('event', '?')
    parts = [f'[{tick}]', f'{src}/{event}']
    for k in ('type', 'change', 'fn', 'caller', 'target', 'result', 'failure', 'reason', 'duration_ms', 'from', 'to', 'delta', 'hook_event', 'context', 'blocks_sent'):
        if k in entry and k != 'event':
            parts.append(f'{k}={entry[k]}')
    print(' '.join(str(p) for p in parts))
" "$(IFS=,; echo "${files[*]}")" "$n"
}

debug_find() {
    # Grep across all debug NDJSON files for a pattern.
    # Usage: debug_find <pattern>
    local pattern="${1:?Usage: debug_find <pattern>}"
    if [ ! -d "$DEBUG_DIR" ]; then echo "No debug directory (game not running?)"; return 1; fi
    python3 -c "
import json, sys, os, re

pattern = sys.argv[1]
debug_dir = sys.argv[2]
if not os.path.isdir(debug_dir):
    print('No debug directory'); sys.exit(1)
files = [os.path.join(debug_dir, f) for f in os.listdir(debug_dir) if f.endswith('.ndjson')]
files.sort()
for fpath in files:
    fname = os.path.basename(fpath)
    with open(fpath) as fh:
        for i, line in enumerate(fh, 1):
            if re.search(pattern, line, re.IGNORECASE):
                line = line.strip()
                try:
                    entry = json.loads(line)
                    tick = entry.get('tick', '?')
                    event = entry.get('event', '?')
                    etype = entry.get('type', entry.get('change', entry.get('fn', '')))
                    result = entry.get('result', '')
                    print(f'{fname}:{i} [{tick}] {event} {etype} {result}')
                except:
                    print(f'{fname}:{i} {line[:120]}')
" "$pattern" "$DEBUG_DIR"
}

debug_timeline() {
    # Interleave all debug logs by timestamp, show last N events.
    # Usage: debug_timeline [n]
    local n="${1:-30}"
    debug_tail all "$n"
}

debug_last_failure() {
    # Find the most recent failure event across all debug logs.
    if [ ! -d "$DEBUG_DIR" ]; then echo "No debug directory (game not running?)"; return 1; fi
    python3 -c "
import json, sys, os

debug_dir = sys.argv[1]
if not os.path.isdir(debug_dir):
    print('No debug directory'); sys.exit(1)
files = [os.path.join(debug_dir, f) for f in os.listdir(debug_dir) if f.endswith('.ndjson') and not f.startswith('prev_')]
failures = []
for fpath in files:
    src = os.path.basename(fpath).replace('.ndjson','')
    with open(fpath) as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try:
                entry = json.loads(line)
                is_fail = (
                    entry.get('failure') == True
                    or entry.get('result') in ('timeout', 'fail', 'stuck', 'no_path', 'blocked', 'no_exits', 'no_items', 'no_loot_ctx', 'no_dialogue', 'bad_args')
                    or any(w in str(entry.get('result', '')) for w in ('BLOCKED', 'failed', 'not found'))
                )
                if is_fail:
                    entry['_src'] = src
                    failures.append(entry)
            except: pass

if not failures:
    print('No failures found in current session logs.')
else:
    failures.sort(key=lambda e: e.get('ts', 0))
    entry = failures[-1]
    tick = entry.get('tick', '?')
    src = entry.get('_src', '?')
    event = entry.get('event', '?')
    print(f'Last failure: [{tick}] {src}/{event}')
    for k, v in entry.items():
        if k not in ('_src', 'ts'):
            print(f'  {k}: {v}')
" "$DEBUG_DIR"
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
    echo "  do_combat [timeout] [crit%]     — auto-combat (engine AI, monitor loop)"
    echo "  heal_to_full                    — loop healing until HP=max"
    echo "  heal_companion <id> [pid]       — use healing item on companion/NPC"
    echo "  doctor_companion <id>           — apply Doctor skill to companion/NPC"
    echo "  party_status                    — compact companion HP/status/weapon list"
    echo "  loot <id>                       — auto-walk + open + take all + close"
    echo "  interact <id>                   — auto-walk + use object"
    echo "  talk <id> [opt1 opt2 ...]       — auto-walk + dialogue (auto-assess)"
    echo "  use_skill <skill> [id]          — apply skill (omit id => self)"
    echo "  use_item_on <pid> <id>          — auto-walk + use item on object"
    echo "  equip_and_use <pid> [hand] [t]  — equip + switch hand + use"
    echo "  check_ammo                      — active weapon ammo + compatible ammo"
    echo "  reload [ammo_pid]               — reload (optionally with specific ammo)"
    echo "  engage_ranged_opening <target_id|nearest> [opening_range] [auto|on|off]"
    echo "                               — pre-combat ranged opener (approach, trigger combat, opening shot)"
    echo "  rest [hours]                    — native rest/time pass (interrupt-aware)"
    echo "  sneak_on / sneak_off            — idempotent sneak toggle"
    echo "  move_and_wait <tile>            — move to tile (polls for arrival/transition)"
    echo "  move_and_wait exit [dest]       — leave map via nearest exit grid"
    echo ""
    echo "WORLD MAP:"
    echo "  worldmap_travel <area_id>       — start native worldmap walking"
    echo "  worldmap_wait [timeout]         — wait for worldmap walk completion"
    echo "  worldmap_enter_location <a> [e] — enter area by id/entrance"
    echo ""
    echo "QUERY:"
    echo "  find_path <to> [from]           — native path query (len + waypoints)"
    echo "  tile_objects <tile> [radius]    — inspect objects near tile"
    echo "  find_item <pid>                 — locate PID across map/inventory"
    echo "  list_all_items                  — sample items/containers on elevation"
    echo ""
    echo "DIALOGUE:"
    echo "  dialogue_assess                 — structured briefing (NPC, options, quests)"
    echo "  select_option <index>           — choose option + track history + show next"
    echo "  dialogue_muse                   — Sonnet in-character reaction (background)"
    echo "  barter_status                   — current barter tables + trade info"
    echo "  barter_offer <pid> [qty]        — move item to your offer table"
    echo "  barter_request <pid> [qty]      — move merchant item to request table"
    echo "  barter_remove_offer <p> [qty]   — remove from your offer"
    echo "  barter_remove_request <p> [qty] — remove from merchant request"
    echo "  barter_confirm                  — native confirm (engine transaction)"
    echo "  barter_talk / barter_cancel     — return to dialogue / cancel barter"
    echo ""
    echo "CHARACTER (creation & level-up):"
    echo "  editor_status                   — editor state summary (SPECIAL, traits, skills, perks)"
    echo "  set_special S P E C I A L       — set all SPECIAL stats (creation only)"
    echo "  set_traits trait1 [trait2]      — select traits (creation only)"
    echo "  tag_skills s1 s2 s3            — tag skills (creation only)"
    echo "  add_skills skill=N [...]       — distribute skill points (level-up)"
    echo "  choose_perk <name|id>          — select a perk by name or ID"
    echo "  level_up                       — open character screen for leveling"
    echo "  finish_editor                  — close editor (validates first)"
    echo ""
    echo "COMBAT AI:"
    echo "  configure_combat_ai k v [...]   — tune engine auto-combat packet options"
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
    echo "  objective add|list|done|clear   — track sub-objectives"
    echo ""
    echo "PERSONA:"
    echo "  read_persona [section]          — read character persona"
    echo "  evolve_persona                  — update after significant events"
    echo ""
    echo "UI:"
    echo "  dismiss_options_menu            — dismiss leaked options dialog"
    echo ""
    echo "DEBUG:"
    echo "  debug_tail [stream] [n]         — tail last N log entries (bridge/executor/hook/all)"
    echo "  debug_find <pattern>            — grep all debug logs for pattern"
    echo "  debug_timeline [n]              — interleaved timeline of last N events"
    echo "  debug_last_failure              — most recent failure across all logs"
}

# ─── Source sub-modules ──────────────────────────────────────────────

# Resolve script dir — works in both bash and zsh
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # zsh: $0 is the sourced script path
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
source "$SCRIPT_DIR/executor_world.sh"
source "$SCRIPT_DIR/executor_combat.sh"
source "$SCRIPT_DIR/executor_dialogue.sh"
source "$SCRIPT_DIR/executor_chargen.sh"

echo "executor.sh loaded — run 'executor_help' for commands"
