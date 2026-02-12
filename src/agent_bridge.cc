#include "agent_bridge.h"

#include <SDL.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <unordered_map>
#include <vector>

#include <nlohmann/json.hpp>

#include "character_editor.h"
#include "critter.h"
#include "db.h"
#include "debug.h"
#include "dinput.h"
#include "game.h"
#include "game_movie.h"
#include "input.h"
#include "kb.h"
#include "mouse.h"
#include "object.h"
#include "skill.h"
#include "stat.h"
#include "svga.h"
#include "trait.h"

using json = nlohmann::json;

namespace fallout {

static const char* kCmdPath = "agent_cmd.json";
static const char* kCmdTmpPath = "agent_cmd.tmp";
static const char* kStatePath = "agent_state.json";
static const char* kStateTmpPath = "agent_state.tmp";

static unsigned int gAgentTick = 0;
static int gAgentContext = AGENT_CONTEXT_UNKNOWN;

static std::unordered_map<std::string, int> gKeyNameToScancode;
static std::unordered_map<std::string, int> gStatNameToId;
static std::unordered_map<std::string, int> gSkillNameToId;
static std::unordered_map<std::string, int> gTraitNameToId;

// --- Name-to-ID maps ---

static void buildKeynameMap()
{
    // Letters
    for (char c = 'a'; c <= 'z'; c++) {
        std::string name(1, c);
        gKeyNameToScancode[name] = SDL_SCANCODE_A + (c - 'a');
    }

    // Digits
    gKeyNameToScancode["0"] = SDL_SCANCODE_0;
    for (char c = '1'; c <= '9'; c++) {
        std::string name(1, c);
        gKeyNameToScancode[name] = SDL_SCANCODE_1 + (c - '1');
    }

    // Function keys
    for (int i = 1; i <= 12; i++) {
        std::string name = "f" + std::to_string(i);
        gKeyNameToScancode[name] = SDL_SCANCODE_F1 + (i - 1);
    }

    // Special keys
    gKeyNameToScancode["escape"] = SDL_SCANCODE_ESCAPE;
    gKeyNameToScancode["return"] = SDL_SCANCODE_RETURN;
    gKeyNameToScancode["enter"] = SDL_SCANCODE_RETURN;
    gKeyNameToScancode["space"] = SDL_SCANCODE_SPACE;
    gKeyNameToScancode["tab"] = SDL_SCANCODE_TAB;
    gKeyNameToScancode["backspace"] = SDL_SCANCODE_BACKSPACE;

    // Arrow keys
    gKeyNameToScancode["up"] = SDL_SCANCODE_UP;
    gKeyNameToScancode["down"] = SDL_SCANCODE_DOWN;
    gKeyNameToScancode["left"] = SDL_SCANCODE_LEFT;
    gKeyNameToScancode["right"] = SDL_SCANCODE_RIGHT;

    // Modifier keys
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

// --- Context detection ---

static const char* detectContext()
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
    case AGENT_CONTEXT_GAMEPLAY:
        return "gameplay";
    default:
        return "unknown";
    }
}

// --- Enriched state serializers ---

static void writeMovieState(json& state)
{
    state["available_actions"] = json::array({ "skip" });
}

