import type { GameState, CharEditorState } from "@fallout2-sdk/core";

export function getSystemPrompt(context: string): string {
    switch (context) {
        case "character_editor":
            return CHARACTER_EDITOR_SYSTEM;
        default:
            return GENERIC_SYSTEM;
    }
}

export function buildPrompt(state: GameState): string {
    switch (state.context) {
        case "character_editor":
            return buildCharEditorPrompt(state as CharEditorState);
        default:
            return JSON.stringify(state, null, 2);
    }
}

function buildCharEditorPrompt(state: CharEditorState): string {
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

const GENERIC_SYSTEM = `You are playing Fallout 2, a post-apocalyptic RPG. You are a tribal warrior on a quest to save your village.

Respond with a JSON object containing "thinking" and "action_groups".
Each action_group has a "narration" and "actions" array.`;
