#include "agent_bridge_internal.h"

#include <SDL.h>
#include <cstdio>
#include <cstring>
#include <vector>

#include "character_editor.h"
#include "critter.h"
#include "db.h"
#include "debug.h"
#include "game.h"
#include "game_movie.h"
#include "mouse.h"
#include "object.h"
#include "skill.h"
#include "stat.h"
#include "svga.h"
#include "trait.h"

// Gameplay state headers
#include "actions.h"
#include "display_monitor.h"
#include "animation.h"
#include "combat.h"
#include "combat_defs.h"
#include "game_dialog.h"
#include "interface.h"
#include "inventory.h"
#include "item.h"
#include "map.h"
#include "obj_types.h"
#include "party_member.h"
#include "perk.h"
#include "proto.h"
#include "proto_instance.h"
#include "proto_types.h"
#include "tile.h"
#include "worldmap.h"
#include "game_vars.h"
#include "pipboy.h"
#include "scripts.h"
#include "settings.h"
#include "game_config.h"

namespace fallout {

static const char* kStateTmpPath = "agent_state.tmp";

// Throttle: only enumerate objects every N ticks
static const int kObjectEnumInterval = 10;

// --- Helper functions ---

// Sanitize a C string to valid UTF-8 for JSON serialization.
// Replaces invalid bytes with '?' to prevent nlohmann::json crashes.
static std::string safeString(const char* str)
{
    if (str == nullptr)
        return "";

    std::string result;
    const unsigned char* p = reinterpret_cast<const unsigned char*>(str);
    while (*p) {
        if (*p < 0x80) {
            // ASCII: pass through, but replace control chars (except newline/tab)
            if (*p >= 0x20 || *p == '\n' || *p == '\t') {
                result += static_cast<char>(*p);
            } else {
                result += '?';
            }
            p++;
        } else if ((*p & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80) {
            // 2-byte UTF-8
            result += static_cast<char>(p[0]);
            result += static_cast<char>(p[1]);
            p += 2;
        } else if ((*p & 0xF0) == 0xE0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
            // 3-byte UTF-8
            result += static_cast<char>(p[0]);
            result += static_cast<char>(p[1]);
            result += static_cast<char>(p[2]);
            p += 3;
        } else if ((*p & 0xF8) == 0xF0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 && (p[3] & 0xC0) == 0x80) {
            // 4-byte UTF-8
            result += static_cast<char>(p[0]);
            result += static_cast<char>(p[1]);
            result += static_cast<char>(p[2]);
            result += static_cast<char>(p[3]);
            p += 4;
        } else {
            // Invalid byte — replace with '?'
            result += '?';
            p++;
        }
    }
    return result;
}

const char* itemTypeToString(int type)
{
    switch (type) {
    case ITEM_TYPE_ARMOR:
        return "armor";
    case ITEM_TYPE_CONTAINER:
        return "container";
    case ITEM_TYPE_DRUG:
        return "drug";
    case ITEM_TYPE_WEAPON:
        return "weapon";
    case ITEM_TYPE_AMMO:
        return "ammo";
    case ITEM_TYPE_MISC:
        return "misc";
    case ITEM_TYPE_KEY:
        return "key";
    default:
        return "unknown";
    }
}

const char* sceneryTypeToString(int type)
{
    switch (type) {
    case SCENERY_TYPE_DOOR:
        return "door";
    case SCENERY_TYPE_STAIRS:
        return "stairs";
    case SCENERY_TYPE_ELEVATOR:
        return "elevator";
    case SCENERY_TYPE_LADDER_UP:
        return "ladder_up";
    case SCENERY_TYPE_LADDER_DOWN:
        return "ladder_down";
    case SCENERY_TYPE_GENERIC:
        return "generic";
    default:
        return "unknown";
    }
}

static const char* damageTypeToString(int type)
{
    switch (type) {
    case DAMAGE_TYPE_NORMAL: return "normal";
    case DAMAGE_TYPE_LASER: return "laser";
    case DAMAGE_TYPE_FIRE: return "fire";
    case DAMAGE_TYPE_PLASMA: return "plasma";
    case DAMAGE_TYPE_ELECTRICAL: return "electrical";
    case DAMAGE_TYPE_EMP: return "emp";
    case DAMAGE_TYPE_EXPLOSION: return "explosion";
    default: return "unknown";
    }
}

static const char* hitModeToString(int hitMode)
{
    switch (hitMode) {
    case HIT_MODE_LEFT_WEAPON_PRIMARY: return "left_primary";
    case HIT_MODE_LEFT_WEAPON_SECONDARY: return "left_secondary";
    case HIT_MODE_RIGHT_WEAPON_PRIMARY: return "right_primary";
    case HIT_MODE_RIGHT_WEAPON_SECONDARY: return "right_secondary";
    case HIT_MODE_PUNCH: return "punch";
    case HIT_MODE_KICK: return "kick";
    case HIT_MODE_LEFT_WEAPON_RELOAD: return "left_reload";
    case HIT_MODE_RIGHT_WEAPON_RELOAD: return "right_reload";
    case HIT_MODE_STRONG_PUNCH: return "strong_punch";
    case HIT_MODE_HAMMER_PUNCH: return "hammer_punch";
    case HIT_MODE_HAYMAKER: return "haymaker";
    case HIT_MODE_JAB: return "jab";
    case HIT_MODE_PALM_STRIKE: return "palm_strike";
    case HIT_MODE_PIERCING_STRIKE: return "piercing_strike";
    case HIT_MODE_STRONG_KICK: return "strong_kick";
    case HIT_MODE_SNAP_KICK: return "snap_kick";
    case HIT_MODE_POWER_KICK: return "power_kick";
    case HIT_MODE_HIP_KICK: return "hip_kick";
    case HIT_MODE_HOOK_KICK: return "hook_kick";
    case HIT_MODE_PIERCING_KICK: return "piercing_kick";
    default: return "unknown";
    }
}

static void writeWeaponAmmoInfo(json& weaponJson, Object* weapon)
{
    if (weapon == nullptr || itemGetType(weapon) != ITEM_TYPE_WEAPON)
        return;

    int capacity = ammoGetCapacity(weapon);
    if (capacity > 0) {
        // This is a weapon that uses ammo
        weaponJson["ammo_count"] = ammoGetQuantity(weapon);
        weaponJson["ammo_capacity"] = capacity;
        int ammoPid = weaponGetAmmoTypePid(weapon);
        if (ammoPid > 0) {
            weaponJson["ammo_pid"] = ammoPid;
            // Get ammo name from proto
            Proto* ammoProto = nullptr;
            if (protoGetProto(ammoPid, &ammoProto) == 0 && ammoProto != nullptr) {
                weaponJson["ammo_name"] = safeString(protoGetName(ammoPid));
            }
        }
    }

    // Damage type
    weaponJson["damage_type"] = damageTypeToString(weaponGetDamageType(gDude, weapon));

    // Range and damage
    int minDmg = 0, maxDmg = 0;
    weaponGetDamageMinMax(weapon, &minDmg, &maxDmg);
    weaponJson["damage_min"] = minDmg;
    weaponJson["damage_max"] = maxDmg;
}

// --- Context-specific state writers ---

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

            File* f = fileOpen(path, "rb");
            if (f != nullptr) {
                char header[91];
                if (fileRead(header, 1, 91, f) == 91) {
                    char characterName[33];
                    memcpy(characterName, header + 29, 32);
                    characterName[32] = '\0';

                    char description[31];
                    memcpy(description, header + 61, 30);
                    description[30] = '\0';

                    slot["character_name"] = safeString(characterName);
                    slot["description"] = safeString(description);
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

static void writeCharEditorState(json& state)
{
    json character;

    char* name = critterGetName(gDude);
    character["name"] = safeString(name);
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
        t["name"] = safeString(tName);
        availableTraits.push_back(t);
    }
    character["available_traits"] = availableTraits;

    // Level-up info (non-creation mode)
    character["unspent_skill_points"] = pcGetStat(PC_STAT_UNSPENT_SKILL_POINTS);
    character["level"] = pcGetStat(PC_STAT_LEVEL);
    character["experience"] = pcGetStat(PC_STAT_EXPERIENCE);

    // Available perks for selection
    int availablePerkIds[PERK_COUNT];
    int availPerkCount = perkGetAvailablePerks(gDude, availablePerkIds);
    if (availPerkCount > 0) {
        json availablePerks = json::array();
        for (int i = 0; i < availPerkCount; i++) {
            json p;
            p["id"] = availablePerkIds[i];
            char* pName = perkGetName(availablePerkIds[i]);
            p["name"] = safeString(pName);
            char* pDesc = perkGetDescription(availablePerkIds[i]);
            p["description"] = safeString(pDesc);
            p["current_rank"] = perkGetRank(gDude, availablePerkIds[i]);
            availablePerks.push_back(p);
        }
        character["available_perks"] = availablePerks;
    }

    state["character"] = character;
    state["available_actions"] = json::array({
        "set_name", "finish_character_creation",
        "adjust_stat", "toggle_trait", "toggle_skill_tag", "editor_done",
        "skill_add", "skill_sub", "perk_add"
    });
}

// --- Character state (shared between editor and gameplay) ---

static void writeCharacterStats(json& state)
{
    json character;

    char* name = critterGetName(gDude);
    character["name"] = safeString(name);

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
    derived["poison_resistance"] = critterGetStat(gDude, STAT_POISON_RESISTANCE);
    derived["radiation_resistance"] = critterGetStat(gDude, STAT_RADIATION_RESISTANCE);

    // Damage resistance (7 types)
    {
        json dr;
        for (int i = 0; i < DAMAGE_TYPE_COUNT; i++) {
            dr[damageTypeToString(i)] = critterGetStat(gDude, STAT_DAMAGE_RESISTANCE + i);
        }
        derived["damage_resistance"] = dr;
    }

    // Damage threshold (7 types)
    {
        json dt;
        for (int i = 0; i < DAMAGE_TYPE_COUNT; i++) {
            dt[damageTypeToString(i)] = critterGetStat(gDude, STAT_DAMAGE_THRESHOLD + i);
        }
        derived["damage_threshold"] = dt;
    }

    character["derived_stats"] = derived;

    // Age and gender
    character["age"] = critterGetStat(gDude, STAT_AGE);
    character["gender"] = (critterGetStat(gDude, STAT_GENDER) == GENDER_MALE) ? "male" : "female";

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
    character["xp_for_next_level"] = pcGetExperienceForNextLevel();
    character["unspent_skill_points"] = pcGetStat(PC_STAT_UNSPENT_SKILL_POINTS);
    character["can_level_up"] = dudeHasState(DUDE_STATE_LEVEL_UP_AVAILABLE);

    // Active perks (with descriptions)
    json perks = json::array();
    for (int i = 0; i < PERK_COUNT; i++) {
        int rank = perkGetRank(gDude, i);
        if (rank > 0) {
            json p;
            p["id"] = i;
            char* pName = perkGetName(i);
            p["name"] = safeString(pName);
            p["rank"] = rank;
            p["description"] = safeString(perkGetDescription(i));
            perks.push_back(p);
        }
    }
    character["perks"] = perks;

    // Status effects
    json statusEffects = json::array();
    int poison = critterGetPoison(gDude);
    if (poison > 0) {
        statusEffects.push_back("poisoned");
        character["poison_level"] = poison;
    }
    int radiation = critterGetRadiation(gDude);
    if (radiation > 0) {
        statusEffects.push_back("irradiated");
        character["radiation_level"] = radiation;
    }
    int combatResults = gDude->data.critter.combat.results;
    if (combatResults & DAM_CRIP_LEG_LEFT) statusEffects.push_back("crippled_left_leg");
    if (combatResults & DAM_CRIP_LEG_RIGHT) statusEffects.push_back("crippled_right_leg");
    if (combatResults & DAM_CRIP_ARM_LEFT) statusEffects.push_back("crippled_left_arm");
    if (combatResults & DAM_CRIP_ARM_RIGHT) statusEffects.push_back("crippled_right_arm");
    if (combatResults & DAM_BLIND) statusEffects.push_back("blinded");
    character["status_effects"] = statusEffects;

    // Karma
    character["karma"] = gameGetGlobalVar(GVAR_PLAYER_REPUTATION);

    // Town reputations (only emit non-zero values)
    json townReps;
    struct { int gvar; const char* name; } townRepEntries[] = {
        { GVAR_TOWN_REP_ARROYO, "arroyo" },
        { GVAR_TOWN_REP_KLAMATH, "klamath" },
        { GVAR_TOWN_REP_THE_DEN, "the_den" },
        { GVAR_TOWN_REP_VAULT_CITY, "vault_city" },
        { GVAR_TOWN_REP_GECKO, "gecko" },
        { GVAR_TOWN_REP_MODOC, "modoc" },
        { GVAR_TOWN_REP_SIERRA_BASE, "sierra_base" },
        { GVAR_TOWN_REP_BROKEN_HILLS, "broken_hills" },
        { GVAR_TOWN_REP_NEW_RENO, "new_reno" },
        { GVAR_TOWN_REP_REDDING, "redding" },
        { GVAR_TOWN_REP_NCR, "ncr" },
        { GVAR_TOWN_REP_VAULT_13, "vault_13" },
        { GVAR_TOWN_REP_SAN_FRANCISCO, "san_francisco" },
        { GVAR_TOWN_REP_VAULT_15, "vault_15" },
        { GVAR_TOWN_REP_GHOST_FARM, "ghost_farm" },
        { GVAR_TOWN_REP_NAVARRO, "navarro" },
    };
    for (const auto& entry : townRepEntries) {
        int val = gameGetGlobalVar(entry.gvar);
        if (val != 0)
            townReps[entry.name] = val;
    }
    if (!townReps.empty())
        character["town_reputations"] = townReps;

    // Addictions
    json addictions = json::array();
    struct { int gvar; const char* name; } addictionEntries[] = {
        { GVAR_NUKA_COLA_ADDICT, "nuka_cola" },
        { GVAR_BUFF_OUT_ADDICT, "buffout" },
        { GVAR_MENTATS_ADDICT, "mentats" },
        { GVAR_PSYCHO_ADDICT, "psycho" },
        { GVAR_RADAWAY_ADDICT, "radaway" },
        { GVAR_ALCOHOL_ADDICT, "alcohol" },
        { GVAR_ADDICT_JET, "jet" },
        { GVAR_ADDICT_TRAGIC, "tragic" },
    };
    for (const auto& entry : addictionEntries) {
        if (gameGetGlobalVar(entry.gvar) != 0)
            addictions.push_back(entry.name);
    }
    if (!addictions.empty())
        character["addictions"] = addictions;

    // Kill counts
    json killCounts;
    for (int i = 0; i < KILL_TYPE_COUNT; i++) {
        int count = killsGetByType(i);
        if (count > 0) {
            char* kName = killTypeGetName(i);
            if (kName != nullptr) {
                killCounts[safeString(kName)] = count;
            }
        }
    }
    if (!killCounts.empty())
        character["kill_counts"] = killCounts;

    state["character"] = character;
}

// --- Inventory state ---

static void writeInventoryState(json& state)
{
    json inv;
    json items = json::array();

    int totalWeight = 0;

    Inventory* inventory = &gDude->data.inventory;
    for (int i = 0; i < inventory->length; i++) {
        InventoryItem* invItem = &inventory->items[i];
        Object* item = invItem->item;
        if (item == nullptr)
            continue;

        json entry;
        entry["pid"] = item->pid;

        char* iName = itemGetName(item);
        entry["name"] = safeString(iName);
        entry["quantity"] = invItem->quantity;
        entry["type"] = itemTypeToString(itemGetType(item));

        int weight = itemGetWeight(item);
        entry["weight"] = weight;
        totalWeight += weight * invItem->quantity;

        // Description (skip if empty or same as name)
        char* iDesc = itemGetDescription(item);
        if (iDesc != nullptr && iDesc[0] != '\0') {
            std::string descStr = safeString(iDesc);
            if (descStr != entry["name"].get<std::string>()) {
                entry["description"] = descStr;
            }
        }

        // Detailed stats by item type
        int iType = itemGetType(item);
        if (iType == ITEM_TYPE_WEAPON) {
            json ws;
            int minDmg = 0, maxDmg = 0;
            weaponGetDamageMinMax(item, &minDmg, &maxDmg);
            ws["damage_min"] = minDmg;
            ws["damage_max"] = maxDmg;
            ws["damage_type"] = damageTypeToString(weaponGetDamageType(nullptr, item));
            ws["ap_cost_primary"] = weaponGetPrimaryActionPointCost(item);
            ws["ap_cost_secondary"] = weaponGetSecondaryActionPointCost(item);
            // Read range from proto directly — weaponGetRange() uses the critter's
            // equipped weapon, not the item being inspected.
            Proto* wProto = nullptr;
            if (protoGetProto(item->pid, &wProto) == 0 && wProto != nullptr) {
                ws["range_primary"] = wProto->item.data.weapon.maxRange1;
                ws["range_secondary"] = wProto->item.data.weapon.maxRange2;
            }
            ws["min_strength"] = weaponGetMinStrengthRequired(item);
            int caliber = ammoGetCaliber(item);
            if (caliber > 0) {
                ws["ammo_caliber"] = caliber;
                ws["ammo_capacity"] = ammoGetCapacity(item);
                ws["ammo_count"] = ammoGetQuantity(item);
            }
            entry["weapon_stats"] = ws;
        } else if (iType == ITEM_TYPE_ARMOR) {
            json as;
            as["armor_class"] = armorGetArmorClass(item);
            json dr, dt;
            for (int t = 0; t < DAMAGE_TYPE_COUNT; t++) {
                dr[damageTypeToString(t)] = armorGetDamageResistance(item, t);
                dt[damageTypeToString(t)] = armorGetDamageThreshold(item, t);
            }
            as["damage_resistance"] = dr;
            as["damage_threshold"] = dt;
            entry["armor_stats"] = as;
        } else if (iType == ITEM_TYPE_AMMO) {
            json ams;
            ams["caliber"] = ammoGetCaliber(item);
            ams["ac_modifier"] = ammoGetArmorClassModifier(item);
            ams["dr_modifier"] = ammoGetDamageResistanceModifier(item);
            ams["damage_multiplier"] = ammoGetDamageMultiplier(item);
            ams["damage_divisor"] = ammoGetDamageDivisor(item);
            entry["ammo_stats"] = ams;
        }

        items.push_back(entry);
    }
    inv["items"] = items;

    // Equipped items
    json equipped;

    Object* rightHand = critterGetItem2(gDude);
    if (rightHand != nullptr) {
        json rh;
        rh["pid"] = rightHand->pid;
        char* rhName = itemGetName(rightHand);
        rh["name"] = safeString(rhName);
        writeWeaponAmmoInfo(rh, rightHand);
        equipped["right_hand"] = rh;
    } else {
        equipped["right_hand"] = nullptr;
    }

    Object* leftHand = critterGetItem1(gDude);
    if (leftHand != nullptr) {
        json lh;
        lh["pid"] = leftHand->pid;
        char* lhName = itemGetName(leftHand);
        lh["name"] = safeString(lhName);
        writeWeaponAmmoInfo(lh, leftHand);
        equipped["left_hand"] = lh;
    } else {
        equipped["left_hand"] = nullptr;
    }

    Object* armor = critterGetArmor(gDude);
    if (armor != nullptr) {
        json ar;
        ar["pid"] = armor->pid;
        char* arName = itemGetName(armor);
        ar["name"] = safeString(arName);
        // Armor stats
        json armorStats;
        armorStats["armor_class"] = armorGetArmorClass(armor);
        json arDr, arDt;
        for (int t = 0; t < DAMAGE_TYPE_COUNT; t++) {
            arDr[damageTypeToString(t)] = armorGetDamageResistance(armor, t);
            arDt[damageTypeToString(t)] = armorGetDamageThreshold(armor, t);
        }
        armorStats["damage_resistance"] = arDr;
        armorStats["damage_threshold"] = arDt;
        ar["armor_stats"] = armorStats;
        equipped["armor"] = ar;
    } else {
        equipped["armor"] = nullptr;
    }

    inv["equipped"] = equipped;
    inv["total_weight"] = totalWeight;
    inv["carry_capacity"] = critterGetStat(gDude, STAT_CARRY_WEIGHT);

    // Active hand and attack mode (available in exploration too)
    int currentHand = interfaceGetCurrentHand();
    inv["active_hand"] = (currentHand == HAND_RIGHT) ? "right" : "left";

    int hitMode = -1;
    bool aimingMode = false;
    if (interfaceGetCurrentHitMode(&hitMode, &aimingMode) == 0) {
        inv["current_hit_mode"] = hitMode;
        inv["current_hit_mode_name"] = hitModeToString(hitMode);
    }

    state["inventory"] = inv;
}

// --- Map & object state ---

static json gCachedObjects;
static unsigned int gLastObjectEnumTick = 0;

void agentForceObjectRefresh()
{
    gLastObjectEnumTick = 0;
}

static void writeMapAndObjectState(json& state)
{
    // Safety: don't enumerate objects if no map is loaded
    if (mapGetCurrentMap() < 0) {
        return;
    }

    // Map info
    json map;
    map["name"] = safeString(gMapHeader.name);
    map["index"] = mapGetCurrentMap();
    map["elevation"] = gElevation;
    state["map"] = map;

    // Player position
    json player;
    player["tile"] = gDude->tile;
    player["elevation"] = gDude->elevation;
    player["rotation"] = gDude->rotation;
    player["animation_busy"] = animationIsBusy(gDude) != 0;
    player["is_sneaking"] = dudeHasState(DUDE_STATE_SNEAKING);

    // Movement progress
    int waypointsLeft = agentGetMovementWaypointsRemaining();
    if (waypointsLeft > 0) {
        player["movement_waypoints_remaining"] = waypointsLeft;
    }

    // Walkable neighbor tiles (6 hex directions)
    json neighbors = json::array();
    for (int dir = 0; dir < 6; dir++) {
        int neighborTile = tileGetTileInDirection(gDude->tile, dir, 1);
        if (neighborTile >= 0 && neighborTile < 40000) {
            Object* blocker = _obj_blocking_at(gDude, neighborTile, gDude->elevation);
            json nb;
            nb["tile"] = neighborTile;
            nb["direction"] = dir;
            nb["walkable"] = (blocker == nullptr);
            neighbors.push_back(nb);
        }
    }
    player["neighbors"] = neighbors;

    state["player"] = player;

    // Only re-enumerate objects every kObjectEnumInterval ticks (unless in combat player turn)
    int gameMode = GameMode::getCurrentGameMode();
    bool isPlayerTurn = isInCombat() && (gameMode & GameMode::kPlayerTurn);
    bool shouldEnum = isPlayerTurn
        || (gAgentTick - gLastObjectEnumTick >= (unsigned int)kObjectEnumInterval);

    if (!shouldEnum) {
        state["objects"] = gCachedObjects;
        return;
    }

    gLastObjectEnumTick = gAgentTick;
    json objects;

    // Critters
    json critters = json::array();
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_CRITTER, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr || obj == gDude)
                continue;

            json c;
            c["id"] = objectToUniqueId(obj);
            c["pid"] = obj->pid;

            char* cName = objectGetName(obj);
            c["name"] = safeString(cName);
            char* cDesc = objectGetDescription(obj);
            if (cDesc != nullptr && cDesc[0] != '\0') {
                std::string cd = safeString(cDesc);
                if (cd != c["name"].get<std::string>())
                    c["description"] = cd;
            }
            c["tile"] = obj->tile;
            c["distance"] = objectGetDistanceBetween(gDude, obj);
            c["hp"] = critterGetHitPoints(obj);
            c["max_hp"] = critterGetStat(obj, STAT_MAXIMUM_HIT_POINTS);
            c["dead"] = critterIsDead(obj);

            // Disposition info
            int critterTeam = obj->data.critter.combat.team;
            int playerTeam = gDude->data.critter.combat.team;
            c["team"] = critterTeam;
            c["is_party_member"] = objectIsPartyMember(obj);

            // "hostile" only meaningful during combat; outside combat show "enemy_team"
            if (isInCombat()) {
                c["hostile"] = (critterTeam != playerTeam && !critterIsDead(obj));
            } else {
                c["enemy_team"] = (critterTeam != playerTeam);
            }

            critters.push_back(c);
        }
        if (list != nullptr) {
            objectListFree(list);
        }
    }
    objects["critters"] = critters;

