# executor_dialogue.sh — Dialogue, persona, and thought system
#
# Sourced by executor.sh. Depends on: cmd, py, field, context, last_debug,
# wait_idle, wait_tick_advance, wait_context, muse, note,
# GAME_DIR, STATE, CMD.

# ─── Persona & Thought Log ────────────────────────────────────────────

PERSONA_FILE="$GAME_DIR/persona.md"
THOUGHT_LOG="$GAME_DIR/thought_log.md"
PROJECT_ROOT="$(cd "$GAME_DIR/.." && pwd)"
DEFAULT_PERSONA="$PROJECT_ROOT/docs/default-persona.md"
DIALOGUE_HELPER="$PROJECT_ROOT/scripts/executor_dialogue_helpers.py"

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
        python3 "$DIALOGUE_HELPER" persona-section \
            --persona "$PERSONA_FILE" \
            --section "$section"
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
    python3 "$DIALOGUE_HELPER" persona-append-evolution \
        --persona "$PERSONA_FILE" \
        --entry "$evolution_entry"

    echo "Persona evolved: $title"

    # Also log to thought log
    think "$title (Evolution)" "Experience shifted my values. $happened Changed: $changed"
}

# ─── Dialogue Context ────────────────────────────────────────────────

DIALOGUE_HISTORY="$GAME_DIR/.dialogue_session.json"

_dialogue_history_clear() {
    echo '[]' > "$DIALOGUE_HISTORY"
}

_dialogue_history_append() {
    # Record current dialogue node before selecting an option.
    # Args: $1 = selected option index
    local index="$1"
    python3 "$DIALOGUE_HELPER" append-history \
        --state "$STATE" \
        --history "$DIALOGUE_HISTORY" \
        --index "$index" \
        2>/dev/null
}

dialogue_assess() {
    # Structured dialogue briefing — shows NPC, options, conversation history,
    # character state, active quests, sub-objectives, and reminders.
    python3 "$DIALOGUE_HELPER" assess \
        --state "$STATE" \
        --history "$DIALOGUE_HISTORY" \
        --objectives "$GAME_DIR/objectives.md"
}

select_option() {
    local _ds=$(_dbg_ts)
    _dbg_start "select_option" "$1"
    local index="${1:?Usage: select_option <index>}"

    # Record current dialogue state before selecting
    _dialogue_history_append "$index"

    # Issue the select command
    cmd "{\"type\":\"select_dialogue\",\"index\":$index}"
    sleep 1

    # Wait for dialogue to advance or end
    wait_tick_advance 10
    sleep 0.5

    # Show next briefing if still in dialogue
    local ctx=$(context)
    if [ "$ctx" = "gameplay_dialogue" ]; then
        dialogue_assess
        _dbg_end "select_option" "ok" "$_ds"
    else
        echo "(Dialogue ended — context: $ctx)"
        post_dialogue_hook
        _dbg_end "select_option" "dialogue_ended" "$_ds"
    fi
}

