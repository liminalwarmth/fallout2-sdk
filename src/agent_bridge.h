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

} // namespace fallout

#endif /* AGENT_BRIDGE_H */