    // Items on ground (within 25 hexes)
    json groundItems = json::array();
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_ITEM, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr)
                continue;

            int dist = objectGetDistanceBetween(gDude, obj);
            if (dist > 100)
                continue;

            json it;
            it["id"] = objectToUniqueId(obj);
            it["pid"] = obj->pid;

            char* iName = objectGetName(obj);
            it["name"] = safeString(iName);
            char* iDesc = objectGetDescription(obj);
            if (iDesc != nullptr && iDesc[0] != '\0') {
                std::string id = safeString(iDesc);
                if (id != it["name"].get<std::string>())
                    it["description"] = id;
            }
            it["tile"] = obj->tile;
            it["distance"] = dist;
            it["type"] = itemTypeToString(itemGetType(obj));

            // For container items (pots, chests), include item count
            if (obj->data.inventory.length > 0) {
                it["item_count"] = obj->data.inventory.length;
            }

            groundItems.push_back(it);
        }
        if (list != nullptr) {
            objectListFree(list);
        }
    }
    objects["ground_items"] = groundItems;

    // Scenery (doors and containers within 30 hexes)
    json scenery = json::array();
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_SCENERY, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr)
                continue;

            Proto* proto = nullptr;
            if (protoGetProto(obj->pid, &proto) != 0 || proto == nullptr)
                continue;

            int scenType = proto->scenery.type;

            // Include doors, stairs, ladders, elevators
            // For generic scenery: include if it has inventory (container) or a script (usable)
            bool isDoor = (scenType == SCENERY_TYPE_DOOR);
            bool isTransition = (scenType == SCENERY_TYPE_STAIRS
                || scenType == SCENERY_TYPE_ELEVATOR
                || scenType == SCENERY_TYPE_LADDER_UP
                || scenType == SCENERY_TYPE_LADDER_DOWN);
            bool isContainer = (scenType == SCENERY_TYPE_GENERIC
                && obj->data.inventory.length > 0);
            bool isScripted = (scenType == SCENERY_TYPE_GENERIC
                && obj->sid != -1
                && obj->data.inventory.length == 0);

            if (!isDoor && !isTransition && !isContainer && !isScripted)
                continue;

            int dist = objectGetDistanceBetween(gDude, obj);
            if (dist > 100)
                continue;

            json s;
            s["id"] = objectToUniqueId(obj);

            char* sName = objectGetName(obj);
            s["name"] = safeString(sName);
            char* sDesc = objectGetDescription(obj);
            if (sDesc != nullptr && sDesc[0] != '\0') {
                std::string sd = safeString(sDesc);
                if (sd != s["name"].get<std::string>())
                    s["description"] = sd;
            }
            s["tile"] = obj->tile;
            s["distance"] = dist;
            s["scenery_type"] = sceneryTypeToString(scenType);

            if (isDoor) {
                s["locked"] = objectIsLocked(obj);
                s["open"] = objectIsOpen(obj);
            }
            if (isContainer) {
                s["locked"] = objectIsLocked(obj);
                s["item_count"] = obj->data.inventory.length;
            }
            if (isScripted) {
                s["usable"] = true;
            }

            scenery.push_back(s);
        }
        if (list != nullptr) {
            objectListFree(list);
        }
    }
    objects["scenery"] = scenery;

    // Exit grids
    json exitGrids = json::array();
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_MISC, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr)
                continue;

            if (!isExitGridPid(obj->pid))
                continue;

            json eg;
            eg["id"] = objectToUniqueId(obj);
            eg["tile"] = obj->tile;
            eg["distance"] = objectGetDistanceBetween(gDude, obj);
            int destMap = obj->data.misc.map;
            int destElev = obj->data.misc.elevation;
            eg["destination_map"] = destMap;
            eg["destination_tile"] = obj->data.misc.tile;
            eg["destination_elevation"] = destElev;

            // Translate map index to name
            if (destMap >= 0) {
                char* mName = mapGetName(destMap, destElev);
                if (mName != nullptr) {
                    eg["destination_map_name"] = safeString(mName);
                }
            } else if (destMap == -2) {
                eg["destination_map_name"] = "worldmap";
            }

            exitGrids.push_back(eg);
        }
        if (list != nullptr) {
            objectListFree(list);
        }
    }
    objects["exit_grids"] = exitGrids;

    gCachedObjects = objects;
    state["objects"] = objects;
}

