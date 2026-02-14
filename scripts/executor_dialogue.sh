# executor_dialogue.sh — Dialogue, persona, and thought system
#
# Sourced by executor.sh. Depends on: cmd, py, field, context, last_debug,
# wait_idle, wait_tick_advance, wait_context, muse, note,
# _walk_to_object, GAME_DIR, STATE, CMD.

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

# ─── Dialogue Context ────────────────────────────────────────────────

DIALOGUE_HISTORY="$GAME_DIR/.dialogue_session.json"

_dialogue_history_clear() {
    echo '[]' > "$DIALOGUE_HISTORY"
}

_dialogue_history_append() {
    # Record current dialogue node before selecting an option.
    # Args: $1 = selected option index
    local index="$1"
    python3 -c "
import json, os

state_file = '$STATE'
hist_file = '$DIALOGUE_HISTORY'

try:
    with open(state_file) as f:
        d = json.load(f)
except:
    d = {}

dlg = d.get('dialogue', {})
reply = dlg.get('reply_text', '')[:200]
options = dlg.get('options', [])
idx = $index
option_text = ''
if idx < len(options):
    opt = options[idx]
    option_text = opt if isinstance(opt, str) else opt.get('text', '?')
    option_text = option_text[:120]

try:
    with open(hist_file) as f:
        history = json.load(f)
except:
    history = []

history.append({
    'reply': reply,
    'selected': idx,
    'option_text': option_text
})

with open(hist_file, 'w') as f:
    json.dump(history, f)
" 2>/dev/null
}

