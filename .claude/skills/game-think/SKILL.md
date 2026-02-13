---
name: game-think
description: Log a character decision with persona-driven reasoning. Shows the decision as floating text above the player's head in-game. Use before morally weighted choices, combat/flee decisions, quest approaches, or faction encounters.
allowed-tools: Bash, Read
argument-hint: "[brief description of the decision to think through]"
---

Think through a decision as the character, consulting the persona for guidance.

1. Read the relevant persona sections:
```bash
source scripts/executor.sh
read_persona "Values"
read_persona "Combat Approach"  # or Social Approach, Quest Approach, etc.
```

2. Consider the situation, identify which persona values apply, weigh options, then log:

**For weighty decisions (moral dilemmas, faction choices, quest approaches):**
```bash
think "Title of Decision" \
  "Description of the situation" \
  "- Values: relevant quote from persona
- Values: another relevant quote" \
  "1. Option A — pros/cons
2. Option B — pros/cons
3. Option C — pros/cons" \
  "Reasoning about why one option best fits the character" \
  "The chosen action" \
  "Impact on persona (or 'No immediate persona impact')"
```

**For quick decisions (minor choices, tactical calls):**
```bash
think "Title" "One or two sentences explaining the reasoning and decision."
```

3. If the experience fundamentally shifts the character's values:
```bash
evolve_persona "Title" "What happened" "What changed" "Optional new rule"
```

**For moment-to-moment reflections (no log, just floating text):**
```bash
muse "Hmm, that door looks suspicious. Better check for traps."
muse "Three ants ahead. I can take them."
muse "12 HP... need to be careful."
```

Use `muse` frequently — it's the character's visible inner monologue. Use `think` for major logged decisions. Keep everything narrative and engaging — it's for an audience. Persona evolution should be rare.