// --- Combat state ---

static void writeCombatState(json& state)
{
    json combat;

    combat["current_ap"] = gDude->data.critter.combat.ap;
    combat["max_ap"] = critterGetStat(gDude, STAT_MAXIMUM_ACTION_POINTS);
    combat["free_move"] = _combat_free_move;

    // Active hand and attack mode
    int currentHand = interfaceGetCurrentHand();
    combat["active_hand"] = (currentHand == HAND_RIGHT) ? "right" : "left";

    int hitMode = -1;
    bool aiming = false;
    if (interfaceGetCurrentHitMode(&hitMode, &aiming) == 0) {
        combat["current_hit_mode"] = hitMode;
        combat["current_hit_mode_name"] = hitModeToString(hitMode);
        combat["aiming"] = aiming;
    }

    // Active weapon info — use the weapon from the CURRENT hand
    Object* weapon = (currentHand == HAND_RIGHT) ? critterGetItem2(gDude) : critterGetItem1(gDude);
    // Use correct hit modes based on which hand is active
    int primaryHitMode, secondaryHitMode;
    if (weapon != nullptr) {
        if (currentHand == HAND_RIGHT) {
            primaryHitMode = HIT_MODE_RIGHT_WEAPON_PRIMARY;
            secondaryHitMode = HIT_MODE_RIGHT_WEAPON_SECONDARY;
        } else {
            primaryHitMode = HIT_MODE_LEFT_WEAPON_PRIMARY;
            secondaryHitMode = HIT_MODE_LEFT_WEAPON_SECONDARY;
        }
    } else {
        primaryHitMode = HIT_MODE_PUNCH;
        secondaryHitMode = HIT_MODE_KICK;
    }

    json activeWeapon;
    if (weapon != nullptr) {
        char* wName = itemGetName(weapon);
        activeWeapon["name"] = safeString(wName);

        // Primary attack
        json primary;
        int minDmg = 0, maxDmg = 0;
        weaponGetDamageMinMax(weapon, &minDmg, &maxDmg);
        primary["ap_cost"] = weaponGetActionPointCost(gDude, primaryHitMode, false);
        primary["damage_min"] = minDmg;
        primary["damage_max"] = maxDmg;
        primary["range"] = weaponGetRange(gDude, primaryHitMode);
        activeWeapon["primary"] = primary;

        // Secondary attack
        json secondary;
        secondary["ap_cost"] = weaponGetActionPointCost(gDude, secondaryHitMode, false);
        secondary["range"] = weaponGetRange(gDude, secondaryHitMode);
        activeWeapon["secondary"] = secondary;
    } else {
        // Unarmed
        activeWeapon["name"] = "Unarmed";

        json primary;
        primary["ap_cost"] = weaponGetActionPointCost(gDude, HIT_MODE_PUNCH, false);
        primary["range"] = weaponGetRange(gDude, HIT_MODE_PUNCH);
        activeWeapon["primary"] = primary;

        json secondary;
        secondary["ap_cost"] = weaponGetActionPointCost(gDude, HIT_MODE_KICK, false);
        secondary["range"] = weaponGetRange(gDude, HIT_MODE_KICK);
        activeWeapon["secondary"] = secondary;
    }
    combat["active_weapon"] = activeWeapon;

    // Hostiles with hit chances
    json hostiles = json::array();
    {
        Object** list = nullptr;
        int count = objectListCreate(-1, gDude->elevation, OBJ_TYPE_CRITTER, &list);
        for (int i = 0; i < count; i++) {
            Object* obj = list[i];
            if (obj == nullptr || obj == gDude)
                continue;
            if (critterIsDead(obj))
                continue;
            if (obj->data.critter.combat.team == gDude->data.critter.combat.team)
                continue;

            json h;
            h["id"] = objectToUniqueId(obj);

            char* hName = objectGetName(obj);
            h["name"] = safeString(hName);
            h["tile"] = obj->tile;
            h["distance"] = objectGetDistanceBetween(gDude, obj);
            h["hp"] = critterGetHitPoints(obj);
            h["max_hp"] = critterGetStat(obj, STAT_MAXIMUM_HIT_POINTS);

            // Hit chances for each location — use the active hand's hit mode
            int hitMode = primaryHitMode;
            json hitChances;
            hitChances["uncalled"] = _determine_to_hit(gDude, obj, HIT_LOCATION_UNCALLED, hitMode);
            hitChances["torso"] = _determine_to_hit(gDude, obj, HIT_LOCATION_TORSO, hitMode);
            hitChances["head"] = _determine_to_hit(gDude, obj, HIT_LOCATION_HEAD, hitMode);
            hitChances["eyes"] = _determine_to_hit(gDude, obj, HIT_LOCATION_EYES, hitMode);
            hitChances["groin"] = _determine_to_hit(gDude, obj, HIT_LOCATION_GROIN, hitMode);
            hitChances["left_arm"] = _determine_to_hit(gDude, obj, HIT_LOCATION_LEFT_ARM, hitMode);
            hitChances["right_arm"] = _determine_to_hit(gDude, obj, HIT_LOCATION_RIGHT_ARM, hitMode);
            hitChances["left_leg"] = _determine_to_hit(gDude, obj, HIT_LOCATION_LEFT_LEG, hitMode);
            hitChances["right_leg"] = _determine_to_hit(gDude, obj, HIT_LOCATION_RIGHT_LEG, hitMode);
            h["hit_chances"] = hitChances;

            hostiles.push_back(h);
        }
        if (list != nullptr) {
            objectListFree(list);
        }
    }
    combat["hostiles"] = hostiles;
    combat["pending_attacks"] = getPendingAttackCount();

    // Turn order — emit ALL combatants (including dead) so indices match
    // current_combatant_index which is the raw _list_com value.
    int combatantCount = agentGetCombatantCount();
    if (combatantCount > 0) {
        json turnOrder = json::array();
        for (int i = 0; i < combatantCount; i++) {
            Object* combatant = agentGetCombatant(i);
            if (combatant == nullptr)
                continue;
            json entry;
            entry["id"] = objectToUniqueId(combatant);
            char* cName = objectGetName(combatant);
            entry["name"] = safeString(cName);
            entry["is_player"] = (combatant == gDude);
            entry["dead"] = critterIsDead(combatant);
            turnOrder.push_back(entry);
        }
        combat["turn_order"] = turnOrder;
        combat["current_combatant_index"] = agentGetCurrentCombatantIndex();
    }
    combat["combat_round"] = _combatNumTurns;

    state["combat"] = combat;
}