static void writeMainMenuState(json& state)
{
    state["available_actions"] = json::array({
        "new_game", "load_game", "options", "credits", "intro", "exit"
    });

    // Detect save games in slots 1-10
    json saveGames = json::array();
    for (int i = 1; i <= 10; i++) {
        char path[64];
        snprintf(path, sizeof(path), "SAVEGAME\\SLOT%.2d\\SAVE.DAT", i);

        json slot;
        slot["slot"] = i;

        int fileSize;
        if (dbGetFileSize(path, &fileSize) == 0) {
            slot["exists"] = true;

            // Read header to extract character name and description
            File* f = fileOpen(path, "rb");
            if (f != nullptr) {
                // Header layout:
                //   signature[24] + versionMinor(2) + versionMajor(2) + versionRelease(1) = 29 bytes
                //   characterName[32] at offset 29
                //   description[30] at offset 61
                char header[91];
                if (fileRead(header, 1, 91, f) == 91) {
                    char characterName[33];
                    memcpy(characterName, header + 29, 32);
                    characterName[32] = '\0';

                    char description[31];
                    memcpy(description, header + 61, 30);
                    description[30] = '\0';

                    slot["character_name"] = characterName;
                    slot["description"] = description;
                } else {
                    slot["character_name"] = "";
                    slot["description"] = "";
                }
                fileClose(f);
            }
        } else {
            slot["exists"] = false;
        }

        saveGames.push_back(slot);
    }
    state["save_games"] = saveGames;
}

static void writeCharSelectorState(json& state)
{
    state["premade_characters"] = json::array({
        "Narg (Combat)", "Chitsa (Stealth)", "Mingun (Diplomat)"
    });
    state["available_actions"] = json::array({
        "create_custom", "take_premade", "modify_premade",
        "next", "previous", "back"
    });
}

// Skill ID to snake_case name (reverse of gSkillNameToId)
static const char* skillIdToName(int skill)
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

// Trait ID to snake_case name (reverse of gTraitNameToId)
static const char* traitIdToName(int trait)
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

static void writeCharEditorState(json& state)
{
    json character;

    // Name
    char* name = critterGetName(gDude);
    character["name"] = name ? name : "None";

    // Remaining character points
    character["remaining_points"] = gCharacterEditorRemainingCharacterPoints;
    character["tagged_skills_remaining"] = gCharacterEditorTaggedSkillCount;

    // SPECIAL stats
    json special;
    special["strength"] = critterGetBaseStat(gDude, STAT_STRENGTH);
    special["perception"] = critterGetBaseStat(gDude, STAT_PERCEPTION);
    special["endurance"] = critterGetBaseStat(gDude, STAT_ENDURANCE);
    special["charisma"] = critterGetBaseStat(gDude, STAT_CHARISMA);
    special["intelligence"] = critterGetBaseStat(gDude, STAT_INTELLIGENCE);
    special["agility"] = critterGetBaseStat(gDude, STAT_AGILITY);
    special["luck"] = critterGetBaseStat(gDude, STAT_LUCK);
    character["special"] = special;

    // Derived stats
    json derived;
    derived["max_hp"] = critterGetStat(gDude, STAT_MAXIMUM_HIT_POINTS);
    derived["max_ap"] = critterGetStat(gDude, STAT_MAXIMUM_ACTION_POINTS);
    derived["armor_class"] = critterGetStat(gDude, STAT_ARMOR_CLASS);
    derived["melee_damage"] = critterGetStat(gDude, STAT_MELEE_DAMAGE);
    derived["carry_weight"] = critterGetStat(gDude, STAT_CARRY_WEIGHT);
    derived["sequence"] = critterGetStat(gDude, STAT_SEQUENCE);
    derived["healing_rate"] = critterGetStat(gDude, STAT_HEALING_RATE);
    derived["critical_chance"] = critterGetStat(gDude, STAT_CRITICAL_CHANCE);
    derived["radiation_resistance"] = critterGetStat(gDude, STAT_RADIATION_RESISTANCE);
    derived["poison_resistance"] = critterGetStat(gDude, STAT_POISON_RESISTANCE);
    character["derived_stats"] = derived;

    // Traits
    int trait1, trait2;
    traitsGetSelected(&trait1, &trait2);
    json traits = json::array();
    if (trait1 >= 0 && trait1 < TRAIT_COUNT)
        traits.push_back(traitIdToName(trait1));
    if (trait2 >= 0 && trait2 < TRAIT_COUNT)
        traits.push_back(traitIdToName(trait2));
    character["traits"] = traits;

    // Tagged skills
    int taggedSkills[NUM_TAGGED_SKILLS];
    skillsGetTagged(taggedSkills, NUM_TAGGED_SKILLS);
    json tagged = json::array();
    for (int i = 0; i < NUM_TAGGED_SKILLS; i++) {
        if (taggedSkills[i] >= 0 && taggedSkills[i] < SKILL_COUNT)
            tagged.push_back(skillIdToName(taggedSkills[i]));
    }
    character["tagged_skills"] = tagged;

    // All skills
    json skills;
    for (int i = 0; i < SKILL_COUNT; i++) {
        skills[skillIdToName(i)] = skillGetValue(gDude, i);
    }
    character["skills"] = skills;

    // Available traits list
    json availableTraits = json::array();
    for (int i = 0; i < TRAIT_COUNT; i++) {
        json t;
        t["id"] = i;
        char* tName = traitGetName(i);
        t["name"] = tName ? tName : "";
        availableTraits.push_back(t);
    }
    character["available_traits"] = availableTraits;

    state["character"] = character;
    state["available_actions"] = json::array({
        "set_special", "select_traits", "tag_skills",
        "set_name", "finish_character_creation",
        "adjust_stat", "toggle_trait", "toggle_skill_tag", "editor_done"
    });
}

