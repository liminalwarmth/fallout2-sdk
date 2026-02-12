#!/bin/bash
# screenshot.sh — Capture a screenshot of the Fallout 2 game window
# Usage: ./scripts/screenshot.sh [output_path]
# Default output: /tmp/fallout2_screenshot.png

OUTPUT="${1:-/tmp/fallout2_screenshot.png}"

# Find the Fallout 2 window ID
WINDOW_ID=$(osascript -e 'tell application "System Events" to get the id of every window of (first process whose name contains "Fallout")' 2>/dev/null | tr ',' '\n' | head -1 | tr -d ' ')

if [ -z "$WINDOW_ID" ]; then
    # Fallback: capture by window name using screencapture -l
    # Get window list and find Fallout
    WINDOW_ID=$(osascript -e '
        tell application "System Events"
            set falloutProc to first process whose name contains "Fallout"
            set frontWindow to first window of falloutProc
            return id of frontWindow
        end tell
    ' 2>/dev/null)
fi

if [ -n "$WINDOW_ID" ]; then
    screencapture -l "$WINDOW_ID" -x "$OUTPUT" 2>/dev/null
    if [ $? -eq 0 ] && [ -f "$OUTPUT" ]; then
        echo "$OUTPUT"
        exit 0
    fi
fi

# Fallback: just capture the whole screen and let Claude look at it
screencapture -x "$OUTPUT" 2>/dev/null
if [ $? -eq 0 ] && [ -f "$OUTPUT" ]; then
    echo "$OUTPUT (full screen)"
    exit 0
fi

echo "ERROR: Could not capture screenshot"
exit 1
