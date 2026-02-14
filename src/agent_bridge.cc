#include "agent_bridge.h"
#include "agent_bridge_internal.h"

#include <SDL.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>

#include "combat.h"
#include "debug.h"
#include "game.h"
#include "object.h"
#include "game_dialog.h"
#include "game_movie.h"
#include "input.h"
#include "skill.h"
#include "stat.h"
#include "trait.h"

namespace fallout {

// --- Shared globals (declared extern in agent_bridge_internal.h) ---

const char* kCmdPath = "agent_cmd.json";
const char* kStatePath = "agent_state.json";

static const char* kCmdTmpPath = "agent_cmd.tmp";
static const char* kStateTmpPath = "agent_state.tmp";

unsigned int gAgentTick = 0;
int gAgentContext = AGENT_CONTEXT_UNKNOWN;
int gAgentMainMenuAction = 0;
int gAgentPendingLoadSlot = -1;
bool gAgentTestMode = false;
int gAgentPendingExplosiveTimer = 0;
int gAgentPendingDialogueSelect = -1;
unsigned int gAgentDialogueSelectTick = 0;

std::unordered_map<std::string, int> gKeyNameToScancode;
std::unordered_map<std::string, int> gStatNameToId;
std::unordered_map<std::string, int> gSkillNameToId;
std::unordered_map<std::string, int> gTraitNameToId;

// --- Name-to-ID map builders ---

static void buildKeynameMap()
{
    for (char c = 'a'; c <= 'z'; c++) {
        std::string name(1, c);
        gKeyNameToScancode[name] = SDL_SCANCODE_A + (c - 'a');
    }

    gKeyNameToScancode["0"] = SDL_SCANCODE_0;
    for (char c = '1'; c <= '9'; c++) {
        std::string name(1, c);
        gKeyNameToScancode[name] = SDL_SCANCODE_1 + (c - '1');
    }

    for (int i = 1; i <= 12; i++) {
        std::string name = "f" + std::to_string(i);
        gKeyNameToScancode[name] = SDL_SCANCODE_F1 + (i - 1);
    }

    gKeyNameToScancode["escape"] = SDL_SCANCODE_ESCAPE;
    gKeyNameToScancode["return"] = SDL_SCANCODE_RETURN;
    gKeyNameToScancode["enter"] = SDL_SCANCODE_RETURN;
    gKeyNameToScancode["space"] = SDL_SCANCODE_SPACE;
    gKeyNameToScancode["tab"] = SDL_SCANCODE_TAB;
    gKeyNameToScancode["backspace"] = SDL_SCANCODE_BACKSPACE;

    gKeyNameToScancode["up"] = SDL_SCANCODE_UP;
    gKeyNameToScancode["down"] = SDL_SCANCODE_DOWN;
    gKeyNameToScancode["left"] = SDL_SCANCODE_LEFT;
    gKeyNameToScancode["right"] = SDL_SCANCODE_RIGHT;

    gKeyNameToScancode["lshift"] = SDL_SCANCODE_LSHIFT;
    gKeyNameToScancode["rshift"] = SDL_SCANCODE_RSHIFT;
    gKeyNameToScancode["lctrl"] = SDL_SCANCODE_LCTRL;
    gKeyNameToScancode["rctrl"] = SDL_SCANCODE_RCTRL;
    gKeyNameToScancode["lalt"] = SDL_SCANCODE_LALT;
    gKeyNameToScancode["ralt"] = SDL_SCANCODE_RALT;
}

static void buildStatNameMap()
{
    gStatNameToId["strength"] = STAT_STRENGTH;
    gStatNameToId["perception"] = STAT_PERCEPTION;
    gStatNameToId["endurance"] = STAT_ENDURANCE;
    gStatNameToId["charisma"] = STAT_CHARISMA;
    gStatNameToId["intelligence"] = STAT_INTELLIGENCE;
    gStatNameToId["agility"] = STAT_AGILITY;
    gStatNameToId["luck"] = STAT_LUCK;
}

static void buildSkillNameMap()
{
    gSkillNameToId["small_guns"] = SKILL_SMALL_GUNS;
    gSkillNameToId["big_guns"] = SKILL_BIG_GUNS;
    gSkillNameToId["energy_weapons"] = SKILL_ENERGY_WEAPONS;
    gSkillNameToId["unarmed"] = SKILL_UNARMED;
    gSkillNameToId["melee_weapons"] = SKILL_MELEE_WEAPONS;
    gSkillNameToId["throwing"] = SKILL_THROWING;
    gSkillNameToId["first_aid"] = SKILL_FIRST_AID;
    gSkillNameToId["doctor"] = SKILL_DOCTOR;
    gSkillNameToId["sneak"] = SKILL_SNEAK;
    gSkillNameToId["lockpick"] = SKILL_LOCKPICK;
    gSkillNameToId["steal"] = SKILL_STEAL;
    gSkillNameToId["traps"] = SKILL_TRAPS;
    gSkillNameToId["science"] = SKILL_SCIENCE;
    gSkillNameToId["repair"] = SKILL_REPAIR;
    gSkillNameToId["speech"] = SKILL_SPEECH;
    gSkillNameToId["barter"] = SKILL_BARTER;
    gSkillNameToId["gambling"] = SKILL_GAMBLING;
    gSkillNameToId["outdoorsman"] = SKILL_OUTDOORSMAN;
}

static void buildTraitNameMap()
{
    gTraitNameToId["fast_metabolism"] = TRAIT_FAST_METABOLISM;
    gTraitNameToId["bruiser"] = TRAIT_BRUISER;
    gTraitNameToId["small_frame"] = TRAIT_SMALL_FRAME;
    gTraitNameToId["one_hander"] = TRAIT_ONE_HANDER;
    gTraitNameToId["finesse"] = TRAIT_FINESSE;
    gTraitNameToId["kamikaze"] = TRAIT_KAMIKAZE;
    gTraitNameToId["heavy_handed"] = TRAIT_HEAVY_HANDED;
    gTraitNameToId["fast_shot"] = TRAIT_FAST_SHOT;
    gTraitNameToId["bloody_mess"] = TRAIT_BLOODY_MESS;
    gTraitNameToId["jinxed"] = TRAIT_JINXED;
    gTraitNameToId["good_natured"] = TRAIT_GOOD_NATURED;
    gTraitNameToId["chem_reliant"] = TRAIT_CHEM_RELIANT;
    gTraitNameToId["chem_resistant"] = TRAIT_CHEM_RESISTANT;
    gTraitNameToId["sex_appeal"] = TRAIT_SEX_APPEAL;
    gTraitNameToId["skilled"] = TRAIT_SKILLED;
    gTraitNameToId["gifted"] = TRAIT_GIFTED;
}

// --- Shared helper functions ---

const char* skillIdToName(int skill)
{
    static const char* names[] = {
        "small_guns", "big_guns", "energy_weapons", "unarmed",
        "melee_weapons", "throwing", "first_aid", "doctor",
        "sneak", "lockpick", "steal", "traps",
        "science", "repair", "speech", "barter",
        "gambling", "outdoorsman"
    };
    if (skill >= 0 && skill < SKILL_COUNT)
        return names[skill];
    return "unknown";
}

const char* traitIdToName(int trait)
{
    static const char* names[] = {
        "fast_metabolism", "bruiser", "small_frame", "one_hander",
        "finesse", "kamikaze", "heavy_handed", "fast_shot",
        "bloody_mess", "jinxed", "good_natured", "chem_reliant",
        "chem_resistant", "sex_appeal", "skilled", "gifted"
    };
    if (trait >= 0 && trait < TRAIT_COUNT)
        return names[trait];
    return "unknown";
}

// --- Object lookup by unique pointer-based ID ---

Object* findObjectByUniqueId(uintptr_t uid)
{
    Object* candidate = reinterpret_cast<Object*>(uid);
    // Validate the pointer by checking it exists in the object list
    Object* obj = objectFindFirst();
    while (obj != nullptr) {
        if (obj == candidate) {
            return obj;
        }
        obj = objectFindNext();
    }
    return nullptr;
}

// --- Context detection ---

const char* detectContext()
{
    // Priority 1: Movie playback
    if (gameMovieIsPlaying()) {
        return "movie";
    }

    // Priority 2: Character editor (GameMode::kEditor flag or manual hook)
    int gameMode = GameMode::getCurrentGameMode();
    if ((gameMode & GameMode::kEditor) || gAgentContext == AGENT_CONTEXT_CHAR_EDITOR) {
        return "character_editor";
    }

    // Priority 3: Manual context hooks
    switch (gAgentContext) {
    case AGENT_CONTEXT_MAIN_MENU:
        return "main_menu";
    case AGENT_CONTEXT_CHAR_SELECTOR:
        return "character_selector";
    case AGENT_CONTEXT_GAMEPLAY: {
        // Fine-grained gameplay sub-contexts
        // Check UI overlays first — these take priority because the player
        // is interacting with the UI, not the game world (even during combat)
        if (gameMode & GameMode::kWorldmap)
            return "gameplay_worldmap";
        if (gameMode & GameMode::kLoot)
            return "gameplay_loot";
        if (gameMode & GameMode::kInventory)
            return "gameplay_inventory";
        if (gameMode & GameMode::kBarter)
            return "gameplay_barter";
        if (gameMode & GameMode::kPipboy)
            return "gameplay_pipboy";
        if (gameMode & GameMode::kSkilldex)
            return "gameplay_skilldex";
        if (gameMode & GameMode::kOptions)
            return "gameplay_options";
        if (_gdialogActive()) {
            return "gameplay_dialogue";
        }
        if (isInCombat()) {
            if (gameMode & GameMode::kPlayerTurn)
                return "gameplay_combat";
            return "gameplay_combat_wait";
        }
        return "gameplay_exploration";
    }
    default:
        return "unknown";
    }
}

// --- Public API ---

void agentBridgeSetContext(int context)
{
    gAgentContext = context;
    debugPrint("AgentBridge: context set to %d\n", context);
}

// Number of ticks to show dialogue highlight before injecting key
static const unsigned int kDialogueHighlightDelay = 15; // ~0.5s at 30fps

// Track context transitions to auto-hide dialogue overlay
static const char* gPrevContext = nullptr;

void agentBridgeTick()
{
    gAgentTick++;
    processCommands();
    processPendingAttacks();
    agentProcessQueuedMovement();

    // Auto-hide dialogue overlay when leaving dialogue context,
    // or re-draw every tick to stay on top of talking head animations
    const char* ctx = detectContext();
    if (gPrevContext != nullptr && ctx != nullptr
        && strcmp(gPrevContext, "gameplay_dialogue") == 0
        && strcmp(ctx, "gameplay_dialogue") != 0) {
        agentHideDialogueOverlay();
    } else if (ctx != nullptr && strcmp(ctx, "gameplay_dialogue") == 0) {
        agentRedrawDialogueOverlay();
    }
    gPrevContext = ctx;

    // Redraw status overlay every tick to animate dots and stay on top
    agentRedrawStatusOverlay();

    // Deferred dialogue select: inject key after highlight delay
    // Re-check that we're still in dialogue before injecting, to avoid
    // leaking numeric keys into gameplay if dialogue closed during the delay.
    if (gAgentPendingDialogueSelect >= 0
        && (gAgentTick - gAgentDialogueSelectTick) >= kDialogueHighlightDelay) {
        int index = gAgentPendingDialogueSelect;
        gAgentPendingDialogueSelect = -1;
        const char* ctx = detectContext();
        if (ctx != nullptr && strcmp(ctx, "gameplay_dialogue") == 0) {
            enqueueInputEvent('1' + index);
            debugPrint("AgentBridge: deferred select_dialogue index=%d injected\n", index);
        } else {
            debugPrint("AgentBridge: deferred select_dialogue index=%d DROPPED (context=%s)\n",
                index, ctx ? ctx : "null");
        }
    }

    writeState();
}

void agentBridgeInit()
{
    debugPrint("AgentBridge: initializing\n");
    buildKeynameMap();
    buildStatNameMap();
    buildSkillNameMap();
    buildTraitNameMap();

    // Clean stale files from previous runs
    remove(kCmdPath);
    remove(kCmdTmpPath);
    remove(kStatePath);
    remove(kStateTmpPath);

    tickersAdd(agentBridgeTick);
    debugPrint("AgentBridge: initialized, ticker registered\n");
}

void agentBridgeExit()
{
    debugPrint("AgentBridge: shutting down\n");
    tickersRemove(agentBridgeTick);

    agentDestroyDialogueOverlay();
    agentHideStatusOverlay();

    remove(kCmdPath);
    remove(kCmdTmpPath);
    remove(kStatePath);
    remove(kStateTmpPath);

    gKeyNameToScancode.clear();
    gStatNameToId.clear();
    gSkillNameToId.clear();
    gTraitNameToId.clear();

    gPrevContext = nullptr;

    debugPrint("AgentBridge: shutdown complete\n");
}

bool agentBridgeCheckMovieSkip()
{
    FILE* f = fopen(kCmdPath, "rb");
    if (f == nullptr)
        return false;

    char buf[512];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    // Look for "skip" command type in the file
    if (strstr(buf, "\"skip\"") != nullptr) {
        remove(kCmdPath);
        debugPrint("AgentBridge: movie skip detected from agent_cmd.json\n");
        return true;
    }

    return false;
}

} // namespace fallout
