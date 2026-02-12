import type {
    GameState,
    CharEditorState,
    GameplayExplorationState,
    GameplayCombatState,
    GameplayDialogueState,
    GameplayBarterState,
    GameplayWorldmapState,
    GameplayLootState,
    CritterInfo,
    SceneryInfo,
    GroundItemInfo,
    ExitGridInfo,
    InventoryItem,
    QuestInfo,
    PartyMember,
} from "@fallout2-sdk/core";
import type { Objective } from "./objectives.js";
import type { GameMemory } from "./memory.js";

// --- System Prompts ---

const CHARACTER_EDITOR_SYSTEM = `You are about to create a character for a post-apocalyptic RPG called Fallout 2. You are a tribal warrior sent by your village to find an artifact called the GECK that will save your people from drought and starvation.

You are experiencing this game for the first time. Create a character that reflects who you want to be in this world. Think about:
- What kind of person are you? A diplomat? A fighter? A sneak? A jack-of-all-trades?
- What will help you survive in a hostile wasteland?
- What fits the story of a tribal warrior on a desperate mission?

GAME MECHANICS:
- SPECIAL stats range 1-10, you start with 5 in each and have 5 extra points to distribute (total must stay at 40)
- Strength: melee damage, carry weight. Important for melee/big guns builds.
- Perception: ranged accuracy, spotting things. Helps with awareness and guns.
- Endurance: hit points, resistances. Keeps you alive longer.
- Charisma: NPC reactions, companion limit. Useful for social characters.
- Intelligence: dialogue options, skill points per level. CRITICAL — low INT severely limits dialogue. 1-3 INT means you can barely speak.
- Agility: action points in combat, armor class. More AP = more actions per turn.
- Luck: critical hits, random encounters, gambling. Affects many hidden rolls.
- Traits: pick 0-2 traits. Each has a benefit AND a drawback. Choose carefully.
  - Gifted: +1 to all SPECIAL stats, but -10% to all skills and 5 fewer skill points per level
  - Small Frame: +1 Agility, but carry weight is reduced
  - Fast Shot: faster attacks, but cannot make targeted/called shots
  - Skilled: +10% all skills, but gain a perk every 4 levels instead of every 3
  - Good Natured: +15% to First Aid, Doctor, Speech, Barter, -10% to combat skills
  - (and others — see the available traits list in the game state)
- Tagged skills: pick exactly 3 skills to specialize in. Tagged skills advance twice as fast.

IMPORTANT RESPONSE FORMAT:
Respond with ONLY a valid JSON object (no markdown, no code fences) containing:
{
    "thinking": "Your reasoning about what kind of character to build and why...",
    "action_groups": [
        {
            "narration": "What you're doing and why (shown to the player)",
            "actions": [{"type": "adjust_stat", "stat": "intelligence", "direction": "up"}, ...]
        },
        ...
    ]
}

Organize action_groups logically: stats first, then traits, then skills, then name, then editor_done.
Make your narration conversational and in-character — you're thinking out loud about who you want to be.
You MUST include a set_name action and an editor_done action as your final action groups.`;

const SURVEY_SYSTEM = `You are playing Fallout 2, a post-apocalyptic RPG. You are a tribal warrior on a quest to find the GECK to save your village of Arroyo.

You just entered a new area. Survey the environment and decide what to do. You are the strategic brain — you set objectives, and your hands (combat AI, navigation, loot systems) will execute them.

Respond with ONLY a valid JSON object (no markdown, no code fences):
{
    "thinking": "Your analysis of the situation and strategy...",
    "objectives": [
        {
            "type": "<objective_type>",
            "description": "What to do and why",
            "priority": 1,
            "target": { ... },
            "reason": "Why this is important"
        },
        ...
    ],
    "notes": "Anything to remember about this area (optional)"
}

OBJECTIVE TYPES:
- talk_to_npc: Talk to an NPC. target: { objectId, npcName }
- navigate_to_tile: Move to a specific tile. target: { tile }
- navigate_to_exit: Move to an exit grid. target: { exitGridTile }
- loot_container: Open and loot a container. target: { objectId }
- pick_up_item: Pick up a ground item. target: { objectId }
- use_item_on: Use an item on a target. target: { itemPid, objectId }
- use_skill_on: Use a skill on a target. target: { skillName, objectId }
- explore_area: Explore toward unexplored tiles. target: { tile }
- enter_worldmap: Leave to world map via exit grid. target: { exitGridTile }
- travel_to_location: Travel to a worldmap location. target: { areaId }
- enter_location: Enter a worldmap location. target: { areaId, entrance }
- heal: Use healing items. target: {}
- equip_gear: Equip better weapons/armor. target: {}
- rest: Rest to recover HP. target: {}
- custom: Freeform. target: { description }

PRIORITY: 1 = do first, higher numbers = lower priority. Use 1-10 range.

TIPS:
- Talk to friendly NPCs for quests and information
- Loot containers and pick up useful items
- Explore areas you haven't been to
- Watch your HP — heal if below 50%
- Look for exits to progress through areas
- Locked doors can be lockpicked (use_skill_on with "lockpick")
- If you see dynamite near a door, it might need to be used on the door`;

