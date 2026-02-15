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
#include "combat_ai.h"
#include "combat_ai_defs.h"
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
#include "text_font.h"
#include "text_object.h"
#include "tile.h"
#include "color.h"
#include "queue.h"
#include "random.h"
#include "scripts.h"
#include "pipboy.h"
#include "window_manager.h"
#include "word_wrap.h"
#include "draw.h"
#include "svga.h"
#include "worldmap.h"

namespace fallout {

std::string gAgentLastCommandDebug;
std::string gAgentLookAtResult;
std::map<std::string, int> gCommandFailureCounts;
json gAgentQueryResult;

// --- Dialogue thought overlay (direct screen blit, no window) ---
// Bottom edge flush with the NPC reply window top (Y=225 in game_dialog.cc)
static bool gAgentDialogueOverlayActive = false;
static const int kOverlayX = 80;
static const int kOverlayY = 0;
static const int kOverlayW = 480;
static const int kOverlayH = 240;
static const int kOverlayPadding = 10;

// Cached text buffer for persistent re-drawing (survives talking head refreshes)
static unsigned char* gOverlayCachedTextBuf = nullptr;
static int gOverlayCachedTextBufW = 0;
static int gOverlayCachedTextBufH = 0;
static int gOverlayCachedDestX = 0;
static int gOverlayCachedDestY = 0;

static void renderDialogueOverlay(const char* text)
{
    size_t textLen = strlen(text);
    if (textLen == 0)
        return;

    // Truncate very long text to prevent oversized breakpoints array
    char truncBuf[512];
    if (textLen > 500) {
        memcpy(truncBuf, text, 497);
        memcpy(truncBuf + 497, "...", 4);
        text = truncBuf;
        textLen = 500;
    }

    // Use font 101 (same as dialogue text and floating text objects)
    int oldFont = fontGetCurrent();
    fontSetCurrent(101);

    int textAreaW = kOverlayW - kOverlayPadding * 2;
    int lineHeight = fontGetLineHeight() + 1;

    // Word wrap
    short breakpoints[128];
    short lineCount = 0;
    if (wordWrap(text, textAreaW, breakpoints, &lineCount) != 0) {
        fontSetCurrent(oldFont);
        return;
    }

    // Cap lines to fit in overlay
    int maxLines = (kOverlayH - 4) / lineHeight;
    if (maxLines < 1)
        maxLines = 1;
    // If too many lines, show the LAST maxLines (most recent text at bottom)
    int firstLine = 0;
    if (lineCount > maxLines) {
        firstLine = lineCount - maxLines;
        lineCount = maxLines;
    }
    if (lineCount < 1) {
        fontSetCurrent(oldFont);
        return;
    }

    int totalTextHeight = lineCount * lineHeight;

    // Render text lines into a temp buffer with 2px padding for outline
    // (palette 0 = transparent for blitBufferToBufferTrans)
    int textBufW = textAreaW + 4; // 2px padding each side
    int textBufH = totalTextHeight + 4;
    if (textBufH < 4) {
        fontSetCurrent(oldFont);
        return;
    }
    unsigned char* textBuf = (unsigned char*)calloc(textBufW * textBufH, 1);
    if (textBuf == nullptr) {
        fontSetCurrent(oldFont);
        return;
    }

    int orangeColor = _colorTable[32322]; // bright orange RGB(248,144,16)

    for (int i = 0; i < lineCount; i++) {
        int srcLine = firstLine + i;
        int start = breakpoints[srcLine];
        int end = (srcLine + 1 < firstLine + lineCount) ? breakpoints[srcLine + 1] : (int)textLen;

        while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\n'))
            end--;
        if (end <= start)
            continue;

        char lineBuf[256];
        int len = end - start;
        if (len > 255)
            len = 255;
        memcpy(lineBuf, text + start, len);
        lineBuf[len] = '\0';

        int lineW = fontGetStringWidth(lineBuf);
        int lineX = (textBufW - lineW) / 2;
        if (lineX < 2)
            lineX = 2;
        int lineY = 2 + i * lineHeight; // offset by 2 for top padding

        int renderW = textBufW - lineX;
        if (renderW < 1)
            continue;

        fontDrawText(textBuf + lineY * textBufW + lineX, lineBuf, renderW, textBufW, orangeColor);
    }

    // Near-black outline: _colorTable[2114] = RGB(2,2,2) in 5-bit space
    // NOT palette 0, so blitBufferToBufferTrans won't skip it
    bufferOutline(textBuf, textBufW, textBufH, textBufW, _colorTable[2114]);

    // Composite all underlying windows into a scene buffer
    Rect overlayRect;
    overlayRect.left = kOverlayX;
    overlayRect.top = kOverlayY;
    overlayRect.right = kOverlayX + kOverlayW - 1;
    overlayRect.bottom = kOverlayY + kOverlayH - 1;

    unsigned char* sceneBuf = (unsigned char*)calloc(kOverlayW * kOverlayH, 1);
    if (sceneBuf == nullptr) {
        free(textBuf);
        fontSetCurrent(oldFont);
        return;
    }

    windowCompositeToBuffer(&overlayRect, sceneBuf);

    // Bottom-align text onto scene buffer using transparent blit
    // Center the text buffer horizontally, align to bottom
    int destX = (kOverlayW - textBufW) / 2;
    if (destX < 0)
        destX = 0;
    int destY = kOverlayH - textBufH;
    if (destY < 0)
        destY = 0;

    int blitW = textBufW;
    int blitH = textBufH;
    if (destX + blitW > kOverlayW)
        blitW = kOverlayW - destX;
    if (destY + blitH > kOverlayH)
        blitH = kOverlayH - destY;

    blitBufferToBufferTrans(textBuf, blitW, blitH, textBufW,
        sceneBuf + destY * kOverlayW + destX, kOverlayW);

    // Blit composited result directly to screen
    _scr_blit(sceneBuf, kOverlayW, kOverlayH, 0, 0,
        kOverlayW, kOverlayH, kOverlayX, kOverlayY);

    // Cache the text buffer for persistent re-drawing (talking heads overwrite us)
    if (gOverlayCachedTextBuf != nullptr)
        free(gOverlayCachedTextBuf);
    gOverlayCachedTextBuf = textBuf; // transfer ownership
    gOverlayCachedTextBufW = textBufW;
    gOverlayCachedTextBufH = textBufH;
    gOverlayCachedDestX = destX;
    gOverlayCachedDestY = destY;

    free(sceneBuf);

    fontSetCurrent(oldFont);
    gAgentDialogueOverlayActive = true;
}

void agentHideDialogueOverlay()
{
    if (gAgentDialogueOverlayActive) {
        gAgentDialogueOverlayActive = false;
        // Refresh the overlay area to restore underlying scene
        Rect overlayRect;
        overlayRect.left = kOverlayX;
        overlayRect.top = kOverlayY;
        overlayRect.right = kOverlayX + kOverlayW - 1;
        overlayRect.bottom = kOverlayY + kOverlayH - 1;
        windowRefreshAll(&overlayRect);
    }
    // Free cached text buffer
    if (gOverlayCachedTextBuf != nullptr) {
        free(gOverlayCachedTextBuf);
        gOverlayCachedTextBuf = nullptr;
    }
}

void agentDestroyDialogueOverlay()
{
    agentHideDialogueOverlay();
}

void agentRedrawDialogueOverlay()
{
    if (!gAgentDialogueOverlayActive || gOverlayCachedTextBuf == nullptr)
        return;

    // Re-composite scene + cached text + blit to screen
    Rect overlayRect;
    overlayRect.left = kOverlayX;
    overlayRect.top = kOverlayY;
    overlayRect.right = kOverlayX + kOverlayW - 1;
    overlayRect.bottom = kOverlayY + kOverlayH - 1;

    unsigned char* sceneBuf = (unsigned char*)calloc(kOverlayW * kOverlayH, 1);
    if (sceneBuf == nullptr)
        return;

    windowCompositeToBuffer(&overlayRect, sceneBuf);

    int blitW = gOverlayCachedTextBufW;
    int blitH = gOverlayCachedTextBufH;
    int destX = gOverlayCachedDestX;
    int destY = gOverlayCachedDestY;

    if (destX + blitW > kOverlayW)
        blitW = kOverlayW - destX;
    if (destY + blitH > kOverlayH)
        blitH = kOverlayH - destY;

    blitBufferToBufferTrans(gOverlayCachedTextBuf, blitW, blitH, gOverlayCachedTextBufW,
        sceneBuf + destY * kOverlayW + destX, kOverlayW);

    _scr_blit(sceneBuf, kOverlayW, kOverlayH, 0, 0,
        kOverlayW, kOverlayH, kOverlayX, kOverlayY);

    free(sceneBuf);
}

// --- Status overlay (top-left corner, shown during compaction/long pauses) ---
static bool gAgentStatusOverlayActive = false;
static std::string gAgentStatusText;
static unsigned int gAgentStatusStartTick = 0;

static const int kStatusX = 16;
static const int kStatusY = 8;
static const int kStatusW = 260;
static const int kStatusH = 24;

static void renderStatusOverlay()
{
    int dotCount = ((gAgentTick - gAgentStatusStartTick) / 20) % 3 + 1;
    std::string displayText = gAgentStatusText + std::string(dotCount, '.');

    int oldFont = fontGetCurrent();
    fontSetCurrent(101);

    unsigned char* textBuf = (unsigned char*)calloc(kStatusW * kStatusH, 1);
    if (textBuf == nullptr) {
        fontSetCurrent(oldFont);
        return;
    }

    fontDrawText(textBuf + 4 * kStatusW + 4, displayText.c_str(), kStatusW, kStatusW, _colorTable[32322]);
    bufferOutline(textBuf, kStatusW, kStatusH, kStatusW, _colorTable[2114]);

    Rect statusRect;
    statusRect.left = kStatusX;
    statusRect.top = kStatusY;
    statusRect.right = kStatusX + kStatusW - 1;
    statusRect.bottom = kStatusY + kStatusH - 1;

    unsigned char* sceneBuf = (unsigned char*)calloc(kStatusW * kStatusH, 1);
    if (sceneBuf == nullptr) {
        free(textBuf);
        fontSetCurrent(oldFont);
        return;
    }

    windowCompositeToBuffer(&statusRect, sceneBuf);
    blitBufferToBufferTrans(textBuf, kStatusW, kStatusH, kStatusW, sceneBuf, kStatusW);

    _scr_blit(sceneBuf, kStatusW, kStatusH, 0, 0, kStatusW, kStatusH, kStatusX, kStatusY);

    free(sceneBuf);
    free(textBuf);
    fontSetCurrent(oldFont);
}

void agentShowStatusOverlay(const char* text)
{
    gAgentStatusText = text != nullptr ? text : "";
    gAgentStatusOverlayActive = true;
    gAgentStatusStartTick = gAgentTick;
    renderStatusOverlay();
}

void agentHideStatusOverlay()
{
    if (gAgentStatusOverlayActive) {
        gAgentStatusOverlayActive = false;
        gAgentStatusText.clear();

        Rect statusRect;
        statusRect.left = kStatusX;
        statusRect.top = kStatusY;
        statusRect.right = kStatusX + kStatusW - 1;
        statusRect.bottom = kStatusY + kStatusH - 1;
        windowRefreshAll(&statusRect);
    }
}

void agentRedrawStatusOverlay()
{
    if (!gAgentStatusOverlayActive)
        return;

    if ((gAgentTick - gAgentStatusStartTick) > 1800) {
        agentHideStatusOverlay();
        return;
    }

    renderStatusOverlay();
}

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
        "attack(queued %d left): target=%llu hitMode=%d hitLoc=%d ap=%d dist=%d rc=%d",
        (int)gPendingAttacks.size(), (unsigned long long)atk.targetId,
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

static AgentCommandStatus handleSetName(const json& cmd)
{
    if (!cmd.contains("name") || !cmd["name"].is_string()) {
        debugPrint("AgentBridge: set_name missing 'name'\n");
        return AgentCommandStatus::BadArgs;
    }

    std::string name = cmd["name"].get<std::string>();
    if (name.empty() || name.length() > 32) {
        debugPrint("AgentBridge: set_name invalid length (%zu)\n", name.length());
        return AgentCommandStatus::BadArgs;
    }

    dudeSetName(name.c_str());
    debugPrint("AgentBridge: set_name applied '%s'\n", name.c_str());
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleFinishCharacterCreation()
{
    KeyboardData data;
    data.key = SDL_SCANCODE_RETURN;
    data.down = 1;
    _kb_simulate_key(&data);
    debugPrint("AgentBridge: finish_character_creation (injected RETURN)\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleAdjustStat(const json& cmd)
{
    if (!cmd.contains("stat") || !cmd["stat"].is_string()
        || !cmd.contains("direction") || !cmd["direction"].is_string()) {
        debugPrint("AgentBridge: adjust_stat missing 'stat' or 'direction'\n");
        return AgentCommandStatus::BadArgs;
    }

    std::string statName = cmd["stat"].get<std::string>();
    std::string direction = cmd["direction"].get<std::string>();

    auto it = gStatNameToId.find(statName);
    if (it == gStatNameToId.end()) {
        debugPrint("AgentBridge: adjust_stat unknown stat '%s'\n", statName.c_str());
        return AgentCommandStatus::BadArgs;
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
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleToggleTrait(const json& cmd)
{
    if (!cmd.contains("trait") || !cmd["trait"].is_string()) {
        debugPrint("AgentBridge: toggle_trait missing 'trait'\n");
        return AgentCommandStatus::BadArgs;
    }

    std::string traitName = cmd["trait"].get<std::string>();
    auto it = gTraitNameToId.find(traitName);
    if (it == gTraitNameToId.end()) {
        debugPrint("AgentBridge: toggle_trait unknown trait '%s'\n", traitName.c_str());
        return AgentCommandStatus::BadArgs;
    }

    int traitId = it->second;
    enqueueInputEvent(CHAR_EDITOR_TRAIT_BASE + traitId);
    debugPrint("AgentBridge: toggle_trait '%s' (injected button event)\n", traitName.c_str());
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleToggleSkillTag(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        debugPrint("AgentBridge: toggle_skill_tag missing 'skill'\n");
        return AgentCommandStatus::BadArgs;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        debugPrint("AgentBridge: toggle_skill_tag unknown skill '%s'\n", skillName.c_str());
        return AgentCommandStatus::BadArgs;
    }

    int skillId = it->second;
    enqueueInputEvent(CHAR_EDITOR_SKILL_TAG_BASE + skillId);
    debugPrint("AgentBridge: toggle_skill_tag '%s' (injected button event)\n", skillName.c_str());
    return AgentCommandStatus::Ok;
}

// --- Menu handlers ---

static AgentCommandStatus handleMainMenuOption(const std::string& option, const json* cmd = nullptr)
{
    if (option == "new_game") {
        gAgentMainMenuAction = 1;
        return AgentCommandStatus::Ok;
    }

    if (option == "load_game") {
        gAgentMainMenuAction = 2;
        if (cmd != nullptr && cmd->contains("slot") && (*cmd)["slot"].is_number_integer()) {
            gAgentPendingLoadSlot = (*cmd)["slot"].get<int>();
        }
        return AgentCommandStatus::Ok;
    }

    if (option == "options") {
        gAgentMainMenuAction = 3;
        return AgentCommandStatus::Ok;
    }

    if (option == "exit") {
        gAgentMainMenuAction = 4;
        return AgentCommandStatus::Ok;
    }

    static const std::unordered_map<std::string, int> keyOptions = {
        { "intro", SDL_SCANCODE_I },
        { "credits", SDL_SCANCODE_C },
    };

    auto it = keyOptions.find(option);
    if (it == keyOptions.end()) {
        return AgentCommandStatus::BadArgs;
    }

    KeyboardData data;
    data.key = it->second;
    data.down = 1;
    _kb_simulate_key(&data);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleMainMenuSelect(const json& cmd)
{
    if (!cmd.contains("option") || !cmd["option"].is_string()) {
        debugPrint("AgentBridge: main_menu_select missing 'option'\n");
        return AgentCommandStatus::BadArgs;
    }

    std::string option = cmd["option"].get<std::string>();
    AgentCommandStatus status = handleMainMenuOption(option);
    if (status != AgentCommandStatus::Ok) {
        debugPrint("AgentBridge: main_menu_select unknown option '%s'\n", option.c_str());
        return status;
    }

    debugPrint("AgentBridge: main_menu_select '%s'\n", option.c_str());
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleCharSelectorSelect(const json& cmd)
{
    if (!cmd.contains("option") || !cmd["option"].is_string()) {
        debugPrint("AgentBridge: char_selector_select missing 'option'\n");
        return AgentCommandStatus::BadArgs;
    }

    std::string option = cmd["option"].get<std::string>();

    static const std::unordered_map<std::string, int> optionToScancode = {
        { "create_custom", SDL_SCANCODE_C },
        { "take_premade", SDL_SCANCODE_T },
        { "modify_premade", SDL_SCANCODE_M },
        { "next", SDL_SCANCODE_RIGHT },
        { "previous", SDL_SCANCODE_LEFT },
        { "back", SDL_SCANCODE_B },
    };

    auto it = optionToScancode.find(option);
    if (it == optionToScancode.end()) {
        debugPrint("AgentBridge: char_selector_select unknown option '%s'\n", option.c_str());
        return AgentCommandStatus::BadArgs;
    }

    KeyboardData data;
    data.key = it->second;
    data.down = 1;
    _kb_simulate_key(&data);
    debugPrint("AgentBridge: char_selector_select '%s'\n", option.c_str());
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleMainMenuCommand(const json& cmd)
{
    if (!cmd.contains("action") || !cmd["action"].is_string()) {
        gAgentLastCommandDebug = "main_menu: missing 'action'";
        debugPrint("AgentBridge: main_menu missing 'action'\n");
        return AgentCommandStatus::BadArgs;
    }

    std::string action = cmd["action"].get<std::string>();
    AgentCommandStatus status = handleMainMenuOption(action, &cmd);
    if (status == AgentCommandStatus::Ok) {
        gAgentLastCommandDebug = "main_menu: " + action;
        debugPrint("AgentBridge: main_menu action=%s\n", action.c_str());
    } else {
        gAgentLastCommandDebug = "main_menu: unknown action '" + action + "'";
        debugPrint("AgentBridge: main_menu unknown action '%s'\n", action.c_str());
    }

    return status;
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

static AgentCommandStatus handleMoveTo(const json& cmd, bool run)
{
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = std::string(run ? "run_to" : "move_to") + ": missing 'tile'";
        debugPrint("AgentBridge: move_to/run_to missing 'tile'\n");
        return AgentCommandStatus::BadArgs;
    }

    int tile = cmd["tile"].get<int>();

    // Block exploration movement during combat — use combat_move instead
    if (isInCombat()) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d rejected (in combat — use combat_move)", run ? "run_to" : "move_to", tile);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: %s rejected — in combat\n", run ? "run_to" : "move_to");
        return AgentCommandStatus::Blocked;
    }

    // Cancel any existing queued movement
    gMoveWaypointCount = 0;

    if (animationIsBusy(gDude)) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d skipped (animation busy)", run ? "run_to" : "move_to", tile);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: move_to/run_to skipped — animation busy\n");
        return AgentCommandStatus::Blocked;
    }

    // Check path length first
    unsigned char rotations[2000];
    int pathLen = _make_path(gDude, gDude->tile, tile, rotations, 0);

    if (pathLen == 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s: tile=%d no path from %d", run ? "run_to" : "move_to", tile, gDude->tile);
        gAgentLastCommandDebug = buf;
        debugPrint("AgentBridge: move_to/run_to no path\n");
        return AgentCommandStatus::Failed;
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
        return AgentCommandStatus::Ok;
    }

    // Short path — direct movement
    if (reg_anim_begin(ANIMATION_REQUEST_RESERVED) != 0) {
        gAgentLastCommandDebug = std::string(run ? "run_to" : "move_to") + ": reg_anim_begin failed";
        debugPrint("AgentBridge: move_to/run_to reg_anim_begin failed\n");
        return AgentCommandStatus::Failed;
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
        return AgentCommandStatus::Failed;
    }

    reg_anim_end();

    // Scroll viewport toward destination so the camera follows the character
    tileSetCenter(tile, TILE_SET_CENTER_REFRESH_WINDOW);

    char buf[128];
    snprintf(buf, sizeof(buf), "%s: tile=%d from=%d", run ? "run_to" : "move_to", tile, gDude->tile);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s to tile %d\n", run ? "run_to" : "move_to", tile);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleUseObject(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: use_object missing 'object_id'\n");
        return AgentCommandStatus::BadArgs;
    }

    if (animationIsBusy(gDude)) {
        debugPrint("AgentBridge: use_object skipped — animation busy\n");
        return AgentCommandStatus::Blocked;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: use_object object %llu not found\n", (unsigned long long)objId);
        return AgentCommandStatus::Failed;
    }

    _action_use_an_object(gDude, target);
    char buf[128];
    snprintf(buf, sizeof(buf), "use_object: id=%llu name=%s", (unsigned long long)objId, safeName(target));
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: use_object on %llu\n", (unsigned long long)objId);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleOpenDoor(const json& cmd)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "open_door: BLOCKED — test mode disabled (use use_object instead)";
        return AgentCommandStatus::Blocked;
    }

    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        gAgentLastCommandDebug = "open_door: missing object_id";
        return AgentCommandStatus::BadArgs;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* door = findObjectByUniqueId(objId);
    if (door == nullptr) {
        gAgentLastCommandDebug = "open_door: object " + std::to_string(objId) + " not found";
        return AgentCommandStatus::Failed;
    }

    // Verify it's a door
    if (PID_TYPE(door->pid) != OBJ_TYPE_SCENERY) {
        gAgentLastCommandDebug = "open_door: not a scenery object";
        return AgentCommandStatus::BadArgs;
    }
    Proto* proto;
    if (protoGetProto(door->pid, &proto) == -1 || proto->scenery.type != SCENERY_TYPE_DOOR) {
        gAgentLastCommandDebug = "open_door: not a door";
        return AgentCommandStatus::BadArgs;
    }

    // Check distance (must be adjacent)
    int dist = objectGetDistanceBetween(gDude, door);
    if (dist > 1) {
        char buf[128];
        snprintf(buf, sizeof(buf), "open_door: too far (dist=%d, need <=1)", dist);
        gAgentLastCommandDebug = buf;
        return AgentCommandStatus::Failed;
    }

    if (objectIsLocked(door)) {
        gAgentLastCommandDebug = "open_door: door is locked";
        return AgentCommandStatus::Blocked;
    }

    if (objectIsOpen(door)) {
        gAgentLastCommandDebug = "open_door: already open";
        return AgentCommandStatus::NoOp;
    }

    // Directly set door open state (bypasses animation system for combat compatibility)
    // Replicate what _set_door_state_open + _check_door_state does
    door->data.scenery.door.openFlags |= 0x01;

    // Set OBJECT_OPEN_DOOR flags (= SHOOT_THRU | LIGHT_THRU | NO_BLOCK)
    // so pathfinding treats the tile as passable
    door->flags |= OBJECT_OPEN_DOOR;

    // Unblock ALL co-located objects that could block pathfinding
    // _obj_blocking_at checks critters, scenery, AND walls
    Object* coObj = objectFindFirstAtLocation(door->elevation, door->tile);
    while (coObj != nullptr) {
        if (coObj != door) {
            int coType = FID_TYPE(coObj->fid);
            if (coType == OBJ_TYPE_SCENERY || coType == OBJ_TYPE_WALL) {
                coObj->flags |= OBJECT_NO_BLOCK;
                debugPrint("AgentBridge: open_door unblocked co-object type=%d flags=0x%x at tile=%d\n",
                    coType, coObj->flags, door->tile);
            }
        }
        coObj = objectFindNextAtLocation();
    }

    // Set frame to fully open position
    Art* art = nullptr;
    CacheEntry* artHandle = nullptr;
    art = artLock(door->fid, &artHandle);
    if (art != nullptr) {
        int frameCount = artGetFrameCount(art);
        Rect dirty;
        objectGetRect(door, &dirty);
        objectSetFrame(door, frameCount - 1, &dirty);
        tileWindowRefreshRect(&dirty, door->elevation);
        artUnlock(artHandle);
    }

    // Rebuild lighting and refresh display
    _obj_rebuild_all_light();
    tileWindowRefresh();

    char buf[128];
    snprintf(buf, sizeof(buf), "open_door: opened door id=%llu at tile=%d", (unsigned long long)objId, door->tile);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    agentForceObjectRefresh();
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handlePickUp(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: pick_up missing 'object_id'\n");
        return AgentCommandStatus::BadArgs;
    }

    if (animationIsBusy(gDude)) {
        debugPrint("AgentBridge: pick_up skipped — animation busy\n");
        return AgentCommandStatus::Blocked;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: pick_up object %llu not found\n", (unsigned long long)objId);
        return AgentCommandStatus::Failed;
    }

    actionPickUp(gDude, target);
    char buf[128];
    snprintf(buf, sizeof(buf), "pick_up: id=%llu name=%s", (unsigned long long)objId, safeName(target));
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: pick_up on %llu\n", (unsigned long long)objId);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleUseSkill(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        debugPrint("AgentBridge: use_skill missing 'skill'\n");
        return AgentCommandStatus::BadArgs;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "use_skill: animation busy";
        debugPrint("AgentBridge: use_skill skipped — animation busy\n");
        return AgentCommandStatus::Blocked;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        gAgentLastCommandDebug = "use_skill: unknown skill " + skillName;
        debugPrint("AgentBridge: use_skill unknown skill '%s'\n", skillName.c_str());
        return AgentCommandStatus::BadArgs;
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
            return AgentCommandStatus::Failed;
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
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleTalkTo(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: talk_to missing 'object_id'\n");
        return AgentCommandStatus::BadArgs;
    }

    if (animationIsBusy(gDude)) {
        debugPrint("AgentBridge: talk_to skipped — animation busy\n");
        return AgentCommandStatus::Blocked;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: talk_to object %llu not found\n", (unsigned long long)objId);
        return AgentCommandStatus::Failed;
    }

    // Check if the NPC is nearby but blocked by a counter/wall
    int dist = objectGetDistanceBetween(gDude, target);
    bool blocked = _combat_is_shot_blocked(gDude, gDude->tile, target->tile, target, nullptr);

    if (dist < 12 && blocked) {
        // NPC is close but line-of-sight blocked (behind counter/wall).
        // Directly request dialogue instead of trying to pathfind.
        scriptsRequestDialog(target);
        char buf[128];
        snprintf(buf, sizeof(buf), "talk_to: id=%llu name=%s (direct, dist=%d)", (unsigned long long)objId, safeName(target), dist);
        gAgentLastCommandDebug = buf;
    } else {
        actionTalk(gDude, target);
        char buf[128];
        snprintf(buf, sizeof(buf), "talk_to: id=%llu name=%s", (unsigned long long)objId, safeName(target));
        gAgentLastCommandDebug = buf;
    }
    debugPrint("AgentBridge: talk_to %llu\n", (unsigned long long)objId);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleUseItemOn(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()
        || !cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: use_item_on missing 'item_pid' or 'object_id'\n");
        return AgentCommandStatus::BadArgs;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "use_item_on: animation busy";
        return AgentCommandStatus::Blocked;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "use_item_on: pid " + std::to_string(itemPid) + " not in inventory";
        return AgentCommandStatus::Failed;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        gAgentLastCommandDebug = "use_item_on: target " + std::to_string(objId) + " not found";
        return AgentCommandStatus::Failed;
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
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleLookAt(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        debugPrint("AgentBridge: look_at missing 'object_id'\n");
        return AgentCommandStatus::BadArgs;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        debugPrint("AgentBridge: look_at object %llu not found\n", (unsigned long long)objId);
        return AgentCommandStatus::Failed;
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
    return AgentCommandStatus::Ok;
}

// --- Inventory commands ---

static AgentCommandStatus handleEquipItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        debugPrint("AgentBridge: equip_item missing 'item_pid'\n");
        return AgentCommandStatus::BadArgs;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        debugPrint("AgentBridge: equip_item pid %d not found in inventory\n", itemPid);
        return AgentCommandStatus::Failed;
    }

    int hand = HAND_RIGHT;
    if (cmd.contains("hand") && cmd["hand"].is_string()) {
        std::string handStr = cmd["hand"].get<std::string>();
        if (handStr == "left")
            hand = HAND_LEFT;
    }

    int rc;
    if (itemGetType(item) == ITEM_TYPE_MISC) {
        // _inven_wield reads weapon animation codes from proto union data,
        // which is garbage for misc items, causing artExists() to fail.
        // Directly set hand flags like the inventory UI's _switch_hand() does.
        Object* oldItem = (hand == HAND_RIGHT) ? critterGetItem2(gDude) : critterGetItem1(gDude);
        if (oldItem != nullptr) {
            oldItem->flags &= ~OBJECT_IN_ANY_HAND;
        }
        item->flags &= ~OBJECT_IN_ANY_HAND;
        if (hand == HAND_RIGHT) {
            item->flags |= OBJECT_IN_RIGHT_HAND;
        } else {
            item->flags |= OBJECT_IN_LEFT_HAND;
        }
        rc = 0;
    } else {
        rc = _inven_wield(gDude, item, hand);
    }
    interfaceUpdateItems(false, INTERFACE_ITEM_ACTION_DEFAULT, INTERFACE_ITEM_ACTION_DEFAULT);
    gAgentLastCommandDebug = "equip_item: pid=" + std::to_string(itemPid)
        + " hand=" + (hand == HAND_LEFT ? "left" : "right")
        + " rc=" + std::to_string(rc);
    debugPrint("AgentBridge: equip_item pid %d in %s hand rc=%d\n", itemPid, hand == HAND_LEFT ? "left" : "right", rc);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleUnequipItem(const json& cmd)
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
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleUseItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "use_item: missing 'item_pid'";
        debugPrint("AgentBridge: use_item missing 'item_pid'\n");
        return AgentCommandStatus::BadArgs;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "use_item: pid " + std::to_string(itemPid) + " not found";
        debugPrint("AgentBridge: use_item pid %d not found in inventory\n", itemPid);
        return AgentCommandStatus::Failed;
    }

    int type = itemGetType(item);
    if (type == ITEM_TYPE_DRUG) {
        if (_item_d_take_drug(gDude, item) == 1) {
            // Remove the consumed drug from inventory and destroy it,
            // matching the engine's inventory screen behavior.
            itemRemove(gDude, item, 1);
            _obj_connect(item, gDude->tile, gDude->elevation, nullptr);
            _obj_destroy(item);
        }
        interfaceRenderHitPoints(true);
        gAgentLastCommandDebug = "use_item: drug pid=" + std::to_string(itemPid);
        debugPrint("AgentBridge: use_item (drug) pid %d\n", itemPid);
    } else {
        // Try generic proto instance use (handles flares, books, radios, etc.)
        int rc = _obj_use_item(gDude, item);
        if (rc == 0 || rc == 2) {
            gAgentLastCommandDebug = "use_item: used pid=" + std::to_string(itemPid) + " rc=" + std::to_string(rc);
            debugPrint("AgentBridge: use_item (generic) pid %d rc=%d\n", itemPid, rc);
            return AgentCommandStatus::Ok;
        } else {
            gAgentLastCommandDebug = "use_item: unsupported type " + std::to_string(type);
            debugPrint("AgentBridge: use_item pid %d — unsupported item type %d\n", itemPid, type);
            return AgentCommandStatus::Failed;
        }
    }
    return AgentCommandStatus::Ok;
}

// --- Use equipped item (player-like: equip to hand → use from game screen) ---

static AgentCommandStatus handleUseEquippedItem(const json& cmd)
{
    Object* item = nullptr;
    if (interfaceGetActiveItem(&item) == -1 || item == nullptr) {
        gAgentLastCommandDebug = "use_equipped_item: no item in active hand";
        return AgentCommandStatus::Failed;
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
    return (rc == 0 || rc == 2) ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

// --- Reload weapon ---

static AgentCommandStatus handleReloadWeapon(const json& cmd)
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
        return AgentCommandStatus::Failed;
    }

    if (itemGetType(weapon) != ITEM_TYPE_WEAPON) {
        gAgentLastCommandDebug = "reload_weapon: held item is not a weapon";
        return AgentCommandStatus::BadArgs;
    }

    int capacity = ammoGetCapacity(weapon);
    if (capacity <= 0) {
        gAgentLastCommandDebug = "reload_weapon: weapon doesn't use ammo";
        return AgentCommandStatus::BadArgs;
    }

    int currentAmmo = ammoGetQuantity(weapon);
    if (currentAmmo >= capacity) {
        gAgentLastCommandDebug = "reload_weapon: already full (" + std::to_string(currentAmmo) + "/" + std::to_string(capacity) + ")";
        return AgentCommandStatus::NoOp;
    }

    // If a specific ammo PID is provided, use it; otherwise find compatible ammo
    Object* ammo = nullptr;
    if (cmd.contains("ammo_pid") && cmd["ammo_pid"].is_number_integer()) {
        int ammoPid = cmd["ammo_pid"].get<int>();
        ammo = objectGetCarriedObjectByPid(gDude, ammoPid);
        if (ammo == nullptr) {
            gAgentLastCommandDebug = "reload_weapon: ammo pid " + std::to_string(ammoPid) + " not in inventory";
            return AgentCommandStatus::Failed;
        }
        if (!weaponCanBeReloadedWith(weapon, ammo)) {
            gAgentLastCommandDebug = "reload_weapon: incompatible ammo pid " + std::to_string(ammoPid);
            return AgentCommandStatus::BadArgs;
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
            return AgentCommandStatus::Failed;
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
    return AgentCommandStatus::Ok;
}

// --- Drop item ---

static AgentCommandStatus handleDropItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "drop_item: missing 'item_pid'";
        return AgentCommandStatus::BadArgs;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }
    if (quantity < 1) {
        gAgentLastCommandDebug = "drop_item: quantity must be >= 1";
        return AgentCommandStatus::BadArgs;
    }

    if (objectGetCarriedObjectByPid(gDude, itemPid) == nullptr) {
        gAgentLastCommandDebug = "drop_item: pid " + std::to_string(itemPid) + " not in inventory";
        return AgentCommandStatus::Failed;
    }

    int dropped = 0;
    for (int i = 0; i < quantity; i++) {
        // Re-fetch each iteration: splitting stacks can replace the inventory object pointer.
        Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
        if (item == nullptr)
            break;

        int rc = itemRemove(gDude, item, 1);
        if (rc != 0) {
            if (dropped == 0) {
                gAgentLastCommandDebug = "drop_item: itemRemove failed rc=" + std::to_string(rc);
                return AgentCommandStatus::Failed;
            }
            break;
        }

        rc = _obj_connect(item, gDude->tile, gDude->elevation, nullptr);
        if (rc != 0) {
            // Failed to place this item — return it to inventory and stop.
            itemAdd(gDude, item, 1);
            if (dropped == 0) {
                gAgentLastCommandDebug = "drop_item: _obj_connect failed, item returned to inventory";
                return AgentCommandStatus::Failed;
            }
            break;
        }

        dropped++;
    }

    interfaceUpdateItems(false, INTERFACE_ITEM_ACTION_DEFAULT, INTERFACE_ITEM_ACTION_DEFAULT);

    char buf[128];
    snprintf(buf, sizeof(buf), "drop_item: pid=%d qty=%d/%d tile=%d",
        itemPid, dropped, quantity, gDude->tile);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return dropped > 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleGiveItem(const json& cmd)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "give_item: BLOCKED — test mode disabled";
        return AgentCommandStatus::Blocked;
    }

    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "give_item: missing 'item_pid'";
        return AgentCommandStatus::BadArgs;
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
            return AgentCommandStatus::Failed;
        }

        rc = itemAdd(gDude, item, 1);
        if (rc != 0) {
            objectDestroy(item, nullptr);
            char buf[128];
            snprintf(buf, sizeof(buf), "give_item: failed to add pid=%d to inventory (rc=%d)", itemPid, rc);
            gAgentLastCommandDebug = buf;
            return AgentCommandStatus::Failed;
        }
    }

    char buf[128];
    snprintf(buf, sizeof(buf), "give_item: pid=%d qty=%d", itemPid, quantity);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return AgentCommandStatus::Ok;
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

