---
name: game-recall
description: Search gameplay knowledge and history. Use when you need to remember something about a location, character, quest, item, or past decision.
allowed-tools: Bash, Read, Grep
argument-hint: "[search terms]"
---

Search for "$ARGUMENTS" across all knowledge files and the game log.

1. First search knowledge files: `source scripts/executor.sh && recall "$ARGUMENTS"`
2. If more context needed, read the relevant knowledge file directly
3. For game log deep dives, use: `grep -i -B2 -A5 "$ARGUMENTS" game/game_log.md | tail -100`
4. Summarize findings concisely for the current decision

Never load the full game_log.md — always search/grep it.
