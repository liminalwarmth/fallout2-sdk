#include "agent_bridge_internal.h"

#include <SDL.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "character_editor.h"
#include "critter.h"
#include "debug.h"
#include "dinput.h"
#include "game.h"
#include "input.h"
#include "kb.h"
#include "mouse.h"
#include "object.h"
#include "skill.h"
#include "stat.h"
#include "trait.h"

// Gameplay command headers
#include "actions.h"
#include "animation.h"
#include "art.h"
#include "combat.h"
#include "combat_defs.h"
#include "game_dialog.h"
#include "interface.h"
#include "inventory.h"
#include "loadsave.h"
#include "item.h"
#include "map.h"
#include "party_member.h"
#include "perk.h"
#include "proto.h"
#include "proto_instance.h"
#include "text_object.h"
#include "tile.h"
#include "color.h"
#include "queue.h"
#include "random.h"
#include "scripts.h"
#include "pipboy.h"
#include "worldmap.h"

namespace fallout {

std::string gAgentLastCommandDebug;
std::string gAgentLookAtResult;

// Safe wrapper for objectGetName — never returns nullptr
static const char* safeName(Object* obj)
{
    if (obj == nullptr)
        return "(null)";
    char* name = objectGetName(obj);
    return name ? name : "(unnamed)";
}

// --- Look-at capture callback ---
// Used by _obj_examine_func to capture description text directly
static std::string gLookAtCaptureBuffer;
static void lookAtCaptureCallback(char* str)
{
    if (str != nullptr && str[0] != '\0') {
        if (!gLookAtCaptureBuffer.empty()) {
            gLookAtCaptureBuffer += " ";
        }
        gLookAtCaptureBuffer += str;
    }
}

// --- Pending attack queue ---
// Allows multiple attacks per turn without needing external timing.
// Attacks are queued and executed one at a time as animations complete.
struct PendingAttack {
    uintptr_t targetId;
    int hitMode;
    int hitLocation;
};
static std::vector<PendingAttack> gPendingAttacks;

void processPendingAttacks()
{
    if (gPendingAttacks.empty())
        return;

    if (!isInCombat()) {
        gPendingAttacks.clear();
        return;
    }

    if (animationIsBusy(gDude))
        return;

    // Check if we still have AP
    if (gDude->data.critter.combat.ap <= 0) {
        gPendingAttacks.clear();
        return;
    }

    PendingAttack atk = gPendingAttacks.front();
    gPendingAttacks.erase(gPendingAttacks.begin());

    Object* target = findObjectByUniqueId(atk.targetId);
    if (target == nullptr || critterIsDead(target)) {
        gPendingAttacks.clear();
        return;
    }

    int ap = gDude->data.critter.combat.ap;
    int dist = objectGetDistanceBetween(gDude, target);
    int rc = _combat_attack(gDude, target, atk.hitMode, atk.hitLocation);

    char buf[256];
    snprintf(buf, sizeof(buf),
        "attack(queued %d left): target=%lu hitMode=%d hitLoc=%d ap=%d dist=%d rc=%d",
        (int)gPendingAttacks.size(), (unsigned long)atk.targetId,
        atk.hitMode, atk.hitLocation, ap, dist, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

int getPendingAttackCount()
{
    return (int)gPendingAttacks.size();
}

// Character editor button event codes (from character_editor.cc)
#define CHAR_EDITOR_STAT_PLUS_BASE 503
#define CHAR_EDITOR_STAT_MINUS_BASE 510
#define CHAR_EDITOR_STAT_BTN_RELEASE 518
#define CHAR_EDITOR_SKILL_PLUS 521
#define CHAR_EDITOR_SKILL_MINUS 523
#define CHAR_EDITOR_SKILL_TAG_BASE 536
#define CHAR_EDITOR_TRAIT_BASE 555

// --- Character creation handlers ---

static void handleSetName(const json& cmd)
{
    if (!cmd.contains("name") || !cmd["name"].is_string()) {
        debugPrint("AgentBridge: set_name missing 'name'\n");
        return;
    }

    std::string name = cmd["name"].get<std::string>();
    if (name.empty() || name.length() > 32) {
        debugPrint("AgentBridge: set_name invalid length (%zu)\n", name.length());
        return;
    }

    dudeSetName(name.c_str());
    debugPrint("AgentBridge: set_name applied '%s'\n", name.c_str());
}

static void handleFinishCharacterCreation()
{
    KeyboardData data;
    data.key = SDL_SCANCODE_RETURN;
    data.down = 1;
    _kb_simulate_key(&data);
    debugPrint("AgentBridge: finish_character_creation (injected RETURN)\n");
}

static void handleAdjustStat(const json& cmd)
{
    if (!cmd.contains("stat") || !cmd["stat"].is_string()
        || !cmd.contains("direction") || !cmd["direction"].is_string()) {
        debugPrint("AgentBridge: adjust_stat missing 'stat' or 'direction'\n");
        return;
    }

    std::string statName = cmd["stat"].get<std::string>();
    std::string direction = cmd["direction"].get<std::string>();

    auto it = gStatNameToId.find(statName);
    if (it == gStatNameToId.end()) {
        debugPrint("AgentBridge: adjust_stat unknown stat '%s'\n", statName.c_str());
        return;
    }

    int statId = it->second;

    if (direction == "up") {
        enqueueInputEvent(CHAR_EDITOR_STAT_PLUS_BASE + statId);
    } else {
        enqueueInputEvent(CHAR_EDITOR_STAT_MINUS_BASE + statId);
    }
    enqueueInputEvent(CHAR_EDITOR_STAT_BTN_RELEASE);

    debugPrint("AgentBridge: adjust_stat '%s' %s (injected button event)\n",
        statName.c_str(), direction.c_str());
}

static void handleToggleTrait(const json& cmd)
{
    if (!cmd.contains("trait") || !cmd["trait"].is_string()) {
        debugPrint("AgentBridge: toggle_trait missing 'trait'\n");
        return;
    }

    std::string traitName = cmd["trait"].get<std::string>();
    auto it = gTraitNameToId.find(traitName);
    if (it == gTraitNameToId.end()) {
        debugPrint("AgentBridge: toggle_trait unknown trait '%s'\n", traitName.c_str());
        return;
    }

    int traitId = it->second;
    enqueueInputEvent(CHAR_EDITOR_TRAIT_BASE + traitId);
    debugPrint("AgentBridge: toggle_trait '%s' (injected button event)\n", traitName.c_str());
}

static void handleToggleSkillTag(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        debugPrint("AgentBridge: toggle_skill_tag missing 'skill'\n");
        return;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        debugPrint("AgentBridge: toggle_skill_tag unknown skill '%s'\n", skillName.c_str());
        return;
    }

    int skillId = it->second;
    enqueueInputEvent(CHAR_EDITOR_SKILL_TAG_BASE + skillId);
    debugPrint("AgentBridge: toggle_skill_tag '%s' (injected button event)\n", skillName.c_str());
}

// --- Menu handlers ---

static void handleMainMenuSelect(const json& cmd)
{
    if (!cmd.contains("option") || !cmd["option"].is_string()) {
        debugPrint("AgentBridge: main_menu_select missing 'option'\n");
        return;
    }

    std::string option = cmd["option"].get<std::string>();

    static const std::unordered_map<std::string, int> optionToScancode = {
        { "new_game", SDL_SCANCODE_N },
        { "load_game", SDL_SCANCODE_L },
        { "intro", SDL_SCANCODE_I },
        { "options", SDL_SCANCODE_O },
        { "credits", SDL_SCANCODE_C },
        { "exit", SDL_SCANCODE_E },
    };

    auto it = optionToScancode.find(option);
    if (it == optionToScancode.end()) {
        debugPrint("AgentBridge: main_menu_select unknown option '%s'\n", option.c_str());
        return;
    }

    KeyboardData data;
    data.key = it->second;
    data.down = 1;
    _kb_simulate_key(&data);
    debugPrint("AgentBridge: main_menu_select '%s'\n", option.c_str());
}

static void handleCharSelectorSelect(const json& cmd)
{
    if (!cmd.contains("option") || !cmd["option"].is_string()) {
        debugPrint("AgentBridge: char_selector_select missing 'option'\n");
        return;
    }

    std::string option = cmd["option"].get<std::string>();

    static const std::unordered_map<std::string, int> optionToScancode = {
        { "create_custom", SDL_SCANCODE_C },
        { "take_premade", SDL_SCANCODE_T },
        { "modify_premade", SDL_SCANCODE_M },
        { "back", SDL_SCANCODE_B },
    };

    auto it = optionToScancode.find(option);
    if (it == optionToScancode.end()) {
        debugPrint("AgentBridge: char_selector_select unknown option '%s'\n", option.c_str());
        return;
    }

    KeyboardData data;
    data.key = it->second;
    data.down = 1;
    _kb_simulate_key(&data);
    debugPrint("AgentBridge: char_selector_select '%s'\n", option.c_str());
}

// --- Exploration commands ---

// Queued waypoints for multi-step movement
static int gMoveWaypoints[40];
static int gMoveWaypointCount = 0;
static int gMoveWaypointIndex = 0;
static bool gMoveIsRunning = false;
static int gMoveElevation = 0; // elevation when waypoints were set
static int gMoveMapIndex = -1; // map index when waypoints were set

int agentGetMovementWaypointsRemaining()
{
    if (gMoveWaypointCount == 0 || gMoveWaypointIndex >= gMoveWaypointCount)
        return 0;
    return gMoveWaypointCount - gMoveWaypointIndex;
}

// Called from the tick function to continue queued movement
void agentProcessQueuedMovement()
{
    if (gMoveWaypointCount == 0 || gMoveWaypointIndex >= gMoveWaypointCount)
        return;

    // Abort waypoints if map or elevation changed (e.g. map transition, exit grid)
    if (gDude->elevation != gMoveElevation || mapGetCurrentMap() != gMoveMapIndex) {
        gMoveWaypointCount = 0;
        debugPrint("AgentBridge: movement aborted — map/elevation changed\n");
        return;
    }

    // Abort waypoints if combat started
    if (isInCombat()) {
        gMoveWaypointCount = 0;
        debugPrint("AgentBridge: movement aborted — combat started\n");
        return;
    }

    if (animationIsBusy(gDude))
        return;

    int targetTile = gMoveWaypoints[gMoveWaypointIndex];
    gMoveWaypointIndex++;

    if (reg_anim_begin(ANIMATION_REQUEST_RESERVED) != 0) {
        gMoveWaypointCount = 0; // Abort
        return;
    }

    int result;
    if (gMoveIsRunning) {
        result = animationRegisterRunToTile(gDude, targetTile, gDude->elevation, -1, 0);
    } else {
        result = animationRegisterMoveToTile(gDude, targetTile, gDude->elevation, -1, 0);
    }

    if (result != 0) {
        reg_anim_end();
        gMoveWaypointCount = 0; // Abort
        return;
    }

    reg_anim_end();
    tileSetCenter(targetTile, TILE_SET_CENTER_REFRESH_WINDOW);

    if (gMoveWaypointIndex >= gMoveWaypointCount) {
        gMoveWaypointCount = 0; // Done
    }
}

static void handleMoveTo(const json& cmd, bool run)
{
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = std::string(run ? "run_to" : "move_to") + ": missing 'tile'";
        debugPrint("AgentBridge: move_to/run_to missing 'tile'\n");
        return;
    }

    int tile = cmd["tile"].get<int>();

    // Block exploration movement during combat — use combat_move instead
    if (isInCombat()) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d rejected (in combat — use combat_move)", run ? "run_to" : "move_to", tile);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: %s rejected — in combat\n", run ? "run_to" : "move_to");
        return;
    }

    // Cancel any existing queued movement
    gMoveWaypointCount = 0;

    if (animationIsBusy(gDude)) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d skipped (animation busy)", run ? "run_to" : "move_to", tile);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: move_to/run_to skipped — animation busy\n");
        return;
    }

    // Check path length first
    unsigned char rotations[800];
    int pathLen = _make_path(gDude, gDude->tile, tile, rotations, 0);

    if (pathLen == 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d no path from %d", run ? "run_to" : "move_to", tile, gDude->tile);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: move_to/run_to no path\n");
        return;
    }

    // For long paths, break into waypoints and queue them
    static const int kMaxSegment = 16;
    if (pathLen > kMaxSegment) {
        // Build waypoint list by walking through rotations
        int waypointCount = 0;
        int currentTile = gDude->tile;
        for (int i = 0; i < pathLen && waypointCount < 39; i++) {
            currentTile = tileGetTileInDirection(currentTile, rotations[i], 1);
            if ((i + 1) % kMaxSegment == 0 || i == pathLen - 1) {
                gMoveWaypoints[waypointCount++] = currentTile;
            }
        }
        gMoveWaypointCount = waypointCount;
        gMoveWaypointIndex = 0;
        gMoveIsRunning = run;
        gMoveElevation = gDude->elevation;
        gMoveMapIndex = mapGetCurrentMap();

        // Start first segment immediately
        agentProcessQueuedMovement();

        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d from=%d pathLen=%d waypoints=%d",
            run ? "run_to" : "move_to", tile, gDude->tile, pathLen, waypointCount);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: %s to tile %d (queued %d waypoints)\n",
            run ? "run_to" : "move_to", tile, waypointCount);
        return;
    }

    // Short path — direct movement
    if (reg_anim_begin(ANIMATION_REQUEST_RESERVED) != 0) {
        gAgentLastCommandDebug = std::string(run ? "run_to" : "move_to") + ": reg_anim_begin failed";
        debugPrint("AgentBridge: move_to/run_to reg_anim_begin failed\n");
        return;
    }

    int result;
    if (run) {
        result = animationRegisterRunToTile(gDude, tile, gDude->elevation, -1, 0);
    } else {
        result = animationRegisterMoveToTile(gDude, tile, gDude->elevation, -1, 0);
    }

    if (result != 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d register failed", run ? "run_to" : "move_to", tile);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: move_to/run_to register failed\n");
        reg_anim_end();
        return;
    }

    reg_anim_end();

    // Scroll viewport toward destination so the camera follows the character
    tileSetCenter(tile, TILE_SET_CENTER_REFRESH_WINDOW);

    char buf[128];
    snprintf(buf, sizeof(buf), "%s: tile=%d from=%d", run ? "run_to" : "move_to", tile, gDude->tile);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s to tile %d\n", run ? "run_to" : "move_to", tile);
}