static void writeGameplayState(json& state)
{
    json character;

    char* name = critterGetName(gDude);
    character["name"] = name ? name : "";

    json special;
    special["strength"] = critterGetBaseStat(gDude, STAT_STRENGTH);
    special["perception"] = critterGetBaseStat(gDude, STAT_PERCEPTION);
    special["endurance"] = critterGetBaseStat(gDude, STAT_ENDURANCE);
    special["charisma"] = critterGetBaseStat(gDude, STAT_CHARISMA);
    special["intelligence"] = critterGetBaseStat(gDude, STAT_INTELLIGENCE);
    special["agility"] = critterGetBaseStat(gDude, STAT_AGILITY);
    special["luck"] = critterGetBaseStat(gDude, STAT_LUCK);
    character["special"] = special;

    json derived;
    derived["max_hp"] = critterGetStat(gDude, STAT_MAXIMUM_HIT_POINTS);
    derived["current_hp"] = critterGetHitPoints(gDude);
    derived["max_ap"] = critterGetStat(gDude, STAT_MAXIMUM_ACTION_POINTS);
    derived["armor_class"] = critterGetStat(gDude, STAT_ARMOR_CLASS);
    derived["melee_damage"] = critterGetStat(gDude, STAT_MELEE_DAMAGE);
    derived["carry_weight"] = critterGetStat(gDude, STAT_CARRY_WEIGHT);
    derived["sequence"] = critterGetStat(gDude, STAT_SEQUENCE);
    derived["healing_rate"] = critterGetStat(gDude, STAT_HEALING_RATE);
    derived["critical_chance"] = critterGetStat(gDude, STAT_CRITICAL_CHANCE);
    character["derived_stats"] = derived;

    int trait1, trait2;
    traitsGetSelected(&trait1, &trait2);
    json traits = json::array();
    if (trait1 >= 0 && trait1 < TRAIT_COUNT)
        traits.push_back(traitIdToName(trait1));
    if (trait2 >= 0 && trait2 < TRAIT_COUNT)
        traits.push_back(traitIdToName(trait2));
    character["traits"] = traits;

    int taggedSkills[NUM_TAGGED_SKILLS];
    skillsGetTagged(taggedSkills, NUM_TAGGED_SKILLS);
    json tagged = json::array();
    for (int i = 0; i < NUM_TAGGED_SKILLS; i++) {
        if (taggedSkills[i] >= 0 && taggedSkills[i] < SKILL_COUNT)
            tagged.push_back(skillIdToName(taggedSkills[i]));
    }
    character["tagged_skills"] = tagged;

    json skills;
    for (int i = 0; i < SKILL_COUNT; i++) {
        skills[skillIdToName(i)] = skillGetValue(gDude, i);
    }
    character["skills"] = skills;

    character["level"] = pcGetStat(PC_STAT_LEVEL);
    character["experience"] = pcGetStat(PC_STAT_EXPERIENCE);

    state["character"] = character;
}