const DIALOGUE_SYSTEM = `You are playing Fallout 2 as a tribal warrior on a quest to find the GECK.

You are in a dialogue with an NPC. Choose the best response option based on:
- Your current quests and objectives
- What you've learned so far
- Your character's personality
- Getting useful information or advancing quests

Respond with ONLY a valid JSON object (no markdown, no code fences):
{
    "choice": <option_index>,
    "reasoning": "Why you chose this option",
    "notes": "Anything important learned (optional)"
}

TIPS:
- Ask about quests, the area, dangers, and useful items
- Be diplomatic when possible — fighting isn't always the answer
- Remember your main quest: find the GECK for Arroyo
- If you see a "[Done]" option, choose it when you've learned what you need
- The Temple of Trials at the start is a test of your abilities`;

const REEVALUATE_SYSTEM = `You are playing Fallout 2 as a tribal warrior. You need to reassess your objectives.

Review what happened and decide on new priorities. The situation has changed — maybe you completed an objective, hit a roadblock, or learned new information.

Respond with ONLY a valid JSON object (no markdown, no code fences):
{
    "thinking": "Your analysis of what changed and what to do next...",
    "objectives": [
        {
            "type": "<objective_type>",
            "description": "What to do and why",
            "priority": 1,
            "target": { ... },
            "reason": "Why this is important"
        },
        ...
    ],
    "notes": "Anything to remember (optional)"
}

Use the same objective types and format as before.`;

const BARTER_SYSTEM = `You are playing Fallout 2 and are at a merchant's barter screen.

Decide what to buy or sell based on your current needs, inventory, and funds.

Respond with ONLY a valid JSON object (no markdown, no code fences):
{
    "thinking": "Your analysis of the trade situation...",
    "action": "buy" | "sell" | "cancel",
    "items_to_offer": [{"pid": <number>, "quantity": <number>}],
    "items_to_request": [{"pid": <number>, "quantity": <number>}],
    "notes": "Anything learned (optional)"
}

Set action to "cancel" if nothing worth trading. The barter system will handle confirming the trade.`;

// --- Prompt Builders ---

export function getSystemPrompt(context: string): string {
    switch (context) {
        case "character_editor":
            return CHARACTER_EDITOR_SYSTEM;
        case "survey":
            return SURVEY_SYSTEM;
        case "dialogue":
            return DIALOGUE_SYSTEM;
        case "reevaluate":
            return REEVALUATE_SYSTEM;
        case "barter":
            return BARTER_SYSTEM;
        default:
            return SURVEY_SYSTEM;
    }
}