static void handleUseObject(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: use_object missing 'object_id'\n");
        return;
    }

    if (animationIsBusy(gDude)) {
        debugPrint("AgentBridge: use_object skipped — animation busy\n");
        return;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: use_object object %d not found\n", objId);
        return;
    }

    _action_use_an_object(gDude, target);
    char buf[128];
    snprintf(buf, sizeof(buf), "use_object: id=%llu name=%s", (unsigned long long)objId, safeName(target));
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: use_object on %llu\n", (unsigned long long)objId);
}

static void handlePickUp(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: pick_up missing 'object_id'\n");
        return;
    }

    if (animationIsBusy(gDude)) {
        debugPrint("AgentBridge: pick_up skipped — animation busy\n");
        return;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: pick_up object %d not found\n", objId);
        return;
    }

    actionPickUp(gDude, target);
    char buf[128];
    snprintf(buf, sizeof(buf), "pick_up: id=%llu name=%s", (unsigned long long)objId, safeName(target));
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: pick_up on %llu\n", (unsigned long long)objId);
}

static void handleUseSkill(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        debugPrint("AgentBridge: use_skill missing 'skill'\n");
        return;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "use_skill: animation busy";
        debugPrint("AgentBridge: use_skill skipped — animation busy\n");
        return;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        gAgentLastCommandDebug = "use_skill: unknown skill " + skillName;
        debugPrint("AgentBridge: use_skill unknown skill '%s'\n", skillName.c_str());
        return;
    }

    // Target: object_id if provided, otherwise self (gDude)
    Object* target;
    std::string targetDesc;
    if (cmd.contains("object_id") && cmd["object_id"].is_number_integer()) {
        uintptr_t objId = cmd["object_id"].get<uintptr_t>();
        target = findObjectByUniqueId(objId);
        if (target == nullptr) {
            gAgentLastCommandDebug = "use_skill: object not found";
            debugPrint("AgentBridge: use_skill object %llu not found\n", (unsigned long long)objId);
            return;
        }
        char* name = objectGetName(target);
        targetDesc = name ? name : "unknown";
    } else {
        // Self-targeted skill (first_aid, doctor on self)
        target = gDude;
        targetDesc = "self";
    }

    actionUseSkill(gDude, target, it->second);
    gAgentLastCommandDebug = "use_skill: " + skillName + " on " + targetDesc;
    debugPrint("AgentBridge: use_skill '%s' on %s\n", skillName.c_str(), targetDesc.c_str());
}

static void handleTalkTo(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: talk_to missing 'object_id'\n");
        return;
    }

    if (animationIsBusy(gDude)) {
        debugPrint("AgentBridge: talk_to skipped — animation busy\n");
        return;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: talk_to object %d not found\n", objId);
        return;
    }

    actionTalk(gDude, target);
    char buf[128];
    snprintf(buf, sizeof(buf), "talk_to: id=%llu name=%s", (unsigned long long)objId, safeName(target));
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: talk_to %llu\n", (unsigned long long)objId);
}

static void handleUseItemOn(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()
        || !cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: use_item_on missing 'item_pid' or 'object_id'\n");
        return;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "use_item_on: animation busy";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "use_item_on: pid " + std::to_string(itemPid) + " not in inventory";
        return;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        gAgentLastCommandDebug = "use_item_on: target " + std::to_string(objId) + " not found";
        return;
    }

    int dist = objectGetDistanceBetween(gDude, target);

    // If already adjacent (dist <= 2), call the use-item callback directly.
    // This avoids the animation chain failing silently when pathfinding can't
    // find a route to an adjacent hex (common with wall-adjacent scenery).
    if (dist <= 2) {
        int rc = _obj_use_item_on(gDude, target, item);
        char buf[256];
        snprintf(buf, sizeof(buf), "use_item_on(direct): pid=%d on id=%llu dist=%d rc=%d",
            itemPid, (unsigned long long)objId, dist, rc);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: %s\n", buf);
    } else {
        _action_use_an_item_on_object(gDude, target, item);
        char buf[196];
        snprintf(buf, sizeof(buf), "use_item_on(anim): pid=%d on id=%llu dist=%d target_sid=%d",
            itemPid, (unsigned long long)objId, dist, target->sid);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: %s\n", buf);
    }
}

static void handleLookAt(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: look_at missing 'object_id'\n");
        return;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: look_at object %d not found\n", objId);
        return;
    }

    char* name = objectGetName(target);

    // Use _obj_examine which sends output to the display monitor (message_log).
    // Also capture via custom callback to get text directly for look_at_result.
    gLookAtCaptureBuffer.clear();
    _obj_examine_func(gDude, target, lookAtCaptureCallback);

    // If script handled the description (callback got nothing), also run
    // through display monitor path so script output appears in message_log.
    if (gLookAtCaptureBuffer.empty()) {
        _obj_examine(gDude, target);
    }

    // Build look_at_result
    if (!gLookAtCaptureBuffer.empty()) {
        gAgentLookAtResult = gLookAtCaptureBuffer;
    } else {
        gAgentLookAtResult = std::string(name ? name : "Unknown") + " (see message_log for full description)";
    }

    char buf2[256];
    snprintf(buf2, sizeof(buf2), "look_at: %s — %s", name ? name : "Unknown",
        gLookAtCaptureBuffer.empty() ? "(script-handled, check message_log)" : gLookAtCaptureBuffer.c_str());
    gAgentLastCommandDebug = buf2;
    debugPrint("AgentBridge: look_at %llu — captured: %s\n", (unsigned long long)objId,
        gLookAtCaptureBuffer.empty() ? "(none)" : gLookAtCaptureBuffer.c_str());
}

// --- Inventory commands ---