// --- Dialogue state ---

static void writeDialogueState(json& state)
{
    json dialogue;

    if (gGameDialogSpeaker != nullptr) {
        char* speakerName = objectGetName(gGameDialogSpeaker);
        dialogue["speaker_name"] = safeString(speakerName);
        dialogue["speaker_id"] = objectToUniqueId(gGameDialogSpeaker);
    }

    const char* replyText = agentGetDialogReplyText();
    dialogue["reply_text"] = safeString(replyText);

    json options = json::array();
    int optionCount = agentGetDialogOptionCount();
    for (int i = 0; i < optionCount; i++) {
        json opt;
        opt["index"] = i;
        const char* optText = agentGetDialogOptionText(i);
        opt["text"] = safeString(optText);
        options.push_back(opt);
    }
    dialogue["options"] = options;

    state["dialogue"] = dialogue;
}

// --- Loot/container state ---

static void writeLootState(json& state)
{
    Object* target = inven_get_current_target_obj();
    if (target == nullptr)
        return;

    json loot;

    char* targetName = objectGetName(target);
    loot["target_name"] = safeString(targetName);
    loot["target_id"] = objectToUniqueId(target);
    loot["target_pid"] = target->pid;

    // Container contents
    json containerItems = json::array();
    Inventory* inv = &target->data.inventory;
    for (int i = 0; i < inv->length; i++) {
        InventoryItem* invItem = &inv->items[i];
        Object* item = invItem->item;
        if (item == nullptr)
            continue;

        json entry;
        entry["pid"] = item->pid;
        char* iName = itemGetName(item);
        entry["name"] = safeString(iName);
        entry["quantity"] = invItem->quantity;
        entry["type"] = itemTypeToString(itemGetType(item));
        entry["weight"] = itemGetWeight(item);
        containerItems.push_back(entry);
    }
    loot["container_items"] = containerItems;

    state["loot"] = loot;
}

