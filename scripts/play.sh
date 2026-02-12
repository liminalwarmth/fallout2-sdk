#!/bin/bash
# play.sh — Helper functions for driving Fallout 2 via the agent bridge
# Source this file, then call the functions.

GAME_DIR="/Users/alexis.radcliff/fallout2-sdk/game"
STATE_FILE="$GAME_DIR/agent_state.json"
CMD_FILE="$GAME_DIR/agent_cmd.json"

# Send a batch of commands
send_cmd() {
    echo "$1" > "$CMD_FILE"
}

# Send a single command
cmd() {
    send_cmd "{\"commands\":[$1]}"
}

# Read current state, extract a field with python
state_field() {
    python3 -c "
import json, sys
try:
    with open('$STATE_FILE') as f:
        d = json.load(f)
    # Navigate dotted path
    val = d
    for key in '$1'.split('.'):
        if isinstance(val, dict):
            val = val.get(key, None)
        else:
            val = None
            break
    if val is None:
        print('null')
    elif isinstance(val, (dict, list)):
        print(json.dumps(val))
    else:
        print(val)
except:
    print('error')
" 2>/dev/null
}

# Read full state as formatted JSON
state() {
    python3 -m json.tool "$STATE_FILE" 2>/dev/null
}

# Read state, filtered to key fields
state_summary() {
    python3 -c "
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
summary = {
    'tick': d.get('tick'),
    'context': d.get('context'),
    'game_mode_flags': d.get('game_mode_flags'),
}
# Add context-specific fields
ctx = d.get('context', '')
if 'gameplay' in ctx:
    if 'player' in d:
        summary['player'] = d['player']
    if 'map' in d:
        summary['map'] = d['map']
    if 'inventory' in d:
        inv = d['inventory']
        summary['inventory_count'] = len(inv.get('items', []))
        summary['equipped'] = inv.get('equipped', {})
    if 'objects' in d:
        objs = d['objects']
        summary['critters'] = len(objs.get('critters', []))
        summary['items_on_ground'] = len(objs.get('items', []))
        summary['scenery'] = len(objs.get('scenery', []))
        summary['exit_grids'] = len(objs.get('exit_grids', []))
    if 'combat' in d:
        c = d['combat']
        summary['combat_ap'] = c.get('current_ap')
        summary['hostiles'] = len(c.get('hostiles', []))
    if 'dialogue' in d:
        summary['dialogue'] = d['dialogue']
if 'character' in d:
    ch = d['character']
    summary['char_name'] = ch.get('name')
    if 'derived_stats' in ch:
        summary['hp'] = ch['derived_stats'].get('current_hp', ch['derived_stats'].get('max_hp'))
print(json.dumps(summary, indent=2))
" 2>/dev/null
}

# Wait for a specific context, with timeout
wait_for_context() {
    local target="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local ctx=$(state_field context)
        if [ "$ctx" = "$target" ]; then
            return 0
        fi
        sleep 0.3
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT waiting for context '$target' (got '$ctx')"
    return 1
}

# Wait for context to start with a prefix
wait_for_context_prefix() {
    local prefix="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local ctx=$(state_field context)
        if [[ "$ctx" == ${prefix}* ]]; then
            echo "$ctx"
            return 0
        fi
        sleep 0.3
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT waiting for context prefix '$prefix' (got '$ctx')"
    return 1
}

# Skip all intro movies one at a time, carefully
skip_movies() {
    echo "Skipping intro movies..."
    for i in $(seq 1 15); do
        local ctx=$(state_field context)
        if [ "$ctx" != "movie" ]; then
            echo "Movies done, context: $ctx"
            return 0
        fi
        # Send escape and then wait for state to change before sending another
        cmd '{"type":"key_press","key":"escape"}'
        # Wait up to 3 seconds for context to change from current state
        for j in $(seq 1 15); do
            sleep 0.2
            local new_ctx=$(state_field context)
            if [ "$new_ctx" != "movie" ]; then
                echo "  Skipped movie $i, now: $new_ctx"
                # If we've left movies entirely, stop
                if [ "$new_ctx" = "main_menu" ]; then
                    echo "Movies done, context: $new_ctx"
                    return 0
                fi
                break
            fi
        done
    done
    echo "Warning: may still be in movies"
}