static void handleEquipItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        debugPrint("AgentBridge: equip_item missing 'item_pid'\n");
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        debugPrint("AgentBridge: equip_item pid %d not found in inventory\n", itemPid);
        return;
    }

    int hand = HAND_RIGHT;
    if (cmd.contains("hand") && cmd["hand"].is_string()) {
        std::string handStr = cmd["hand"].get<std::string>();
        if (handStr == "left")
            hand = HAND_LEFT;
    }

    int rc = _inven_wield(gDude, item, hand);
    interfaceUpdateItems(false, INTERFACE_ITEM_ACTION_DEFAULT, INTERFACE_ITEM_ACTION_DEFAULT);
    gAgentLastCommandDebug = "equip_item: pid=" + std::to_string(itemPid)
        + " hand=" + (hand == HAND_LEFT ? "left" : "right")
        + " rc=" + std::to_string(rc);
    debugPrint("AgentBridge: equip_item pid %d in %s hand rc=%d\n", itemPid, hand == HAND_LEFT ? "left" : "right", rc);
}

static void handleUnequipItem(const json& cmd)
{
    int hand = HAND_RIGHT;
    if (cmd.contains("hand") && cmd["hand"].is_string()) {
        std::string handStr = cmd["hand"].get<std::string>();
        if (handStr == "left")
            hand = HAND_LEFT;
    }

    _inven_unwield(gDude, hand);
    gAgentLastCommandDebug = std::string("unequip_item: ") + (hand == HAND_LEFT ? "left" : "right") + " hand";
    debugPrint("AgentBridge: unequip_item %s hand\n", hand == HAND_LEFT ? "left" : "right");
}

static void handleUseItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "use_item: missing 'item_pid'";
        debugPrint("AgentBridge: use_item missing 'item_pid'\n");
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "use_item: pid " + std::to_string(itemPid) + " not found";
        debugPrint("AgentBridge: use_item pid %d not found in inventory\n", itemPid);
        return;
    }

    int type = itemGetType(item);
    if (type == ITEM_TYPE_DRUG) {
        _item_d_take_drug(gDude, item);
        gAgentLastCommandDebug = "use_item: drug pid=" + std::to_string(itemPid);
        debugPrint("AgentBridge: use_item (drug) pid %d\n", itemPid);
    } else {
        // Try generic proto instance use (handles flares, books, radios, etc.)
        int rc = _obj_use_item(gDude, item);
        if (rc == 0 || rc == 2) {
            gAgentLastCommandDebug = "use_item: used pid=" + std::to_string(itemPid) + " rc=" + std::to_string(rc);
            debugPrint("AgentBridge: use_item (generic) pid %d rc=%d\n", itemPid, rc);
        } else {
            gAgentLastCommandDebug = "use_item: unsupported type " + std::to_string(type);
            debugPrint("AgentBridge: use_item pid %d — unsupported item type %d\n", itemPid, type);
        }
    }
}

// --- Use equipped item (player-like: equip to hand → use from game screen) ---