// --- Structured command handlers ---

static void handleSetSpecial(const json& cmd)
{
    static const char* statNames[] = {
        "strength", "perception", "endurance", "charisma",
        "intelligence", "agility", "luck"
    };
    static const int statIds[] = {
        STAT_STRENGTH, STAT_PERCEPTION, STAT_ENDURANCE, STAT_CHARISMA,
        STAT_INTELLIGENCE, STAT_AGILITY, STAT_LUCK
    };

    int values[7];
    int total = 0;

    for (int i = 0; i < 7; i++) {
        if (!cmd.contains(statNames[i]) || !cmd[statNames[i]].is_number_integer()) {
            debugPrint("AgentBridge: set_special missing '%s'\n", statNames[i]);
            return;
        }
        values[i] = cmd[statNames[i]].get<int>();
        if (values[i] < PRIMARY_STAT_MIN || values[i] > PRIMARY_STAT_MAX) {
            debugPrint("AgentBridge: set_special '%s' out of range (%d)\n", statNames[i], values[i]);
            return;
        }
        total += values[i];
    }

    if (total != 40) {
        debugPrint("AgentBridge: set_special total must be 40 (got %d)\n", total);
        return;
    }

    for (int i = 0; i < 7; i++) {
        critterSetBaseStat(gDude, statIds[i], values[i]);
    }

    gCharacterEditorRemainingCharacterPoints = 0;
    critterUpdateDerivedStats(gDude);
    debugPrint("AgentBridge: set_special applied\n");
}

static void handleSelectTraits(const json& cmd)
{
    if (!cmd.contains("traits") || !cmd["traits"].is_array()) {
        debugPrint("AgentBridge: select_traits missing 'traits' array\n");
        return;
    }

    auto& traitArr = cmd["traits"];
    if (traitArr.size() > TRAITS_MAX_SELECTED_COUNT) {
        debugPrint("AgentBridge: select_traits too many traits (max %d)\n", TRAITS_MAX_SELECTED_COUNT);
        return;
    }

    int t1 = -1;
    int t2 = -1;

    for (size_t i = 0; i < traitArr.size(); i++) {
        if (!traitArr[i].is_string()) {
            debugPrint("AgentBridge: select_traits entry is not a string\n");
            return;
        }
        std::string traitName = traitArr[i].get<std::string>();
        auto it = gTraitNameToId.find(traitName);
        if (it == gTraitNameToId.end()) {
            debugPrint("AgentBridge: select_traits unknown trait '%s'\n", traitName.c_str());
            return;
        }
        if (i == 0)
            t1 = it->second;
        else
            t2 = it->second;
    }

    traitsSetSelected(t1, t2);

    // Sync with editor's temp arrays so changes survive editor exit
    gCharacterEditorTempTraits[0] = t1;
    gCharacterEditorTempTraits[1] = t2;
    gCharacterEditorTempTraitCount = 0;
    if (t2 == -1)
        gCharacterEditorTempTraitCount++;
    if (t1 == -1)
        gCharacterEditorTempTraitCount++;

    critterUpdateDerivedStats(gDude);
    debugPrint("AgentBridge: select_traits applied (%d, %d)\n", t1, t2);
}