static AgentCommandStatus handleAttack(const json& cmd)
{
    if (!cmd.contains("target_id") || !cmd["target_id"].is_number_integer()) {
        gAgentLastCommandDebug = "attack: missing target_id";
        return AgentCommandStatus::BadArgs;
    }

    if (!isInCombat()) {
        // Auto-enter combat if not already in combat
        enqueueInputEvent('a');
        gAgentLastCommandDebug = "attack: entering combat first (send attack again next tick)";
        return AgentCommandStatus::Blocked;
    }

    uintptr_t targetId = cmd["target_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(targetId);
    if (target == nullptr) {
        gAgentLastCommandDebug = "attack: target " + std::to_string(targetId) + " not found";
        return AgentCommandStatus::Failed;
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
        return AgentCommandStatus::Failed;
    }

    // If animation busy, queue ALL attacks (including first)
    if (animationIsBusy(gDude)) {
        for (int i = 0; i < count; i++) {
            gPendingAttacks.push_back({ targetId, hitMode, hitLocation });
        }
        char buf[128];
        snprintf(buf, sizeof(buf), "attack: queued %d attacks (animation busy)", count);
        gAgentLastCommandDebug = buf;
        return AgentCommandStatus::Blocked;
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
        "attack: target=%llu hitMode=%d hitLoc=%d ap=%d dist=%d rc=%d queued=%d",
        (unsigned long long)targetId, hitMode, hitLocation, ap, dist, rc, count - 1);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleCombatMove(const json& cmd)
{
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "combat_move: missing 'tile'";
        return AgentCommandStatus::BadArgs;
    }

    if (!isInCombat()) {
        gAgentLastCommandDebug = "combat_move: not in combat";
        return AgentCommandStatus::Blocked;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "combat_move: animation busy";
        return AgentCommandStatus::Blocked;
    }

    int tile = cmd["tile"].get<int>();
    int ap = gDude->data.critter.combat.ap;

    if (ap <= 0) {
        gAgentLastCommandDebug = "combat_move: REJECTED — no AP remaining";
        return AgentCommandStatus::Blocked;
    }

    if (reg_anim_begin(ANIMATION_REQUEST_RESERVED) != 0) {
        gAgentLastCommandDebug = "combat_move: reg_anim_begin failed";
        return AgentCommandStatus::Failed;
    }

    if (animationRegisterMoveToTile(gDude, tile, gDude->elevation, ap, 0) != 0) {
        gAgentLastCommandDebug = "combat_move: no path or register failed";
        reg_anim_end();
        return AgentCommandStatus::Failed;
    }

    reg_anim_end();

    // Center viewport on destination
    tileSetCenter(tile, TILE_SET_CENTER_REFRESH_WINDOW);

    char buf[128];
    snprintf(buf, sizeof(buf), "combat_move: tile=%d from=%d ap=%d", tile, gDude->tile, ap);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: combat_move to tile %d\n", tile);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleEndTurn()
{
    if (!isInCombat()) {
        gAgentLastCommandDebug = "end_turn: not in combat";
        debugPrint("AgentBridge: end_turn — not in combat\n");
        return AgentCommandStatus::Blocked;
    }

    // Space key ends the player's turn in the combat input loop
    enqueueInputEvent(32); // ASCII space = 32
    gAgentLastCommandDebug = "end_turn: ap=" + std::to_string(gDude->data.critter.combat.ap);
    debugPrint("AgentBridge: end_turn\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleUseCombatItem(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "use_combat_item: missing 'item_pid'";
        debugPrint("AgentBridge: use_combat_item missing 'item_pid'\n");
        return AgentCommandStatus::BadArgs;
    }

    if (!isInCombat()) {
        gAgentLastCommandDebug = "use_combat_item: not in combat";
        debugPrint("AgentBridge: use_combat_item — not in combat\n");
        return AgentCommandStatus::Blocked;
    }

    int itemPid = cmd["item_pid"].get<int>();
    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "use_combat_item: pid " + std::to_string(itemPid) + " not found";
        debugPrint("AgentBridge: use_combat_item pid %d not found\n", itemPid);
        return AgentCommandStatus::Failed;
    }

    int type = itemGetType(item);
    if (type == ITEM_TYPE_DRUG) {
        if (_item_d_take_drug(gDude, item) == 1) {
            itemRemove(gDude, item, 1);
            _obj_connect(item, gDude->tile, gDude->elevation, nullptr);
            _obj_destroy(item);
        }
        interfaceRenderHitPoints(true);
        if (gDude->data.critter.combat.ap >= 2) {
            gDude->data.critter.combat.ap -= 2;
        }
        gAgentLastCommandDebug = "use_combat_item: drug pid=" + std::to_string(itemPid);
        debugPrint("AgentBridge: use_combat_item (drug) pid %d\n", itemPid);
        return AgentCommandStatus::Ok;
    } else {
        gAgentLastCommandDebug = "use_combat_item: unsupported type " + std::to_string(type);
        debugPrint("AgentBridge: use_combat_item pid %d — unsupported type %d\n", itemPid, type);
        return AgentCommandStatus::Failed;
    }
}

// --- Pathfinding / navigation queries ---

static AgentCommandStatus handleFindPath(const json& cmd)
{
    if (!cmd.contains("to") || !cmd["to"].is_number_integer()) {
        gAgentLastCommandDebug = "find_path: missing 'to' tile";
        gAgentQueryResult = json::object({ { "type", "find_path" }, { "error", "missing 'to' tile" } });
        return AgentCommandStatus::BadArgs;
    }

    int from = gDude->tile;
    if (cmd.contains("from") && cmd["from"].is_number_integer()) {
        from = cmd["from"].get<int>();
    }
    int to = cmd["to"].get<int>();
    json query = json::object();
    query["type"] = "find_path";
    query["from"] = from;
    query["to"] = to;

    unsigned char rotations[2000];
    int pathLen = _make_path(gDude, from, to, rotations, 0);

    if (pathLen == 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "find_path: no path from %d to %d (len=0)", from, to);
        gAgentLastCommandDebug = buf;
        query["path_exists"] = false;
        query["path_length"] = 0;
        query["waypoints"] = json::array();
        gAgentQueryResult = query;
        return AgentCommandStatus::Failed;
    }

    // Convert rotations to tile waypoints spaced ~15 tiles apart.
    // Each waypoint is reachable from the previous in a single move_to/run_to call
    // (engine per-move pathfinder handles ~20 tiles).
    std::string waypoints = "[";
    json waypointList = json::array();
    int currentTile = from;
    int waypointSpacing = 15; // tiles between waypoints
    int lastWaypointIdx = 0;

    for (int i = 0; i < pathLen; i++) {
        currentTile = tileGetTileInDirection(currentTile, rotations[i], 1);
        if ((i - lastWaypointIdx >= waypointSpacing) || i == pathLen - 1) {
            if (waypoints.length() > 1) waypoints += ",";
            waypoints += std::to_string(currentTile);
            waypointList.push_back(currentTile);
            lastWaypointIdx = i;
        }
    }
    waypoints += "]";

    query["path_exists"] = true;
    query["path_length"] = pathLen;
    query["waypoints"] = waypointList;
    gAgentQueryResult = query;

    char buf[256];
    snprintf(buf, sizeof(buf), "find_path: %d -> %d len=%d waypoints=", from, to, pathLen);
    gAgentLastCommandDebug = std::string(buf) + waypoints;
    debugPrint("AgentBridge: find_path from=%d to=%d len=%d\n", from, to, pathLen);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleTileObjects(const json& cmd)
{
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "tile_objects: missing 'tile'";
        gAgentQueryResult = json::object({ { "type", "tile_objects" }, { "error", "missing 'tile'" } });
        return AgentCommandStatus::BadArgs;
    }

    int targetTile = cmd["tile"].get<int>();
    int radius = 2;
    if (cmd.contains("radius") && cmd["radius"].is_number_integer()) {
        radius = cmd["radius"].get<int>();
    }

    std::string result = "tile_objects at " + std::to_string(targetTile) + ": ";
    json query = json::object();
    query["type"] = "tile_objects";
    query["tile"] = targetTile;
    query["radius"] = radius;
    json objects = json::array();

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

            json entry;
            entry["id"] = objectToUniqueId(obj);
            entry["type"] = typeNames[t];
            entry["pid"] = obj->pid;
            entry["tile"] = obj->tile;
            entry["distance"] = dist;
            entry["name"] = safeString(name);
            objects.push_back(entry);
        }
        if (list != nullptr) {
            objectListFree(list);
        }
    }

    query["objects"] = objects;
    gAgentQueryResult = query;

    gAgentLastCommandDebug = result;
    debugPrint("AgentBridge: %s\n", result.c_str());
    return AgentCommandStatus::Ok;
}