dialogue_assess() {
    # Structured dialogue briefing — shows NPC, options, conversation history,
    # character state, active quests, sub-objectives, and reminders.
    python3 -c "
import json, os

with open('$STATE') as f:
    d = json.load(f)

dlg = d.get('dialogue', {})
speaker = dlg.get('speaker_name', 'Unknown')
reply = dlg.get('reply_text', '')
options = dlg.get('options', [])
map_name = d.get('map', {}).get('name', '?')

# NPC + Reply
print('=== DIALOGUE ===')
print(f'NPC: {speaker} | Map: {map_name}')
if reply:
    print(f'Reply: \"{reply}\"')
if options:
    print('Options:')
    for i, opt in enumerate(options):
        text = opt if isinstance(opt, str) else opt.get('text', '?')
        print(f'  [{i}] \"{text}\"')
print()

# Conversation history
hist_file = '$DIALOGUE_HISTORY'
history = []
try:
    with open(hist_file) as f:
        history = json.load(f)
except:
    pass
if history:
    print('--- CONVERSATION SO FAR ---')
    for i, h in enumerate(history):
        print(f'  ({i+1}) \"{h.get(\"reply\", \"...\")[:80]}\" -> You chose: \"{h.get(\"option_text\", \"?\")[:60]}\"')
    print()

# Character state
ch = d.get('character', {})
ds = ch.get('derived_stats', {})
inv = d.get('inventory', {})
equipped = inv.get('equipped', {})
weapon = 'unarmed'
for slot in ['right_hand', 'left_hand']:
    eq = equipped.get(slot)
    if eq:
        weapon = eq.get('name', weapon)
        break
armor_eq = equipped.get('armor')
armor = armor_eq.get('name', 'none') if armor_eq else 'none'
caps = sum(it.get('quantity', 0) for it in inv.get('items', []) if it.get('pid') == 41)
print('--- CHARACTER STATE ---')
print(f'  HP: {ds.get(\"current_hp\", \"?\")}/{ds.get(\"max_hp\", \"?\")} | Level: {ch.get(\"level\", \"?\")} | Caps: {caps}')
print(f'  Weapon: {weapon} | Armor: {armor}')
print()

# Active quests
quests = d.get('quests', [])
active = [q for q in quests if not q.get('completed', False)]
if active:
    print('--- ACTIVE QUESTS ---')
    for q in active:
        loc = q.get('location', '')
        desc = q.get('description', '')
        loc_str = f' ({loc})' if loc else ''
        print(f'  {q.get(\"name\", \"?\")}{loc_str} -- {desc[:60]}')
    print()

# Sub-objectives
obj_file = '$GAME_DIR/objectives.md'
try:
    with open(obj_file) as f:
        objectives = [line.strip() for line in f if line.strip()]
    if objectives:
        print('--- SUB-OBJECTIVES ---')
        for obj in objectives:
            print(f'  {obj}')
        print()
except:
    pass

# Reminders
print('--- REMINDERS ---')
print('  You can RECALL knowledge: recall \"keyword\" to search notes')
print('  You can BARTER with this NPC: select barter option or use barter command')
print('  You can NOTE anything interesting: note \"category\" \"text\"')
"
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
    prompt=$(python3 -c "
import json, re, sys, os

# Read game state
try:
    with open('$STATE') as f:
        d = json.load(f)
except:
    sys.exit(0)

dlg = d.get('dialogue', {})
speaker = dlg.get('speaker_name', 'Unknown')
reply = dlg.get('reply_text', '')
options = dlg.get('options', [])
map_name = d.get('map', {}).get('name', '?')

if not reply and not options:
    sys.exit(0)

# Read persona
name = 'Wanderer'
persona = 'sarcastic, witty, audacious rogue with main-character energy'
try:
    with open('$GAME_DIR/persona.md') as f:
        text = f.read()
    m = re.search(r'^# (.+)', text)
    if m:
        name = m.group(1).strip()
    parts = []
    for section in ['Personality', 'Values', 'Dialogue Style']:
        m = re.search(r'## ' + section + r'\n(.*?)(?=\n## |\Z)', text, re.DOTALL)
        if m:
            parts.append(m.group(1).strip())
    if parts:
        persona = ' | '.join(parts)
except:
    pass

# Conversation history
history_str = ''
try:
    with open('$DIALOGUE_HISTORY') as f:
        history = json.load(f)
    if history:
        lines = []
        for h in history[-5:]:
            lines.append(f'NPC: \"{h.get(\"reply\",\"...\")[:60]}\" -> You chose: \"{h.get(\"option_text\",\"?\")[:40]}\"')
        history_str = chr(10).join(lines)
except:
    pass

# Options text
opt_lines = []
for i, opt in enumerate(options):
    text = opt if isinstance(opt, str) else opt.get('text', '?')
    opt_lines.append(f'[{i}] \"{text}\"')
options_str = chr(10).join(opt_lines)

# Character state
ch = d.get('character', {})
ds = ch.get('derived_stats', {})
inv = d.get('inventory', {})
equipped = inv.get('equipped', {})
weapon = 'unarmed'
for slot in ['right_hand', 'left_hand']:
    eq = equipped.get(slot)
    if eq:
        weapon = eq.get('name', weapon)
        break
armor_eq = equipped.get('armor')
armor = armor_eq.get('name', 'none') if armor_eq else 'none'
caps = sum(it.get('quantity', 0) for it in inv.get('items', []) if it.get('pid') == 41)

# Active quests
quests = d.get('quests', [])
active = [q for q in quests if not q.get('completed', False)]
quest_str = ', '.join(q.get('name', '?') for q in active[:5]) if active else 'none'

# Sub-objectives
obj_str = 'none'
try:
    with open('$GAME_DIR/objectives.md') as f:
        objectives = [line.strip() for line in f if line.strip()]
    if objectives:
        obj_str = ', '.join(objectives[:5])
except:
    pass

hist_block = f'Conversation so far:\\n{history_str}' if history_str else 'This is the start of the conversation.'

prompt = f'''You are {name}. Voice: {persona}

Talking to {speaker} in {map_name}.
{hist_block}
Current NPC reply: \"{reply[:200]}\"
Your options:
{options_str}

Your quests: {quest_str}
Your goals right now: {obj_str}
Your state: HP {ds.get('current_hp','?')}/{ds.get('max_hp','?')}, Caps {caps}, wearing {armor}, wielding {weapon}

Write a short in-character inner thought (under 25 words) reacting to these dialogue options. What catches your eye? What matters given your goals? No quotes, no narration.'''

print(prompt)
" 2>/dev/null)

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

    _walk_to_object "$obj_id" || true
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
        summary=$(python3 -c "
import json
try:
    with open('$DIALOGUE_HISTORY') as f:
        history = json.load(f)
    if history:
        lines = []
        for h in history:
            r = h.get('reply', '')[:80]
            o = h.get('option_text', '')[:60]
            lines.append(f'  NPC: \"{r}\" -> Chose: \"{o}\"')
        print('\n'.join(lines))
except:
    pass
" 2>/dev/null)
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