static void handleTagSkills(const json& cmd)
{
    if (!cmd.contains("skills") || !cmd["skills"].is_array()) {
        debugPrint("AgentBridge: tag_skills missing 'skills' array\n");
        return;
    }

    auto& skillArr = cmd["skills"];
    if ((int)skillArr.size() != DEFAULT_TAGGED_SKILLS) {
        debugPrint("AgentBridge: tag_skills requires exactly %d skills\n", DEFAULT_TAGGED_SKILLS);
        return;
    }

    int skills[NUM_TAGGED_SKILLS];
    // Initialize remaining slot to -1
    for (int i = 0; i < NUM_TAGGED_SKILLS; i++) {
        skills[i] = -1;
    }

    for (size_t i = 0; i < skillArr.size(); i++) {
        if (!skillArr[i].is_string()) {
            debugPrint("AgentBridge: tag_skills entry is not a string\n");
            return;
        }
        std::string skillName = skillArr[i].get<std::string>();
        auto it = gSkillNameToId.find(skillName);
        if (it == gSkillNameToId.end()) {
            debugPrint("AgentBridge: tag_skills unknown skill '%s'\n", skillName.c_str());
            return;
        }
        skills[i] = it->second;
    }

    skillsSetTagged(skills, NUM_TAGGED_SKILLS);

    // Sync with editor's temp arrays so changes survive editor exit
    for (int i = 0; i < NUM_TAGGED_SKILLS; i++) {
        gCharacterEditorTempTaggedSkills[i] = skills[i];
    }
    gCharacterEditorTaggedSkillCount = 0;

    debugPrint("AgentBridge: tag_skills applied\n");
}

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

// Character editor button event codes (from character_editor.cc)
// These are injected into the input queue so the editor's own event loop
// handles both state changes AND UI redraws/animations/sounds.
#define CHAR_EDITOR_STAT_PLUS_BASE 503  // 503-509 for STAT_STRENGTH..STAT_LUCK
#define CHAR_EDITOR_STAT_MINUS_BASE 510 // 510-516 for STAT_STRENGTH..STAT_LUCK
#define CHAR_EDITOR_STAT_BTN_RELEASE 518
#define CHAR_EDITOR_SKILL_TAG_BASE 536  // 536-553 for SKILL_SMALL_GUNS..SKILL_OUTDOORSMAN
#define CHAR_EDITOR_TRAIT_BASE 555      // 555-570 for TRAIT_FAST_METABOLISM..TRAIT_GIFTED

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
    // The stat handler has a do-while loop waiting for button release
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

// --- Command processing ---

static void processCommands()
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

    // Separate commands into ordered batches for character creation
    // Order: set_special → select_traits → tag_skills → set_name → finish_character_creation → others
    std::vector<const json*> setSpecialCmds;
    std::vector<const json*> selectTraitsCmds;
    std::vector<const json*> tagSkillsCmds;
    std::vector<const json*> setNameCmds;
    std::vector<const json*> finishCmds;
    std::vector<const json*> otherCmds;

    for (const auto& cmd : doc["commands"]) {
        if (!cmd.contains("type") || !cmd["type"].is_string())
            continue;

        std::string type = cmd["type"].get<std::string>();

        if (type == "set_special")
            setSpecialCmds.push_back(&cmd);
        else if (type == "select_traits")
            selectTraitsCmds.push_back(&cmd);
        else if (type == "tag_skills")
            tagSkillsCmds.push_back(&cmd);
        else if (type == "set_name")
            setNameCmds.push_back(&cmd);
        else if (type == "finish_character_creation")
            finishCmds.push_back(&cmd);
        else
            otherCmds.push_back(&cmd);
    }

    // Process character creation commands in correct order
    for (const auto* cmd : setSpecialCmds)
        handleSetSpecial(*cmd);
    for (const auto* cmd : selectTraitsCmds)
        handleSelectTraits(*cmd);
    for (const auto* cmd : tagSkillsCmds)
        handleTagSkills(*cmd);
    for (const auto* cmd : setNameCmds)
        handleSetName(*cmd);
    for (const auto* cmd : finishCmds)
        handleFinishCharacterCreation();

    // Process all other commands
    for (const auto* cmdPtr : otherCmds) {
        const auto& cmd = *cmdPtr;
        std::string type = cmd["type"].get<std::string>();

        if (type == "mouse_move") {
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

                // Simulate button down then up
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
        } else if (type == "adjust_stat") {
            handleAdjustStat(cmd);
        } else if (type == "toggle_trait") {
            handleToggleTrait(cmd);
        } else if (type == "toggle_skill_tag") {
            handleToggleSkillTag(cmd);
        } else if (type == "editor_done") {
            handleFinishCharacterCreation();
        } else if (type == "main_menu_select") {
            handleMainMenuSelect(cmd);
        } else if (type == "char_selector_select") {
            handleCharSelectorSelect(cmd);
        }
    }
}

