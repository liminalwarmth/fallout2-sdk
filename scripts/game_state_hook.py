#!/usr/bin/env python3
"""PreToolUse hook: inject compact game state before Bash tool calls.

Reads agent_state.json and outputs a [GAME] status line as additionalContext.
Fires synchronously before every Bash tool call (via matcher in settings.json).

Output: {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "[GAME] ..."}}
Exit 0 always (hook must never block tool execution).
"""

import json
import os
import sys
import time

def main():
    # Drain stdin (hook input — not needed)
    try:
        sys.stdin.read()
    except Exception:
        pass

    # Locate state file
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not project_dir:
        # Fallback: try to find game dir relative to this script
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_dir = os.path.dirname(script_dir)

    state_path = os.path.join(project_dir, "game", "agent_state.json")

    if not os.path.isfile(state_path):
        sys.exit(0)

    # Skip if stale (>30s = game not running)
    try:
        age = time.time() - os.path.getmtime(state_path)
        if age > 30:
            sys.exit(0)
    except OSError:
        sys.exit(0)

    # Parse state
    try:
        with open(state_path) as f:
            d = json.load(f)
    except (json.JSONDecodeError, OSError):
        sys.exit(0)

    # Extract compact status
    ch = d.get("character", {}).get("derived_stats", {})
    hp = ch.get("current_hp", "?")
    max_hp = ch.get("max_hp", "?")
    map_name = d.get("map", {}).get("name", "?")
    tile = d.get("player", {}).get("tile", "?")
    ctx = d.get("context", "?")
    busy = d.get("player", {}).get("animation_busy", False)

    parts = [f"HP:{hp}/{max_hp}", map_name, f"tile:{tile}", ctx]

    # BUSY flag
    if busy:
        parts.append("BUSY")

    # Combat details
    combat = d.get("combat", {})
    if "gameplay_combat" in str(ctx):
        ap = combat.get("current_ap", "?")
        hostiles = combat.get("hostiles", [])
        alive = [h for h in hostiles if h.get("hp", 0) > 0]
        rnd = combat.get("combat_round", "?")
        parts.append(f"AP:{ap}")
        parts.append(f"enemies:{len(alive)}")
        parts.append(f"round:{rnd}")

    # Auto-combat flag
    if d.get("auto_combat"):
        parts.append("AUTO-COMBAT")

    # Dialogue details
    if "dialogue" in str(ctx):
        dialog = d.get("dialogue", {})
        npc = dialog.get("npc_name", "?")
        options = dialog.get("options", [])
        parts.append(f"NPC:{npc}")
        parts.append(f"options:{len(options)}")

    brief = " | ".join(parts)

    # Output hook response
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"[GAME] {brief}"
        }
    }
    json.dump(output, sys.stdout)
    sys.exit(0)


if __name__ == "__main__":
    main()
