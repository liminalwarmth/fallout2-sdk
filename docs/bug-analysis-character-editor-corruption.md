# Character Editor Corruption Bug - 2026-02-13

## Summary
Attempted to move from tile 18264 to tile 20528 in KLATRAP.SAV. Instead of moving, the game entered character_editor context and became unresponsive. All save files were subsequently lost.

## Timeline
1. **Starting state**: HP 16/30, tile 18264, just finished gecko combat in KLATRAP
2. **heal_to_full**: Successful - used Stimpak, HP restored to 30/30
3. **explore_area 80**: FAILED - stuck at tile 18264, couldn't reach any of 4 ground items (Firewood x2, Booze x2)
4. **Manual move attempt**: Sent `cmd '{"type":"move_to","tile":20528}'` to move toward door
5. **Unexpected behavior**: Game context changed to `character_editor`
6. **Unresponsive**: `editor_done` command had no effect, remained in character_editor
7. **Save corruption**: quickload failed - all SLOT01-10 were empty
8. **Recovery**: Had to kill game process and restart

## Root Cause Analysis

### Animation System Stuck
The initial symptom was being unable to move from tile 18264. The `explore_area` function failed on all 4 items with "Move failed (stuck at 18264), retry 3/3". This suggests:

- `animationIsBusy(gDude)` may have been stuck returning true
- OR pathfinding was failing for some structural reason (blocked by corpse? object collision?)
- Player was standing next to a dead gecko corpse (Tough Lil Gecko at tile 18263)

### Character Editor Trigger Mystery
The move_to command should NOT trigger character editor. Possible causes:

1. **Engine race condition**: Animation system in bad state + move command = state corruption
2. **Command file corruption**: JSON parsing error could have misinterpreted command
3. **Key event leak**: Some stray 'c' key event in the queue (from combat? from escape menu?)
4. **Memory corruption**: Bad pointer/state from stuck animation system

Code review shows:
- `move_to` handler (line 679 of agent_commands.cc) does NOT call characterEditorShow
- Only ways to trigger character editor:
  - User presses 'C' key (game.cc:636-646)
  - Agent sends `character_screen` command (agent_commands.cc:2748)
  - Character selector calls it during new game (character_selector.cc:200, 210)

### Save File Loss
All SLOT01-10 directories exist but contain no .DAT files. This is catastrophic - suggests either:
- Game crashed during save operation
- Save files were deleted/corrupted by process kill
- Filesystem issue (unlikely - macOS APFS is transactional)

## Reproduction Steps
Not yet reproducible. Would need to:
1. Get into a state where player is stuck at a tile (animation busy or path blocked)
2. Attempt move_to to a distant tile
3. See if character editor opens

## Proposed Fixes

### Short-term Mitigations
1. **Implement auto-save before risky commands**: Before any movement that might trigger bugs, save to a named slot
2. **Add animation state checks**: Before move commands, verify `animationIsBusy(gDude)` and report in debug
3. **Add command validation**: Log all commands before execution to a separate debug file
4. **Graceful recovery**: If stuck in bad UI state, implement force-escape sequence

### Long-term Fixes
1. **Investigate animation stuck**: Add logging to `animationIsBusy()` to track what's blocking
2. **Add state transition guards**: Prevent character_editor from opening during gameplay unless via explicit command
3. **Improve save resilience**: Multiple save slots, backup before any risky operation
4. **Add watchdog**: Detect when game state becomes unresponsive and auto-restart

## Action Items
- [ ] Add pre-command save function to executor.sh
- [ ] Add animation state debug logging to agent_bridge
- [ ] Add guard in characterEditorShow() to prevent opening during gameplay
- [ ] Implement command logging to separate file
- [ ] Test if corpses block movement
- [ ] Test if long-distance move_to is reliable

## Related Memory Notes
- "Combat animation deadlock": Tick can freeze during combat (tick stops advancing)
- "macOS App Nap freezes game": Event loop suspension causes similar symptoms
- "Object IDs are NOT unique": Might relate to corpse collision issues