// --- Find item by PID on current elevation ---

static AgentCommandStatus handleFindItem(const json& cmd)
{
    if (!cmd.contains("pid") || !cmd["pid"].is_number_integer()) {
        gAgentLastCommandDebug = "find_item: missing 'pid'";
        gAgentQueryResult = json::object({ { "type", "find_item" }, { "error", "missing 'pid'" } });
        return AgentCommandStatus::BadArgs;
    }
    int targetPid = cmd["pid"].get<int>();
    std::string result = "find_item pid=" + std::to_string(targetPid) + ": ";
    int found = 0;
    json query = json::object();
    query["type"] = "find_item";
    query["pid"] = targetPid;
    json matches = json::array();

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

                json match;
                match["location"] = "ground";
                match["tile"] = obj->tile;
                match["distance"] = dist;
                match["name"] = safeString(name);
                match["object_id"] = objectToUniqueId(obj);
                match["quantity"] = 1;
                matches.push_back(match);
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

                    json match;
                    match["location"] = "ground_container";
                    match["container_id"] = objectToUniqueId(obj);
                    match["container_name"] = safeString(cname);
                    match["tile"] = obj->tile;
                    match["distance"] = dist;
                    match["quantity"] = inv->items[j].quantity;
                    matches.push_back(match);
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

                    json match;
                    match["location"] = "container";
                    match["container_id"] = objectToUniqueId(obj);
                    match["container_name"] = safeString(name);
                    match["tile"] = obj->tile;
                    match["distance"] = dist;
                    match["quantity"] = inv->items[j].quantity;
                    matches.push_back(match);
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

                json match;
                match["location"] = "player_inventory";
                match["quantity"] = inv->items[j].quantity;
                matches.push_back(match);
            }
        }
    }

    if (found == 0) {
        result += "NONE FOUND";
    }

    query["matches"] = matches;
    query["match_count"] = found;
    gAgentQueryResult = query;

    gAgentLastCommandDebug = result;
    debugPrint("AgentBridge: %s\n", result.c_str());
    return AgentCommandStatus::Ok;
}