// --- State writing ---

static std::vector<std::string> decodeGameModeFlags(int mode)
{
    std::vector<std::string> flags;

    struct FlagEntry {
        int value;
        const char* name;
    };

    static const FlagEntry entries[] = {
        { GameMode::kWorldmap, "worldmap" },
        { GameMode::kDialog, "dialog" },
        { GameMode::kOptions, "options" },
        { GameMode::kSaveGame, "save_game" },
        { GameMode::kLoadGame, "load_game" },
        { GameMode::kCombat, "combat" },
        { GameMode::kPreferences, "preferences" },
        { GameMode::kHelp, "help" },
        { GameMode::kEditor, "editor" },
        { GameMode::kPipboy, "pipboy" },
        { GameMode::kPlayerTurn, "player_turn" },
        { GameMode::kInventory, "inventory" },
        { GameMode::kAutomap, "automap" },
        { GameMode::kSkilldex, "skilldex" },
        { GameMode::kLoot, "loot" },
        { GameMode::kBarter, "barter" },
    };

    for (const auto& entry : entries) {
        if (mode & entry.value) {
            flags.push_back(entry.name);
        }
    }

    return flags;
}

static void writeState()
{
    int mouseX = 0;
    int mouseY = 0;
    mouseGetPosition(&mouseX, &mouseY);

    int gameMode = GameMode::getCurrentGameMode();

    json state;
    state["tick"] = gAgentTick;
    state["timestamp_ms"] = SDL_GetTicks();
    state["game_mode"] = gameMode;
    state["game_mode_flags"] = decodeGameModeFlags(gameMode);
    state["game_state"] = gameGetState();
    state["mouse"] = { { "x", mouseX }, { "y", mouseY } };
    state["screen"] = { { "width", screenGetWidth() }, { "height", screenGetHeight() } };

    // Enriched context-specific state
    const char* context = detectContext();
    state["context"] = context;

    if (strcmp(context, "movie") == 0) {
        writeMovieState(state);
    } else if (strcmp(context, "main_menu") == 0) {
        writeMainMenuState(state);
    } else if (strcmp(context, "character_selector") == 0) {
        writeCharSelectorState(state);
    } else if (strcmp(context, "character_editor") == 0) {
        writeCharEditorState(state);
    } else if (strcmp(context, "gameplay") == 0) {
        writeGameplayState(state);
    }

    std::string content = state.dump(2);

    FILE* f = fopen(kStateTmpPath, "wb");
    if (f == nullptr) {
        return;
    }
    fwrite(content.data(), 1, content.size(), f);
    fclose(f);

    rename(kStateTmpPath, kStatePath);
}

// --- Public API ---

void agentBridgeSetContext(int context)
{
    gAgentContext = context;
    debugPrint("AgentBridge: context set to %d\n", context);
}

void agentBridgeTick()
{
    gAgentTick++;
    processCommands();
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

    remove(kCmdPath);
    remove(kCmdTmpPath);
    remove(kStatePath);
    remove(kStateTmpPath);

    gKeyNameToScancode.clear();
    gStatNameToId.clear();
    gSkillNameToId.clear();
    gTraitNameToId.clear();

    debugPrint("AgentBridge: shutdown complete\n");
}

} // namespace fallout