static void handleUseEquippedItem(const json& cmd)
{
    Object* item = nullptr;
    if (interfaceGetActiveItem(&item) == -1 || item == nullptr) {
        gAgentLastCommandDebug = "use_equipped_item: no item in active hand";
        return;
    }

    // For explosives, pre-set the timer so _inven_set_timer returns immediately
    // instead of showing a blocking dialog
    if (explosiveIsExplosive(item->pid)) {
        int seconds = 30;
        if (cmd.contains("timer_seconds") && cmd["timer_seconds"].is_number_integer()) {
            seconds = cmd["timer_seconds"].get<int>();
            if (seconds < 10) seconds = 10;
            if (seconds > 180) seconds = 180;
            seconds = (seconds / 10) * 10;
        }
        gAgentPendingExplosiveTimer = seconds;
    }

    // Cache pid before _obj_use_item — it can destroy/replace the item object
    int itemPid = item->pid;

    // Call through the real engine item-use path
    int rc = _obj_use_item(gDude, item);
    interfaceUpdateItems(false, INTERFACE_ITEM_ACTION_DEFAULT, INTERFACE_ITEM_ACTION_DEFAULT);

    char buf[256];
    snprintf(buf, sizeof(buf), "use_equipped_item: pid=%d rc=%d", itemPid, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Reload weapon ---

static void handleReloadWeapon(const json& cmd)
{
    // Determine which hand to reload (default: current active hand)
    int hand = interfaceGetCurrentHand();
    if (cmd.contains("hand") && cmd["hand"].is_string()) {
        std::string handStr = cmd["hand"].get<std::string>();
        if (handStr == "left")
            hand = HAND_LEFT;
        else if (handStr == "right")
            hand = HAND_RIGHT;
    }

    Object* weapon = (hand == HAND_RIGHT) ? critterGetItem2(gDude) : critterGetItem1(gDude);
    if (weapon == nullptr) {
        gAgentLastCommandDebug = "reload_weapon: no weapon in hand";
        return;
    }

    if (itemGetType(weapon) != ITEM_TYPE_WEAPON) {
        gAgentLastCommandDebug = "reload_weapon: held item is not a weapon";
        return;
    }

    int capacity = ammoGetCapacity(weapon);
    if (capacity <= 0) {
        gAgentLastCommandDebug = "reload_weapon: weapon doesn't use ammo";
        return;
    }

    int currentAmmo = ammoGetQuantity(weapon);
    if (currentAmmo >= capacity) {
        gAgentLastCommandDebug = "reload_weapon: already full (" + std::to_string(currentAmmo) + "/" + std::to_string(capacity) + ")";
        return;
    }

    // If a specific ammo PID is provided, use it; otherwise find compatible ammo
    Object* ammo = nullptr;
    if (cmd.contains("ammo_pid") && cmd["ammo_pid"].is_number_integer()) {
        int ammoPid = cmd["ammo_pid"].get<int>();
        ammo = objectGetCarriedObjectByPid(gDude, ammoPid);
        if (ammo == nullptr) {
            gAgentLastCommandDebug = "reload_weapon: ammo pid " + std::to_string(ammoPid) + " not in inventory";
            return;
        }
        if (!weaponCanBeReloadedWith(weapon, ammo)) {
            gAgentLastCommandDebug = "reload_weapon: incompatible ammo pid " + std::to_string(ammoPid);
            return;
        }
    } else {
        // Search inventory for compatible ammo
        Inventory* inv = &gDude->data.inventory;
        for (int i = 0; i < inv->length; i++) {
            Object* item = inv->items[i].item;
            if (item != nullptr && itemGetType(item) == ITEM_TYPE_AMMO
                && weaponCanBeReloadedWith(weapon, item)) {
                ammo = item;
                break;
            }
        }
        if (ammo == nullptr) {
            gAgentLastCommandDebug = "reload_weapon: no compatible ammo in inventory";
            return;
        }
    }

    int result = weaponReload(weapon, ammo);
    // If ammo stack is depleted, remove it from inventory
    if (result == 0) {
        // Ammo fully consumed — remove from inventory
        itemRemove(gDude, ammo, 1);
        objectDestroy(ammo, nullptr);
    }

    interfaceUpdateItems(false, INTERFACE_ITEM_ACTION_DEFAULT, INTERFACE_ITEM_ACTION_DEFAULT);

    char buf[128];
    snprintf(buf, sizeof(buf), "reload_weapon: %d/%d result=%d",
        ammoGetQuantity(weapon), capacity, result);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Drop item ---

static void handleDropItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "drop_item: missing 'item_pid'";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "drop_item: pid " + std::to_string(itemPid) + " not in inventory";
        return;
    }

    // Remove item from inventory (does NOT destroy the object)
    int rc = itemRemove(gDude, item, quantity);
    if (rc != 0) {
        gAgentLastCommandDebug = "drop_item: itemRemove failed rc=" + std::to_string(rc);
        return;
    }

    // Place the removed item object on the ground at player's tile
    rc = _obj_connect(item, gDude->tile, gDude->elevation, nullptr);
    if (rc != 0) {
        // Failed to place — try to put it back in inventory
        itemAdd(gDude, item, quantity);
        gAgentLastCommandDebug = "drop_item: _obj_connect failed, item returned to inventory";
        return;
    }

    char buf[128];
    snprintf(buf, sizeof(buf), "drop_item: pid=%d qty=%d tile=%d",
        itemPid, quantity, gDude->tile);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleGiveItem(const json& cmd)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "give_item: BLOCKED — test mode disabled";
        return;
    }

    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "give_item: missing 'item_pid'";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    for (int i = 0; i < quantity; i++) {
        Object* item = nullptr;
        int rc = objectCreateWithPid(&item, itemPid);
        if (rc != 0 || item == nullptr) {
            char buf[128];
            snprintf(buf, sizeof(buf), "give_item: failed to create pid=%d (iteration %d)", itemPid, i);
            gAgentLastCommandDebug = buf;
            return;
        }

        rc = itemAdd(gDude, item, 1);
        if (rc != 0) {
            objectDestroy(item, nullptr);
            char buf[128];
            snprintf(buf, sizeof(buf), "give_item: failed to add pid=%d to inventory (rc=%d)", itemPid, rc);
            gAgentLastCommandDebug = buf;
            return;
        }
    }

    char buf[128];
    snprintf(buf, sizeof(buf), "give_item: pid=%d qty=%d", itemPid, quantity);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Combat commands ---

static int hitModeFromString(const std::string& mode, bool hasWeapon)
{
    if (mode == "primary")
        return hasWeapon ? HIT_MODE_RIGHT_WEAPON_PRIMARY : HIT_MODE_PUNCH;
    if (mode == "secondary")
        return hasWeapon ? HIT_MODE_RIGHT_WEAPON_SECONDARY : HIT_MODE_KICK;
    if (mode == "punch")
        return HIT_MODE_PUNCH;
    if (mode == "kick")
        return HIT_MODE_KICK;
    return hasWeapon ? HIT_MODE_RIGHT_WEAPON_PRIMARY : HIT_MODE_PUNCH;
}

static int hitLocationFromString(const std::string& loc)
{
    if (loc == "head")
        return HIT_LOCATION_HEAD;
    if (loc == "torso")
        return HIT_LOCATION_TORSO;
    if (loc == "eyes")
        return HIT_LOCATION_EYES;
    if (loc == "groin")
        return HIT_LOCATION_GROIN;
    if (loc == "left_arm")
        return HIT_LOCATION_LEFT_ARM;
    if (loc == "right_arm")
        return HIT_LOCATION_RIGHT_ARM;
    if (loc == "left_leg")
        return HIT_LOCATION_LEFT_LEG;
    if (loc == "right_leg")
        return HIT_LOCATION_RIGHT_LEG;
    return HIT_LOCATION_UNCALLED;
}

static void handleAttack(const json& cmd)
{
    if (!cmd.contains("target_id") || !cmd["target_id"].is_number_integer()) {
        gAgentLastCommandDebug = "attack: missing target_id";
        return;
    }

    if (!isInCombat()) {
        gAgentLastCommandDebug = "attack: not in combat";
        return;
    }

    uintptr_t targetId = cmd["target_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(targetId);
    if (target == nullptr) {
        gAgentLastCommandDebug = "attack: target " + std::to_string(targetId) + " not found";
        return;
    }

    // Use the interface's current hit mode by default (respects switch_hand/cycle_attack_mode)
    int hitMode = -1;
    bool aiming = false;
    if (interfaceGetCurrentHitMode(&hitMode, &aiming) != 0) {
        int currentHand = interfaceGetCurrentHand();
        Object* weapon = (currentHand == HAND_RIGHT) ? critterGetItem2(gDude) : critterGetItem1(gDude);
        if (weapon != nullptr) {
            hitMode = (currentHand == HAND_RIGHT) ? HIT_MODE_RIGHT_WEAPON_PRIMARY : HIT_MODE_LEFT_WEAPON_PRIMARY;
        } else {
            hitMode = HIT_MODE_PUNCH;
        }
    }

    // Allow explicit override via command
    if (cmd.contains("hit_mode") && cmd["hit_mode"].is_string()) {
        std::string hitModeStr = cmd["hit_mode"].get<std::string>();
        int currentHand = interfaceGetCurrentHand();
        Object* weapon = (currentHand == HAND_RIGHT) ? critterGetItem2(gDude) : critterGetItem1(gDude);
        bool hasWeapon = weapon != nullptr;
        hitMode = hitModeFromString(hitModeStr, hasWeapon);
    }

    int hitLocation = HIT_LOCATION_UNCALLED;
    if (cmd.contains("hit_location") && cmd["hit_location"].is_string())
        hitLocation = hitLocationFromString(cmd["hit_location"].get<std::string>());

    // Support "count" for repeated attacks (queued via pending attack system)
    int count = 1;
    if (cmd.contains("count") && cmd["count"].is_number_integer()) {
        count = cmd["count"].get<int>();
        if (count < 1) count = 1;
        if (count > 10) count = 10; // Cap at 10 to prevent runaway queues
    }

    // Pre-validate shot before attempting
    aiming = (hitLocation != HIT_LOCATION_UNCALLED);
    int badShot = _combat_check_bad_shot(gDude, target, hitMode, aiming);
    if (badShot != COMBAT_BAD_SHOT_OK) {
        const char* reason = "unknown";
        switch (badShot) {
        case COMBAT_BAD_SHOT_NO_AMMO: reason = "no ammo"; break;
        case COMBAT_BAD_SHOT_OUT_OF_RANGE: reason = "out of range"; break;
        case COMBAT_BAD_SHOT_NOT_ENOUGH_AP: reason = "not enough AP"; break;
        case COMBAT_BAD_SHOT_ALREADY_DEAD: reason = "target already dead"; break;
        case COMBAT_BAD_SHOT_AIM_BLOCKED: reason = "aim blocked"; break;
        case COMBAT_BAD_SHOT_ARM_CRIPPLED: reason = "arm crippled"; break;
        case COMBAT_BAD_SHOT_BOTH_ARMS_CRIPPLED: reason = "both arms crippled"; break;
        }
        int ap = gDude->data.critter.combat.ap;
        int dist = objectGetDistanceBetween(gDude, target);
        int apCost = weaponGetActionPointCost(gDude, hitMode, aiming);
        int range = weaponGetRange(gDude, hitMode);
        char buf[256];
        snprintf(buf, sizeof(buf),
            "attack: REJECTED — %s (ap=%d cost=%d dist=%d range=%d)",
            reason, ap, apCost, dist, range);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: %s\n", buf);
        return;
    }

    // If animation busy, queue ALL attacks (including first)
    if (animationIsBusy(gDude)) {
        for (int i = 0; i < count; i++) {
            gPendingAttacks.push_back({ targetId, hitMode, hitLocation });
        }
        char buf[128];
        snprintf(buf, sizeof(buf), "attack: queued %d attacks (animation busy)", count);
        gAgentLastCommandDebug = buf;
        return;
    }

    // Execute first attack immediately
    int ap = gDude->data.critter.combat.ap;
    int dist = objectGetDistanceBetween(gDude, target);
    int rc = _combat_attack(gDude, target, hitMode, hitLocation);

    // Queue remaining attacks
    for (int i = 1; i < count; i++) {
        gPendingAttacks.push_back({ targetId, hitMode, hitLocation });
    }

    char buf[256];
    snprintf(buf, sizeof(buf),
        "attack: target=%lu hitMode=%d hitLoc=%d ap=%d dist=%d rc=%d queued=%d",
        (unsigned long)targetId, hitMode, hitLocation, ap, dist, rc, count - 1);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleCombatMove(const json& cmd)
{
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "combat_move: missing 'tile'";
        return;
    }

    if (!isInCombat()) {
        gAgentLastCommandDebug = "combat_move: not in combat";
        return;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "combat_move: animation busy";
        return;
    }

    int tile = cmd["tile"].get<int>();
    int ap = gDude->data.critter.combat.ap;

    if (ap <= 0) {
        gAgentLastCommandDebug = "combat_move: REJECTED — no AP remaining";
        return;
    }

    if (reg_anim_begin(ANIMATION_REQUEST_RESERVED) != 0) {
        gAgentLastCommandDebug = "combat_move: reg_anim_begin failed";
        return;
    }

    if (animationRegisterMoveToTile(gDude, tile, gDude->elevation, ap, 0) != 0) {
        gAgentLastCommandDebug = "combat_move: no path or register failed";
        reg_anim_end();
        return;
    }

    reg_anim_end();

    // Center viewport on destination
    tileSetCenter(tile, TILE_SET_CENTER_REFRESH_WINDOW);

    char buf[128];
    snprintf(buf, sizeof(buf), "combat_move: tile=%d from=%d ap=%d", tile, gDude->tile, ap);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: combat_move to tile %d\n", tile);
}

static void handleEndTurn()
{
    if (!isInCombat()) {
        gAgentLastCommandDebug = "end_turn: not in combat";
        debugPrint("AgentBridge: end_turn — not in combat\n");
        return;
    }

    // Space key ends the player's turn in the combat input loop
    enqueueInputEvent(32); // ASCII space = 32
    gAgentLastCommandDebug = "end_turn: ap=" + std::to_string(gDude->data.critter.combat.ap);
    debugPrint("AgentBridge: end_turn\n");
}

static void handleUseCombatItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "use_combat_item: missing 'item_pid'";
        debugPrint("AgentBridge: use_combat_item missing 'item_pid'\n");
        return;
    }

    if (!isInCombat()) {
        gAgentLastCommandDebug = "use_combat_item: not in combat";
        debugPrint("AgentBridge: use_combat_item — not in combat\n");
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "use_combat_item: pid " + std::to_string(itemPid) + " not found";
        debugPrint("AgentBridge: use_combat_item pid %d not found\n", itemPid);
        return;
    }

    int type = itemGetType(item);
    if (type == ITEM_TYPE_DRUG) {
        _item_d_take_drug(gDude, item);
        if (gDude->data.critter.combat.ap >= 2) {
            gDude->data.critter.combat.ap -= 2;
        }
        gAgentLastCommandDebug = "use_combat_item: drug pid=" + std::to_string(itemPid);
        debugPrint("AgentBridge: use_combat_item (drug) pid %d\n", itemPid);
    } else {
        gAgentLastCommandDebug = "use_combat_item: unsupported type " + std::to_string(type);
        debugPrint("AgentBridge: use_combat_item pid %d — unsupported type %d\n", itemPid, type);
    }
}

// --- Pathfinding / navigation queries ---

static void handleFindPath(const json& cmd)
{
    if (!cmd.contains("to") || !cmd["to"].is_number_integer()) {
        gAgentLastCommandDebug = "find_path: missing 'to' tile";
        return;
    }

    int from = gDude->tile;
    if (cmd.contains("from") && cmd["from"].is_number_integer()) {
        from = cmd["from"].get<int>();
    }
    int to = cmd["to"].get<int>();

    unsigned char rotations[800];
    int pathLen = _make_path(gDude, from, to, rotations, 0);

    if (pathLen == 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "find_path: no path from %d to %d (len=0)", from, to);
        gAgentLastCommandDebug = buf;
        return;
    }

    // Convert rotations to tile waypoints (sample every few tiles to keep output manageable)
    std::string waypoints = "[";
    int currentTile = from;
    int step = (pathLen > 40) ? (pathLen / 20) : 1; // Sample ~20 waypoints for long paths
    if (step < 1) step = 1;

    for (int i = 0; i < pathLen; i++) {
        currentTile = tileGetTileInDirection(currentTile, rotations[i], 1);
        if (i % step == 0 || i == pathLen - 1) {
            if (waypoints.length() > 1) waypoints += ",";
            waypoints += std::to_string(currentTile);
        }
    }
    waypoints += "]";

    char buf[256];
    snprintf(buf, sizeof(buf), "find_path: %d -> %d len=%d waypoints=", from, to, pathLen);
    gAgentLastCommandDebug = std::string(buf) + waypoints;
    debugPrint("AgentBridge: find_path from=%d to=%d len=%d\n", from, to, pathLen);
}

