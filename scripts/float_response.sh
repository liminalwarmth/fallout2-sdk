#!/usr/bin/env bash
# float_response.sh — Claude Code hook (PostToolUse + Stop)
# Broadcasts Claude's text responses as floating text above the player in Fallout 2.
# Fires incrementally: PostToolUse catches text before each tool call,
# Stop catches the final text after the last tool.
# Tracks position in transcript so each text block is sent exactly once.

set -euo pipefail

GAME_DIR="${CLAUDE_PROJECT_DIR}/game"
STATE="$GAME_DIR/agent_state.json"
CMD="$GAME_DIR/agent_cmd.json"
TMP="$GAME_DIR/agent_cmd.tmp"

# Read hook input from stdin
INPUT=$(cat)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Prevent infinite loops (stop hook calling itself)
if [ "$HOOK_EVENT" = "Stop" ] && [ "$STOP_ACTIVE" = "true" ]; then exit 0; fi

# Bail if game isn't running or no state file
if [ ! -f "$STATE" ]; then exit 0; fi

# Only broadcast in gameplay contexts
CONTEXT=$(jq -r '.context // ""' "$STATE" 2>/dev/null || echo "")
case "$CONTEXT" in gameplay_*) ;; *) exit 0 ;; esac

# Bail if no transcript
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then exit 0; fi

# Track how far we've read in the transcript (per session)
TRACK_FILE="/tmp/fallout2_float_${SESSION_ID:-unknown}"
TEXTS_FILE="/tmp/fallout2_float_texts_${SESSION_ID:-unknown}"

LAST_LINE=0
if [ -f "$TRACK_FILE" ]; then
    LAST_LINE=$(cat "$TRACK_FILE" 2>/dev/null || echo 0)
fi

# Extract NEW text blocks since last invocation, sanitize to ASCII 32-126.
# Python writes each block as a JSON-escaped string on its own line to TEXTS_FILE.
# This avoids bash's null-byte stripping problem with $().
PYSCRIPT="/tmp/fallout2_float_extract.py"
cat > "$PYSCRIPT" << 'PYEOF'
import json, sys

transcript = sys.argv[1]
last_line = int(sys.argv[2])
track_file = sys.argv[3]
texts_file = sys.argv[4]

with open(transcript) as f:
    all_lines = f.readlines()

total = len(all_lines)
new_lines = all_lines[last_line:]

SUBS = {
    '\u2014': '--',
    '\u2013': '-',
    '\u2018': "'",
    '\u2019': "'",
    '\u201c': '"',
    '\u201d': '"',
    '\u2026': '...',
    '\u2022': '*',
    '\u00b7': '*',
    '\u2010': '-',
    '\u2011': '-',
    '\u00a0': ' ',
    '\u200b': '',
    '\u2032': "'",
    '\u2033': '"',
    '\u00d7': 'x',
    '\u2192': '->',
    '\u2190': '<-',
    '\u2264': '<=',
    '\u2265': '>=',
    '\u2260': '!=',
}

def sanitize(text):
    for old, new in SUBS.items():
        text = text.replace(old, new)
    return ''.join(c if 32 <= ord(c) <= 126 or c == '\n' else '' for c in text)

# Write each text block as a ready-to-use JSON command, one per line
with open(texts_file, 'w') as out:
    for raw in new_lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue

        msg = entry.get('message', {})
        if msg.get('role') != 'assistant':
            continue

        content = msg.get('content', [])
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'text':
                    t = sanitize(block.get('text', '')).strip()
                    if len(t) >= 10:
                        cmd = json.dumps({"commands": [{"type": "float_thought", "text": t}]})
                        out.write(cmd + '\n')

with open(track_file, 'w') as f:
    f.write(str(total))
PYEOF

python3 "$PYSCRIPT" "$TRANSCRIPT" "$LAST_LINE" "$TRACK_FILE" "$TEXTS_FILE" 2>/dev/null

# Nothing to send
if [ ! -f "$TEXTS_FILE" ] || [ ! -s "$TEXTS_FILE" ]; then exit 0; fi

# Send each text block as a separate float_thought command
while IFS= read -r cmd_json; do
    [ -z "$cmd_json" ] && continue

    # Wait for any pending command to be consumed (up to 500ms)
    for i in 1 2 3 4 5; do
        [ ! -f "$CMD" ] && break
        sleep 0.1
    done

    # Write command via atomic tmp+mv
    echo "$cmd_json" > "$TMP" && mv "$TMP" "$CMD"

    # Brief pause so engine can consume before next one
    sleep 0.2
done < "$TEXTS_FILE"

rm -f "$TEXTS_FILE"