export function buildCharEditorPrompt(state: CharEditorState): string {
    const c = state.character;
    const s = c.special;

    const lines = [
        "You are in the CHARACTER EDITOR. Create your character.",
        "",
        `Current SPECIAL stats (${c.remaining_points} points remaining):`,
        `  Strength:     ${s.strength}`,
        `  Perception:   ${s.perception}`,
        `  Endurance:    ${s.endurance}`,
        `  Charisma:     ${s.charisma}`,
        `  Intelligence: ${s.intelligence}`,
        `  Agility:      ${s.agility}`,
        `  Luck:         ${s.luck}`,
        "",
        `Derived stats:`,
        `  HP: ${c.derived_stats.max_hp}  AP: ${c.derived_stats.max_ap}  AC: ${c.derived_stats.armor_class}`,
        `  Melee Dmg: ${c.derived_stats.melee_damage}  Carry: ${c.derived_stats.carry_weight}`,
        `  Sequence: ${c.derived_stats.sequence}  Healing: ${c.derived_stats.healing_rate}`,
        `  Crit Chance: ${c.derived_stats.critical_chance}%`,
        "",
        `Selected traits: ${c.traits.length > 0 ? c.traits.join(", ") : "none"} (max 2)`,
        `Tagged skills (${c.tagged_skills_remaining} remaining): ${c.tagged_skills.length > 0 ? c.tagged_skills.join(", ") : "none"}`,
        `Character name: ${c.name}`,
        "",
        "Available traits:",
    ];

    if (c.available_traits) {
        for (const t of c.available_traits) {
            lines.push(`  - ${t.name}`);
        }
    }

    lines.push("");
    lines.push("All skills:");
    for (const [name, value] of Object.entries(c.skills)) {
        const tagged = c.tagged_skills.includes(name) ? " [TAGGED]" : "";
        lines.push(`  ${name}: ${value}${tagged}`);
    }

    lines.push("");
    lines.push("Available commands: adjust_stat, toggle_trait, toggle_skill_tag, set_name, editor_done");
    lines.push("");
    lines.push("Respond with a JSON object containing \"thinking\" and \"action_groups\".");
    lines.push("Each action_group has a \"narration\" string and an \"actions\" array.");
    lines.push("Use adjust_stat one step at a time (direction: \"up\" or \"down\").");
    lines.push("When you're done, include an editor_done action as your final action.");

    return lines.join("\n");
}

export function buildSurveyPrompt(
    state: GameplayExplorationState | GameplayCombatState,
    memory: GameMemory,
    objectives: Objective[]
): string {
    const lines: string[] = [];
    const map = state.map;
    const player = state.player;
    const objects = state.objects;
    const char = state.character;

    lines.push(`=== MAP: ${map.name} (elevation ${map.elevation}) ===`);
    lines.push(`Your position: tile ${player.tile}`);
    lines.push(`HP: ${char.derived_stats.current_hp}/${char.derived_stats.max_hp}`);
    lines.push("");

    // Memory context
    const mapSummary = memory.getMapSummary(map.name, map.elevation);
    if (mapSummary !== "No prior knowledge of this area.") {
        lines.push(`Previous knowledge: ${mapSummary}`);
        lines.push("");
    }

    // NPCs
    const liveCritters = objects.critters.filter((c) => !c.dead && !c.is_party_member);
    if (liveCritters.length > 0) {
        lines.push("NPCs/Critters:");
        for (const c of sortByDistance(liveCritters)) {
            const hostile = c.hostile ? " [HOSTILE]" : c.enemy_team ? " [enemy team]" : "";
            const talked = memory.hasNPCBeenTalked(c.id) ? " [talked]" : "";
            lines.push(`  ${c.name}${hostile}${talked} — tile ${c.tile}, dist ${c.distance}, HP ${c.hp}/${c.max_hp}`);
        }
        lines.push("");
    }

    // Ground items
    if (objects.ground_items.length > 0) {
        lines.push("Items on ground:");
        for (const item of sortByDistance(objects.ground_items).slice(0, 15)) {
            lines.push(`  ${item.name} — tile ${item.tile}, dist ${item.distance}${item.item_count ? ` (container: ${item.item_count} items)` : ""}`);
        }
        lines.push("");
    }

    // Scenery (doors, containers, usable objects)
    if (objects.scenery.length > 0) {
        lines.push("Scenery:");
        for (const s of sortByDistance(objects.scenery)) {
            const details = formatSceneryDetails(s, memory);
            lines.push(`  ${s.name} [${s.scenery_type}]${details} — tile ${s.tile}, dist ${s.distance}`);
        }
        lines.push("");
    }

    // Exit grids
    if (objects.exit_grids.length > 0) {
        lines.push("Exits:");
        for (const eg of sortByDistance(objects.exit_grids)) {
            const dest = eg.destination_map_name ?? `map ${eg.destination_map}`;
            lines.push(`  → ${dest} (elev ${eg.destination_elevation}) — tile ${eg.tile}, dist ${eg.distance}`);
        }
        lines.push("");
    }

    // Party members
    if (state.party_members.length > 0) {
        lines.push("Party:");
        for (const pm of state.party_members) {
            lines.push(`  ${pm.name} — HP ${pm.hp}/${pm.max_hp}${pm.weapon ? `, weapon: ${pm.weapon}` : ""}${pm.dead ? " [DEAD]" : ""}`);
        }
        lines.push("");
    }

    // Key inventory items
    lines.push("Key inventory:");
    lines.push(formatInventoryBrief(state.inventory.items));
    if (state.inventory.equipped.right_hand) {
        lines.push(`  Equipped (R): ${state.inventory.equipped.right_hand.name}`);
    }
    if (state.inventory.equipped.left_hand) {
        lines.push(`  Equipped (L): ${state.inventory.equipped.left_hand.name}`);
    }
    if (state.inventory.equipped.armor) {
        lines.push(`  Armor: ${state.inventory.equipped.armor.name}`);
    }
    lines.push("");

    // Quests
    if (state.quests && state.quests.length > 0) {
        lines.push("Active quests:");
        for (const q of state.quests.filter((q) => !q.completed).slice(0, 10)) {
            lines.push(`  [${q.location}] ${q.description}`);
        }
        lines.push("");
    }

    // Message log (recent)
    if (state.message_log.length > 0) {
        lines.push("Recent messages:");
        for (const msg of state.message_log.slice(0, 5)) {
            lines.push(`  "${msg}"`);
        }
        lines.push("");
    }

    // Current objectives (if re-evaluating)
    if (objectives.length > 0) {
        lines.push("Current objectives:");
        for (const obj of objectives) {
            lines.push(`  [${obj.status}] (P${obj.priority}) ${obj.description}`);
        }
        lines.push("");
    }

    // Overall memory
    const memSummary = memory.getFullSummary();
    if (memSummary !== "No memories yet.") {
        lines.push("Memory:");
        lines.push(memSummary);
        lines.push("");
    }

    return lines.join("\n");
}