static void handleTileObjects(const json& cmd)
{
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "tile_objects: missing 'tile'";
        return;
    }

    int targetTile = cmd["tile"].get<int>();
    int radius = 2;
    if (cmd.contains("radius") && cmd["radius"].is_number_integer()) {
        radius = cmd["radius"].get<int>();
    }

    std::string result = "tile_objects at " + std::to_string(targetTile) + ": ";

    // Check all object types
    static const int objTypes[] = { OBJ_TYPE_CRITTER, OBJ_TYPE_SCENERY, OBJ_TYPE_WALL, OBJ_TYPE_TILE, OBJ_TYPE_MISC, OBJ_TYPE_ITEM };
    static const char* typeNames[] = { "critter", "scenery", "wall", "tile", "misc", "item" };

    for (int t = 0; t < 6; t++) {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, objTypes[t], &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr) continue;
            int dist = tileDistanceBetween(obj->tile, targetTile);
            if (dist > radius) continue;

            char* name = objectGetName(obj);
            char buf[256];
            snprintf(buf, sizeof(buf), "[%s pid=%d tile=%d dist=%d name=%s] ",
                typeNames[t], obj->pid, obj->tile, dist, name ? name : "?");
            result += buf;
        }
        if (list != nullptr) {
            objectListFree(list);
        }
    }

    gAgentLastCommandDebug = result;
    debugPrint("AgentBridge: %s\n", result.c_str());
}

// --- Find item by PID on current elevation ---

static void handleFindItem(const json& cmd)
{
    if (!cmd.contains("pid") || !cmd["pid"].is_number_integer()) {
        gAgentLastCommandDebug = "find_item: missing 'pid'";
        return;
    }
    int targetPid = cmd["pid"].get<int>();
    std::string result = "find_item pid=" + std::to_string(targetPid) + ": ";
    int found = 0;

    // Search ground items AND inside ground item containers (pots, chests)
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_ITEM, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr) continue;
            if (obj->pid == targetPid) {
                int dist = objectGetDistanceBetween(gDude, obj);
                char* name = objectGetName(obj);
                char buf[256];
                snprintf(buf, sizeof(buf), "[ground tile=%d dist=%d name=%s] ", obj->tile, dist, name ? name : "?");
                result += buf;
                found++;
            }
            // Also check inventory of ground item containers (pots, chests, etc.)
            Inventory* inv = &obj->data.inventory;
            for (int j = 0; j < inv->length; j++) {
                if (inv->items[j].item != nullptr && inv->items[j].item->pid == targetPid) {
                    int dist = objectGetDistanceBetween(gDude, obj);
                    char* cname = objectGetName(obj);
                    char buf[256];
                    snprintf(buf, sizeof(buf), "[in_ground_container tile=%d dist=%d container=%s qty=%d] ",
                        obj->tile, dist, cname ? cname : "?", inv->items[j].quantity);
                    result += buf;
                    found++;
                }
            }
        }
        if (list) objectListFree(list);
    }

    // Search inside scenery containers
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_SCENERY, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr) continue;
            Inventory* inv = &obj->data.inventory;
            for (int j = 0; j < inv->length; j++) {
                if (inv->items[j].item != nullptr && inv->items[j].item->pid == targetPid) {
                    int dist = objectGetDistanceBetween(gDude, obj);
                    char* name = objectGetName(obj);
                    char buf[256];
                    snprintf(buf, sizeof(buf), "[in_container tile=%d dist=%d container=%s qty=%d] ",
                        obj->tile, dist, name ? name : "?", inv->items[j].quantity);
                    result += buf;
                    found++;
                }
            }
        }
        if (list) objectListFree(list);
    }

    // Search player inventory
    {
        Inventory* inv = &gDude->data.inventory;
        for (int j = 0; j < inv->length; j++) {
            if (inv->items[j].item != nullptr && inv->items[j].item->pid == targetPid) {
                char buf[128];
                snprintf(buf, sizeof(buf), "[player_inventory qty=%d] ", inv->items[j].quantity);
                result += buf;
                found++;
            }
        }
    }

    if (found == 0) {
        result += "NONE FOUND";
    }

    gAgentLastCommandDebug = result;
    debugPrint("AgentBridge: %s\n", result.c_str());
}

// --- Enumerate all items/containers on current elevation ---

static void handleListAllItems(const json& cmd)
{
    std::string result = "list_all_items elev=" + std::to_string(gDude->elevation) + ": ";
    int totalItems = 0;

    // Ground items (include container contents)
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_ITEM, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr) continue;
            char* name = objectGetName(obj);
            int dist = objectGetDistanceBetween(gDude, obj);
            char buf[256];
            // Show container contents if it has inventory
            if (obj->data.inventory.length > 0) {
                snprintf(buf, sizeof(buf), "[ground_container pid=%d tile=%d d=%d name=%s items=%d: ", obj->pid, obj->tile, dist, name ? name : "?", obj->data.inventory.length);
                result += buf;
                Inventory* inv = &obj->data.inventory;
                for (int j = 0; j < inv->length && j < 5; j++) {
                    if (inv->items[j].item != nullptr) {
                        char* iname = objectGetName(inv->items[j].item);
                        char ibuf[128];
                        snprintf(ibuf, sizeof(ibuf), "%s(pid=%d qty=%d) ", iname ? iname : "?", inv->items[j].item->pid, inv->items[j].quantity);
                        result += ibuf;
                    }
                }
                result += "] ";
            } else {
                snprintf(buf, sizeof(buf), "[ground pid=%d tile=%d d=%d name=%s] ", obj->pid, obj->tile, dist, name ? name : "?");
                result += buf;
            }
            totalItems++;
            if (totalItems >= 30) break;
        }
        if (list) objectListFree(list);
    }

    // Items in scenery containers
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_SCENERY, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr) continue;
            Inventory* inv = &obj->data.inventory;
            if (inv->length == 0) continue;
            char* cname = objectGetName(obj);
            int dist = objectGetDistanceBetween(gDude, obj);
            char buf[256];
            snprintf(buf, sizeof(buf), "[container pid=%d tile=%d d=%d name=%s items=%d: ", obj->pid, obj->tile, dist, cname ? cname : "?", inv->length);
            result += buf;
            for (int j = 0; j < inv->length && j < 5; j++) {
                if (inv->items[j].item != nullptr) {
                    char* iname = objectGetName(inv->items[j].item);
                    char ibuf[128];
                    snprintf(ibuf, sizeof(ibuf), "%s(pid=%d qty=%d) ", iname ? iname : "?", inv->items[j].item->pid, inv->items[j].quantity);
                    result += ibuf;
                }
            }
            result += "] ";
            totalItems++;
            if (totalItems >= 30) break;
        }
        if (list) objectListFree(list);
    }

    if (totalItems == 0) {
        result += "NONE";
    }

    gAgentLastCommandDebug = result;
    debugPrint("AgentBridge: %s\n", result.c_str());
}

// --- Map transition command ---

static void handleMapTransition(const json& cmd)
{
    if (!cmd.contains("map") || !cmd["map"].is_number_integer()
        || !cmd.contains("elevation") || !cmd["elevation"].is_number_integer()
        || !cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "map_transition: missing map/elevation/tile";
        return;
    }

    int map = cmd["map"].get<int>();
    int elevation = cmd["elevation"].get<int>();
    int tile = cmd["tile"].get<int>();

    // Direct map transitions (map >= 0) require test mode — players can't
    // teleport between maps.  map=-2 (world map entry) is a normal action.
    if (map >= 0 && !gAgentTestMode) {
        char buf[128];
        snprintf(buf, sizeof(buf), "map_transition: BLOCKED — direct map transition (map=%d) requires test mode", map);
        gAgentLastCommandDebug = buf;
        return;
    }
    int rotation = 0;
    if (cmd.contains("rotation") && cmd["rotation"].is_number_integer()) {
        rotation = cmd["rotation"].get<int>();
    }

    char buf[128];
    snprintf(buf, sizeof(buf), "map_transition: setting map=%d elev=%d tile=%d rot=%d", map, elevation, tile, rotation);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);

    MapTransition transition;
    memset(&transition, 0, sizeof(transition));
    transition.map = map;
    transition.elevation = elevation;
    transition.tile = tile;
    transition.rotation = rotation;
    mapSetTransition(&transition);

    wmMapMarkMapEntranceState(transition.map, transition.elevation, 1);

    // Force object re-enumeration after elevation/map change
    agentForceObjectRefresh();

    snprintf(buf, sizeof(buf), "map_transition: done map=%d elev=%d tile=%d", map, elevation, tile);
    gAgentLastCommandDebug = buf;
}

// --- Teleport command (direct position set) ---

static void handleTeleport(const json& cmd)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "teleport: BLOCKED — test mode disabled (use set_test_mode to enable)";
        return;
    }

    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "teleport: missing 'tile'";
        return;
    }

    int tile = cmd["tile"].get<int>();
    int elevation = gDude->elevation;
    if (cmd.contains("elevation") && cmd["elevation"].is_number_integer()) {
        elevation = cmd["elevation"].get<int>();
    }

    int oldTile = gDude->tile;
    int oldElev = gDude->elevation;

    objectSetLocation(gDude, tile, elevation, nullptr);

    if (elevation != oldElev) {
        mapSetElevation(elevation);
    }

    tileSetCenter(gDude->tile, TILE_SET_CENTER_REFRESH_WINDOW);

    // Force object re-enumeration after position/elevation change
    agentForceObjectRefresh();

    char buf[128];
    snprintf(buf, sizeof(buf), "teleport: %d/%d -> %d/%d (gDude->tile=%d)",
        oldTile, oldElev, tile, elevation, gDude->tile);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Container interaction ---

