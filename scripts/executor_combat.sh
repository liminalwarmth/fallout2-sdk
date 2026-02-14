# executor_combat.sh — Auto-combat monitoring loop and quip generation
#
# Sourced by executor.sh. Depends on: cmd, py, field, context, last_debug,
# wait_idle, wait_tick_advance, wait_context, move_and_wait, muse, GAME_DIR, STATE, CMD.
#
# Combat decisions are handled by the engine's native _combat_ai() when
# auto_combat is enabled. This script only monitors for death, critical HP,
# stuck situations, combat end, and generates quips.

# ─── Combat ───────────────────────────────────────────────────────────

_combat_target_snapshot() {
    # Args: $1 = object id
    py "
for c in d.get('objects', {}).get('critters', []):
    if str(c.get('id')) != '$1':
        continue
    if c.get('dead'):
        continue
    print(f\"{c.get('tile', '')}\t{c.get('distance', 999)}\t{c.get('name', '?')}\")
    break
"
}

engage_ranged_opening() {
    # Smart opener for exploration encounters:
    # 1) Optionally sneak while approaching.
    # 2) Stop at standoff distance (weapon-aware).
    # 3) Manually enter combat and fire a first shot.
    #
    # Usage:
    #   engage_ranged_opening <target_id|nearest> [opening_range] [auto|on|off]
    local _ds=$(_dbg_ts)
    _dbg_start "engage_ranged_opening" "$*"

    local target_id="${1:-}"
    local opening_range="${2:-}"
    local sneak_mode="${3:-auto}"

    local ctx=$(context)
    if [[ "$ctx" == gameplay_combat* ]]; then
        echo "Already in combat (context=$ctx)"
        _dbg_end "engage_ranged_opening" "already_combat" "$_ds"
        return 0
    fi

    if [ -z "$target_id" ]; then
        echo "Usage: engage_ranged_opening <target_id|nearest> [opening_range] [auto|on|off]"
        _dbg_end "engage_ranged_opening" "bad_args" "$_ds"
        return 1
    fi

    if [ -n "$opening_range" ] && ! [[ "$opening_range" =~ ^[0-9]+$ ]]; then
        echo "opening_range must be a positive integer (got '$opening_range')"
        _dbg_end "engage_ranged_opening" "bad_range" "$_ds"
        return 1
    fi
    if [ -n "$opening_range" ] && [ "$opening_range" -lt 1 ]; then
        echo "opening_range must be >= 1 (got '$opening_range')"
        _dbg_end "engage_ranged_opening" "bad_range" "$_ds"
        return 1
    fi

    if [ "$target_id" = "nearest" ]; then
        target_id=$(py "
critters = d.get('objects', {}).get('critters', [])
enemyish = [c for c in critters if c.get('enemy_team') and not c.get('dead')]
enemyish.sort(key=lambda c: c.get('distance', 999))
if enemyish:
    print(enemyish[0].get('id', ''))
")
    fi

    if [ -z "$target_id" ]; then
        echo "No enemy-team critter found nearby"
        _dbg_end "engage_ranged_opening" "no_target" "$_ds"
        return 1
    fi

    local tinfo=$(_combat_target_snapshot "$target_id")
    if [ -z "$tinfo" ]; then
        echo "Target id=$target_id not found/alive"
        _dbg_end "engage_ranged_opening" "target_missing" "$_ds"
        return 1
    fi

    local target_tile="${tinfo%%	*}"
    tinfo="${tinfo#*	}"
    local target_dist="${tinfo%%	*}"
    local target_name="${tinfo##*	}"

    local winfo=$(py "
inv = d.get('inventory', {})
eq = inv.get('equipped', {})
active = inv.get('active_hand', 'right')
slot = 'right_hand' if active == 'right' else 'left_hand'
w = eq.get(slot) if isinstance(eq, dict) else None
if not isinstance(w, dict):
    w = {}
combat = d.get('combat', {})
primary = combat.get('active_weapon', {}).get('primary', {})
wrange = primary.get('range', 1) if isinstance(primary, dict) else 1
skills = d.get('character', {}).get('skills', {})
sneak_skill = skills.get('sneak', 0) if isinstance(skills, dict) else 0
print(f\"{w.get('name','Unarmed')}\t{inv.get('attack_mode_label','')}\t{wrange}\t{w.get('ammo_capacity',0)}\t{w.get('ammo_count',0)}\t{sneak_skill}\")
")
    local weapon_name="${winfo%%	*}"
    winfo="${winfo#*	}"
    local attack_mode="${winfo%%	*}"
    winfo="${winfo#*	}"
    local weapon_range="${winfo%%	*}"
    winfo="${winfo#*	}"
    local ammo_capacity="${winfo%%	*}"
    winfo="${winfo#*	}"
    local ammo_count="${winfo%%	*}"
    local sneak_skill="${winfo##*	}"

    if [ -n "$ammo_capacity" ] && [ "$ammo_capacity" -gt 0 ] 2>/dev/null && [ "$ammo_count" -le 0 ] 2>/dev/null; then
        echo "Reloading $weapon_name before opening..."
        reload >/dev/null
        local refreshed=$(py "
inv = d.get('inventory', {})
eq = inv.get('equipped', {})
active = inv.get('active_hand', 'right')
slot = 'right_hand' if active == 'right' else 'left_hand'
w = eq.get(slot) if isinstance(eq, dict) else None
if not isinstance(w, dict):
    print(0)
else:
    print(w.get('ammo_count', 0))
")
        ammo_count="${refreshed:-0}"
    fi

    local ranged_nonthrow=0
    if [ "${weapon_range:-1}" -gt 1 ] 2>/dev/null && [ "${attack_mode:-}" != "throw" ]; then
        ranged_nonthrow=1
    fi

    if [ "$ranged_nonthrow" -ne 1 ]; then
        echo "Active mode is not non-throw ranged (weapon='$weapon_name' mode='${attack_mode:-?}' range=${weapon_range:-1})"
        echo "Entering combat without ranged opener."
        cmd '{"type":"enter_combat"}'
        sleep 0.3
        wait_context_prefix "gameplay_combat" 20 || true
        _dbg_end "engage_ranged_opening" "fallback_enter_combat" "$_ds"
        return 0
    fi

    if [ -z "$opening_range" ]; then
        opening_range=$((weapon_range - 2))
        [ "$opening_range" -lt 6 ] && opening_range=6
        [ "$opening_range" -gt 12 ] && opening_range=12
        if [ "$opening_range" -ge "$weapon_range" ]; then
            opening_range=$((weapon_range - 1))
        fi
        [ "$opening_range" -lt 2 ] && opening_range=2
    fi

    if [ "$sneak_mode" = "on" ] || { [ "$sneak_mode" = "auto" ] && [ "${sneak_skill:-0}" -ge 40 ] 2>/dev/null && [ "${target_dist:-999}" -gt "$opening_range" ] 2>/dev/null; }; then
        sneak_on >/dev/null || true
    fi

    echo "Engaging $target_name (id=$target_id) with $weapon_name at standoff range ~$opening_range"

    if [ "${target_dist:-999}" -gt "$opening_range" ] 2>/dev/null; then
        local attempts=0
        local last_dist="${target_dist:-999}"
        while [ $attempts -lt 5 ]; do
            ctx=$(context)
            if [[ "$ctx" == gameplay_combat* ]]; then
                break
            fi

            tinfo=$(_combat_target_snapshot "$target_id")
            if [ -z "$tinfo" ]; then
                break
            fi
            target_tile="${tinfo%%	*}"
            tinfo="${tinfo#*	}"
            target_dist="${tinfo%%	*}"
            target_name="${tinfo##*	}"

            if [ "${target_dist:-999}" -le "$opening_range" ] 2>/dev/null; then
                cmd '{"type":"enter_combat"}'
                sleep 0.3
                break
            fi

            # Move via world helper instead of direct run_to to avoid hard-failing on occupied critter tiles.
            move_and_wait "$target_tile" >/dev/null || true

            ctx=$(context)
            if [[ "$ctx" == gameplay_combat* ]]; then
                break
            fi

            tinfo=$(_combat_target_snapshot "$target_id")
            if [ -z "$tinfo" ]; then
                break
            fi
            target_dist="${tinfo#*	}"
            target_dist="${target_dist%%	*}"
            if [ "${target_dist:-999}" -ge "$last_dist" ] 2>/dev/null; then
                # No progress closing distance; stop retrying.
                break
            fi
            last_dist="$target_dist"
            attempts=$((attempts + 1))
        done
    fi

    ctx=$(context)
    if [[ "$ctx" != gameplay_combat* ]]; then
        tinfo=$(_combat_target_snapshot "$target_id")
        if [ -n "$tinfo" ]; then
            target_dist="${tinfo#*	}"
            target_dist="${target_dist%%	*}"
        fi
        local engage_dist="$opening_range"
        if [ "${weapon_range:-1}" -gt "$engage_dist" ] 2>/dev/null; then
            engage_dist="$weapon_range"
        fi
        if [ "${target_dist:-999}" -le $((engage_dist + 1)) ] 2>/dev/null; then
            cmd '{"type":"enter_combat"}'
            sleep 0.3
        fi
    fi

    wait_context_prefix "gameplay_combat" 30 || true
    ctx=$(context)
    if [[ "$ctx" != gameplay_combat* ]]; then
        echo "Failed to enter combat (context=$ctx)"
        _dbg_end "engage_ranged_opening" "no_combat" "$_ds"
        return 1
    fi

    local got_player_turn=0
    for _ in $(seq 1 24); do
        ctx=$(context)
        if [ "$ctx" = "gameplay_combat" ]; then
            got_player_turn=1
            break
        fi
        if [ "$ctx" = "gameplay_combat_auto" ]; then
            echo "Auto-combat is active; skipping manual opening shot."
            _dbg_end "engage_ranged_opening" "auto_combat_active" "$_ds"
            return 0
        fi
        sleep 0.5
    done

    if [ "$got_player_turn" -ne 1 ]; then
        echo "In combat but player turn not available yet (context=$(context))"
        _dbg_end "engage_ranged_opening" "combat_wait" "$_ds"
        return 0
    fi

    local attack_target=$(py "
hostiles = d.get('combat', {}).get('hostiles', [])
chosen = None
for h in hostiles:
    if str(h.get('id')) == '$target_id' and h.get('hp', 0) > 0:
        chosen = h
        break
if chosen is None and hostiles:
    hostiles = [h for h in hostiles if h.get('hp', 0) > 0]
    hostiles.sort(key=lambda h: h.get('distance', 999))
    if hostiles:
        chosen = hostiles[0]
if chosen:
    print(chosen.get('id', ''))
")

    if [ -z "$attack_target" ]; then
        echo "No hostile target available for opening shot"
        _dbg_end "engage_ranged_opening" "no_hostile" "$_ds"
        return 1
    fi

    cmd "{\"type\":\"attack\",\"target_id\":$attack_target}"
    sleep 0.3
    wait_tick_advance 10 || true
    echo "Opening shot debug: $(last_debug)"
    _dbg_end "engage_ranged_opening" "ok" "$_ds"
    return 0
}

do_combat() {
    local _ds=$(_dbg_ts)
    _dbg_start "do_combat" "${1:-120} ${2:-20}"
    local timeout_secs="${1:-120}" critical_hp_pct="${2:-20}"
    local start_time=$(date +%s) round=0
    local last_n_alive=999 last_total_hp=999999
    local stuck_checks=0

    _combat_quip_tick=0
    _combat_kills=0
    _combat_last_hp=0

    echo "=== COMBAT START (auto-combat, timeout=${timeout_secs}s) ==="

    # Enable engine auto-combat
    cmd '{"type":"auto_combat","enabled":true}'
    sleep 0.5

    while true; do
        # Wall-clock timeout
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        if [ $elapsed -ge $timeout_secs ]; then
            echo "=== COMBAT TIMEOUT (${elapsed}s, rounds=$round) ==="
            cmd '{"type":"auto_combat","enabled":false}'
            _dbg_end "do_combat" "timeout" "$_ds"
            return 1
        fi

        local ctx=$(context)

        # Death detection
        local hp=$(py "print(d.get('character',{}).get('derived_stats',{}).get('current_hp',0))" 2>/dev/null)
        if [ "${hp:-1}" -le 0 ]; then
            echo "=== PLAYER DIED (HP=${hp}, round $round) ==="
            echo "    Loading quicksave..."
            cmd '{"type":"auto_combat","enabled":false}'
            sleep 3
            cmd '{"type":"load_slot","slot":0}'
            sleep 5
            _dbg_end "do_combat" "died" "$_ds"
            return 2
        fi

        # Combat over? (exploration, dialogue, or any non-combat context)
        if [ "$ctx" != "gameplay_combat" ] && [ "$ctx" != "gameplay_combat_wait" ] && [ "$ctx" != "gameplay_combat_auto" ]; then
            echo "=== COMBAT END (context: $ctx, rounds: $round, ${elapsed}s) ==="
            cmd '{"type":"auto_combat","enabled":false}'
            _end_status
            combat_quip_sync win "$_combat_kills kills in $round rounds"
            _dbg_end "do_combat" "ok" "$_ds"
            return 0
        fi

        # Read combat snapshot for monitoring
        local info=$(py "
import json
c = d.get('combat', {})
ch = d.get('character', {}).get('derived_stats', {})
hostiles = c.get('hostiles', [])
alive = [h for h in hostiles if h.get('hp', 0) > 0]
print(json.dumps({
    'hp': ch.get('current_hp', 0),
    'max_hp': ch.get('max_hp', 0),
    'n_alive': len(alive),
    'total_hp': sum(h.get('hp', 0) for h in alive),
    'round': c.get('combat_round', 0),
}, separators=(',',':')))
" 2>/dev/null)

        if [ -z "$info" ]; then
            sleep 1
            continue
        fi

        local mon_hp=0 mon_max_hp=0 n_alive=0 total_hp=0 combat_round=0
        eval $(echo "$info" | python3 -c "
import json, sys, shlex
d = json.load(sys.stdin)
for k,v in d.items():
    print(f'{k}={shlex.quote(str(v))}')
")
        mon_hp=${hp:-0}
        mon_max_hp=${max_hp:-1}

        # Track rounds from engine
        if [ "$combat_round" -gt "$round" ]; then
            round=$combat_round
        fi

        # ─── Quip triggers ─────────────────────────────────────────
        # Initialize HP tracking
        if [ "$_combat_last_hp" -eq 0 ] && [ "$mon_hp" -gt 0 ]; then
            _combat_last_hp=$mon_hp
        fi

        # Detect kills
        if [ "$last_n_alive" -ne 999 ] && [ "$n_alive" -lt "$last_n_alive" ] 2>/dev/null; then
            local killed=$((last_n_alive - n_alive))
            _combat_kills=$((_combat_kills + killed))
            _combat_quip_tick=0
            combat_quip kill "Round $round, $_combat_kills total kills"
        fi

        # Detect taking damage
        if [ "$_combat_last_hp" -gt 0 ] && [ "$mon_hp" -lt "$_combat_last_hp" ]; then
            local dmg_taken=$((_combat_last_hp - mon_hp))
            if [ "$mon_max_hp" -gt 0 ] && [ $((dmg_taken * 100 / mon_max_hp)) -ge 25 ]; then
                _combat_quip_tick=0
                combat_quip big_hurt "Took $dmg_taken damage in round $round"
            else
                combat_quip hurt "Took $dmg_taken damage in round $round"
            fi
        fi
        _combat_last_hp=$mon_hp

        # ─── Safety checks ─────────────────────────────────────────
        # Critical HP: disable auto-combat and reload
        if [ "$mon_max_hp" -gt 0 ]; then
            local hp_pct=$((mon_hp * 100 / mon_max_hp))
            if [ $hp_pct -lt $critical_hp_pct ]; then
                echo "    CRITICAL HP ($hp_pct%) — reloading quicksave"
                cmd '{"type":"auto_combat","enabled":false}'
                sleep 0.5
                cmd '{"type":"load_slot","slot":0}'
                sleep 5
                _dbg_end "do_combat" "reload_critical" "$_ds"
                return 2
            fi
        fi

        # Stuck detection: no progress across multiple checks
        if [ "$last_n_alive" -ne 999 ]; then
            if [ "$n_alive" -lt "$last_n_alive" ] 2>/dev/null || [ "$total_hp" -lt "$last_total_hp" ] 2>/dev/null; then
                stuck_checks=0
            else
                stuck_checks=$((stuck_checks + 1))
            fi
        fi
        last_n_alive=$n_alive
        last_total_hp=$total_hp

        if [ $stuck_checks -ge 60 ]; then
            echo "    STUCK for ${stuck_checks}s with no progress — reloading quicksave"
            cmd '{"type":"auto_combat","enabled":false}'
            sleep 0.5
            cmd '{"type":"load_slot","slot":0}'
            sleep 5
            _dbg_end "do_combat" "reload_stuck" "$_ds"
            return 2
        fi

        # Poll at ~1Hz — engine handles all decisions natively
        sleep 1
    done
}

# Configure engine auto-combat AI profile while auto_combat is enabled.
# Usage:
#   configure_combat_ai key value [key value ...]
# Example:
#   configure_combat_ai attack_who weakest distance stay_close chem_use clean
configure_combat_ai() {
    if [ "$#" -lt 2 ] || [ $(( $# % 2 )) -ne 0 ]; then
        echo "Usage: configure_combat_ai key value [key value ...]"
        echo "Keys: attack_who distance best_weapon chem_use run_away_mode area_attack_mode disposition"
        return 1
    fi

    local payload='"type":"configure_combat_ai"'
    while [ "$#" -gt 0 ]; do
        local key="$1"
        local value="$2"
        payload="$payload,\"$key\":\"$value\""
        shift 2
    done

    cmd "{$payload}"
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

# ─── Combat Quips ────────────────────────────────────────────────────

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
    _combat_quip_tick=3  # ~4 rounds between quips

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
