# executor_combat.sh — Combat loop and quip generation
#
# Sourced by executor.sh. Depends on: cmd, py, field, context, last_debug,
# wait_idle, wait_tick_advance, wait_context, muse, GAME_DIR, STATE, CMD.

# ─── Combat ───────────────────────────────────────────────────────────

wait_my_turn() {
    local _ds=$(_dbg_ts)
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
                _dbg "{\"ts\":$(_dbg_ts),\"event\":\"wait\",\"type\":\"my_turn\",\"duration_ms\":$(( $(_dbg_ts) - _ds )),\"result\":\"ok\"}"
                return 0
            fi
        fi
        if [ "$ctx" = "gameplay_exploration" ] || [ "$ctx" = "gameplay_dialogue" ]; then
            # Combat ended
            _dbg "{\"ts\":$(_dbg_ts),\"event\":\"wait\",\"type\":\"my_turn\",\"duration_ms\":$(( $(_dbg_ts) - _ds )),\"result\":\"combat_ended\"}"
            return 0
        fi
        sleep 0.8
        elapsed=$((elapsed + 1))
    done
    _dbg "{\"ts\":$(_dbg_ts),\"event\":\"wait\",\"type\":\"my_turn\",\"duration_ms\":$(( $(_dbg_ts) - _ds )),\"result\":\"timeout\"}"
    return 1
}

