#!/usr/bin/env bash
# Smoke test for the agent bridge file-based protocol.
# Run this while Fallout 2 CE (with AGENT_BRIDGE=ON) is running in game/.

set -euo pipefail

GAME_DIR="$(cd "$(dirname "$0")/../game" && pwd)"
STATE_FILE="$GAME_DIR/agent_state.json"
CMD_FILE="$GAME_DIR/agent_cmd.json"
CMD_TMP="$GAME_DIR/agent_cmd.tmp"

echo "=== Agent Bridge Smoke Test ==="
echo "Game dir: $GAME_DIR"
echo ""

# 1. Check state file exists
echo "1. Checking for state file..."
if [ ! -f "$STATE_FILE" ]; then
    echo "   FAIL: $STATE_FILE not found. Is the game running with AGENT_BRIDGE=ON?"
    exit 1
fi
echo "   OK: State file exists"

# 2. Read initial state
echo "2. Reading initial state..."
TICK1=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['tick'])")
echo "   Tick: $TICK1"

# 3. Wait a moment and check tick advances
echo "3. Checking tick advances..."
sleep 0.2
TICK2=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['tick'])")
echo "   Tick: $TICK2"
if [ "$TICK2" -gt "$TICK1" ]; then
    echo "   OK: Tick advanced ($TICK1 -> $TICK2)"
else
    echo "   FAIL: Tick did not advance"
    exit 1
fi

# 4. Validate state JSON structure
echo "4. Validating state JSON structure..."
python3 -c "
import json, sys
state = json.load(open('$STATE_FILE'))
required = ['tick', 'timestamp_ms', 'game_mode', 'game_mode_flags', 'game_state', 'mouse', 'screen']
missing = [k for k in required if k not in state]
if missing:
    print(f'   FAIL: Missing keys: {missing}')
    sys.exit(1)
if 'x' not in state['mouse'] or 'y' not in state['mouse']:
    print('   FAIL: mouse missing x/y')
    sys.exit(1)
if 'width' not in state['screen'] or 'height' not in state['screen']:
    print('   FAIL: screen missing width/height')
    sys.exit(1)
print('   OK: All required fields present')
print(f\"   Game mode: {state['game_mode']} flags={state['game_mode_flags']}\")
print(f\"   Mouse: ({state['mouse']['x']}, {state['mouse']['y']})\")
print(f\"   Screen: {state['screen']['width']}x{state['screen']['height']}\")
"

# 5. Send mouse move command
echo "5. Sending mouse_move command..."
echo '{"commands":[{"type":"mouse_move","x":320,"y":240}]}' > "$CMD_TMP"
mv "$CMD_TMP" "$CMD_FILE"
sleep 0.2

# 6. Verify command was consumed
echo "6. Checking command file was consumed..."
if [ -f "$CMD_FILE" ]; then
    echo "   FAIL: Command file still exists (not consumed)"
    exit 1
fi
echo "   OK: Command file consumed"

# 7. Verify mouse position updated
echo "7. Checking mouse position..."
python3 -c "
import json
state = json.load(open('$STATE_FILE'))
mx, my = state['mouse']['x'], state['mouse']['y']
print(f'   Mouse position: ({mx}, {my})')
if mx == 320 and my == 240:
    print('   OK: Mouse moved to (320, 240)')
else:
    print(f'   WARN: Mouse not at expected position (may be clamped by screen)')
"

echo ""
echo "=== All checks passed ==="
