---
name: game-note
description: Record a gameplay discovery or learning to the knowledge files. Use this whenever you discover something worth remembering — a new NPC, a quest clue, a useful item, a combat tactic, or world lore.
user-invocable: false
allowed-tools: Bash, Read, Edit
---

Record the discovery to the appropriate knowledge file in game/knowledge/.

1. Determine the category: locations, characters, quests, strategies, items, or world
2. Read the current knowledge file to see what's already recorded
3. Edit the file to add or UPDATE the relevant section (don't duplicate — merge with existing entries)
4. Keep entries concise — summaries, not transcripts
5. If the file is getting long (>150 lines), consolidate older entries

Use `source scripts/executor.sh && note "<category>" "<text>"` for quick appends,
or use the Edit tool for structured updates to existing sections.

Also log significant decisions to the game log:
`source scripts/executor.sh && game_log "<text>"`