// --- Party member state ---

static void writePartyState(json& state)
{
    json partyMembers = json::array();

    std::vector<Object*> members = get_all_party_members_objects(false);
    for (Object* obj : members) {
        if (obj == nullptr || obj == gDude)
            continue;

        json m;
        m["id"] = objectToUniqueId(obj);
        m["pid"] = obj->pid;

        char* mName = objectGetName(obj);
        m["name"] = safeString(mName);
        m["tile"] = obj->tile;
        m["distance"] = objectGetDistanceBetween(gDude, obj);
        m["hp"] = critterGetHitPoints(obj);
        m["max_hp"] = critterGetStat(obj, STAT_MAXIMUM_HIT_POINTS);
        m["dead"] = critterIsDead(obj);

        // Equipment
        Object* armor = critterGetArmor(obj);
        if (armor != nullptr) {
            char* arName = itemGetName(armor);
            m["armor"] = safeString(arName);
        }

        Object* weapon = critterGetItem2(obj);
        if (weapon != nullptr) {
            char* wName = itemGetName(weapon);
            m["weapon"] = safeString(wName);
        }

        partyMembers.push_back(m);
    }

    state["party_members"] = partyMembers;
}

// --- Barter state ---

static void writeBarterState(json& state)
{
    json barter;

    // Merchant info
    if (gGameDialogSpeaker != nullptr) {
        char* merchantName = objectGetName(gGameDialogSpeaker);
        barter["merchant_name"] = safeString(merchantName);
        barter["merchant_id"] = objectToUniqueId(gGameDialogSpeaker);

        // Merchant's inventory (items available to buy)
        json merchantItems = json::array();
        Inventory* merchInv = &gGameDialogSpeaker->data.inventory;
        for (int i = 0; i < merchInv->length; i++) {
            InventoryItem* invItem = &merchInv->items[i];
            Object* item = invItem->item;
            if (item == nullptr)
                continue;

            json entry;
            entry["pid"] = item->pid;
            char* iName = itemGetName(item);
            entry["name"] = safeString(iName);
            entry["quantity"] = invItem->quantity;
            entry["type"] = itemTypeToString(itemGetType(item));
            entry["cost"] = itemGetCost(item);
            merchantItems.push_back(entry);
        }
        barter["merchant_inventory"] = merchantItems;
    }

    // Player's offer table (items player is offering)
    Object* playerTable = agentGetBarterPlayerTable();
    if (playerTable != nullptr) {
        json playerOffer = json::array();
        Inventory* ptInv = &playerTable->data.inventory;
        for (int i = 0; i < ptInv->length; i++) {
            InventoryItem* invItem = &ptInv->items[i];
            Object* item = invItem->item;
            if (item == nullptr)
                continue;

            json entry;
            entry["pid"] = item->pid;
            char* iName = itemGetName(item);
            entry["name"] = safeString(iName);
            entry["quantity"] = invItem->quantity;
            entry["cost"] = itemGetCost(item);
            playerOffer.push_back(entry);
        }
        barter["player_offer"] = playerOffer;
    }

    // Merchant's offer table (items player wants to buy)
    Object* merchantTable = agentGetBarterMerchantTable();
    if (merchantTable != nullptr) {
        json merchantOffer = json::array();
        Inventory* btInv = &merchantTable->data.inventory;
        for (int i = 0; i < btInv->length; i++) {
            InventoryItem* invItem = &btInv->items[i];
            Object* item = invItem->item;
            if (item == nullptr)
                continue;

            json entry;
            entry["pid"] = item->pid;
            char* iName = itemGetName(item);
            entry["name"] = safeString(iName);
            entry["quantity"] = invItem->quantity;
            entry["cost"] = itemGetCost(item);
            merchantOffer.push_back(entry);
        }
        barter["merchant_offer"] = merchantOffer;
    }

    barter["barter_modifier"] = agentGetBarterModifier();

    // Player's money (caps)
    barter["player_caps"] = itemGetTotalCaps(gDude);
    if (gGameDialogSpeaker != nullptr) {
        barter["merchant_caps"] = itemGetTotalCaps(gGameDialogSpeaker);
    }

    // Trade value estimation — helps the agent understand if a trade will succeed
    if (playerTable != nullptr && merchantTable != nullptr && gGameDialogSpeaker != nullptr) {
        json tradeInfo;

        int playerOfferValue = objectGetCost(playerTable);
        int merchantOfferValue = objectGetCost(merchantTable);
        int merchantOfferCaps = itemGetTotalCaps(merchantTable);
        int costWithoutCaps = merchantOfferValue - merchantOfferCaps;

        tradeInfo["player_offer_value"] = playerOfferValue;
        tradeInfo["merchant_offer_value"] = merchantOfferValue;

        int partyBarter = partyGetBestSkillValue(SKILL_BARTER);
        int npcBarter = skillGetValue(gGameDialogSpeaker, SKILL_BARTER);
        tradeInfo["party_barter_skill"] = partyBarter;
        tradeInfo["npc_barter_skill"] = npcBarter;

        // Replicate _barter_compute_value formula
        double perkBonus = perkHasRank(gDude, PERK_MASTER_TRADER) ? 25.0 : 0.0;
        int barterMod = agentGetBarterModifier();
        double barterModMult = (barterMod + 100.0 - perkBonus) * 0.01;
        if (barterModMult < 0) barterModMult = 0.0099999998;
        double balancedCost = (160.0 + npcBarter) / (160.0 + partyBarter) * (costWithoutCaps * 2.0);
        int merchantWants = (int)(barterModMult * balancedCost + merchantOfferCaps);

        tradeInfo["merchant_wants"] = merchantWants;
        tradeInfo["trade_will_succeed"] = (merchantTable->data.inventory.length > 0 || playerTable->data.inventory.length > 0)
            && playerOfferValue >= merchantWants
            && playerTable->data.inventory.length > 0;

        barter["trade_info"] = tradeInfo;
    }

    state["barter"] = barter;
}