// --- Enumerate all items/containers on current elevation ---

static AgentCommandStatus handleListAllItems(const json& cmd)
{
    std::string result = "list_all_items elev=" + std::to_string(gDude->elevation) + ": ";
    int totalItems = 0;
    json query = json::object();
    query["type"] = "list_all_items";
    query["elevation"] = gDude->elevation;
    json entries = json::array();

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
                json entry;
                entry["location"] = "ground_container";
                entry["object_id"] = objectToUniqueId(obj);
                entry["pid"] = obj->pid;
                entry["tile"] = obj->tile;
                entry["distance"] = dist;
                entry["name"] = safeString(name);
                entry["item_count"] = obj->data.inventory.length;
                json sample = json::array();
                Inventory* inv = &obj->data.inventory;
                for (int j = 0; j < inv->length && j < 5; j++) {
                    if (inv->items[j].item != nullptr) {
                        char* iname = objectGetName(inv->items[j].item);
                        char ibuf[128];
                        snprintf(ibuf, sizeof(ibuf), "%s(pid=%d qty=%d) ", iname ? iname : "?", inv->items[j].item->pid, inv->items[j].quantity);
                        result += ibuf;
                        json s;
                        s["pid"] = inv->items[j].item->pid;
                        s["name"] = safeString(iname);
                        s["quantity"] = inv->items[j].quantity;
                        sample.push_back(s);
                    }
                }
                entry["sample_items"] = sample;
                entries.push_back(entry);
                result += "] ";
            } else {
                snprintf(buf, sizeof(buf), "[ground pid=%d tile=%d d=%d name=%s] ", obj->pid, obj->tile, dist, name ? name : "?");
                result += buf;
                json entry;
                entry["location"] = "ground";
                entry["object_id"] = objectToUniqueId(obj);
                entry["pid"] = obj->pid;
                entry["tile"] = obj->tile;
                entry["distance"] = dist;
                entry["name"] = safeString(name);
                entries.push_back(entry);
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
            json entry;
            entry["location"] = "container";
            entry["object_id"] = objectToUniqueId(obj);
            entry["pid"] = obj->pid;
            entry["tile"] = obj->tile;
            entry["distance"] = dist;
            entry["name"] = safeString(cname);
            entry["item_count"] = inv->length;
            json sample = json::array();
            for (int j = 0; j < inv->length && j < 5; j++) {
                if (inv->items[j].item != nullptr) {
                    char* iname = objectGetName(inv->items[j].item);
                    char ibuf[128];
                    snprintf(ibuf, sizeof(ibuf), "%s(pid=%d qty=%d) ", iname ? iname : "?", inv->items[j].item->pid, inv->items[j].quantity);
                    result += ibuf;
                    json s;
                    s["pid"] = inv->items[j].item->pid;
                    s["name"] = safeString(iname);
                    s["quantity"] = inv->items[j].quantity;
                    sample.push_back(s);
                }
            }
            entry["sample_items"] = sample;
            entries.push_back(entry);
            result += "] ";
            totalItems++;
            if (totalItems >= 30) break;
        }
        if (list) objectListFree(list);
    }

    if (totalItems == 0) {
        result += "NONE";
    }

    query["entries"] = entries;
    query["entry_count"] = entries.size();
    gAgentQueryResult = query;

    gAgentLastCommandDebug = result;
    debugPrint("AgentBridge: %s\n", result.c_str());
    return AgentCommandStatus::Ok;
}

