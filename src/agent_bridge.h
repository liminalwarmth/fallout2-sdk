#ifndef AGENT_BRIDGE_H
#define AGENT_BRIDGE_H

namespace fallout {

// Context constants for agentBridgeSetContext()
#define AGENT_CONTEXT_UNKNOWN 0
#define AGENT_CONTEXT_MAIN_MENU 1
#define AGENT_CONTEXT_CHAR_SELECTOR 2
#define AGENT_CONTEXT_GAMEPLAY 3
#define AGENT_CONTEXT_CHAR_EDITOR 4

void agentBridgeInit();
void agentBridgeExit();
void agentBridgeTick();
void agentBridgeSetContext(int context);

// Check agent_cmd.json for a "skip" command during movie playback.
// Returns true if skip was requested (and consumes the command file).
bool agentBridgeCheckMovieSkip();

// Main menu action injection — set by command handler, read by main menu loop
// 0=none, 1=new_game, 2=load_game, 3=options, 4=exit
extern int gAgentMainMenuAction;

// Agent-requested direct slot load from main menu (-1 = none, 0-9 = slot)
// When set, MAIN_MENU_LOAD_GAME bypasses the dialog and loads this slot directly
extern int gAgentPendingLoadSlot;

// Test mode flag — when false, teleport and other cheat commands are blocked
// Defaults to false. Enable via {"type":"set_test_mode","enabled":true}
extern bool gAgentTestMode;

// Auto-combat flag — when true, engine runs _combat_ai(gDude, ...) on player's
// turn instead of waiting for manual input via _combat_input().
// Enable via {"type":"auto_combat","enabled":true}
extern bool gAgentAutoCombat;

// Death screen flag — set while showDeath() is active so bridge can detect it.
// During death screen, mainLoop() has already exited and game state is reset,
// so normal HP/context reads are stale. The bridge emits "death_screen" context.
extern bool gAgentDeathScreenActive;

// Re-draw the dialogue thought overlay (call from dialogue render loops
// to keep overlay on top of talking heads and window refreshes)
void agentRedrawDialogueOverlay();

} // namespace fallout

#endif /* AGENT_BRIDGE_H */