static void handleOpenContainer(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        gAgentLastCommandDebug = "open_container: missing 'object_id'";
        return;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "open_container: animation busy";
        return;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        gAgentLastCommandDebug = "open_container: object " + std::to_string(objId) + " not found";
        return;
    }

    int distance = objectGetDistanceBetween(gDude, target);

    if (distance > 5) {
        // Too far — walk to it first via actionPickUp (will trigger loot on arrival)
        actionPickUp(gDude, target);
        char buf[128];
        snprintf(buf, sizeof(buf), "open_container: walking to id=%lu (dist=%d)", (unsigned long)objId, distance);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: %s\n", buf);
        return;
    }

    // Player is close enough — open the loot screen directly.
    // inventoryOpenLooting has a frame check: if the container has multiple
    // frames and frame==0 (closed), it rejects the call. We handle this by
    // opening the container first via _obj_use_container, which also handles
    // lock checks and scripts. But that plays an async animation. So instead,
    // we directly call inventoryOpenLooting and handle the frame issue.
    //
    // For single-frame containers (frame check passes) this just works.
    // For multi-frame containers, we set frame=1 before calling, since the
    // visual open animation is not critical for the agent.
    if (FID_TYPE(target->fid) == OBJ_TYPE_ITEM) {
        Proto* proto;
        if (protoGetProto(target->pid, &proto) != -1 && proto->item.type == ITEM_TYPE_CONTAINER) {
            // Check if locked
            if (objectIsLocked(target)) {
                gAgentLastCommandDebug = "open_container: locked";
                debugPrint("AgentBridge: open_container: locked\n");
                return;
            }

            // Handle multi-frame containers: set frame to "open" state
            if (target->frame == 0) {
                CacheEntry* handle;
                Art* frm = artLock(target->fid, &handle);
                if (frm != nullptr) {
                    int frameCount = artGetFrameCount(frm);
                    artUnlock(handle);
                    if (frameCount > 1) {
                        // Set frame to open state so inventoryOpenLooting passes
                        objectSetFrame(target, 1, nullptr);
                    }
                }
            }
        }
    }

    inventoryOpenLooting(gDude, target);

    char buf[128];
    snprintf(buf, sizeof(buf), "open_container: id=%lu (direct)", (unsigned long)objId);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Loot/container commands ---

