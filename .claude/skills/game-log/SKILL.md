---
name: game-log
description: Log a gameplay decision, action, or event to the game log. Use at major decision points, after combat, after completing objectives, or when changing strategy.
allowed-tools: Bash
argument-hint: "[description of what happened and why]"
---

Append an entry to the game log with current game state context.

```bash
source scripts/executor.sh
game_log "**Decision:** [what was decided and why]
**Action:** [what was done]
**Result:** [what happened]
Tags: [comma-separated keywords for searchability]"
```

Include tags that would help find this entry later. Good tags: map names, NPC names,
quest names, action types (combat, dialogue, exploration, barter, puzzle).