// --- World map state ---

static void writeWorldmapState(json& state)
{
    json wm;

    // Current position
    int worldX = 0, worldY = 0;
    wmGetPartyWorldPos(&worldX, &worldY);
    wm["world_pos_x"] = worldX;
    wm["world_pos_y"] = worldY;

    // Current area
    int currentArea = -1;
    wmGetPartyCurArea(&currentArea);
    wm["current_area_id"] = currentArea;
    if (currentArea >= 0) {
        char areaName[40] = {};
        wmGetAreaIdxName(currentArea, areaName);
        wm["current_area_name"] = safeString(areaName);
    }

    // Walking state
    wm["is_walking"] = agentWmIsWalking();
    if (agentWmIsWalking()) {
        int destX = 0, destY = 0;
        agentWmGetWalkDestination(&destX, &destY);
        wm["walk_destination_x"] = destX;
        wm["walk_destination_y"] = destY;
    }

    // Car state
    wm["is_in_car"] = agentWmIsInCar();
    if (agentWmIsInCar()) {
        wm["car_fuel"] = agentWmGetCarFuel();
        wm["car_fuel_max"] = CAR_FUEL_MAX;
    }

    // Known/visited locations
    json locations = json::array();
    int areaCount = agentWmGetAreaCount();
    for (int i = 0; i < areaCount; i++) {
        if (!wmAreaIsKnown(i))
            continue;

        char name[40] = {};
        int x = 0, y = 0, areaState = 0, size = 0;
        agentWmGetAreaInfo(i, name, sizeof(name), &x, &y, &areaState, &size);

        json loc;
        loc["area_id"] = i;
        loc["name"] = safeString(name);
        loc["x"] = x;
        loc["y"] = y;
        loc["visited"] = wmAreaVisitedState(i);

        // List all entrances (show all regardless of state so agent can navigate)
        int entranceCount = agentWmGetAreaEntranceCount(i);
        json entrances = json::array();
        for (int e = 0; e < entranceCount; e++) {
            int map = 0, elev = 0, tile = 0, entState = 0;
            if (agentWmGetAreaEntrance(i, e, &map, &elev, &tile, &entState) == 0) {
                json ent;
                ent["index"] = e;
                ent["map_index"] = map;
                ent["elevation"] = elev;
                ent["tile"] = tile;
                ent["known"] = (entState > 0);
                if (map >= 0) {
                    char* mName = mapGetName(map, elev >= 0 ? elev : 0);
                    if (mName != nullptr) {
                        ent["map_name"] = safeString(mName);
                    }
                }
                entrances.push_back(ent);
            }
        }
        loc["entrances"] = entrances;

        locations.push_back(loc);
    }
    wm["locations"] = locations;

    state["worldmap"] = wm;
}