_dialogue_muse_generate() {
    # Generate in-character dialogue commentary using Sonnet.
    local prompt
    prompt=$(python3 "$DIALOGUE_HELPER" muse-prompt \
        --state "$STATE" \
        --history "$DIALOGUE_HISTORY" \
        --persona "$GAME_DIR/persona.md" \
        --objectives "$GAME_DIR/objectives.md" \
        2>/dev/null)

    [ -z "$prompt" ] && return

    local thought
    thought=$(unset CLAUDECODE && claude -p --model sonnet "$prompt" 2>/dev/null)
    if [ -n "$thought" ] && [ ${#thought} -ge 5 ]; then
        muse "$thought"
    fi
}

dialogue_muse() {
    # Generate in-character commentary on current dialogue using Sonnet.
    # Runs in background (same pattern as combat_quip).
    ( _dialogue_muse_generate ) &
}

# ─── Talk & Dialogue Hooks ───────────────────────────────────────────

talk() {
    local _ds=$(_dbg_ts)
    _dbg_start "talk" "$*"
    local obj_id="$1"; shift

    # Clear conversation history for new dialogue
    _dialogue_history_clear

    cmd "{\"type\":\"talk_to\",\"object_id\":$obj_id}"
    sleep 1.5

    if [ $# -eq 0 ]; then
        # No options specified — wait for dialogue and show briefing
        if ! wait_context "gameplay_dialogue" 15; then
            _dbg_end "talk" "no_dialogue" "$_ds"
            return 1
        fi
        sleep 0.5
        dialogue_assess
        _end_status
        _dbg_end "talk" "ok" "$_ds"
    else
        # Options specified — select them in sequence with history tracking
        for opt in "$@"; do
            if ! wait_context "gameplay_dialogue" 15; then
                _dbg_end "talk" "lost_dialogue" "$_ds"
                return 1
            fi
            sleep 0.5
            _dialogue_history_append "$opt"
            cmd "{\"type\":\"select_dialogue\",\"index\":$opt}"
            sleep 1
        done
        # Auto-capture dialogue info when conversation ends
        post_dialogue_hook
        _end_status
        _dbg_end "talk" "ok" "$_ds"
    fi
}

# ─── Barter ───────────────────────────────────────────────────────────

barter_status() {
    # Print current barter tables and computed trade info from state.
    py "
b = d.get('barter', {})
if not b:
    print('Not in barter context')
else:
    print(f\"Merchant: {b.get('merchant_name', '?')} id={b.get('merchant_id', '?')}\")
    print(f\"Barter modifier: {b.get('barter_modifier', '?')}\")
    print(f\"Player caps: {b.get('player_caps', 0)} | Merchant caps: {b.get('merchant_caps', 0)}\")
    ti = b.get('trade_info', {})
    if ti:
        succ = ' OK' if ti.get('trade_will_succeed') else ' NEED MORE'
        print(f\"Offer value: {ti.get('player_offer_value', 0)} | Merchant wants: {ti.get('merchant_wants', 0)}{succ}\")
    def item_detail(i):
        s = f\"{i.get('name','?')} x{i.get('quantity',1)} pid={i.get('pid')} cost={i.get('cost',0)}\"
        ws = i.get('weapon_stats')
        if ws:
            s += f\" [dmg:{ws.get('damage_min',0)}-{ws.get('damage_max',0)} range:{ws.get('range_primary','?')} AP:{ws.get('ap_cost_primary','?')}]\"
        ars = i.get('armor_stats')
        if ars:
            s += f\" [AC:{ars.get('armor_class',0)} DR:{ars.get('damage_resistance',{}).get('normal',0)}%]\"
        ams = i.get('ammo_stats')
        if ams:
            s += f\" [cal:{ams.get('caliber',0)} dmgMul:{ams.get('damage_multiplier',1)}/{ams.get('damage_divisor',1)}]\"
        return s
    mi = b.get('merchant_inventory', [])
    if mi:
        print(f'Merchant inventory ({len(mi)} items):')
        for i in mi:
            print(f'  {item_detail(i)}')
    po = b.get('player_offer', [])
    mo = b.get('merchant_offer', [])
    if po:
        print('Player offer:')
        for i in po:
            print(f'  {item_detail(i)}')
    if mo:
        print('Merchant offer:')
        for i in mo:
            print(f'  {item_detail(i)}')
"
}

barter_offer() {
    local pid="${1:?Usage: barter_offer <pid> [qty]}"
    local qty="${2:-1}"
    cmd "{\"type\":\"barter_offer\",\"item_pid\":$pid,\"quantity\":$qty}"
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

barter_remove_offer() {
    local pid="${1:?Usage: barter_remove_offer <pid> [qty]}"
    local qty="${2:-1}"
    cmd "{\"type\":\"barter_remove_offer\",\"item_pid\":$pid,\"quantity\":$qty}"
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

barter_request() {
    local pid="${1:?Usage: barter_request <pid> [qty]}"
    local qty="${2:-1}"
    cmd "{\"type\":\"barter_request\",\"item_pid\":$pid,\"quantity\":$qty}"
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

barter_remove_request() {
    local pid="${1:?Usage: barter_remove_request <pid> [qty]}"
    local qty="${2:-1}"
    cmd "{\"type\":\"barter_remove_request\",\"item_pid\":$pid,\"quantity\":$qty}"
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

barter_confirm() {
    # Native confirm path: injects barter UI's confirm key.
    cmd '{"type":"barter_confirm"}'
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

barter_talk() {
    cmd '{"type":"barter_talk"}'
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

barter_cancel() {
    cmd '{"type":"barter_cancel"}'
    sleep 0.2
    wait_tick_advance 5 || true
    echo "$(last_debug)"
}

post_dialogue_hook() {
    # Auto-record NPC conversation summary after dialogue ends.
    # Uses conversation history for multi-line summary when available.
    local npc_name=$(py "print(d.get('dialogue', {}).get('speaker_name', 'Unknown'))")

    if [ -z "$npc_name" ] || [ "$npc_name" = "Unknown" ] || [ "$npc_name" = "null" ]; then
        return 0
    fi

    local map_name=$(field "map.name")

    # Build conversation summary from history if available
    local summary=""
    if [ -f "$DIALOGUE_HISTORY" ]; then
        summary=$(python3 "$DIALOGUE_HELPER" history-summary \
            --history "$DIALOGUE_HISTORY" \
            2>/dev/null)
    fi

    if [ -n "$summary" ]; then
        local entry
        entry=$(printf '- **%s** (%s):\n%s' "$npc_name" "$map_name" "$summary")
        note "characters" "$entry" 2>/dev/null
    else
        local reply=$(py "
reply = d.get('dialogue', {}).get('reply_text', '')
print(reply[:120] if reply else '')
")
        local entry="- **${npc_name}** (${map_name}): ${reply}"
        note "characters" "$entry" 2>/dev/null
    fi
    echo "AUTO-NOTE: Talked to $npc_name"
}

# Auto-initialize persona on source
init_persona