// --- Map transition command ---

static AgentCommandStatus handleMapTransition(const json& cmd)
{
    if (!cmd.contains("map") || !cmd["map"].is_number_integer()
        || !cmd.contains("elevation") || !cmd["elevation"].is_number_integer()
        || !cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "map_transition: missing map/elevation/tile";
        return AgentCommandStatus::BadArgs;
    }

    int map = cmd["map"].get<int>();
    int elevation = cmd["elevation"].get<int>();
    int tile = cmd["tile"].get<int>();

    // ALL map transitions require test mode — players navigate via exit grids
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "map_transition: BLOCKED — test mode disabled (use exit grids instead)";
        return AgentCommandStatus::Blocked;
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
    return AgentCommandStatus::Ok;
}

// --- Teleport command (direct position set) ---

static AgentCommandStatus handleTeleport(const json& cmd)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "teleport: BLOCKED — test mode disabled (use set_test_mode to enable)";
        return AgentCommandStatus::Blocked;
    }

    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "teleport: missing 'tile'";
        return AgentCommandStatus::BadArgs;
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
    return AgentCommandStatus::Ok;
}

// --- Container interaction ---

static AgentCommandStatus handleOpenContainer(const json& cmd)
{
    if (!cmd.contains("object_id") || !cmd["object_id"].is_number_integer()) {
        gAgentLastCommandDebug = "open_container: missing 'object_id'";
        return AgentCommandStatus::BadArgs;
    }

    if (animationIsBusy(gDude)) {
        gAgentLastCommandDebug = "open_container: animation busy";
        return AgentCommandStatus::Blocked;
    }

    uintptr_t objId = cmd["object_id"].get<uintptr_t>();
    Object* target = findObjectByUniqueId(objId);
    if (target == nullptr) {
        gAgentLastCommandDebug = "open_container: object " + std::to_string(objId) + " not found";
        return AgentCommandStatus::Failed;
    }

    // Always use actionPickUp — the engine's proper walk-to-and-interact.
    // Handles walking, open animation, lock checks, scripts, and loot screen.
    actionPickUp(gDude, target);
    agentForceObjectRefresh();

    int distance = objectGetDistanceBetween(gDude, target);
    char buf[128];
    snprintf(buf, sizeof(buf), "open_container: id=%llu dist=%d", (unsigned long long)objId, distance);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return AgentCommandStatus::Ok;
}

// --- Loot/container commands ---