// --- Message log state ---

static void writeMessageLog(json& state)
{
    json messages = json::array();

    // Read recent messages from the display monitor (index 0 = most recent)
    // Only include non-empty messages; stop after 20 or when we hit empty lines
    for (int i = 0; i < 20; i++) {
        const char* line = agentDisplayMonitorGetLine(i);
        if (line == nullptr || line[0] == '\0') {
            break;
        }
        // Strip the bullet character prefix (\x95) if present
        if ((unsigned char)line[0] == 0x95) {
            line++;
        }
        messages.push_back(safeString(line));
    }

    state["message_log"] = messages;
}

// --- Quest state ---

static void writeQuestState(json& state)
{
    // Ensure quest data is loaded (normally only loaded when Pip-Boy is opened)
    agentInitQuestData();

    int questCount = agentGetQuestCount();
    if (questCount <= 0)
        return;

    json quests = json::array();
    for (int i = 0; i < questCount; i++) {
        int gvar = agentGetQuestGvar(i);
        int displayThreshold = agentGetQuestDisplayThreshold(i);
        int completedThreshold = agentGetQuestCompletedThreshold(i);

        int gvarValue = gameGetGlobalVar(gvar);

        // Match Pip-Boy logic exactly: skip if display threshold not met
        if (displayThreshold > gvarValue)
            continue;

        json q;
        const char* locText = agentGetQuestLocationText(i);
        const char* descText = agentGetQuestDescriptionText(i);
        q["location"] = safeString(locText);
        q["description"] = safeString(descText);
        q["completed"] = (gvarValue >= completedThreshold);
        q["gvar_value"] = gvarValue;
        quests.push_back(q);
    }

    if (!quests.empty())
        state["quests"] = quests;

    // Holodisks
    int holodiskCount = agentGetHolodiskCount();
    if (holodiskCount <= 0)
        return;

    json holodisks = json::array();
    for (int i = 0; i < holodiskCount; i++) {
        int gvar = agentGetHolodiskGvar(i);
        if (gameGetGlobalVar(gvar) != 0) {
            const char* name = agentGetHolodiskName(i);
            json h;
            h["name"] = safeString(name);
            holodisks.push_back(h);
        }
    }

    if (!holodisks.empty())
        state["holodisks"] = holodisks;
}