static void handleLootTake(const json& cmd)
{
    Object* target = inven_get_current_target_obj();
    if (target == nullptr) {
        gAgentLastCommandDebug = "loot_take: no loot target";
        return;
    }

    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "loot_take: missing 'item_pid'";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    // Find the item in the container's inventory
    Object* item = objectGetCarriedObjectByPid(target, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "loot_take: item pid " + std::to_string(itemPid) + " not in container";
        return;
    }

    int rc = itemMove(target, gDude, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "loot_take: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleLootTakeAll()
{
    Object* target = inven_get_current_target_obj();
    if (target == nullptr) {
        gAgentLastCommandDebug = "loot_take_all: no loot target";
        return;
    }

    int taken = 0;
    Inventory* inv = &target->data.inventory;
    int prevLength = inv->length;
    // Take items in reverse order since removing shifts the array
    while (inv->length > 0 && taken < 100) {
        InventoryItem* invItem = &inv->items[inv->length - 1];
        Object* item = invItem->item;
        int qty = invItem->quantity;
        if (item == nullptr)
            break;

        int rc = itemMove(target, gDude, item, qty);
        if (rc != 0)
            break;

        // Safety: ensure inventory actually shrank
        if (inv->length >= prevLength)
            break;
        prevLength = inv->length;
        taken++;
    }

    char buf[64];
    snprintf(buf, sizeof(buf), "loot_take_all: took %d item stacks", taken);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleLootClose()
{
    // Send Escape to close the loot screen
    enqueueInputEvent(KEY_ESCAPE);
    debugPrint("AgentBridge: loot_close (injected Escape)\n");
}

// --- World map commands ---

static void handleWorldmapTravel(const json& cmd)
{
    if (!cmd.contains("area_id") || !cmd["area_id"].is_number_integer()) {
        gAgentLastCommandDebug = "worldmap_travel: missing 'area_id'";
        return;
    }

    int areaId = cmd["area_id"].get<int>();

    if (!wmAreaIsKnown(areaId)) {
        // Auto-discover the area so we can travel to it
        wmAreaSetVisibleState(areaId, CITY_STATE_KNOWN, true);
    }

    // Initiate walking (player-like) instead of teleporting.
    // The engine handles walking naturally: wmPartyWalkingStep() moves
    // incrementally per frame, wmRndEncounterOccurred() checks for random
    // encounters, and arrival is detected when walkDistance <= 0.
    int rc = agentWmStartWalkingToArea(areaId);
    char buf[128];
    snprintf(buf, sizeof(buf), "worldmap_travel: walking to area %d rc=%d", areaId, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleWorldmapEnterLocation(const json& cmd)
{
    if (!cmd.contains("area_id") || !cmd["area_id"].is_number_integer()) {
        gAgentLastCommandDebug = "worldmap_enter_location: missing 'area_id'";
        return;
    }

    int areaId = cmd["area_id"].get<int>();
    int entranceIdx = 0;
    if (cmd.contains("entrance") && cmd["entrance"].is_number_integer()) {
        entranceIdx = cmd["entrance"].get<int>();
    }

    if (!wmAreaIsKnown(areaId)) {
        wmAreaSetVisibleState(areaId, CITY_STATE_KNOWN, true);
    }

    // Teleport to the area and mark as visited
    wmTeleportToArea(areaId);
    wmAreaMarkVisitedState(areaId, 2);

    // Look up the entrance's map index, elevation, tile
    int entMapIdx = -1, entElev = -1, entTile = -1, entState = -1;
    if (agentWmGetAreaEntrance(areaId, entranceIdx, &entMapIdx, &entElev, &entTile, &entState) != 0
        || entMapIdx < 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "worldmap_enter_location: invalid entrance %d for area %d",
            entranceIdx, areaId);
        gAgentLastCommandDebug = buf;
        return;
    }

    // Auto-discover the entrance if unknown
    if (entState != 1) {
        wmMapMarkMapEntranceState(entMapIdx, entElev, 1);
    }

    // Request the worldmap loop to load this map directly.
    // This bypasses the town map UI (and its SFALL hotkey fix that blocks
    // entrances with x/y == -1) by setting a pending map load that the
    // worldmap loop picks up on the next iteration.
    agentWmRequestMapLoad(entMapIdx, entElev, entTile, 0);

    agentForceObjectRefresh();

    char buf[128];
    snprintf(buf, sizeof(buf), "worldmap_enter_location: area=%d entrance=%d map=%d (direct load)",
        areaId, entranceIdx, entMapIdx);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Level-up commands (player-like: work through character editor UI) ---

static void handleSkillAdd(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        gAgentLastCommandDebug = "skill_add: missing 'skill'";
        return;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        gAgentLastCommandDebug = "skill_add: unknown skill '" + skillName + "'";
        return;
    }

    int skillId = it->second;

    // Set the editor's current skill selection, then inject the "+" button event.
    // The editor's characterEditorHandleAdjustSkillButtonPressed() will call
    // skillAdd(gDude, gCharacterEditorCurrentSkill) on the next inputGetInput().
    agentEditorSetCurrentSkill(skillId);
    enqueueInputEvent(CHAR_EDITOR_SKILL_PLUS);

    char buf[128];
    snprintf(buf, sizeof(buf), "skill_add: %s (injected button event, skill=%d sp=%d)",
        skillName.c_str(), skillId, pcGetStat(PC_STAT_UNSPENT_SKILL_POINTS));
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleSkillSub(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        gAgentLastCommandDebug = "skill_sub: missing 'skill'";
        return;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        gAgentLastCommandDebug = "skill_sub: unknown skill '" + skillName + "'";
        return;
    }

    int skillId = it->second;

    // Set the editor's current skill selection, then inject the "-" button event.
    agentEditorSetCurrentSkill(skillId);
    enqueueInputEvent(CHAR_EDITOR_SKILL_MINUS);

    char buf[128];
    snprintf(buf, sizeof(buf), "skill_sub: %s (injected button event, skill=%d sp=%d)",
        skillName.c_str(), skillId, pcGetStat(PC_STAT_UNSPENT_SKILL_POINTS));
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handlePerkAdd(const json& cmd)
{
    if (!cmd.contains("perk_id") || !cmd["perk_id"].is_number_integer()) {
        gAgentLastCommandDebug = "perk_add: missing 'perk_id'";
        return;
    }

    int perkId = cmd["perk_id"].get<int>();
    if (perkId < 0 || perkId >= PERK_COUNT) {
        gAgentLastCommandDebug = "perk_add: invalid perk_id " + std::to_string(perkId);
        return;
    }

    // Guard: only act when the perk dialog is open (i.e., editor has a free perk)
    if (!agentEditorHasFreePerk()) {
        gAgentLastCommandDebug = "perk_add: no free perk available (is perk dialog open?)";
        return;
    }

    // Position the perk dialog selection and inject KEY_RETURN to confirm.
    // The perk dialog's perkDialogHandleInput() processes KEY_RETURN as "Done".
    int rc = agentEditorSelectPerk(perkId);
    char* pName = perkGetName(perkId);
    char buf[128];
    if (rc == -1) {
        snprintf(buf, sizeof(buf), "perk_add: %s (id=%d) not available in dialog",
            pName ? pName : "?", perkId);
    } else {
        snprintf(buf, sizeof(buf), "perk_add: %s (id=%d) selected in dialog (injected RETURN)",
            pName ? pName : "?", perkId);
    }
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Barter commands ---

static void handleBarterOffer(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_offer: missing 'item_pid'";
        return;
    }

    Object* playerTable = agentGetBarterPlayerTable();
    if (playerTable == nullptr) {
        gAgentLastCommandDebug = "barter_offer: not in barter (no player table)";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_offer: item pid " + std::to_string(itemPid) + " not in player inventory";
        return;
    }

    int rc = itemMove(gDude, playerTable, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_offer: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleBarterRemoveOffer(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_remove_offer: missing 'item_pid'";
        return;
    }

    Object* playerTable = agentGetBarterPlayerTable();
    if (playerTable == nullptr) {
        gAgentLastCommandDebug = "barter_remove_offer: not in barter";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(playerTable, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_remove_offer: item pid " + std::to_string(itemPid) + " not in offer table";
        return;
    }

    int rc = itemMove(playerTable, gDude, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_remove_offer: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleBarterRequest(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_request: missing 'item_pid'";
        return;
    }

    if (gGameDialogSpeaker == nullptr) {
        gAgentLastCommandDebug = "barter_request: no merchant";
        return;
    }

    Object* merchantTable = agentGetBarterMerchantTable();
    if (merchantTable == nullptr) {
        gAgentLastCommandDebug = "barter_request: not in barter (no merchant table)";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(gGameDialogSpeaker, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_request: item pid " + std::to_string(itemPid) + " not in merchant inventory";
        return;
    }

    int rc = itemMove(gGameDialogSpeaker, merchantTable, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_request: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

static void handleBarterRemoveRequest(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_remove_request: missing 'item_pid'";
        return;
    }

    if (gGameDialogSpeaker == nullptr) {
        gAgentLastCommandDebug = "barter_remove_request: no merchant";
        return;
    }

    Object* merchantTable = agentGetBarterMerchantTable();
    if (merchantTable == nullptr) {
        gAgentLastCommandDebug = "barter_remove_request: not in barter";
        return;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(merchantTable, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_remove_request: item pid " + std::to_string(itemPid) + " not in offer table";
        return;
    }

    int rc = itemMove(merchantTable, gGameDialogSpeaker, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_remove_request: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
}

// --- Dialogue commands ---

static void handleSelectDialogue(const json& cmd)
{
    if (!cmd.contains("index") || !cmd["index"].is_number_integer()) {
        gAgentLastCommandDebug = "select_dialogue: missing 'index'";
        return;
    }

    if (!_gdialogActive()) {
        gAgentLastCommandDebug = "select_dialogue: no dialogue active";
        return;
    }

    int index = cmd["index"].get<int>();
    int optionCount = agentGetDialogOptionCount();

    if (index < 0 || index >= optionCount) {
        char buf[96];
        snprintf(buf, sizeof(buf), "select_dialogue: index %d out of range (options=%d)", index, optionCount);
        gAgentLastCommandDebug = buf;
        return;
    }

    // Dialogue options are selected by pressing keys '1'-'9'
    // In the engine, these are processed as ASCII characters
    enqueueInputEvent('1' + index);
    char buf[64];
    snprintf(buf, sizeof(buf), "select_dialogue: index=%d key='%c'", index, '1' + index);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: select_dialogue index %d\n", index);
}

// --- Command processing ---

void processCommands()
{
    FILE* f = fopen(kCmdPath, "rb");
    if (f == nullptr) {
        return;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    std::string content(size, '\0');
    fread(&content[0], 1, size, f);
    fclose(f);

    // Delete command file immediately after reading
    remove(kCmdPath);

    json doc;
    try {
        doc = json::parse(content);
    } catch (...) {
        debugPrint("AgentBridge: failed to parse command JSON\n");
        return;
    }

    if (!doc.contains("commands") || !doc["commands"].is_array()) {
        debugPrint("AgentBridge: missing 'commands' array\n");
        return;
    }

    // Process all commands in order
    for (const auto& cmd : doc["commands"]) {
        if (!cmd.contains("type") || !cmd["type"].is_string())
            continue;

        std::string type = cmd["type"].get<std::string>();

        // Skip command — works during movies by injecting an input event
        if (type == "skip") {
            enqueueInputEvent(KEY_ESCAPE);
            gAgentLastCommandDebug = "skip";
            debugPrint("AgentBridge: skip (injected escape event)\n");
        }
        // Main menu action — directly sets the menu result
        else if (type == "main_menu") {
            if (cmd.contains("action") && cmd["action"].is_string()) {
                std::string action = cmd["action"].get<std::string>();
                if (action == "new_game") gAgentMainMenuAction = 1;
                else if (action == "load_game") {
                    gAgentMainMenuAction = 2;
                    // Optional: specify a slot to bypass the load dialog entirely
                    if (cmd.contains("slot") && cmd["slot"].is_number_integer()) {
                        gAgentPendingLoadSlot = cmd["slot"].get<int>();
                    }
                }
                else if (action == "options") gAgentMainMenuAction = 3;
                else if (action == "exit") gAgentMainMenuAction = 4;
                gAgentLastCommandDebug = "main_menu: " + action;
                debugPrint("AgentBridge: main_menu action=%s\n", action.c_str());
            }
        }
        // Input injection
        else if (type == "mouse_move") {
            if (cmd.contains("x") && cmd.contains("y")) {
                int x = cmd["x"].get<int>();
                int y = cmd["y"].get<int>();
                _mouse_set_position(x, y);
            }
        } else if (type == "mouse_click") {
            if (cmd.contains("x") && cmd.contains("y")) {
                int x = cmd["x"].get<int>();
                int y = cmd["y"].get<int>();
                _mouse_set_position(x, y);

                int buttons = MOUSE_STATE_LEFT_BUTTON_DOWN;
                if (cmd.contains("button") && cmd["button"].is_string()) {
                    std::string button = cmd["button"].get<std::string>();
                    if (button == "right") {
                        buttons = MOUSE_STATE_RIGHT_BUTTON_DOWN;
                    }
                }

                _mouse_simulate_input(0, 0, buttons);
                _mouse_simulate_input(0, 0, 0);
            }
        } else if (type == "key_press") {
            if (cmd.contains("key") && cmd["key"].is_string()) {
                std::string keyName = cmd["key"].get<std::string>();
                auto it = gKeyNameToScancode.find(keyName);
                if (it != gKeyNameToScancode.end()) {
                    KeyboardData data;
                    data.key = it->second;
                    data.down = 1;
                    _kb_simulate_key(&data);
                } else {
                    debugPrint("AgentBridge: unknown key '%s'\n", keyName.c_str());
                }
            }
        } else if (type == "key_release") {
            if (cmd.contains("key") && cmd["key"].is_string()) {
                std::string keyName = cmd["key"].get<std::string>();
                auto it = gKeyNameToScancode.find(keyName);
                if (it != gKeyNameToScancode.end()) {
                    KeyboardData data;
                    data.key = it->second;
                    data.down = 0;
                    _kb_simulate_key(&data);
                } else {
                    debugPrint("AgentBridge: unknown key '%s'\n", keyName.c_str());
                }
            }
        }
        // Character editor commands
        else if (type == "adjust_stat") {
            handleAdjustStat(cmd);
        } else if (type == "toggle_trait") {
            handleToggleTrait(cmd);
        } else if (type == "toggle_skill_tag") {
            handleToggleSkillTag(cmd);
        } else if (type == "set_name") {
            handleSetName(cmd);
        } else if (type == "editor_done" || type == "finish_character_creation") {
            handleFinishCharacterCreation();
        }
        // Menu commands
        else if (type == "main_menu_select") {
            handleMainMenuSelect(cmd);
        } else if (type == "char_selector_select") {
            handleCharSelectorSelect(cmd);
        }
        // Exploration commands
        else if (type == "move_to") {
            handleMoveTo(cmd, false);
        } else if (type == "run_to") {
            handleMoveTo(cmd, true);
        } else if (type == "use_object") {
            handleUseObject(cmd);
        } else if (type == "pick_up") {
            handlePickUp(cmd);
        } else if (type == "use_skill") {
            handleUseSkill(cmd);
        } else if (type == "talk_to") {
            handleTalkTo(cmd);
        } else if (type == "use_item_on") {
            handleUseItemOn(cmd);
        } else if (type == "look_at") {
            handleLookAt(cmd);
        }
        // Interface commands
        else if (type == "switch_hand") {
            interfaceBarSwapHands(true);
            gAgentLastCommandDebug = "switch_hand: now hand " + std::to_string(interfaceGetCurrentHand());
            debugPrint("AgentBridge: switch_hand (now hand %d)\n", interfaceGetCurrentHand());
        } else if (type == "cycle_attack_mode") {
            interfaceCycleItemAction();
            gAgentLastCommandDebug = "cycle_attack_mode";
            debugPrint("AgentBridge: cycle_attack_mode\n");
        } else if (type == "center_camera") {
            tileSetCenter(gDude->tile, TILE_SET_CENTER_REFRESH_WINDOW);
            gAgentLastCommandDebug = "center_camera: tile=" + std::to_string(gDude->tile);
            debugPrint("AgentBridge: center_camera on tile %d\n", gDude->tile);
        } else if (type == "rest") {
            // Headless rest: incremental time advancement with event processing
            if (isInCombat()) {
                gAgentLastCommandDebug = "rest: cannot rest in combat";
            } else if (!_critter_can_obj_dude_rest()) {
                gAgentLastCommandDebug = "rest: cannot rest here (hostile critters or location)";
            } else {
                int hours = 1;
                if (cmd.contains("hours") && cmd["hours"].is_number_integer()) {
                    hours = cmd["hours"].get<int>();
                    if (hours < 1) hours = 1;
                    if (hours > 24) hours = 24;
                }
                bool interrupted = agentRest(hours, 0);
                int hp = critterGetHitPoints(gDude);
                int maxHp = critterGetStat(gDude, STAT_MAXIMUM_HIT_POINTS);
                char buf[128];
                snprintf(buf, sizeof(buf), "rest: %d hours%s hp=%d/%d",
                    hours, interrupted ? " (interrupted)" : "", hp, maxHp);
                gAgentLastCommandDebug = buf;
                debugPrint("AgentBridge: %s\n", buf);
            }
        } else if (type == "pip_boy") {
            enqueueInputEvent('p');
            gAgentLastCommandDebug = "pip_boy";
            debugPrint("AgentBridge: pip_boy (injected 'p')\n");
        } else if (type == "character_screen") {
            enqueueInputEvent('c');
            gAgentLastCommandDebug = "character_screen";
            debugPrint("AgentBridge: character_screen (injected 'c')\n");
        } else if (type == "inventory_open") {
            enqueueInputEvent('i');
            gAgentLastCommandDebug = "inventory_open";
            debugPrint("AgentBridge: inventory_open (injected 'i')\n");
        } else if (type == "skilldex") {
            enqueueInputEvent('s');
            gAgentLastCommandDebug = "skilldex";
            debugPrint("AgentBridge: skilldex (injected 's')\n");
        } else if (type == "toggle_sneak") {
            dudeToggleState(DUDE_STATE_SNEAKING);
            bool sneaking = dudeHasState(DUDE_STATE_SNEAKING);
            gAgentLastCommandDebug = std::string("toggle_sneak: now ") + (sneaking ? "sneaking" : "not sneaking");
            debugPrint("AgentBridge: toggle_sneak → %s\n", sneaking ? "on" : "off");
        }
        // Inventory commands
        else if (type == "reload_weapon") {
            handleReloadWeapon(cmd);
        } else if (type == "drop_item") {
            handleDropItem(cmd);
        } else if (type == "give_item") {
            handleGiveItem(cmd);
        } else if (type == "equip_item") {
            handleEquipItem(cmd);
        } else if (type == "unequip_item") {
            handleUnequipItem(cmd);
        } else if (type == "use_item") {
            handleUseItem(cmd);
        } else if (type == "use_equipped_item") {
            handleUseEquippedItem(cmd);
        }
        // Combat commands
        else if (type == "attack") {
            handleAttack(cmd);
        } else if (type == "combat_move") {
            handleCombatMove(cmd);
        } else if (type == "end_turn") {
            handleEndTurn();
        } else if (type == "use_combat_item") {
            handleUseCombatItem(cmd);
        } else if (type == "enter_combat") {
            // 'A' key initiates combat from exploration mode
            if (isInCombat()) {
                gAgentLastCommandDebug = "enter_combat: already in combat";
            } else {
                enqueueInputEvent('a');
                gAgentLastCommandDebug = "enter_combat: initiated";
            }
        } else if (type == "flee_combat") {
            // Enter key attempts to end combat (flee) — only works if enemies agree
            if (!isInCombat()) {
                gAgentLastCommandDebug = "flee_combat: not in combat";
            } else {
                enqueueInputEvent(KEY_RETURN);
                gAgentLastCommandDebug = "flee_combat: attempted";
            }
        }
        // Level-up commands
        else if (type == "skill_add") {
            handleSkillAdd(cmd);
        } else if (type == "skill_sub") {
            handleSkillSub(cmd);
        } else if (type == "perk_add") {
            handlePerkAdd(cmd);
        }
        // Dialogue commands
        else if (type == "select_dialogue") {
            handleSelectDialogue(cmd);
        }
        // Container interaction
        else if (type == "open_container") {
            handleOpenContainer(cmd);
        }
        // Loot/container commands
        else if (type == "loot_take") {
            handleLootTake(cmd);
        } else if (type == "loot_take_all") {
            handleLootTakeAll();
        } else if (type == "loot_close") {
            handleLootClose();
        }
        // Barter commands
        else if (type == "barter_offer") {
            handleBarterOffer(cmd);
        } else if (type == "barter_remove_offer") {
            handleBarterRemoveOffer(cmd);
        } else if (type == "barter_request") {
            handleBarterRequest(cmd);
        } else if (type == "barter_remove_request") {
            handleBarterRemoveRequest(cmd);
        } else if (type == "barter_confirm") {
            Object* ptbl = agentGetBarterPlayerTable();
            Object* mtbl = agentGetBarterMerchantTable();
            if (ptbl == nullptr || mtbl == nullptr || gGameDialogSpeaker == nullptr) {
                gAgentLastCommandDebug = "barter_confirm: not in barter";
            } else {
                int pitems = ptbl->data.inventory.length;
                int mitems = mtbl->data.inventory.length;
                int pval = objectGetCost(ptbl);

                if (pitems == 0 && mitems == 0) {
                    gAgentLastCommandDebug = "barter_confirm: nothing on tables";
                } else if (pitems == 0) {
                    gAgentLastCommandDebug = "barter_confirm: must offer something";
                } else {
                    // Replicate _barter_compute_value to check if trade will succeed
                    int partyBarter = partyGetBestSkillValue(SKILL_BARTER);
                    int npcBarter = skillGetValue(gGameDialogSpeaker, SKILL_BARTER);
                    double perkBonus = perkHasRank(gDude, PERK_MASTER_TRADER) ? 25.0 : 0.0;
                    int barterMod = agentGetBarterModifier();
                    double barterModMult = (barterMod + 100.0 - perkBonus) * 0.01;
                    if (barterModMult < 0) barterModMult = 0.0099999998;

                    int merchantOfferCaps = itemGetTotalCaps(mtbl);
                    int costWithoutCaps = objectGetCost(mtbl) - merchantOfferCaps;
                    double balancedCost = (160.0 + npcBarter) / (160.0 + partyBarter) * (costWithoutCaps * 2.0);
                    int merchantWants = (int)(barterModMult * balancedCost + merchantOfferCaps);

                    if (pval < merchantWants) {
                        char buf[256];
                        snprintf(buf, sizeof(buf),
                            "barter_confirm: rejected (offer=%d wants=%d)", pval, merchantWants);
                        gAgentLastCommandDebug = buf;
                    } else {
                        // Execute trade directly: move items between tables and owners
                        itemMoveAll(mtbl, gDude);
                        itemMoveAll(ptbl, gGameDialogSpeaker);

                        char buf[256];
                        snprintf(buf, sizeof(buf),
                            "barter_confirm: trade succeeded (offered=%d wanted=%d, %d+%d items)",
                            pval, merchantWants, pitems, mitems);
                        gAgentLastCommandDebug = buf;
                        debugPrint("AgentBridge: %s\n", buf);
                    }
                }
            }
        } else if (type == "barter_talk") {
            enqueueInputEvent('t');
            gAgentLastCommandDebug = "barter_talk";
            debugPrint("AgentBridge: barter_talk (injected 't')\n");
        } else if (type == "barter_cancel") {
            enqueueInputEvent(KEY_ESCAPE);
            gAgentLastCommandDebug = "barter_cancel";
            debugPrint("AgentBridge: barter_cancel (injected escape)\n");
        }
        // World map commands
        else if (type == "worldmap_travel") {
            handleWorldmapTravel(cmd);
        } else if (type == "worldmap_enter_location") {
            handleWorldmapEnterLocation(cmd);
        }
        // Pathfinding queries
        else if (type == "find_path") {
            handleFindPath(cmd);
        } else if (type == "tile_objects") {
            handleTileObjects(cmd);
        } else if (type == "find_item") {
            handleFindItem(cmd);
        } else if (type == "list_all_items") {
            handleListAllItems(cmd);
        } else if (type == "map_transition") {
            handleMapTransition(cmd);
        } else if (type == "teleport") {
            handleTeleport(cmd);
        }
        // Game management commands
        else if (type == "quicksave") {
            if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
                gAgentLastCommandDebug = "quicksave: not in gameplay context";
                debugPrint("AgentBridge: quicksave — not in gameplay context\n");
            } else {
                std::string desc = "Agent Save";
                if (cmd.contains("description") && cmd["description"].is_string()) {
                    desc = cmd["description"].get<std::string>();
                }
                int rc = agentQuickSave(desc.c_str());
                gAgentLastCommandDebug = "quicksave: rc=" + std::to_string(rc) + " desc=" + desc;
                debugPrint("AgentBridge: quicksave result=%d\n", rc);
            }
        } else if (type == "quickload") {
            if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
                gAgentLastCommandDebug = "quickload: not in gameplay context";
                debugPrint("AgentBridge: quickload — not in gameplay, ignoring\n");
            } else {
                int rc = agentQuickLoad();
                gAgentLastCommandDebug = "quickload: rc=" + std::to_string(rc);
                debugPrint("AgentBridge: quickload result=%d\n", rc);
            }
        } else if (type == "save_slot") {
            if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
                gAgentLastCommandDebug = "save_slot: not in gameplay context";
            } else {
                int slot = 0;
                if (cmd.contains("slot") && cmd["slot"].is_number_integer()) {
                    slot = cmd["slot"].get<int>();
                }
                std::string desc = "Agent Save";
                if (cmd.contains("description") && cmd["description"].is_string()) {
                    desc = cmd["description"].get<std::string>();
                }
                int rc = agentSaveToSlot(slot, desc.c_str());
                gAgentLastCommandDebug = "save_slot: slot=" + std::to_string(slot) + " rc=" + std::to_string(rc) + " desc=" + desc;
                debugPrint("AgentBridge: save_slot slot=%d result=%d\n", slot, rc);
            }
        } else if (type == "load_slot") {
            if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
                gAgentLastCommandDebug = "load_slot: not in gameplay context";
            } else {
                int slot = 0;
                if (cmd.contains("slot") && cmd["slot"].is_number_integer()) {
                    slot = cmd["slot"].get<int>();
                }
                int rc = agentLoadFromSlot(slot);
                gAgentLastCommandDebug = "load_slot: slot=" + std::to_string(slot) + " rc=" + std::to_string(rc);
                debugPrint("AgentBridge: load_slot slot=%d result=%d\n", slot, rc);
            }
        } else if (type == "input_event") {
            if (cmd.contains("key_code") && cmd["key_code"].is_number_integer()) {
                int keyCode = cmd["key_code"].get<int>();
                enqueueInputEvent(keyCode);
                gAgentLastCommandDebug = "input_event: code=" + std::to_string(keyCode);
                debugPrint("AgentBridge: input_event code=%d\n", keyCode);
            }
        }
        // Float thought text above player's head
        else if (type == "float_thought") {
            if (cmd.contains("text") && cmd["text"].is_string()) {
                std::string text = cmd["text"].get<std::string>();
                if (!text.empty() && gDude != nullptr) {
                    // Claude orange text (#DA7756), black outline — distinct from yellow NPC speech
                    Rect rect;
                    char* buf = strdup(text.c_str());
                    if (textObjectAdd(gDude, buf, 101, _colorTable[28106], _colorTable[0], &rect) == 0) {
                        tileWindowRefreshRect(&rect, gElevation);
                    }
                    free(buf);
                    gAgentLastCommandDebug = "float_thought: " + text.substr(0, 40);
                } else {
                    gAgentLastCommandDebug = "float_thought: empty text or no player";
                }
            } else {
                gAgentLastCommandDebug = "float_thought: missing text field";
            }
        }
        // Test mode toggle
        else if (type == "set_test_mode") {
            bool enabled = cmd.contains("enabled") && cmd["enabled"].is_boolean()
                && cmd["enabled"].get<bool>();
            gAgentTestMode = enabled;
            gAgentLastCommandDebug = std::string("set_test_mode: ") + (enabled ? "ON" : "OFF");
            debugPrint("AgentBridge: test mode %s\n", enabled ? "ON" : "OFF");
        } else {
            gAgentLastCommandDebug = "unknown_cmd: " + type;
            debugPrint("AgentBridge: unknown command type: %s\n", type.c_str());
        }
    }
}

} // namespace fallout