do_combat() {
    local _ds=$(_dbg_ts)
    _dbg_start "do_combat" "${1:-60} ${2:-40}"
    local timeout_secs="${1:-60}" heal_pct="${2:-40}"
    local start_time=$(date +%s) action_count=0 consec_fail=0 round=0
    local stuck_rounds=0 last_n_alive=999 last_total_hp=999999

    _combat_failed_heal_pid=0
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
            _dbg_end "do_combat" "timeout" "$_ds"
            return 1
        fi

        local ctx=$(context)

        # Combat over?
        if [ "$ctx" != "gameplay_combat" ] && [ "$ctx" != "gameplay_combat_wait" ]; then
            echo "=== COMBAT END (context: $ctx, rounds: $round, actions: $action_count, ${elapsed}s) ==="
            # Win quip runs synchronously (not background) so it completes before we return
            combat_quip_sync win "$_combat_kills kills in $round rounds"
            _dbg_end "do_combat" "ok" "$_ds"
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
ws = w.get('secondary', {})
mode_name = c.get('current_hit_mode_name', 'primary') or 'primary'
secondary_modes = {
    'left_secondary', 'right_secondary', 'kick', 'strong_kick', 'snap_kick',
    'power_kick', 'hip_kick', 'hook_kick', 'piercing_kick'
}
use_secondary = isinstance(mode_name, str) and (mode_name.endswith('_secondary') or mode_name in secondary_modes)
wa = ws if use_secondary else wp
if not isinstance(wa, dict):
    wa = wp if isinstance(wp, dict) else {}
total_hp = sum(h.get('hp', 0) for h in alive)
# Count nearby combatants (within 15 tiles) as 'engaged' — distant ones are bystanders
nearby = [h for h in alive if h.get('distance', 999) <= 15]
n_engaged = len(nearby) if nearby else len(alive)
# Names of engaged enemies for quip context
engaged_names = list(set(h.get('name','?') for h in (nearby if nearby else alive)))
inv = d.get('inventory', {}).get('items', [])
inv_eq = d.get('inventory', {}).get('equipped', {})
active_hand = c.get('active_hand', d.get('inventory', {}).get('active_hand', 'right'))
cur_key = 'right_hand' if active_hand == 'right' else 'left_hand'
off_key = 'left_hand' if cur_key == 'right_hand' else 'right_hand'
cur_eq = inv_eq.get(cur_key) or {}
off_eq = inv_eq.get(off_key) or {}
def hand_usable(h):
    if not isinstance(h, dict) or not h:
        return False
    cap = h.get('ammo_capacity', 0) or 0
    if cap > 0:
        return (h.get('ammo_count', 0) or 0) > 0
    return True
failed_heal_pid = int(${_combat_failed_heal_pid:-0})
heal = None
for pid in (40, 144, 81):  # Stimpak, Super Stimpak, Healing Powder
    if pid == failed_heal_pid:
        continue
    heal = next((it for it in inv if it.get('pid') == pid and it.get('quantity', 0) > 0), None)
    if heal:
        break
if heal is None:
    for it in inv:
        if it.get('pid') == failed_heal_pid:
            continue
        name = (it.get('name') or '').lower()
        if ('stim' in name or 'healing powder' in name) and it.get('quantity', 0) > 0:
            heal = it
            break
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
    'n_has_ranged': 1 if (n and n.get('has_ranged_weapon', False)) else 0,
    'n_chance_uncalled': n.get('hit_chances', {}).get('uncalled', 0) if n else 0,
    'n_chance_torso': n.get('hit_chances', {}).get('torso', 0) if n else 0,
    'n_chance_left_leg': n.get('hit_chances', {}).get('left_leg', 0) if n else 0,
    'n_chance_right_leg': n.get('hit_chances', {}).get('right_leg', 0) if n else 0,
    'total_hp': total_hp,
    'w_range': wa.get('range', wp.get('range', 1)),
    'w_ap': wa.get('ap_cost', wp.get('ap_cost', 3)),
    'w_ap_primary': wp.get('ap_cost', 3),
    'w_ap_secondary': ws.get('ap_cost', 3),
    'w_range_primary': wp.get('range', 1),
    'w_range_secondary': ws.get('range', 1),
    'w_secondary_active': 1 if use_secondary else 0,
    'w_mode': mode_name,
    'w_name': w.get('name', c.get('active_hand', 'unarmed')),
    'attack_label': c.get('attack_mode_label', ''),
    'w_is_burst': 1 if c.get('is_burst', False) else 0,
    'active_hand': active_hand,
    'cur_usable': 1 if hand_usable(cur_eq) else 0,
    'off_usable': 1 if hand_usable(off_eq) else 0,
    'heal_pid': heal.get('pid', 0) if heal else 0,
    'heal_name': heal.get('name', '') if heal else '',
}, separators=(',',':')))
")
        # Parse all fields from one JSON blob (shlex.quote to prevent injection)
        if [ -z "$info" ]; then
            echo "    WARN: failed to read combat state, retrying..."
            sleep 0.5
            continue
        fi
        local ap=0 hp=0 max_hp=0 n_alive=0 n_engaged=0 engaged_names='' n_id=0 n_dist=999 n_tile=0 n_name='?' n_hp=0 total_hp=0 free_move=0 w_range=1 w_ap=3 w_name='unarmed' w_mode='primary' w_is_burst=0 heal_pid=0 heal_name=''
        local w_ap_primary=3 w_ap_secondary=3 w_range_primary=1 w_range_secondary=1 w_secondary_active=0 attack_label='' active_hand='right' cur_usable=1 off_usable=0
        local n_has_ranged=0 n_chance_uncalled=0 n_chance_torso=0 n_chance_left_leg=0 n_chance_right_leg=0
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

        echo "  Round $round: AP=$ap(+${free_move}fm) HP=$hp/$max_hp [weapon: $w_name $w_mode rng=$w_range ap=$w_ap] vs $n_name($n_hp hp, dist=$n_dist) [$n_engaged engaged, $n_alive total]"

        # If active hand cannot currently attack (typically empty gun), switch hands if offhand can.
        if [ "$cur_usable" -eq 0 ] && [ "$off_usable" -eq 1 ] && [ "$ap" -gt 0 ]; then
            echo "    Active hand can't attack; switching hands"
            cmd '{"type":"switch_hand"}'
            sleep 0.4
            wait_tick_advance 5
            action_count=$((action_count + 1))
            continue
        fi

        # Avoid burst mode by default for autonomous safety unless no other mode is available.
        if [ "$w_is_burst" -eq 1 ] && [ "$ap" -gt 0 ]; then
            echo "    Switching out of burst mode for safer fire control"
            cmd '{"type":"cycle_attack_mode"}'
            sleep 0.3
            wait_tick_advance 5
            action_count=$((action_count + 1))
            continue
        fi

        # Choose primary vs secondary attack mode by range/AP efficiency.
        local desired_secondary="$w_secondary_active"
        local can_primary=0 can_secondary=0
        [ "$w_range_primary" -ge "$n_dist" ] && can_primary=1
        [ "$w_range_secondary" -ge "$n_dist" ] && can_secondary=1
        if [ "$can_primary" -eq 1 ] && [ "$can_secondary" -eq 1 ]; then
            [ "$w_ap_secondary" -lt "$w_ap_primary" ] && desired_secondary=1 || desired_secondary=0
        elif [ "$can_secondary" -eq 1 ] && [ "$can_primary" -eq 0 ]; then
            desired_secondary=1
        elif [ "$can_primary" -eq 1 ] && [ "$can_secondary" -eq 0 ]; then
            desired_secondary=0
        else
            [ "$w_range_secondary" -gt "$w_range_primary" ] && desired_secondary=1 || desired_secondary=0
        fi
        if [ "$desired_secondary" -ne "$w_secondary_active" ] && [ "$ap" -gt 0 ]; then
            echo "    Cycling attack mode for better AP/range fit"
            cmd '{"type":"cycle_attack_mode"}'
            sleep 0.3
            wait_tick_advance 5
            action_count=$((action_count + 1))
            continue
        fi

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
                _dbg_end "do_combat" "fled_stuck" "$_ds"
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
                    _dbg_end "do_combat" "fled_critical" "$_ds"
                    return 1
                fi
                # Flee failed, try end turn
                cmd '{"type":"end_turn"}'
                wait_my_turn
                round=$((round + 1))
                continue
            fi
        fi

        # Heal if low HP (prefer stimpak, fallback to other heal items)
        if [ "$max_hp" -gt 0 ]; then
            local hp_pct=$((hp * 100 / max_hp))
            if [ $hp_pct -lt $heal_pct ] && [ "$ap" -ge 2 ] && [ "$heal_pid" -gt 0 ]; then
                echo "    Healing with ${heal_name:-item $heal_pid} (HP $hp_pct%)"
                local hp_before=$hp
                cmd "{\"type\":\"use_combat_item\",\"item_pid\":$heal_pid}"
                sleep 1
                wait_tick_advance 10
                local hp_after=$(py "print(d.get('character',{}).get('derived_stats',{}).get('current_hp',0))" 2>/dev/null)
                if [ "${hp_after:-0}" -le "$hp_before" ]; then
                    echo "    Heal attempt failed with ${heal_name:-pid $heal_pid} — trying alternatives"
                    _combat_failed_heal_pid=$heal_pid
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
            echo "    Attacking $n_name (uncalled ${n_chance_uncalled}%)"
            cmd "{\"type\":\"attack\",\"target_id\":$n_id}"
            sleep 0.5
            wait_idle 20
            wait_tick_advance 5
            action_count=$((action_count + 1))

            # Check for attack failure in debug output
            local dbg=$(last_debug)
            if [[ "$dbg" == *"no ammo"* ]]; then
                if [ "$off_usable" -eq 1 ] && [ "$ap" -gt 0 ]; then
                    echo "    Out of ammo — switching to offhand"
                    cmd '{"type":"switch_hand"}'
                    sleep 0.4
                    wait_tick_advance 5
                    action_count=$((action_count + 1))
                    consec_fail=0
                    continue
                fi
                echo "    Out of ammo — reloading"
                local ap_before_reload=$ap
                cmd '{"type":"reload_weapon"}'
                sleep 0.5
                wait_tick_advance 5 || true
                local ap_after_reload=$(py "print(d.get('combat',{}).get('current_ap',0))" 2>/dev/null)
                local reload_dbg=$(last_debug)
                if { [[ "${ap_after_reload:-}" =~ ^[0-9]+$ ]] && [ "$ap_after_reload" -lt "$ap_before_reload" ]; } || [[ "$reload_dbg" == reload_weapon:* ]]; then
                    action_count=$((action_count + 1))
                    consec_fail=0
                    continue
                fi
                consec_fail=$((consec_fail + 1))
                echo "    Reload failed: $reload_dbg [consec_fail=$consec_fail]"
            elif [[ "$dbg" == *"REJECTED"* ]] || [[ "$dbg" == *"no path"* ]] || [[ "$dbg" == *"failed"* ]] || [[ "$dbg" == *"busy"* ]]; then
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