// --- Gameplay state (dispatches to sub-context writers) ---

static void writeGameplayState(json& state, const char* context)
{
    // Safety: gDude must be valid before accessing any gameplay state
    if (gDude == nullptr) {
        state["error"] = "gDude not initialized";
        return;
    }

    // Game time
    {
        json gt;
        int month, day, year;
        gameTimeGetDate(&month, &day, &year);
        gt["hour"] = gameTimeGetHour();
        gt["month"] = month;
        gt["day"] = day;
        gt["year"] = year;
        gt["time_string"] = safeString(gameTimeGetTimeString());
        gt["ticks"] = gameTimeGetTime();
        state["game_time"] = gt;
    }

    // Difficulty settings
    {
        json s;
        int gd = settings.preferences.game_difficulty;
        int cd = settings.preferences.combat_difficulty;
        s["game_difficulty"] = (gd == GAME_DIFFICULTY_EASY) ? "easy" : (gd == GAME_DIFFICULTY_HARD) ? "hard" : "normal";
        s["combat_difficulty"] = (cd == COMBAT_DIFFICULTY_EASY) ? "easy" : (cd == COMBAT_DIFFICULTY_HARD) ? "hard" : "normal";
        state["settings"] = s;
    }

    // World map is a special context — only character + worldmap + party + messages + quests state
    if (strcmp(context, "gameplay_worldmap") == 0) {
        writeCharacterStats(state);
        writeInventoryState(state);
        writePartyState(state);
        writeMessageLog(state);
        writeQuestState(state);
        writeWorldmapState(state);
        return;
    }

    // Always emit character stats, inventory, party, message log, and quests in any gameplay sub-context
    writeCharacterStats(state);
    writeInventoryState(state);
    writePartyState(state);
    writeMessageLog(state);
    writeQuestState(state);

    // Map and objects for most gameplay sub-contexts
    if (strcmp(context, "gameplay_inventory") != 0
        && strcmp(context, "gameplay_loot") != 0
        && strcmp(context, "gameplay_barter") != 0) {
        writeMapAndObjectState(state);
    }

    // Context-specific additions
    if (strcmp(context, "gameplay_combat") == 0) {
        writeCombatState(state);
    } else if (strcmp(context, "gameplay_dialogue") == 0) {
        writeDialogueState(state);
    } else if (strcmp(context, "gameplay_loot") == 0) {
        writeLootState(state);
    } else if (strcmp(context, "gameplay_barter") == 0) {
        writeBarterState(state);
    }
}

// --- Game mode flag decoder ---

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

// --- Main state writer ---

void writeState()
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
    state["test_mode"] = gAgentTestMode;
    state["mouse"] = { { "x", mouseX }, { "y", mouseY } };
    state["screen"] = { { "width", screenGetWidth() }, { "height", screenGetHeight() } };

    const char* context = detectContext();
    state["context"] = context;

    // Death/game over detection
    if (gDude != nullptr && critterIsDead(gDude)) {
        state["player_dead"] = true;
    }

    if (!gAgentLastCommandDebug.empty()) {
        state["last_command_debug"] = safeString(gAgentLastCommandDebug.c_str());
    }

    // Look-at result (kept for 300 ticks / ~5 seconds so external polling can read it)
    static std::string gLastEmittedLookAt;
    static unsigned int gLookAtResultExpiry = 0;
    if (!gAgentLookAtResult.empty()) {
        // New result or updated result — reset expiry
        if (gAgentLookAtResult != gLastEmittedLookAt) {
            gLastEmittedLookAt = gAgentLookAtResult;
            gLookAtResultExpiry = gAgentTick + 300;
        }
        state["look_at_result"] = safeString(gAgentLookAtResult.c_str());
        if (gAgentTick >= gLookAtResultExpiry) {
            gAgentLookAtResult.clear();
            gLastEmittedLookAt.clear();
            gLookAtResultExpiry = 0;
        }
    }

    if (strcmp(context, "movie") == 0) {
        writeMovieState(state);
    } else if (strcmp(context, "main_menu") == 0) {
        writeMainMenuState(state);
    } else if (strcmp(context, "character_selector") == 0) {
        writeCharSelectorState(state);
    } else if (strcmp(context, "character_editor") == 0) {
        writeCharEditorState(state);
    } else if (strncmp(context, "gameplay_", 9) == 0) {
        writeGameplayState(state, context);
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

} // namespace fallout
