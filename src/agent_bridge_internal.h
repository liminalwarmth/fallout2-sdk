#ifndef AGENT_BRIDGE_INTERNAL_H
#define AGENT_BRIDGE_INTERNAL_H

#include <map>
#include <string>
#include <unordered_map>

#include <nlohmann/json.hpp>

#include "agent_bridge.h"
#include <cstdint>

namespace fallout {

struct Object;

using json = nlohmann::json;

// --- File paths ---

extern const char* kCmdPath;
extern const char* kStatePath;

// --- Shared globals ---

extern unsigned int gAgentTick;
extern int gAgentContext;

// --- Name-to-ID lookup maps ---

extern std::unordered_map<std::string, int> gKeyNameToScancode;
extern std::unordered_map<std::string, int> gStatNameToId;
extern std::unordered_map<std::string, int> gSkillNameToId;
extern std::unordered_map<std::string, int> gTraitNameToId;

// --- Helpers (shared between state and commands) ---

const char* skillIdToName(int skill);
const char* traitIdToName(int trait);
const char* detectContext();
const char* itemTypeToString(int type);
const char* sceneryTypeToString(int type);

// --- Explosive timer bypass ---
extern int gAgentPendingExplosiveTimer;

// --- Deferred dialogue select (for visual highlight before selection) ---
extern int gAgentPendingDialogueSelect;      // index to select, or -1
extern unsigned int gAgentDialogueSelectTick; // tick when highlight was shown

// --- Debug tracking ---

extern std::string gAgentLastCommandDebug;

// --- Command failure counters ---
// Tracks consecutive failures per command type. Reset on success, incremented on failure.
extern std::map<std::string, int> gCommandFailureCounts;

// --- Look-at result ---
// Set by look_at command, consumed by next state write
extern std::string gAgentLookAtResult;

// --- State emission ---

void writeState();

// --- Object lookup by unique pointer-based ID ---

// Convert object pointer to a unique ID for JSON state
inline uintptr_t objectToUniqueId(Object* obj) { return reinterpret_cast<uintptr_t>(obj); }

// Find an object by its unique ID (pointer value) on the current map/elevation
Object* findObjectByUniqueId(uintptr_t uid);

// --- Cache control ---

// Force object re-enumeration on next state write (call after elevation changes)
void agentForceObjectRefresh();

// --- Command processing ---

void processCommands();
void processPendingAttacks();
int getPendingAttackCount();

// --- Queued movement ---

void agentProcessQueuedMovement();
int agentGetMovementWaypointsRemaining();

// --- Dialogue thought overlay ---
// agentRedrawDialogueOverlay() is declared in agent_bridge.h (public API for engine hooks)

void agentHideDialogueOverlay();
void agentDestroyDialogueOverlay();

// --- Status overlay (compaction indicator, top-left corner) ---
void agentRedrawStatusOverlay();
void agentHideStatusOverlay();

} // namespace fallout

#endif /* AGENT_BRIDGE_INTERNAL_H */