# Navigate from main menu to new game
start_new_game() {
    echo "Starting new game..."
    wait_for_context "main_menu" 30 || return 1
    cmd '{"type":"main_menu_select","option":"new_game"}'
    sleep 1
    echo "Main menu -> new game sent"
}

# Select "create custom character" from character selector
select_custom_character() {
    echo "Selecting custom character..."
    wait_for_context "character_selector" 15 || return 1
    cmd '{"type":"char_selector_select","option":"create_custom"}'
    sleep 1
    echo "Character selector -> create custom sent"
}

# Create a melee-focused character for Temple of Trials
create_temple_character() {
    echo "Creating character..."
    wait_for_context "character_editor" 15 || return 1
    sleep 0.5

    send_cmd '{
        "commands": [
            {
                "type": "set_special",
                "strength": 6,
                "perception": 6,
                "endurance": 6,
                "charisma": 4,
                "intelligence": 6,
                "agility": 8,
                "luck": 4
            },
            {
                "type": "select_traits",
                "traits": ["finesse"]
            },
            {
                "type": "tag_skills",
                "skills": ["unarmed", "melee_weapons", "lockpick"]
            },
            {
                "type": "set_name",
                "name": "Claude"
            }
        ]
    }'

    sleep 1
    echo "Character stats set. Finishing creation..."
    cmd '{"type":"editor_done"}'
    sleep 2
    echo "Character creation complete"
}

# Quicksave (uses direct engine API, no UI)
quicksave() {
    local desc="${1:-Agent Save}"
    echo "Quicksaving ($desc)..."
    cmd "{\"type\":\"quicksave\",\"description\":\"$desc\"}"
    sleep 1
    echo "Quicksaved"
}

# Quickload (uses direct engine API, no UI)
quickload() {
    echo "Quickloading..."
    cmd '{"type":"quickload"}'
    sleep 2
    echo "Quickloaded"
}

# Skip post-creation movie(s) and wait for gameplay
wait_for_gameplay() {
    echo "Waiting for gameplay..."
    local timeout="${1:-60}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local ctx=$(state_field context)
        if [[ "$ctx" == gameplay_* ]]; then
            # Escape key during movies can leak into gameplay and open the
            # options menu (Escape = Options in game.cc). Dismiss it.
            local gm=$(state_field game_mode)
            if [ "$gm" = "8" ] || [ "$gm" = "24" ]; then
                echo "  Dismissing stuck options menu (game_mode=$gm)..."
                cmd '{"type":"key_press","key":"escape"}'
                sleep 1
            fi
            echo "In gameplay: $ctx"
            return 0
        fi
        # If we're in a movie, skip it
        if [ "$ctx" = "movie" ]; then
            cmd '{"type":"key_press","key":"escape"}'
            sleep 1
            elapsed=$((elapsed + 3))
            continue
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT waiting for gameplay (got '$ctx')"
    return 1
}

# Take a screenshot for debugging
screenshot() {
    local output="${1:-/tmp/fallout2_screenshot.png}"
    bash /Users/alexis.radcliff/fallout2-sdk/scripts/screenshot.sh "$output"
}

# Full flow: movies -> main menu -> character creation -> gameplay -> quicksave
full_startup() {
    skip_movies
    start_new_game
    select_custom_character
    create_temple_character
    wait_for_gameplay
    sleep 1
    quicksave "Temple Start"
    echo "=== Ready to play! ==="
    state_summary
}

echo "play.sh loaded. Functions available:"
echo "  full_startup     — movies -> character creation -> quicksave"
echo "  skip_movies      — skip intro movies"
echo "  quicksave/quickload"
echo "  send_cmd '{...}' — send raw command JSON"
echo "  cmd '{...}'      — send single command"
echo "  state            — full state JSON"
echo "  state_summary    — compact state overview"
echo "  state_field KEY  — extract one field"
echo "  wait_for_context CTX [timeout]"
