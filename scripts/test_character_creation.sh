#!/usr/bin/env bash
# Integration test: Movie → Main Menu → Character Selector → Character Editor → Gameplay
# Verifies character stats survive into actual gameplay.
# Run this while Fallout 2 CE (with AGENT_BRIDGE=ON) is running in game/.

set -euo pipefail

GAME_DIR="$(cd "$(dirname "$0")/../game" && pwd)"
STATE_FILE="$GAME_DIR/agent_state.json"
CMD_FILE="$GAME_DIR/agent_cmd.json"
CMD_TMP="$GAME_DIR/agent_cmd.tmp"

send_cmd() {
    echo "$1" > "$CMD_TMP"
    mv "$CMD_TMP" "$CMD_FILE"
}

read_context() {
    python3 -c "
import json
try:
    state = json.load(open('$STATE_FILE'))
    print(state.get('context', 'NO_CONTEXT'))
except:
    print('NO_FILE')
"
}

read_state() {
    python3 -c "
import json
try:
    state = json.load(open('$STATE_FILE'))
    print(json.dumps(state, indent=2))
except Exception as e:
    print(f'Error: {e}')
"
}

wait_for_context() {
    local target="$1"
    local timeout="${2:-30}"
    local elapsed=0
    echo "   Waiting for context '$target' (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local ctx=$(read_context)
        if [ "$ctx" = "$target" ]; then
            echo "   Got context '$target' after ${elapsed}s"
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    echo "   TIMEOUT waiting for '$target' (last context: $(read_context))"
    return 1
}

wait_for_not_context() {
    local avoid="$1"
    local timeout="${2:-30}"
    local elapsed=0
    echo "   Waiting to leave context '$avoid' (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local ctx=$(read_context)
        if [ "$ctx" != "$avoid" ]; then
            echo "   Left '$avoid', now in '$ctx' after ${elapsed}s"
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    echo "   TIMEOUT leaving '$avoid'"
    return 1
}

echo "=== Character Creation → Gameplay Verification Test ==="
echo "Game dir: $GAME_DIR"
echo ""

# 0. Wait for state file
echo "--- Phase 0: Wait for game ---"
for i in $(seq 1 30); do
    if [ -f "$STATE_FILE" ]; then break; fi
    sleep 1
done
if [ ! -f "$STATE_FILE" ]; then
    echo "FAIL: No state file after 30s. Is the game running?"
    exit 1
fi
echo "   State file found"
echo ""

# 1. Skip intro movies
echo "--- Phase 1: Skip Intro Movies ---"
SKIP_ATTEMPTS=0
while [ "$(read_context)" = "movie" ] && [ $SKIP_ATTEMPTS -lt 20 ]; do
    echo "   Sending escape (attempt $((SKIP_ATTEMPTS+1)), context: $(read_context))..."
    send_cmd '{"commands":[{"type":"key_press","key":"escape"}]}'
    sleep 1
    SKIP_ATTEMPTS=$((SKIP_ATTEMPTS + 1))
done
echo "   Context: $(read_context)"
echo ""

# 2. Main Menu — select New Game
echo "--- Phase 2: Main Menu ---"
wait_for_context "main_menu" 15 || { read_state; exit 1; }
echo "   Sending main_menu_select 'new_game'..."
send_cmd '{"commands":[{"type":"main_menu_select","option":"new_game"}]}'
echo ""

# 3. Character Selector — select Create Custom
echo "--- Phase 3: Character Selector ---"
wait_for_context "character_selector" 15 || { read_state; exit 1; }
echo "   Sending char_selector_select 'create_custom'..."
send_cmd '{"commands":[{"type":"char_selector_select","option":"create_custom"}]}'
echo ""

# 4. Character Editor — read defaults, then configure
echo "--- Phase 4: Character Editor ---"
wait_for_context "character_editor" 15 || { read_state; exit 1; }

echo "   Initial state:"
python3 -c "
import json
state = json.load(open('$STATE_FILE'))
char = state.get('character', {})
print(f'     Name: {char.get(\"name\")}')
print(f'     Remaining points: {char.get(\"remaining_points\")}')
print(f'     Tagged skills remaining: {char.get(\"tagged_skills_remaining\")}')
print(f'     SPECIAL: {json.dumps(char.get(\"special\", {}))}')
"
echo ""

# 5. Configure character
echo "--- Phase 5: Configure Character ---"
echo "   Target: Name=Claude, S6/P8/E4/C4/I9/A6/L3, Gifted+SmallFrame, SmallGuns+Speech+Lockpick"
echo ""
echo "   Step 5a: set_special..."
send_cmd '{
    "commands": [{
        "type": "set_special",
        "strength": 6, "perception": 8, "endurance": 4,
        "charisma": 4, "intelligence": 9, "agility": 6, "luck": 3
    }]
}'
sleep 0.5

echo "   Step 5b: select_traits..."
send_cmd '{
    "commands": [{
        "type": "select_traits",
        "traits": ["gifted", "small_frame"]
    }]
}'
sleep 0.5

echo "   Step 5c: tag_skills..."
send_cmd '{
    "commands": [{
        "type": "tag_skills",
        "skills": ["small_guns", "speech", "lockpick"]
    }]
}'
sleep 0.5

echo "   Step 5d: set_name..."
send_cmd '{
    "commands": [{
        "type": "set_name",
        "name": "Claude"
    }]
}'
sleep 1

echo ""
echo "   Verifying editor state after configuration:"
python3 -c "
import json, sys
state = json.load(open('$STATE_FILE'))
char = state.get('character', {})
print(f'     Name: {char.get(\"name\")}')
print(f'     Remaining points: {char.get(\"remaining_points\")}')
print(f'     Tagged skills remaining: {char.get(\"tagged_skills_remaining\")}')
print(f'     SPECIAL: {json.dumps(char.get(\"special\", {}))}')
print(f'     Traits: {char.get(\"traits\", [])}')
print(f'     Tagged skills: {char.get(\"tagged_skills\", [])}')