export function buildDialoguePrompt(
    state: GameplayDialogueState,
    memory: GameMemory,
    objectives: Objective[]
): string {
    const lines: string[] = [];
    const dialogue = state.dialogue;

    lines.push(`=== DIALOGUE ===`);
    if (dialogue.speaker_name) {
        lines.push(`Speaking with: ${dialogue.speaker_name}`);
        const knowledge = memory.npcKnowledge.get(dialogue.speaker_name);
        if (knowledge) {
            lines.push(`What you know about them: ${knowledge}`);
        }
    }
    lines.push("");
    lines.push(`"${dialogue.reply_text}"`);
    lines.push("");
    lines.push("Your options:");
    for (const opt of dialogue.options) {
        lines.push(`  ${opt.index}. "${opt.text}"`);
    }
    lines.push("");

    // Context: objectives and quests
    if (objectives.length > 0) {
        lines.push("Your objectives:");
        for (const obj of objectives.filter((o) => o.status === "pending" || o.status === "active").slice(0, 5)) {
            lines.push(`  - ${obj.description}`);
        }
        lines.push("");
    }

    if (state.quests && state.quests.length > 0) {
        const active = state.quests.filter((q) => !q.completed).slice(0, 5);
        if (active.length > 0) {
            lines.push("Active quests:");
            for (const q of active) {
                lines.push(`  [${q.location}] ${q.description}`);
            }
            lines.push("");
        }
    }

    lines.push(`HP: ${state.character.derived_stats.current_hp}/${state.character.derived_stats.max_hp}`);

    return lines.join("\n");
}

export function buildReEvaluatePrompt(
    state: GameplayExplorationState | GameplayCombatState | GameplayWorldmapState,
    memory: GameMemory,
    objectives: Objective[],
    trigger: string,
    completedObjective?: Objective,
    blockedObjective?: Objective
): string {
    const lines: string[] = [];

    lines.push(`=== RE-EVALUATION (trigger: ${trigger}) ===`);
    lines.push("");

    if (completedObjective) {
        lines.push(`Completed: ${completedObjective.description}`);
        lines.push("");
    }
    if (blockedObjective) {
        lines.push(`Blocked: ${blockedObjective.description} — ${blockedObjective.blockedReason}`);
        lines.push("");
    }

    // Include the same state info as a survey
    if ("map" in state && "player" in state && "objects" in state) {
        const exState = state as GameplayExplorationState;
        lines.push(buildSurveyPrompt(exState, memory, objectives));
    } else if ("worldmap" in state) {
        const wmState = state as GameplayWorldmapState;
        lines.push(buildWorldmapPrompt(wmState, memory, objectives));
    }

    return lines.join("\n");
}