static AgentCommandStatus handleLootTake(const json& cmd)
{
    Object* target = inven_get_current_target_obj();
    if (target == nullptr) {
        gAgentLastCommandDebug = "loot_take: no loot target";
        return AgentCommandStatus::Blocked;
    }

    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "loot_take: missing 'item_pid'";
        return AgentCommandStatus::BadArgs;
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
        return AgentCommandStatus::Failed;
    }

    int rc = itemMove(target, gDude, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "loot_take: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    agentForceObjectRefresh();
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleLootTakeAll()
{
    Object* target = inven_get_current_target_obj();
    if (target == nullptr) {
        gAgentLastCommandDebug = "loot_take_all: no loot target";
        return AgentCommandStatus::Blocked;
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
    agentForceObjectRefresh();
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleLootClose()
{
    // Send Escape to close the loot screen
    enqueueInputEvent(KEY_ESCAPE);
    debugPrint("AgentBridge: loot_close (injected Escape)\n");
    return AgentCommandStatus::Ok;
}

// --- World map commands ---

static AgentCommandStatus handleWorldmapTravel(const json& cmd)
{
    if (!cmd.contains("area_id") || !cmd["area_id"].is_number_integer()) {
        gAgentLastCommandDebug = "worldmap_travel: missing 'area_id'";
        return AgentCommandStatus::BadArgs;
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
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleWorldmapEnterLocation(const json& cmd)
{
    if (!cmd.contains("area_id") || !cmd["area_id"].is_number_integer()) {
        gAgentLastCommandDebug = "worldmap_enter_location: missing 'area_id'";
        return AgentCommandStatus::BadArgs;
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
        return AgentCommandStatus::BadArgs;
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
    return AgentCommandStatus::Ok;
}

// --- Level-up commands (player-like: work through character editor UI) ---

static AgentCommandStatus handleSkillAdd(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        gAgentLastCommandDebug = "skill_add: missing 'skill'";
        return AgentCommandStatus::BadArgs;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        gAgentLastCommandDebug = "skill_add: unknown skill '" + skillName + "'";
        return AgentCommandStatus::BadArgs;
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
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleSkillSub(const json& cmd)
{
    if (!cmd.contains("skill") || !cmd["skill"].is_string()) {
        gAgentLastCommandDebug = "skill_sub: missing 'skill'";
        return AgentCommandStatus::BadArgs;
    }

    std::string skillName = cmd["skill"].get<std::string>();
    auto it = gSkillNameToId.find(skillName);
    if (it == gSkillNameToId.end()) {
        gAgentLastCommandDebug = "skill_sub: unknown skill '" + skillName + "'";
        return AgentCommandStatus::BadArgs;
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
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handlePerkAdd(const json& cmd)
{
    if (!cmd.contains("perk_id") || !cmd["perk_id"].is_number_integer()) {
        gAgentLastCommandDebug = "perk_add: missing 'perk_id'";
        return AgentCommandStatus::BadArgs;
    }

    int perkId = cmd["perk_id"].get<int>();
    if (perkId < 0 || perkId >= PERK_COUNT) {
        gAgentLastCommandDebug = "perk_add: invalid perk_id " + std::to_string(perkId);
        return AgentCommandStatus::BadArgs;
    }

    // Guard: only act when the perk dialog is open (i.e., editor has a free perk)
    if (!agentEditorHasFreePerk()) {
        gAgentLastCommandDebug = "perk_add: no free perk available (is perk dialog open?)";
        return AgentCommandStatus::Blocked;
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
    return rc == -1 ? AgentCommandStatus::Failed : AgentCommandStatus::Ok;
}

// --- Barter commands ---

static AgentCommandStatus handleBarterOffer(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_offer: missing 'item_pid'";
        return AgentCommandStatus::BadArgs;
    }

    Object* playerTable = agentGetBarterPlayerTable();
    if (playerTable == nullptr) {
        gAgentLastCommandDebug = "barter_offer: not in barter (no player table)";
        return AgentCommandStatus::Blocked;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(gDude, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_offer: item pid " + std::to_string(itemPid) + " not in player inventory";
        return AgentCommandStatus::Failed;
    }

    int rc = itemMove(gDude, playerTable, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_offer: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleBarterRemoveOffer(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_remove_offer: missing 'item_pid'";
        return AgentCommandStatus::BadArgs;
    }

    Object* playerTable = agentGetBarterPlayerTable();
    if (playerTable == nullptr) {
        gAgentLastCommandDebug = "barter_remove_offer: not in barter";
        return AgentCommandStatus::Blocked;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(playerTable, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_remove_offer: item pid " + std::to_string(itemPid) + " not in offer table";
        return AgentCommandStatus::Failed;
    }

    int rc = itemMove(playerTable, gDude, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_remove_offer: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleBarterRequest(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_request: missing 'item_pid'";
        return AgentCommandStatus::BadArgs;
    }

    if (gGameDialogSpeaker == nullptr) {
        gAgentLastCommandDebug = "barter_request: no merchant";
        return AgentCommandStatus::Blocked;
    }

    Object* merchantTable = agentGetBarterMerchantTable();
    if (merchantTable == nullptr) {
        gAgentLastCommandDebug = "barter_request: not in barter (no merchant table)";
        return AgentCommandStatus::Blocked;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(gGameDialogSpeaker, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_request: item pid " + std::to_string(itemPid) + " not in merchant inventory";
        return AgentCommandStatus::Failed;
    }

    int rc = itemMove(gGameDialogSpeaker, merchantTable, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_request: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleBarterRemoveRequest(const json& cmd)
{
    if (!cmd.contains("item_pid") || !cmd["item_pid"].is_number_integer()) {
        gAgentLastCommandDebug = "barter_remove_request: missing 'item_pid'";
        return AgentCommandStatus::BadArgs;
    }

    if (gGameDialogSpeaker == nullptr) {
        gAgentLastCommandDebug = "barter_remove_request: no merchant";
        return AgentCommandStatus::Blocked;
    }

    Object* merchantTable = agentGetBarterMerchantTable();
    if (merchantTable == nullptr) {
        gAgentLastCommandDebug = "barter_remove_request: not in barter";
        return AgentCommandStatus::Blocked;
    }

    int itemPid = cmd["item_pid"].get<int>();
    int quantity = 1;
    if (cmd.contains("quantity") && cmd["quantity"].is_number_integer()) {
        quantity = cmd["quantity"].get<int>();
    }

    Object* item = objectGetCarriedObjectByPid(merchantTable, itemPid);
    if (item == nullptr) {
        gAgentLastCommandDebug = "barter_remove_request: item pid " + std::to_string(itemPid) + " not in offer table";
        return AgentCommandStatus::Failed;
    }

    int rc = itemMove(merchantTable, gGameDialogSpeaker, item, quantity);

    char buf[128];
    snprintf(buf, sizeof(buf), "barter_remove_request: pid=%d qty=%d rc=%d", itemPid, quantity, rc);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

// --- Dialogue commands ---

static AgentCommandStatus handleSelectDialogue(const json& cmd)
{
    if (!cmd.contains("index") || !cmd["index"].is_number_integer()) {
        gAgentLastCommandDebug = "select_dialogue: missing 'index'";
        return AgentCommandStatus::BadArgs;
    }

    if (!_gdialogActive()) {
        gAgentLastCommandDebug = "select_dialogue: no dialogue active";
        return AgentCommandStatus::Blocked;
    }

    int index = cmd["index"].get<int>();
    int optionCount = agentGetDialogOptionCount();

    if (index < 0 || index >= optionCount) {
        char buf[96];
        snprintf(buf, sizeof(buf), "select_dialogue: index %d out of range (options=%d)", index, optionCount);
        gAgentLastCommandDebug = buf;
        return AgentCommandStatus::BadArgs;
    }

    // Visually highlight the selected option, then defer key injection
    // so viewers can see which option was chosen (~0.5s highlight)
    agentDialogHighlightOption(index);
    gAgentPendingDialogueSelect = index;
    gAgentDialogueSelectTick = gAgentTick;

    char buf[64];
    snprintf(buf, sizeof(buf), "select_dialogue: index=%d highlighted (deferred)", index);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: select_dialogue index %d highlighted, deferring key\n", index);
    return AgentCommandStatus::Ok;
}

using AgentCommandHandler = AgentCommandStatus (*)(const json&);

static AgentCommandStatus handleFinishCharacterCreationCommand(const json&)
{
    return handleFinishCharacterCreation();
}

static AgentCommandStatus handleMoveToWalkCommand(const json& cmd)
{
    return handleMoveTo(cmd, false);
}

static AgentCommandStatus handleMoveToRunCommand(const json& cmd)
{
    return handleMoveTo(cmd, true);
}

static AgentCommandStatus handleEndTurnCommand(const json&)
{
    return handleEndTurn();
}

static AgentCommandStatus handleLootTakeAllCommand(const json&)
{
    return handleLootTakeAll();
}

static AgentCommandStatus handleLootCloseCommand(const json&)
{
    return handleLootClose();
}

static AgentCommandStatus handleSkipCommand(const json&)
{
    enqueueInputEvent(KEY_ESCAPE);
    gAgentLastCommandDebug = "skip";
    debugPrint("AgentBridge: skip (injected escape event)\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleMouseMoveCommand(const json& cmd)
{
    if (!cmd.contains("x") || !cmd.contains("y")
        || !cmd["x"].is_number_integer() || !cmd["y"].is_number_integer()) {
        gAgentLastCommandDebug = "mouse_move: missing x/y";
        return AgentCommandStatus::BadArgs;
    }

    int x = cmd["x"].get<int>();
    int y = cmd["y"].get<int>();
    _mouse_set_position(x, y);
    gAgentLastCommandDebug = "mouse_move: x=" + std::to_string(x) + " y=" + std::to_string(y);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleMouseClickCommand(const json& cmd)
{
    if (!cmd.contains("x") || !cmd.contains("y")
        || !cmd["x"].is_number_integer() || !cmd["y"].is_number_integer()) {
        gAgentLastCommandDebug = "mouse_click: missing x/y";
        return AgentCommandStatus::BadArgs;
    }

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
    gAgentLastCommandDebug = "mouse_click: x=" + std::to_string(x) + " y=" + std::to_string(y);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleKeyPressCommand(const json& cmd)
{
    if (!cmd.contains("key") || !cmd["key"].is_string()) {
        gAgentLastCommandDebug = "key_press: missing key";
        return AgentCommandStatus::BadArgs;
    }

    std::string keyName = cmd["key"].get<std::string>();
    auto it = gKeyNameToScancode.find(keyName);
    if (it == gKeyNameToScancode.end()) {
        debugPrint("AgentBridge: unknown key '%s'\n", keyName.c_str());
        gAgentLastCommandDebug = "key_press: unknown key '" + keyName + "'";
        return AgentCommandStatus::BadArgs;
    }

    KeyboardData data;
    data.key = it->second;
    data.down = 1;
    _kb_simulate_key(&data);
    gAgentLastCommandDebug = "key_press: " + keyName;
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleKeyReleaseCommand(const json& cmd)
{
    if (!cmd.contains("key") || !cmd["key"].is_string()) {
        gAgentLastCommandDebug = "key_release: missing key";
        return AgentCommandStatus::BadArgs;
    }

    std::string keyName = cmd["key"].get<std::string>();
    auto it = gKeyNameToScancode.find(keyName);
    if (it == gKeyNameToScancode.end()) {
        debugPrint("AgentBridge: unknown key '%s'\n", keyName.c_str());
        gAgentLastCommandDebug = "key_release: unknown key '" + keyName + "'";
        return AgentCommandStatus::BadArgs;
    }

    KeyboardData data;
    data.key = it->second;
    data.down = 0;
    _kb_simulate_key(&data);
    gAgentLastCommandDebug = "key_release: " + keyName;
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleSwitchHandCommand(const json&)
{
    interfaceBarSwapHands(true);
    gAgentLastCommandDebug = "switch_hand: now hand " + std::to_string(interfaceGetCurrentHand());
    debugPrint("AgentBridge: switch_hand (now hand %d)\n", interfaceGetCurrentHand());
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleCycleAttackModeCommand(const json&)
{
    interfaceCycleItemAction();
    gAgentLastCommandDebug = "cycle_attack_mode";
    debugPrint("AgentBridge: cycle_attack_mode\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleForceIdleCommand(const json&)
{
    reg_anim_clear(gDude);
    gAgentLastCommandDebug = "force_idle: animation cleared";
    debugPrint("AgentBridge: force_idle — animation state reset\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleForceEndCombatCommand(const json&)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "force_end_combat: BLOCKED — test mode disabled";
        return AgentCommandStatus::Blocked;
    }
    if (!isInCombat()) {
        gAgentLastCommandDebug = "force_end_combat: not in combat";
        return AgentCommandStatus::NoOp;
    }

    _combat_over_from_load();
    gAgentLastCommandDebug = "force_end_combat: combat ended";
    debugPrint("AgentBridge: force_end_combat — combat forcefully ended\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleDetonateAtCommand(const json& cmd)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "detonate_at: BLOCKED — test mode disabled";
        return AgentCommandStatus::Blocked;
    }
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "detonate_at: missing 'tile'";
        return AgentCommandStatus::BadArgs;
    }

    int tile = cmd["tile"].get<int>();
    int elevation = gDude->elevation;

    int pid = 85;
    if (cmd.contains("pid") && cmd["pid"].is_number_integer()) {
        pid = cmd["pid"].get<int>();
    }

    int minDamage = 40;
    int maxDamage = 80;
    explosiveGetDamage(pid, &minDamage, &maxDamage);
    int radius = weaponGetRocketExplosionRadius(nullptr);

    actionExplode(tile, elevation, minDamage, maxDamage, gDude, false);
    _scr_explode_scenery(gDude, tile, radius, elevation);

    char buf[128];
    snprintf(buf, sizeof(buf), "detonate_at: tile=%d dmg=%d-%d radius=%d",
        tile, minDamage, maxDamage, radius);
    gAgentLastCommandDebug = buf;
    debugPrint("AgentBridge: %s\n", buf);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleNudgeCommand(const json& cmd)
{
    if (!gAgentTestMode) {
        gAgentLastCommandDebug = "nudge: BLOCKED — test mode disabled";
        return AgentCommandStatus::Blocked;
    }
    if (!cmd.contains("tile") || !cmd["tile"].is_number_integer()) {
        gAgentLastCommandDebug = "nudge: missing 'tile'";
        return AgentCommandStatus::BadArgs;
    }

    int tile = cmd["tile"].get<int>();
    int dist = tileDistanceBetween(gDude->tile, tile);
    if (dist > 1) {
        gAgentLastCommandDebug = "nudge: too far (dist=" + std::to_string(dist) + ", max=1)";
        return AgentCommandStatus::Failed;
    }

    reg_anim_clear(gDude);
    Rect rect;
    int oldTile = gDude->tile;
    objectSetLocation(gDude, tile, gDude->elevation, &rect);
    tileSetCenter(tile, TILE_SET_CENTER_REFRESH_WINDOW);
    if (isInCombat() && gDude->data.critter.combat.ap > 0) {
        gDude->data.critter.combat.ap -= 1;
    }
    gAgentLastCommandDebug = "nudge: " + std::to_string(oldTile) + " -> " + std::to_string(tile);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleCenterCameraCommand(const json&)
{
    tileSetCenter(gDude->tile, TILE_SET_CENTER_REFRESH_WINDOW);
    gAgentLastCommandDebug = "center_camera: tile=" + std::to_string(gDude->tile);
    debugPrint("AgentBridge: center_camera on tile %d\n", gDude->tile);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleRestCommand(const json& cmd)
{
    if (isInCombat()) {
        gAgentLastCommandDebug = "rest: cannot rest in combat";
        return AgentCommandStatus::Blocked;
    }
    if (!_critter_can_obj_dude_rest()) {
        gAgentLastCommandDebug = "rest: cannot rest here (hostile critters or location)";
        return AgentCommandStatus::Blocked;
    }

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
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handlePipBoyCommand(const json&)
{
    enqueueInputEvent('p');
    gAgentLastCommandDebug = "pip_boy";
    debugPrint("AgentBridge: pip_boy (injected 'p')\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleCharacterScreenCommand(const json&)
{
    enqueueInputEvent('c');
    gAgentLastCommandDebug = "character_screen";
    debugPrint("AgentBridge: character_screen (injected 'c')\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleInventoryOpenCommand(const json&)
{
    enqueueInputEvent('i');
    gAgentLastCommandDebug = "inventory_open";
    debugPrint("AgentBridge: inventory_open (injected 'i')\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleSkilldexCommand(const json&)
{
    enqueueInputEvent('s');
    gAgentLastCommandDebug = "skilldex";
    debugPrint("AgentBridge: skilldex (injected 's')\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleToggleSneakCommand(const json&)
{
    dudeToggleState(DUDE_STATE_SNEAKING);
    bool sneaking = dudeHasState(DUDE_STATE_SNEAKING);
    gAgentLastCommandDebug = std::string("toggle_sneak: now ") + (sneaking ? "sneaking" : "not sneaking");
    debugPrint("AgentBridge: toggle_sneak → %s\n", sneaking ? "on" : "off");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleEnterCombatCommand(const json&)
{
    if (isInCombat()) {
        gAgentLastCommandDebug = "enter_combat: already in combat";
        return AgentCommandStatus::NoOp;
    }
    enqueueInputEvent('a');
    gAgentLastCommandDebug = "enter_combat: initiated";
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleFleeCombatCommand(const json&)
{
    if (!isInCombat()) {
        gAgentLastCommandDebug = "flee_combat: not in combat";
        return AgentCommandStatus::Blocked;
    }
    enqueueInputEvent(KEY_RETURN);
    gAgentLastCommandDebug = "flee_combat: attempted";
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleBarterConfirmCommand(const json&)
{
    Object* ptbl = agentGetBarterPlayerTable();
    Object* mtbl = agentGetBarterMerchantTable();
    if (ptbl == nullptr || mtbl == nullptr || gGameDialogSpeaker == nullptr) {
        gAgentLastCommandDebug = "barter_confirm: not in barter";
        return AgentCommandStatus::Blocked;
    }

    int pitems = ptbl->data.inventory.length;
    int mitems = mtbl->data.inventory.length;
    if (pitems == 0 && mitems == 0) {
        gAgentLastCommandDebug = "barter_confirm: nothing on tables";
        return AgentCommandStatus::NoOp;
    }

    enqueueInputEvent('m');
    gAgentLastCommandDebug = "barter_confirm: attempted (injected 'm')";
    debugPrint("AgentBridge: barter_confirm (injected 'm', pitems=%d mitems=%d)\n", pitems, mitems);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleBarterTalkCommand(const json&)
{
    enqueueInputEvent('t');
    gAgentLastCommandDebug = "barter_talk";
    debugPrint("AgentBridge: barter_talk (injected 't')\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleBarterCancelCommand(const json&)
{
    enqueueInputEvent(KEY_ESCAPE);
    gAgentLastCommandDebug = "barter_cancel";
    debugPrint("AgentBridge: barter_cancel (injected escape)\n");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleQuicksaveCommand(const json& cmd)
{
    if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
        gAgentLastCommandDebug = "quicksave: not in gameplay context";
        debugPrint("AgentBridge: quicksave — not in gameplay context\n");
        return AgentCommandStatus::Blocked;
    }

    std::string desc = "Agent Save";
    if (cmd.contains("description") && cmd["description"].is_string()) {
        desc = cmd["description"].get<std::string>();
    }
    int rc = agentQuickSave(desc.c_str());
    gAgentLastCommandDebug = "quicksave: rc=" + std::to_string(rc) + " desc=" + desc;
    debugPrint("AgentBridge: quicksave result=%d\n", rc);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleQuickloadCommand(const json&)
{
    if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
        gAgentLastCommandDebug = "quickload: not in gameplay context";
        debugPrint("AgentBridge: quickload — not in gameplay, ignoring\n");
        return AgentCommandStatus::Blocked;
    }

    int rc = agentQuickLoad();
    gAgentLastCommandDebug = "quickload: rc=" + std::to_string(rc);
    debugPrint("AgentBridge: quickload result=%d\n", rc);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleSaveSlotCommand(const json& cmd)
{
    if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
        gAgentLastCommandDebug = "save_slot: not in gameplay context";
        return AgentCommandStatus::Blocked;
    }

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
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleLoadSlotCommand(const json& cmd)
{
    if (gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
        gAgentLastCommandDebug = "load_slot: not in gameplay context";
        return AgentCommandStatus::Blocked;
    }

    int slot = 0;
    if (cmd.contains("slot") && cmd["slot"].is_number_integer()) {
        slot = cmd["slot"].get<int>();
    }
    int rc = agentLoadFromSlot(slot);
    gAgentLastCommandDebug = "load_slot: slot=" + std::to_string(slot) + " rc=" + std::to_string(rc);
    debugPrint("AgentBridge: load_slot slot=%d result=%d\n", slot, rc);
    return rc == 0 ? AgentCommandStatus::Ok : AgentCommandStatus::Failed;
}

static AgentCommandStatus handleInputEventCommand(const json& cmd)
{
    if (!cmd.contains("key_code") || !cmd["key_code"].is_number_integer()) {
        gAgentLastCommandDebug = "input_event: missing key_code";
        return AgentCommandStatus::BadArgs;
    }

    int keyCode = cmd["key_code"].get<int>();
    enqueueInputEvent(keyCode);
    gAgentLastCommandDebug = "input_event: code=" + std::to_string(keyCode);
    debugPrint("AgentBridge: input_event code=%d\n", keyCode);
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleFloatThoughtCommand(const json& cmd)
{
    if (!cmd.contains("text") || !cmd["text"].is_string()) {
        gAgentLastCommandDebug = "float_thought: missing text field";
        return AgentCommandStatus::BadArgs;
    }

    std::string text = cmd["text"].get<std::string>();
    if (text.empty() || gDude == nullptr) {
        gAgentLastCommandDebug = "float_thought: empty text or no player";
        return AgentCommandStatus::Failed;
    }

    const char* ctx = detectContext();
    if (ctx != nullptr && strcmp(ctx, "gameplay_dialogue") == 0) {
        renderDialogueOverlay(text.c_str());
        gAgentLastCommandDebug = "float_thought(overlay): " + text.substr(0, 40);
    } else {
        agentHideDialogueOverlay();
        textObjectsRemoveByOwner(gDude);
        Rect rect;
        char* buf = strdup(text.c_str());
        if (textObjectAdd(gDude, buf, 101, _colorTable[28106], _colorTable[0], &rect) == 0) {
            tileWindowRefreshRect(&rect, gElevation);
        }
        free(buf);
        gAgentLastCommandDebug = "float_thought: " + text.substr(0, 40);
    }
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleSetStatusCommand(const json& cmd)
{
    std::string text = cmd.value("text", "");
    if (text.empty()) {
        gAgentLastCommandDebug = "set_status: missing text";
        return AgentCommandStatus::BadArgs;
    }

    agentShowStatusOverlay(text.c_str());
    gAgentLastCommandDebug = "set_status: " + text;
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleClearStatusCommand(const json&)
{
    agentHideStatusOverlay();
    gAgentLastCommandDebug = "clear_status";
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleAutoCombatCommand(const json& cmd)
{
    bool enabled = cmd.contains("enabled") && cmd["enabled"].is_boolean()
        && cmd["enabled"].get<bool>();
    if (enabled && gAgentContext != AGENT_CONTEXT_GAMEPLAY) {
        gAgentLastCommandDebug = "auto_combat: not in gameplay";
        return AgentCommandStatus::Blocked;
    }
    if (enabled && !gAgentAutoCombat) {
        gAgentOriginalAiPacket = gDude->data.critter.combat.aiPacket;
        int numPackets = combat_ai_num();
        int dedicatedPacket = numPackets > 1 ? numPackets - 1 : 0;
        gDude->data.critter.combat.aiPacket = dedicatedPacket;

        aiSetAttackWho(gDude, ATTACK_WHO_STRONGEST);
        aiSetDistance(gDude, DISTANCE_CHARGE);
        aiSetBestWeapon(gDude, BEST_WEAPON_NO_PREF);
        aiSetChemUse(gDude, CHEM_USE_STIMS_WHEN_HURT_LOTS);
        aiSetRunAwayMode(gDude, RUN_AWAY_MODE_NEVER);
        aiSetAreaAttackMode(gDude, AREA_ATTACK_MODE_BE_CAREFUL);
        aiSetDisposition(gDude, DISPOSITION_AGGRESSIVE);

        gAgentAutoCombat = true;
        gAgentLastCommandDebug = "auto_combat: ON (packet=" + std::to_string(dedicatedPacket) + ")";
        debugPrint("AgentBridge: auto_combat ON (packet=%d, total=%d)\n", dedicatedPacket, numPackets);
        return AgentCommandStatus::Ok;
    }
    if (!enabled && gAgentAutoCombat) {
        gAgentAutoCombat = false;
        if (gAgentOriginalAiPacket >= 0) {
            gDude->data.critter.combat.aiPacket = gAgentOriginalAiPacket;
            gAgentOriginalAiPacket = -1;
        }
        gAgentLastCommandDebug = "auto_combat: OFF";
        debugPrint("AgentBridge: auto_combat OFF\n");
        return AgentCommandStatus::Ok;
    }

    gAgentLastCommandDebug = std::string("auto_combat: already ") + (enabled ? "ON" : "OFF");
    return AgentCommandStatus::NoOp;
}

static AgentCommandStatus handleConfigureCombatAiCommand(const json& cmd)
{
    if (!gAgentAutoCombat) {
        gAgentLastCommandDebug = "configure_combat_ai: auto_combat not enabled";
        return AgentCommandStatus::Blocked;
    }

    std::string configResult = "configure_combat_ai:";
    if (cmd.contains("attack_who") && cmd["attack_who"].is_string()) {
        std::string val = cmd["attack_who"].get<std::string>();
        for (int i = 0; i < ATTACK_WHO_COUNT; i++) {
            if (val == gAttackWhoKeys[i]) {
                aiSetAttackWho(gDude, i);
                configResult += " attack_who=" + val;
                break;
            }
        }
    }
    if (cmd.contains("distance") && cmd["distance"].is_string()) {
        std::string val = cmd["distance"].get<std::string>();
        for (int i = 0; i < DISTANCE_COUNT; i++) {
            if (val == gDistanceModeKeys[i]) {
                aiSetDistance(gDude, i);
                configResult += " distance=" + val;
                break;
            }
        }
    }
    if (cmd.contains("best_weapon") && cmd["best_weapon"].is_string()) {
        std::string val = cmd["best_weapon"].get<std::string>();
        for (int i = 0; i < BEST_WEAPON_COUNT; i++) {
            if (val == gBestWeaponKeys[i]) {
                aiSetBestWeapon(gDude, i);
                configResult += " best_weapon=" + val;
                break;
            }
        }
    }
    if (cmd.contains("chem_use") && cmd["chem_use"].is_string()) {
        std::string val = cmd["chem_use"].get<std::string>();
        for (int i = 0; i < CHEM_USE_COUNT; i++) {
            if (val == gChemUseKeys[i]) {
                aiSetChemUse(gDude, i);
                configResult += " chem_use=" + val;
                break;
            }
        }
    }
    if (cmd.contains("run_away_mode") && cmd["run_away_mode"].is_string()) {
        std::string val = cmd["run_away_mode"].get<std::string>();
        for (int i = 0; i < RUN_AWAY_MODE_COUNT; i++) {
            if (val == gRunAwayModeKeys[i]) {
                aiSetRunAwayMode(gDude, i);
                configResult += " run_away_mode=" + val;
                break;
            }
        }
    }
    if (cmd.contains("area_attack_mode") && cmd["area_attack_mode"].is_string()) {
        std::string val = cmd["area_attack_mode"].get<std::string>();
        for (int i = 0; i < AREA_ATTACK_MODE_COUNT; i++) {
            if (val == gAreaAttackModeKeys[i]) {
                aiSetAreaAttackMode(gDude, i);
                configResult += " area_attack_mode=" + val;
                break;
            }
        }
    }
    if (cmd.contains("disposition") && cmd["disposition"].is_string()) {
        std::string val = cmd["disposition"].get<std::string>();
        for (int i = 0; i < DISPOSITION_COUNT; i++) {
            if (val == gDispositionKeys[i]) {
                aiSetDisposition(gDude, i);
                configResult += " disposition=" + val;
                break;
            }
        }
    }

    gAgentLastCommandDebug = configResult;
    debugPrint("AgentBridge: %s\n", configResult.c_str());
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleSetTestModeCommand(const json& cmd)
{
    bool enabled = cmd.contains("enabled") && cmd["enabled"].is_boolean()
        && cmd["enabled"].get<bool>();
    gAgentTestMode = enabled;
    gAgentLastCommandDebug = std::string("set_test_mode: ") + (enabled ? "ON" : "OFF");
    debugPrint("AgentBridge: test mode %s\n", enabled ? "ON" : "OFF");
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus handleReadHolodisk(const json& cmd)
{
    if (!cmd.contains("index") || !cmd["index"].is_number_integer()) {
        gAgentLastCommandDebug = "read_holodisk: missing 'index'";
        gAgentQueryResult = json::object({ { "type", "read_holodisk" }, { "error", "missing 'index'" } });
        return AgentCommandStatus::BadArgs;
    }

    int index = cmd["index"].get<int>();
    int holodiskCount = agentGetHolodiskCount();

    if (index < 0 || index >= holodiskCount) {
        gAgentLastCommandDebug = "read_holodisk: index out of range (0-" + std::to_string(holodiskCount - 1) + ")";
        gAgentQueryResult = json::object({ { "type", "read_holodisk" }, { "error", gAgentLastCommandDebug } });
        return AgentCommandStatus::BadArgs;
    }

    // Check if the player has acquired this holodisk
    int gvar = agentGetHolodiskGvar(index);
    if (gameGetGlobalVar(gvar) == 0) {
        gAgentLastCommandDebug = "read_holodisk: holodisk not acquired";
        gAgentQueryResult = json::object({ { "type", "read_holodisk" }, { "error", "not acquired" } });
        return AgentCommandStatus::Failed;
    }

    const char* name = agentGetHolodiskName(index);
    std::string fullText = agentGetHolodiskFullText(index);

    json query = json::object();
    query["type"] = "read_holodisk";
    query["index"] = index;
    query["name"] = safeString(name);
    query["text"] = safeString(fullText.c_str());
    gAgentQueryResult = query;

    gAgentLastCommandDebug = "read_holodisk: " + std::string(name ? name : "?") + " (" + std::to_string(fullText.size()) + " chars)";
    debugPrint("AgentBridge: %s\n", gAgentLastCommandDebug.c_str());
    return AgentCommandStatus::Ok;
}

static AgentCommandStatus dispatchMappedCommand(const std::string& type, const json& cmd)
{
    static const std::unordered_map<std::string, AgentCommandHandler> handlers = {
        { "skip", handleSkipCommand },
        { "mouse_move", handleMouseMoveCommand },
        { "mouse_click", handleMouseClickCommand },
        { "key_press", handleKeyPressCommand },
        { "key_release", handleKeyReleaseCommand },
        { "adjust_stat", handleAdjustStat },
        { "toggle_trait", handleToggleTrait },
        { "toggle_skill_tag", handleToggleSkillTag },
        { "set_name", handleSetName },
        { "editor_done", handleFinishCharacterCreationCommand },
        { "finish_character_creation", handleFinishCharacterCreationCommand },
        { "main_menu", handleMainMenuCommand },
        { "main_menu_select", handleMainMenuSelect },
        { "char_selector_select", handleCharSelectorSelect },
        { "move_to", handleMoveToWalkCommand },
        { "run_to", handleMoveToRunCommand },
        { "use_object", handleUseObject },
        { "open_door", handleOpenDoor },
        { "pick_up", handlePickUp },
        { "use_skill", handleUseSkill },
        { "talk_to", handleTalkTo },
        { "use_item_on", handleUseItemOn },
        { "look_at", handleLookAt },
        { "reload_weapon", handleReloadWeapon },
        { "reload_weapon_with", handleReloadWeapon },
        { "drop_item", handleDropItem },
        { "give_item", handleGiveItem },
        { "equip_item", handleEquipItem },
        { "unequip_item", handleUnequipItem },
        { "use_item", handleUseItem },
        { "use_equipped_item", handleUseEquippedItem },
        { "attack", handleAttack },
        { "combat_move", handleCombatMove },
        { "end_turn", handleEndTurnCommand },
        { "use_combat_item", handleUseCombatItem },
        { "skill_add", handleSkillAdd },
        { "skill_sub", handleSkillSub },
        { "perk_add", handlePerkAdd },
        { "select_dialogue", handleSelectDialogue },
        { "open_container", handleOpenContainer },
        { "loot_take", handleLootTake },
        { "loot_take_all", handleLootTakeAllCommand },
        { "loot_close", handleLootCloseCommand },
        { "barter_offer", handleBarterOffer },
        { "barter_remove_offer", handleBarterRemoveOffer },
        { "barter_request", handleBarterRequest },
        { "barter_remove_request", handleBarterRemoveRequest },
        { "barter_confirm", handleBarterConfirmCommand },
        { "barter_talk", handleBarterTalkCommand },
        { "barter_cancel", handleBarterCancelCommand },
        { "worldmap_travel", handleWorldmapTravel },
        { "worldmap_enter_location", handleWorldmapEnterLocation },
        { "find_path", handleFindPath },
        { "tile_objects", handleTileObjects },
        { "find_item", handleFindItem },
        { "list_all_items", handleListAllItems },
        { "map_transition", handleMapTransition },
        { "teleport", handleTeleport },
        { "switch_hand", handleSwitchHandCommand },
        { "cycle_attack_mode", handleCycleAttackModeCommand },
        { "force_idle", handleForceIdleCommand },
        { "force_end_combat", handleForceEndCombatCommand },
        { "detonate_at", handleDetonateAtCommand },
        { "nudge", handleNudgeCommand },
        { "center_camera", handleCenterCameraCommand },
        { "rest", handleRestCommand },
        { "pip_boy", handlePipBoyCommand },
        { "character_screen", handleCharacterScreenCommand },
        { "inventory_open", handleInventoryOpenCommand },
        { "skilldex", handleSkilldexCommand },
        { "toggle_sneak", handleToggleSneakCommand },
        { "enter_combat", handleEnterCombatCommand },
        { "flee_combat", handleFleeCombatCommand },
        { "quicksave", handleQuicksaveCommand },
        { "quickload", handleQuickloadCommand },
        { "save_slot", handleSaveSlotCommand },
        { "load_slot", handleLoadSlotCommand },
        { "input_event", handleInputEventCommand },
        { "float_thought", handleFloatThoughtCommand },
        { "set_status", handleSetStatusCommand },
        { "clear_status", handleClearStatusCommand },
        { "auto_combat", handleAutoCombatCommand },
        { "configure_combat_ai", handleConfigureCombatAiCommand },
        { "set_test_mode", handleSetTestModeCommand },
        { "read_holodisk", handleReadHolodisk },
    };

    auto it = handlers.find(type);
    if (it == handlers.end()) {
        return AgentCommandStatus::UnknownCommand;
    }

    return it->second(cmd);
}

static void trackAndLogCommandResult(const std::string& type, const json& cmd, AgentCommandStatus status)
{
    if (agentCommandStatusIsFailure(status)) {
        gCommandFailureCounts[type]++;
    } else {
        gCommandFailureCounts.erase(type);
    }

    agentDebugLogCommand(type, cmd, gAgentLastCommandDebug, status);
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
        // Auto-clear status overlay on any real command (not set_status/clear_status)
        if (gAgentStatusOverlayActive && type != "set_status" && type != "clear_status") {
            agentHideStatusOverlay();
        }

        AgentCommandStatus status = dispatchMappedCommand(type, cmd);
        if (status == AgentCommandStatus::UnknownCommand) {
            gAgentLastCommandDebug = "unknown_cmd: " + type;
            debugPrint("AgentBridge: unknown command type: %s\n", type.c_str());
        }

        trackAndLogCommandResult(type, cmd, status);
    }
}

} // namespace fallout