errors = []
s = char.get('special', {})
if s.get('strength') != 6: errors.append('strength != 6')
if s.get('perception') != 8: errors.append('perception != 8')
if s.get('endurance') != 4: errors.append('endurance != 4')
if s.get('charisma') != 4: errors.append('charisma != 4')
if s.get('intelligence') != 9: errors.append('intelligence != 9')
if s.get('agility') != 6: errors.append('agility != 6')
if s.get('luck') != 3: errors.append('luck != 3')
if char.get('remaining_points') != 0: errors.append('remaining_points != 0')
if char.get('tagged_skills_remaining') != 0: errors.append('tagged_skills_remaining != 0')
if char.get('name') != 'Claude': errors.append(f\"name != Claude (got {char.get('name')})\")
traits = char.get('traits', [])
if 'gifted' not in traits or 'small_frame' not in traits: errors.append(f'traits mismatch: {traits}')
tagged = char.get('tagged_skills', [])
if 'small_guns' not in tagged or 'speech' not in tagged or 'lockpick' not in tagged: errors.append(f'tagged_skills mismatch: {tagged}')

if errors:
    for e in errors: print(f'     FAIL: {e}')
    sys.exit(1)
else:
    print('     ALL EDITOR VALIDATIONS PASSED')
"
echo ""

# 6. Finish character creation
echo "--- Phase 6: Finish Character Creation ---"
send_cmd '{"commands":[{"type":"finish_character_creation"}]}'
sleep 2
echo "   Context after finish: $(read_context)"
echo ""

# 7. Skip Elder movie
echo "--- Phase 7: Skip Elder Movie ---"
SKIP_ATTEMPTS=0
while [ "$(read_context)" = "movie" ] && [ $SKIP_ATTEMPTS -lt 20 ]; do
    echo "   Sending escape to skip elder movie (attempt $((SKIP_ATTEMPTS+1)))..."
    send_cmd '{"commands":[{"type":"key_press","key":"escape"}]}'
    sleep 1
    SKIP_ATTEMPTS=$((SKIP_ATTEMPTS + 1))
done
echo "   Context: $(read_context)"
echo ""

# 8. Wait for gameplay and verify character
echo "--- Phase 8: Verify Character in Gameplay ---"
wait_for_context "gameplay" 30 || {
    echo "   Current context: $(read_context)"
    echo "   Full state:"
    read_state
    exit 1
}

# Give the game a moment to fully load the map
sleep 3

echo "   GAMEPLAY CHARACTER STATE:"
python3 -c "
import json, sys
state = json.load(open('$STATE_FILE'))
assert state['context'] == 'gameplay', f\"Expected gameplay, got {state['context']}\"

char = state.get('character', {})
print(f'     Name: {char.get(\"name\")}')
print(f'     Level: {char.get(\"level\")}')
print(f'     Experience: {char.get(\"experience\")}')
print()

special = char.get('special', {})
print(f'     SPECIAL (base):')
for stat in ['strength', 'perception', 'endurance', 'charisma', 'intelligence', 'agility', 'luck']:
    print(f'       {stat}: {special.get(stat)}')
print()

derived = char.get('derived_stats', {})
print(f'     Derived stats:')
for k, v in derived.items():
    print(f'       {k}: {v}')
print()

traits = char.get('traits', [])
print(f'     Traits: {traits}')

tagged = char.get('tagged_skills', [])
print(f'     Tagged skills: {tagged}')

skills = char.get('skills', {})
print(f'     All skills:')
for k, v in sorted(skills.items()):
    tag_mark = ' [TAGGED]' if k in tagged else ''
    print(f'       {k}: {v}{tag_mark}')
print()

# Final validation against expected values
errors = []
if char.get('name') != 'Claude':
    errors.append(f\"name: expected 'Claude', got '{char.get('name')}'\")
if special.get('strength') != 6: errors.append(f\"strength: expected 6, got {special.get('strength')}\")
if special.get('perception') != 8: errors.append(f\"perception: expected 8, got {special.get('perception')}\")
if special.get('endurance') != 4: errors.append(f\"endurance: expected 4, got {special.get('endurance')}\")
if special.get('charisma') != 4: errors.append(f\"charisma: expected 4, got {special.get('charisma')}\")
if special.get('intelligence') != 9: errors.append(f\"intelligence: expected 9, got {special.get('intelligence')}\")
if special.get('agility') != 6: errors.append(f\"agility: expected 6, got {special.get('agility')}\")
if special.get('luck') != 3: errors.append(f\"luck: expected 3, got {special.get('luck')}\")
if 'gifted' not in traits: errors.append(f\"missing trait 'gifted'\")
if 'small_frame' not in traits: errors.append(f\"missing trait 'small_frame'\")
if 'small_guns' not in tagged: errors.append(f\"missing tagged skill 'small_guns'\")
if 'speech' not in tagged: errors.append(f\"missing tagged skill 'speech'\")
if 'lockpick' not in tagged: errors.append(f\"missing tagged skill 'lockpick'\")
if char.get('level') != 1: errors.append(f\"level: expected 1, got {char.get('level')}\")

print('=' * 50)
if errors:
    print('GAMEPLAY VERIFICATION FAILED:')
    for e in errors:
        print(f'  - {e}')
    sys.exit(1)
else:
    print('GAMEPLAY VERIFICATION PASSED')
    print('Character \"Claude\" is in the game world with correct stats.')
print('=' * 50)
"

echo ""
echo "=== Test Complete ==="
echo "Game is still running — you can check the character screen in-game."