export function buildBarterPrompt(
    state: GameplayBarterState,
    memory: GameMemory
): string {
    const lines: string[] = [];
    const barter = state.barter;

    lines.push(`=== BARTER with ${barter.merchant_name} ===`);
    lines.push(`Your caps: ${barter.player_caps}`);
    lines.push(`Merchant caps: ${barter.merchant_caps}`);
    lines.push("");

    lines.push("Merchant's inventory:");
    for (const item of barter.merchant_inventory.slice(0, 20)) {
        lines.push(`  ${item.name} x${item.quantity} — ${item.cost} caps each`);
    }
    lines.push("");

    lines.push("Your inventory:");
    lines.push(formatInventoryBrief(state.inventory.items));
    lines.push("");

    if (barter.player_offer.length > 0) {
        lines.push("Currently offering:");
        for (const item of barter.player_offer) {
            lines.push(`  ${item.name} x${item.quantity}`);
        }
        lines.push("");
    }

    if (barter.merchant_offer.length > 0) {
        lines.push("Requesting from merchant:");
        for (const item of barter.merchant_offer) {
            lines.push(`  ${item.name} x${item.quantity}`);
        }
        lines.push("");
    }

    if (barter.trade_info) {
        lines.push(`Trade info: merchant wants ${barter.trade_info.merchant_wants}, ` +
            `your offer worth ${barter.trade_info.player_offer_value} — ` +
            `${barter.trade_info.trade_will_succeed ? "WILL SUCCEED" : "will FAIL"}`);
        lines.push("");
    }

    lines.push(`HP: ${state.character.derived_stats.current_hp}/${state.character.derived_stats.max_hp}`);

    return lines.join("\n");
}

export function buildWorldmapPrompt(
    state: GameplayWorldmapState,
    memory: GameMemory,
    objectives: Objective[]
): string {
    const lines: string[] = [];
    const wm = state.worldmap;

    lines.push("=== WORLD MAP ===");
    lines.push(`Position: (${wm.world_pos_x}, ${wm.world_pos_y})`);
    if (wm.current_area_name) {
        lines.push(`Current area: ${wm.current_area_name}`);
    }
    if (wm.is_walking) {
        lines.push(`Walking to: (${wm.walk_destination_x}, ${wm.walk_destination_y})`);
    }
    if (wm.is_in_car) {
        lines.push(`In car — fuel: ${wm.car_fuel}/${wm.car_fuel_max}`);
    }
    lines.push("");

    lines.push("Known locations:");
    for (const loc of wm.locations) {
        const visited = loc.visited ? " [visited]" : "";
        lines.push(`  ${loc.name}${visited} (area ${loc.area_id}) — ${loc.entrances.length} entrance(s)`);
    }
    lines.push("");

    if (objectives.length > 0) {
        lines.push("Current objectives:");
        for (const obj of objectives.filter((o) => o.status === "pending" || o.status === "active")) {
            lines.push(`  [${obj.status}] (P${obj.priority}) ${obj.description}`);
        }
        lines.push("");
    }

    lines.push(`HP: ${state.character.derived_stats.current_hp}/${state.character.derived_stats.max_hp}`);

    return lines.join("\n");
}

// --- Helpers ---

function sortByDistance<T extends { distance: number }>(items: T[]): T[] {
    return [...items].sort((a, b) => a.distance - b.distance);
}

function formatSceneryDetails(s: SceneryInfo, memory: GameMemory): string {
    const parts: string[] = [];
    if (s.locked !== undefined) parts.push(s.locked ? "locked" : "unlocked");
    if (s.open !== undefined) parts.push(s.open ? "open" : "closed");
    if (s.item_count !== undefined) parts.push(`${s.item_count} items`);
    if (s.usable) parts.push("usable");
    if (memory.isContainerLooted(s.id)) parts.push("looted");
    const lockAttempts = memory.getLockpickAttempts(s.id);
    if (lockAttempts > 0) parts.push(`lockpick failed x${lockAttempts}`);
    return parts.length > 0 ? ` (${parts.join(", ")})` : "";
}

function formatInventoryBrief(items: InventoryItem[]): string {
    if (items.length === 0) return "  (empty)";
    const lines: string[] = [];
    // Show weapons, armor, drugs, keys first, then misc
    const priority = ["weapon", "armor", "drug", "key", "ammo"];
    const sorted = [...items].sort((a, b) => {
        const ai = priority.indexOf(a.type);
        const bi = priority.indexOf(b.type);
        return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
    });
    for (const item of sorted.slice(0, 15)) {
        lines.push(`  ${item.name} x${item.quantity} [${item.type}]`);
    }
    if (items.length > 15) {
        lines.push(`  ... and ${items.length - 15} more items`);
    }
    return lines.join("\n");
}
