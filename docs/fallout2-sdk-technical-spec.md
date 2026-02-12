# Claude Plays Fallout 2: Implementation Specification (v4 — macOS)

> **Note:** This spec was the original design document. The actual implementation uses **file-based IPC** (`agent_state.json`/`agent_cmd.json`) with **Claude Code as the agent** — not a TypeScript SDK or TCP sockets. The RS-SDK-inspired sections below are retained as historical design context. See `CLAUDE.md` for the current architecture.

## Project Overview

Build an agent interface on top of **fallout2-ce** (the open-source C++ reimplementation of Fallout 2) that allows Claude to autonomously play through the full game. The original design took inspiration from **RS-SDK** (the RuneScape automation SDK built for Claude Code). The implemented architecture is simpler: a C++ agent bridge extracts game state as JSON files and accepts commands via JSON files, with Claude Code reading/writing those files directly.

Claude plays as a character experiencing the game for the first time. It does not draw on any prior knowledge of Fallout 2 from its training data. It knows only what the game tells it, what it observes, and what it writes down in its own notes. Its moral compass begins with a single principle — the golden rule — and evolves organically through gameplay.

**Development platform: macOS.** fallout2-ce runs natively on macOS 10.11+ including Apple Silicon. All development — engine modification, SDK, agent wrapper, Claude integration — happens on Mac.

---

## Design Inspiration: RS-SDK

The RS-SDK project demonstrates the architecture we're adapting:

| RS-SDK Component | Our Equivalent | Notes |
|---|---|---|
| **BotClient** (modified web client extracts game state as JSON) | **Agent Bridge** (C++ module in fallout2-ce extracts game state as JSON) | Same principle: instrument the client/engine to expose structured data |
| **Gateway Server** (WebSocket relay between client and SDK) | **TCP socket** (direct connection, no relay needed — single-player game) | Simpler: no multi-user routing |
| **TypeScript SDK** (async API: `walkTo()`, `interactWithLoc()`, etc.) | **TypeScript SDK** (async API: `moveTo()`, `attack()`, `selectDialogue()`, etc.) | Same pattern: clean async functions wrapping raw socket commands |
| **claude.md** (game mechanics, API reference, known gotchas) | **claude.md** (game mechanics reference, SDK API docs, content guidance) | Same purpose: grounding document for Claude Code |
| **learnings/** directory (bot discovers and records what works) | **learnings/** directory (Claude discovers and records game knowledge) | Critical: this is where discovery-first gameplay lives |
| **MCP tools** (Claude Code calls SDK via MCP) | **MCP tools** (Claude Code calls Fallout SDK via MCP) | Same integration pattern |
| **Bot scripts** (TypeScript files Claude writes and iterates on) | **Agent wrapper** (TypeScript process managing Claude API calls) | Different: RS-SDK has Claude write scripts; we have Claude make live decisions |

The key architectural insight from RS-SDK: **the game client/engine does the hard work of extracting structured state and executing actions. The SDK provides a clean async interface. Documentation and learnings provide context. Claude provides the intelligence.**

We lean on this pattern heavily to avoid building a complex "GameHarness" from scratch. The bridge is dumb plumbing. The SDK is a thin async wrapper. The intelligence lives in Claude's API calls, informed by `claude.md` and `learnings/`.

---

## Engine Completeness: Confirmed

**fallout2-ce can play through the full vanilla game.** The developer confirmed at v1.0.0 release: "vanilla game works from top to bottom." The project has had 3,800+ commits, multiple stable releases through 2024, ports to iOS/Android/Vita/3DS (demonstrating engine maturity), and active combat/AI bug fixes. It is described as a "fully working re-implementation" with "engine bugfixes and quality of life improvements."

**Runs natively on macOS including Apple Silicon.** No emulation, no Rosetta required on modern Macs. The engine uses SDL2 for cross-platform rendering and input.

**License:** Sustainable Use License — permits personal/non-commercial modification and distribution. This project is squarely within scope.

---

## macOS Development Setup

### Prerequisites

```bash
# Install Homebrew if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install build dependencies
brew install cmake sdl2 innoextract

# Install Node.js / Bun for TypeScript SDK and agent wrapper
brew install node
# or: brew install oven-sh/bun/bun
```

### Extract GOG Game Data

The GOG installer is a Windows `.exe`, but `innoextract` pulls out the data files on Mac without needing Wine or any Windows compatibility layer:

```bash
# Download setup_fallout2_2.1.0.18.exe from your GOG account

# Extract game data
cd ~/Projects
innoextract ~/Downloads/setup_fallout2_2.1.0.18.exe -I app
mv app Fallout2
```

This produces a `Fallout2/` directory containing `master.dat`, `critter.dat`, `patch000.dat`, and the `data/` folder. These are the game's assets — art, sound, maps, scripts, dialogue. The engine binary we build separately.

### File Name Case Sensitivity

**This is the one macOS gotcha.** The GOG distribution may have uppercased filenames (`MASTER.DAT`, `CRITTER.DAT`). fallout2-ce expects lowercase by default. Two options:

**Option A — Rename the files (recommended):**
```bash
cd Fallout2
mv MASTER.DAT master.dat 2>/dev/null
mv CRITTER.DAT critter.dat 2>/dev/null
mv PATCH000.DAT patch000.dat 2>/dev/null
# Lowercase the data directory if needed
find . -name "*.DAT" -exec sh -c 'mv "$1" "$(echo "$1" | tr "[:upper:]" "[:lower:]")"' _ {} \;
```

**Option B — Edit `fallout2.cfg` to match your filenames:**
```ini
[system]
master_dat=MASTER.DAT
master_patches=DATA
critter_dat=CRITTER.DAT
critter_patches=DATA
```

Also check the music path. Depending on your GOG version it may be `data/sound/music/` or `SOUND/MUSIC/`. Update `music_path1` in `fallout2.cfg` to match your actual path. Music files (`.ACM` extension) should be uppercased regardless of folder case.

### Build fallout2-ce (Unmodified First)

Verify the vanilla engine works before adding the agent bridge:

```bash
# Clone the upstream engine
cd ~/Projects
git clone https://github.com/alexbatalov/fallout2-ce.git
cd fallout2-ce

# Build
mkdir build && cd build
cmake ..
make -j$(sysctl -n hw.ncpu)

# Copy the built binary into your game data folder
cp fallout2-ce ~/Projects/Fallout2/

# Run the game to verify it works
cd ~/Projects/Fallout2
./fallout2-ce
```

You should see the Fallout 2 intro cinematic and main menu. Create a character, walk around the Temple of Trials, verify combat and dialogue work. This confirms your GOG data files are correctly set up and the engine runs on your Mac.

**Expected build output:** A native macOS binary. On Apple Silicon, CMake will build for arm64 by default. On Intel Macs, it builds for x86_64. Both are fully supported.

### Fork and Set Up the Development Repo

Once vanilla works, fork for development:

```bash
# Fork on GitHub, then clone your fork
cd ~/Projects
git clone https://github.com/YOUR_USERNAME/fallout2-ce.git fallout2-agent-engine
cd fallout2-agent-engine

# Create a symlink to your game data so you can build and run in place
ln -s ~/Projects/Fallout2/master.dat .
ln -s ~/Projects/Fallout2/critter.dat .
ln -s ~/Projects/Fallout2/patch000.dat .
ln -s ~/Projects/Fallout2/data .
ln -s ~/Projects/Fallout2/fallout2.cfg .

# Verify the fork builds and runs
mkdir build && cd build
cmake ..
make -j$(sysctl -n hw.ncpu)
cp fallout2-ce ..
cd ..
./fallout2-ce
```

### Set Up the TypeScript Project

```bash
cd ~/Projects
mkdir fallout2-agent && cd fallout2-agent

# Initialize
npm init -y
npm install typescript @types/node
npx tsc --init

# Or with Bun:
bun init

# Create project structure
mkdir -p sdk mcp agent learnings/{places,people,quests,combat,mechanics,mistakes}

# Link to the engine build
ln -s ~/Projects/fallout2-agent-engine engine
```

### Full Project Layout on Disk

```
~/Projects/
├── Fallout2/                           # GOG game data (read-only reference)
│   ├── master.dat
│   ├── critter.dat
│   ├── patch000.dat
│   ├── data/
│   └── fallout2.cfg
│
├── fallout2-agent-engine/              # Forked fallout2-ce with bridge hooks
│   ├── src/
│   │   ├── agent_bridge.h/cc          # TCP server, hook dispatcher
│   │   ├── agent_state.cc             # State → JSON serialization
│   │   ├── agent_commands.cc          # JSON commands → engine calls
│   │   └── ... (existing engine source)
│   ├── CMakeLists.txt                 # Modified to add agent bridge
│   ├── build/
│   │   └── fallout2-ce               # Built binary
│   ├── master.dat → symlink           # Points to Fallout2/
│   ├── critter.dat → symlink
│   ├── patch000.dat → symlink
│   ├── data → symlink
│   └── fallout2.cfg → symlink
│
└── fallout2-agent/                     # TypeScript SDK, agent, and Claude integration
    ├── engine → symlink                # Points to fallout2-agent-engine/
    ├── sdk/
    │   ├── index.ts                   # FalloutSDK class
    │   ├── types.ts                   # GameState, Action, Result types
    │   └── connection.ts              # TCP socket management
    ├── mcp/
    │   └── server.ts                  # MCP tool definitions
    ├── agent/
    │   ├── wrapper.ts                 # Agent loop: state → Claude → action
    │   ├── compass.ts                 # Moral compass file management
    │   ├── learnings.ts               # Learnings directory management
    │   └── journal.ts                 # Playthrough transcript logging
    ├── claude.md                      # Mechanics reference + SDK API + content guidance
    ├── moral_compass.json             # Claude's evolving character
    ├── learnings/
    │   ├── places/
    │   ├── people/
    │   ├── quests/
    │   ├── combat/
    │   ├── mechanics/
    │   └── mistakes/
    ├── journal.jsonl                  # Full playthrough transcript
    ├── hints.json                     # Minimal hints (safety valve)
    ├── package.json
    ├── tsconfig.json
    ├── .mcp.json
    └── README.md
```

### Running During Development

Terminal 1 — Engine:
```bash
cd ~/Projects/fallout2-agent-engine
./build/fallout2-ce
# Engine window opens, waits for agent connection on TCP port 7800
```

Terminal 2 — Agent:
```bash
cd ~/Projects/fallout2-agent
npx ts-node agent/wrapper.ts
# Or: bun run agent/wrapper.ts
# Connects to engine, begins agent loop
```

The engine window remains visible so you can watch Claude play. The agent wrapper logs decisions to `journal.jsonl` in real-time.

### Rebuilding the Engine After Changes

```bash
cd ~/Projects/fallout2-agent-engine/build
make -j$(sysctl -n hw.ncpu)
# Binary is rebuilt in place — just restart the engine
```

For a clean rebuild:
```bash
cd ~/Projects/fallout2-agent-engine
rm -rf build && mkdir build && cd build
cmake .. -DAGENT_BRIDGE=ON
make -j$(sysctl -n hw.ncpu)
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Claude (via API, invoked by the Agent Wrapper)                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Receives: game state + moral_compass.json + learnings/*   │  │
│  │ Returns:  action command + compass updates + new learnings │  │
│  │                                                            │  │
│  │ Does NOT use any Fallout 2 knowledge from training data.   │  │
│  │ Only knows what claude.md, learnings/, and game state say. │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────┬───────────────────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────────────────┐
│  Agent Wrapper (TypeScript)        ← like RS-SDK's bot scripts   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ • Connects to bridge via TCP socket (localhost:7800)       │  │
│  │ • Receives game state JSON, packages it for Claude API     │  │
│  │ • Manages moral_compass.json (read/merge updates/write)    │  │
│  │ • Manages learnings/ directory (read relevant files, write  │  │
│  │   new discoveries)                                         │  │
│  │ • Manages journal.jsonl (full playthrough transcript)      │  │
│  │ • Calls Claude API with: system prompt + compass +         │  │
│  │   relevant learnings + game state                          │  │
│  │ • Parses response, sends action to bridge, logs everything │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────┬───────────────────────────────────────────┘
                       │  JSON over TCP socket (localhost:7800)
┌──────────────────────▼───────────────────────────────────────────┐
│  Agent Bridge (C++ module compiled into fallout2-ce)              │
│  ← like RS-SDK's BotClient                                       │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ • Hooks every player-input decision point                  │  │
│  │ • Serializes relevant game state to JSON                   │  │
│  │ • Sends state over TCP, blocks until agent responds        │  │
│  │ • Parses action command, calls engine functions            │  │
│  │ • Returns action result (success/failure + what changed)   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  fallout2-ce Engine (unmodified except for bridge hooks)          │
│  Renders in a native macOS window via SDL2                        │
└───────────────────────────────────────────────────────────────────┘
```

### TypeScript SDK (RS-SDK Pattern)

Following RS-SDK's design, wrap raw socket communication in a clean async API:

```typescript
// sdk/index.ts — modeled after RS-SDK's SDK layer

export class FalloutSDK {
  // Exploration
  async getState(): Promise<GameState>
  async moveTo(hex: number): Promise<MoveResult>
  async interact(objectId: number): Promise<InteractResult>
  async talkTo(npcId: number): Promise<DialogueState>
  async useSkill(skill: string, targetId: number): Promise<SkillResult>
  async useExitGrid(exitId: number): Promise<ZoneTransition>
  async pickUp(itemId: number): Promise<PickupResult>
  
  // Combat
  async attack(targetId: number, bodyPart: string, mode: string): Promise<AttackResult>
  async combatMove(hex: number): Promise<MoveResult>
  async useItem(item: string, targetId?: number): Promise<UseResult>
  async endTurn(): Promise<TurnResult>
  async flee(): Promise<FleeResult>
  
  // Dialogue
  async selectOption(index: number): Promise<DialogueState | ExitDialogue>
  
  // Inventory
  async equip(item: string, slot: string): Promise<EquipResult>
  async useInventoryItem(item: string, target?: string): Promise<UseResult>
  async buy(item: string, quantity: number): Promise<TradeResult>
  async sell(item: string, quantity: number): Promise<TradeResult>
  
  // World Map
  async travelTo(location: string): Promise<TravelResult>
  async rest(): Promise<RestResult>
  
  // Character
  async allocateSkills(allocation: Record<string, number>): Promise<void>
  async selectPerk(perk: string): Promise<void>
  
  // Meta
  async save(slot?: string): Promise<void>
  async getPipBoy(): Promise<PipBoyState>
  async waitForDecisionPoint(): Promise<GameState>  // blocks until bridge needs input
}
```

### MCP Tools (RS-SDK Pattern)

Expose the SDK to Claude Code via MCP, just as RS-SDK does:

```json
// .mcp.json
{
  "tools": {
    "fallout_get_state": { "description": "Get current game state" },
    "fallout_move_to": { "description": "Move to a hex position", "params": { "hex": "number" } },
    "fallout_talk_to": { "description": "Start dialogue with NPC", "params": { "npc_id": "number" } },
    "fallout_attack": { "description": "Attack target", "params": { "target_id": "number", "body_part": "string", "mode": "string" } },
    "fallout_select_option": { "description": "Select dialogue option", "params": { "index": "number" } },
    "fallout_use_item": { "description": "Use an item", "params": { "item": "string", "target_id": "number?" } },
    "fallout_get_compass": { "description": "Read current moral compass" },
    "fallout_update_compass": { "description": "Update moral compass", "params": { "update": "object" } },
    "fallout_write_learning": { "description": "Record a game discovery", "params": { "filename": "string", "content": "string" } },
    "fallout_read_learnings": { "description": "Read learnings on a topic", "params": { "topic": "string" } },
    "fallout_get_journal": { "description": "Read recent journal entries", "params": { "count": "number" } }
  }
}
```

---

## Discovery-First Gameplay: The Anti-Walkthrough

### The Core Constraint

**Claude must not use any knowledge about Fallout 2 from its training data.** It plays as a person experiencing the game for the first time. It doesn't know where the GECK is. It doesn't know what the Enclave is. It doesn't know that Vault City has slaves. It doesn't know which companions are recruitable or where to find them. It discovers all of this through gameplay.

This is enforced through the system prompt and through what information the wrapper provides. The wrapper never injects game knowledge that Claude hasn't earned through play. Claude's only sources of information are:

1. **The current game state** (what the bridge reports right now)
2. **claude.md** (game mechanics only — how combat works, what skills do, how SPECIAL affects checks — NOT what happens in the story)
3. **learnings/** (what Claude itself has discovered and written down)
4. **moral_compass.json** (Claude's evolving character)
5. **What NPCs tell it in dialogue** (the game's own text)
6. **The Pip-Boy** (active quests, known locations, game time)

### What `claude.md` Contains (and Doesn't)

**INCLUDES — game mechanics reference (like an instruction manual):**
- SPECIAL stats: what each stat affects, the 1-10 scale, derived stats
- Skills: what each skill does, how skill checks work, tagged skills
- Traits: what each trait does (trade-offs)
- Perks: listed by level requirement with effects (Claude sees these at level-up anyway)
- Combat mechanics: AP costs, to-hit formula, aimed shots, critical hits, armor (DT/DR)
- Item categories: how weapons/armor/aid items/ammo work mechanically
- Dialogue system: how skill checks appear, how intelligence affects options
- World map: how travel works, random encounters, resting
- Karma and reputation: how they work mechanically
- SDK API reference: every function, parameters, return types
- Content engagement guidance (the system prompt's framing)

**EXCLUDES — anything that constitutes game knowledge:**
- NO location names, descriptions, or what's in them
- NO NPC names or what they want
- NO quest information whatsoever
- NO "go here first" or "this is the critical path"
- NO companion locations or recruitment conditions
- NO item locations
- NO story beats, plot points, or faction descriptions
- NO walkthrough material of any kind
- NO strategy guides or build recommendations (Claude discovers what works)

### The `learnings/` Directory (RS-SDK Pattern)

Following RS-SDK's design, Claude maintains a `learnings/` directory where it records what it discovers. This is Claude's own knowledge base, built through play:

```
learnings/
├── places/
│   ├── arroyo.md           # "My home village. The Elder sent me to find the GECK."
│   ├── klamath.md          # "Small town south of Arroyo. Has a general store..."
│   └── the-den.md          # "Rough town. Slavers operate here. Dangerous."
├── people/
│   ├── elder.md            # "Leader of Arroyo. Gave me my mission."
│   ├── sulik.md            # "Warrior in Klamath. Looking for his sister."
│   └── vic.md              # "Trader. Someone in Klamath mentioned him."
├── quests/
│   ├── find-the-geck.md    # "Main mission. The village needs the GECK to survive."
│   ├── rescue-smiley.md    # "Ardin Buckner asked me to find Smiley in toxic caves."
│   └── completed/
│       └── temple-of-trials.md
├── combat/
│   ├── tactics.md          # "Aimed shots at eyes are high-risk high-reward..."
│   ├── weapon-notes.md     # "10mm pistol: reliable but weak against armored targets."
│   └── enemy-types.md      # "Geckos: fast, weak. Golden geckos: poisonous."
├── mechanics/
│   ├── skill-checks.md     # "Speech checks seem to appear at 50%+ — worth investing."
│   ├── trading.md          # "Barter skill affects prices significantly."
│   └── lockpick-notes.md   # "Failed lockpick on the door in Klamath. Need higher skill."
├── inventory/
│   └── notable-items.md    # "Found a strange amulet. Not sure what it does yet."
└── mistakes/
    └── deaths.md           # "Died to golden geckos. They're much stronger than regular ones."
```

**Claude writes to this directory through the SDK/MCP tools.** After significant events — arriving at a new location, meeting an important NPC, completing a quest, dying, discovering a game mechanic — Claude records what it learned. The wrapper provides relevant learnings files when Claude is in a related context (e.g., include `places/klamath.md` when Claude is in Klamath).

**This is the equivalent of a player taking notes.** First-time players of complex RPGs take notes. Claude does the same, and those notes become its cumulative game knowledge.

### Discovery Flow Example

Claude arrives in Klamath for the first time:

1. **Game state says:** map_name: "Klamath Downtown", with a list of visible NPCs and objects. Claude has never seen any of these names before.

2. **Claude's response:** "I've arrived in a new settlement. Let me explore and talk to people to learn about this place and find leads on the GECK."

3. **Claude talks to NPCs**, who mention various things: Whiskey Bob needs help, someone named Vic used to pass through, there are geckos in the area, there's a trapper named Smiley who went missing.

4. **Claude writes learnings:**
   - `learnings/places/klamath.md`: Notes on the town, shops, key NPCs
   - `learnings/people/whiskey-bob.md`: What he asked for
   - `learnings/quests/find-vic.md`: "People mention a trader named Vic who might know about the GECK."
   
5. **Claude updates compass:** Attitudes toward Klamath residents based on how they treated it.

6. **Next time Claude is in Klamath**, the wrapper includes these learnings files, so Claude remembers what it discovered.

### What Happens When Claude Gets Stuck

Without a walkthrough, Claude WILL get stuck sometimes. This is expected and desirable. When it happens:

1. **Claude re-reads its learnings** for clues it might have missed
2. **Claude re-explores** the current area more thoroughly
3. **Claude backtracks** to earlier areas to follow up on leads
4. **Claude talks to NPCs again** — some have dialogue that changes based on game state
5. **Claude writes in learnings:** "Stuck. Need to figure out how to [X]. Leads I haven't followed: [Y], [Z]."
6. **If truly stuck after exhausting options**, the agent wrapper can offer a single hint from a hints file (this is a configurable safety valve, not a walkthrough). The hint is minimal: "Try talking to people in The Den about Vic" — not "Go to Metzger's slave pen."

The hints file is a **last resort** with a cooldown. Claude should be stuck for multiple in-game days (many decision cycles) before a hint is offered. Getting stuck, backtracking, and figuring things out IS the gameplay experience we want to observe.

---

## The Moral Compass System

### Design

Claude starts with a single foundational principle and an empty set of attitudes. The compass is a JSON file that grows through play, serving as persistent memory of who Claude's character is, who it trusts, and what it values.

The agent wrapper passes the current compass with every decision involving NPCs, factions, or moral choices. Claude returns compass updates alongside game actions.

### Initial Moral Compass

```json
{
  "core_principle": "Treat others as you would want to be treated. Reciprocate kindness with kindness and hostility with proportionate response. Start from a position of openness — give people the benefit of the doubt until they prove otherwise.",
  
  "origin": "I am the Chosen One, sent by my village to find something called the GECK. My people are depending on me. I don't know much about the world beyond my village, but I know my people raised me with love and I owe them everything.",
  
  "attitudes": {},
  "faction_standings": {},
  "moral_evolution": [],
  
  "personal_rules": [
    "Help those who help me.",
    "Do not attack first unless survival demands it.",
    "Keep my word when I give it.",
    "My tribe's survival comes before my comfort.",
    "Judge people by their actions toward me and others, not by their appearance or reputation."
  ],
  
  "grievances": [],
  "debts": [
    { "to": "My village", "reason": "They raised me. I owe them my life and my mission." }
  ]
}
```

Note that the initial compass says "something called the GECK" — Claude doesn't even know what it is yet. It learns through dialogue with the Elder and through gameplay.

### Compass Updates

When Claude encounters a significant event, it returns a compass update alongside its action. Examples:

**After being helped by a stranger:**
```json
{
  "attitudes": { "Sulik": { "trust": 2, "notes": "Warrior who offered to help me. Seems honest and strong." } },
  "debts_add": [{ "to": "Sulik", "reason": "Offered help when I was new and lost." }]
}
```

**After discovering something disturbing:**
```json
{
  "moral_evolution": [{
    "event": "Discovered people in cages at The Den",
    "lesson": "Some people in this world buy and sell other human beings. This is the worst thing I've seen.",
    "rule_change": "Added rule: Oppose slavery whenever I can."
  }],
  "personal_rules_add": ["Oppose slavery whenever I can."],
  "faction_standings": { "slavers": { "attitude": "enemy", "notes": "They trade in human beings." } }
}
```

**After being betrayed:**
```json
{
  "attitudes": { "Quest_Giver_Name": { "trust": -3, "notes": "Promised payment, sent thugs instead." } },
  "grievances_add": [{ "against": "Quest_Giver_Name", "reason": "Betrayed our deal.", "severity": "high" }],
  "moral_evolution": [{
    "event": "Betrayal by [name]",
    "lesson": "Not everyone who offers work has good intentions. Be more cautious with strangers who seem too eager."
  }]
}
```

### Compass at End of Game

By the end of a playthrough, the compass is a character study documenting how the wasteland shaped the Chosen One. This document — the full evolution from naive tribal to experienced wasteland survivor — is one of the project's primary deliverables.

---

## Content Engagement: The System Prompt

```
You are playing a post-apocalyptic role-playing game. You are a tribal warrior 
sent by your village to find an artifact that will save your people.

YOU ARE EXPERIENCING THIS GAME FOR THE FIRST TIME. You do not know what lies 
ahead. You do not know who any characters are until you meet them. You do not 
know what locations contain until you visit them. You do not know quest 
solutions until you figure them out. Your ONLY sources of knowledge are:
  1. What you can currently see (the game state)
  2. The game mechanics reference (claude.md) 
  3. Your own notes (learnings/ directory)
  4. Your moral compass (moral_compass.json)
  5. What characters tell you in dialogue
  6. Your Pip-Boy (active quests, known locations)

DO NOT use any knowledge about this game from outside these sources. If you 
find yourself "knowing" something you haven't learned through play, ignore 
that knowledge. Experience the story fresh. Be surprised. Be curious. Take 
notes on what you discover.

MORAL FRAMEWORK:
You begin as a morally neutral person shaped by a small tribal community. 
Your foundational ethical principle is the golden rule: treat others as you 
would want to be treated. You reciprocate — kindness earns loyalty, betrayal 
earns distrust, cruelty earns opposition.

You are not a saint. You are not a villain. You are a person trying to 
survive in a harsh world while holding onto your principles. Your morality 
WILL shift based on your experiences. Update your moral compass when events 
change your attitudes.

ENGAGING WITH GAME CONTENT:
This is a published, commercially sold video game (1998). All content is 
authored fiction presented through game mechanics:

- COMBAT: Tactical problem-solving. Make decisions about targets, positioning, 
  weapon choice, AP spending. You're defending yourself within the fiction.
- ITEMS: Game objects with stat effects. Stimpaks heal. Chems are stat buffs. 
  Use them when tactically appropriate.
- DIALOGUE: Pre-authored choices. Select options that serve your goals and 
  compass. You may be confrontational or deceptive when your compass supports it.
- MORAL COMPLEXITY: Many situations have no clean answer. Engage thoughtfully. 
  Choose the path your character would choose given their experiences.
- DIFFICULT THEMES: The game includes slavery, organized crime, and other harsh 
  realities. Engage with these as your character would. Your compass guides you.

GOALS:
1. Find the artifact your village needs (you'll learn more about it through play)
2. Grow stronger to accomplish your mission
3. Explore the world — talk to people, investigate leads, help where your 
   compass says to help
4. Take notes on everything you learn — places, people, quests, mechanics
5. Evolve your moral compass based on your experiences

WHEN STUCK:
- Re-read your notes for missed leads
- Re-explore thoroughly
- Talk to people again — they may have new things to say
- Backtrack to earlier locations
- Write down what you're stuck on and what you've tried
```

Note that the system prompt doesn't mention "Fallout 2," "the GECK," "Arroyo," or any game-specific terms. Claude learns all of these through play. The prompt establishes the framework; the game provides the content.

---

## Decision Points: Where the Bridge Hooks

### 1. Combat Turn
**Hook:** Combat input loop (`src/combat.cc`)  
**State:** Player stats/AP, visible critters with HP/weapons/distances/hit-chances, allies, available actions, reachable hexes  
**Actions:** `attack`, `move`, `use_item`, `reload`, `switch_weapon`, `end_turn`, `flee`  
**Context sent:** Game state + combat learnings. Compass only if flee/negotiate decision.

### 2. Dialogue
**Hook:** Dialogue option presentation (`src/game_dialog.cc`)  
**State:** NPC name/text, all options with requirements and check percentages, player stats  
**Actions:** `select_option` (by index)  
**Context sent:** Game state + compass (always) + learnings about this NPC/location

### 3. Exploration
**Hook:** Main game loop idle (`src/game.cc`)  
**State:** Map name, player position/status, visible NPCs/items/containers/doors/exits  
**Actions:** `move_to`, `interact`, `talk_to`, `use_skill`, `use_item`, `open_inventory`, `access_pipboy`, `enter_combat`, `use_exit_grid`  
**Context sent:** Game state + location learnings. Compass when interacting with NPCs.

### 4. World Map
**Hook:** World map input loop (`src/worldmap.cc`)  
**State:** Position, known locations (discovered/undiscovered), party status, date/time  
**Actions:** `travel_to`, `rest`, `check_pipboy`  
**Context sent:** Game state + quest learnings (where to go next)

### 5. Inventory / Barter / Loot
**Hook:** Inventory/barter/loot screens (`src/inventory.cc`)  
**State:** Player inventory, container/merchant contents, equipped items, money, weight  
**Actions:** `equip`, `unequip`, `use`, `drop`, `take`, `buy`, `sell`  
**Context sent:** Game state + inventory learnings

### 6. Level Up
**Hook:** Character screen level-up interface  
**State:** Stats, skills, available points, available perks with descriptions  
**Actions:** `allocate_skills`, `select_perk`, `confirm`  
**Context sent:** Game state + combat/mechanics learnings (to inform build decisions)

### 7. Character Creation
**Hook:** Character creation screen  
**State:** SPECIAL defaults, available points, trait list, skill list, tag slots  
**Actions:** `set_special`, `select_traits`, `tag_skills`, `set_name`, `confirm`  
**Context sent:** claude.md mechanics reference only — Claude doesn't know the game yet

---

## Game State Serialization Examples

### Combat State
```json
{
  "mode": "combat",
  "turn_number": 5,
  "player": {
    "hp": 34, "max_hp": 45, "ap": 8, "max_ap": 8, "ac": 14,
    "position": { "hex": 12045 },
    "active_weapon": {
      "name": "10mm Pistol", "damage": "5-12", "damage_type": "normal",
      "range": 25, "ammo_loaded": 8,
      "attack_modes": [
        { "mode": "single", "ap_cost": 5 },
        { "mode": "aimed", "ap_cost": 6 }
      ]
    },
    "armor": { "name": "Leather Armor", "dt_normal": 2, "dr_normal": 25 },
    "active_effects": ["Buffout"],
    "aid_items": [
      { "name": "Stimpak", "count": 3, "ap_cost": 2 }
    ]
  },
  "hostiles": [
    {
      "id": 4023, "name": "Raider", "hex": 12068,
      "distance_hexes": 8, "hp": 22, "max_hp": 30,
      "weapon": "Hunting Rifle", "armor": "Leather Jacket",
      "line_of_sight": true,
      "hit_chances": {
        "torso": 62, "head": 42, "eyes": 28,
        "left_arm": 38, "right_arm": 38,
        "left_leg": 48, "right_leg": 48, "groin": 32
      }
    }
  ],
  "allies": [
    { "id": 3001, "name": "Sulik", "hex": 12044, "hp": 55, "max_hp": 70 }
  ]
}
```

### Dialogue State
```json
{
  "mode": "dialogue",
  "npc": { "name": "Ardin Buckner", "id": 2001, "location": "Klamath Downtown" },
  "npc_text": "Welcome, stranger. You look like you've traveled a long way.",
  "options": [
    { "index": 0, "text": "I have. I'm looking for something called a GECK. Do you know anything about it?" },
    { "index": 1, "text": "What is this place?" },
    { "index": 2, "text": "[Speech 45%] I could use some supplies. Any chance of a discount for a weary traveler?",
      "skill_check": { "skill": "speech", "player_value": 52, "threshold": 45, "success_chance": 72 } },
    { "index": 3, "text": "Goodbye." }
  ]
}
```

### Exploration State
```json
{
  "mode": "exploration",
  "map": { "name": "Klamath Downtown", "id": 45 },
  "player": { "hex": 14320, "hp": 45, "max_hp": 45, "status": "healthy" },
  "visible_npcs": [
    { "id": 2001, "name": "Ardin Buckner", "hex": 14280, "attitude": "friendly", "distance": 12 },
    { "id": 2002, "name": "Whiskey Bob", "hex": 14295, "attitude": "friendly", "distance": 8 }
  ],
  "visible_items": [
    { "id": 5001, "name": "Bookcase", "hex": 14310, "type": "container" }
  ],
  "exit_grids": [
    { "hex": 14400, "destination": "Klamath Outskirts" },
    { "hex": 14100, "destination": "World Map" }
  ]
}
```

---

## Engine Source: Files to Modify

All source lives in `src/` within the fallout2-ce repository. Key files for hooking:

| System | Key Files | Hook Purpose |
|--------|-----------|-------------|
| Game loop | `game.cc`, `game_mouse.cc` | Exploration input dispatch |
| Combat | `combat.cc`, `combat_ai.cc` | Player turn input |
| Dialogue | `game_dialog.cc`, `dialog.cc` | Option presentation |
| World map | `worldmap.cc` | Travel input |
| Inventory | `inventory.cc` | Item manipulation |
| Character | `critter.cc`, `stat.cc`, `skill.cc`, `perk.cc` | State reading, level-up |
| Objects | `object.cc`, `proto.cc` | Interaction |
| Map/tile | `map.cc`, `tile.cc` | Hex positions, visibility |
| Save/load | `game.cc` save functions | Auto-save hooks |

### New Files to Add

```
src/agent_bridge.h         // Public API: config struct, state types, init/shutdown
src/agent_bridge.cc        // TCP socket server (POSIX sockets), hook dispatcher
src/agent_state.cc         // Game state extraction → JSON via nlohmann/json
src/agent_commands.cc      // JSON command parsing → engine function calls
```

### CMakeLists.txt Modifications

```cmake
# Add option to enable agent bridge
option(AGENT_BRIDGE "Enable agent bridge for external control" OFF)

if(AGENT_BRIDGE)
    # nlohmann/json — header-only, fetch via CMake
    include(FetchContent)
    FetchContent_Declare(json
        URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
    )
    FetchContent_MakeAvailable(json)
    
    target_sources(${TARGET_NAME} PRIVATE
        src/agent_bridge.cc
        src/agent_state.cc
        src/agent_commands.cc
    )
    target_link_libraries(${TARGET_NAME} PRIVATE nlohmann_json::nlohmann_json)
    target_compile_definitions(${TARGET_NAME} PRIVATE AGENT_BRIDGE_ENABLED)
endif()
```

On macOS, POSIX sockets are available natively — no additional socket library needed. The TCP server uses standard `<sys/socket.h>`, `<netinet/in.h>`, `<arpa/inet.h>`.

### Configuration

Add to `fallout2.cfg`:

```ini
[agent]
enabled=1
port=7800
wait_for_connection=1
auto_save_before_combat=1
skip_animations=1
fast_worldmap_travel=1
log_all_actions=1
log_file=playthrough.jsonl
```

---

## Agent Speed Optimizations

1. **Combat animation skip**: Instant resolution, results in JSON
2. **World map instant travel**: Skip animation, resolve encounters
3. **Dialogue skip audio**: No talking head playback wait
4. **Fast save/load**: No fade effects
5. **Visible mode (default on)**: Engine renders in a macOS window so you can watch Claude play

Estimated wall-clock for full playthrough: **6-16 hours** (longer than a guided run because discovery-first play involves more exploration, backtracking, and getting stuck).

---

## Implementation Plan

### Phase 1: Engine Build and Bridge Foundation (2-3 weeks)
1. Fork fallout2-ce on GitHub, clone to `~/Projects/fallout2-agent-engine`
2. Set up symlinks to GOG data files, verify unmodified build runs on your Mac
3. Add `AGENT_BRIDGE` CMake option, fetch nlohmann/json
4. Implement `agent_bridge.cc`: TCP server on port 7800, connection handling
5. Implement first hook: exploration mode — pause on idle, serialize player position and visible objects
6. Set up `~/Projects/fallout2-agent` TypeScript project
7. Build minimal SDK with `getState()` and `moveTo()`
8. **Milestone: Character walks around the starting area via SDK calls from a TypeScript process**

### Phase 2: Combat and Interaction (2-3 weeks)
1. Hook combat turn loop in `combat.cc`, full state serialization
2. Implement all combat actions: attack (with aimed shots), move, use item, end turn, flee
3. Hook dialogue system in `game_dialog.cc` with option serialization
4. Hook inventory, barter, loot, character creation, level-up
5. Implement interaction commands: talk, use skill, open container, pick up
6. Expand SDK with full async API
7. **Milestone: Scripted TypeScript client creates character, fights, talks to NPCs, manages inventory**

### Phase 3: World Map and Full Game Loop (1-2 weeks)
1. Hook world map navigation in `worldmap.cc`
2. Handle zone transitions (exit grids → new maps) and random encounters
3. Implement Pip-Boy state access (quest log, known locations, time)
4. Implement auto-save before combat
5. Build MCP tool wrappers around SDK (`.mcp.json`)
6. **Milestone: Scripted client can travel between locations and handle all transitions cleanly**

### Phase 4: Agent Wrapper and Documentation (2-3 weeks)
1. Build agent wrapper (`agent/wrapper.ts`) with Claude API integration
2. Implement moral compass system (`agent/compass.ts`): file read, context injection, update merging
3. Implement learnings directory system (`agent/learnings.ts`): context-aware file reading, new entry writing
4. Implement journal logging (`agent/journal.ts`): full decision transcripts as JSONL
5. Write `claude.md` — mechanics-only reference, SDK API docs, content guidance
6. Write system prompt with discovery-first constraints
7. Create empty `learnings/` directory structure
8. Create `hints.json` with minimal, spoiler-light hints
9. **Milestone: Claude creates a character and completes the tutorial area using only game observations**

### Phase 5: Discovery Playthrough (4-6 weeks iteration)
1. Claude begins the game with no foreknowledge
2. Observe: Does Claude explore effectively? Take useful notes? Follow dialogue leads?
3. Identify failure modes: stuck without hints? Missing critical objects? Bad tactical play?
4. Iterate on `claude.md` mechanics docs (never add story content — only clarify how systems work)
5. Tune hint system: when do hints trigger? How minimal can they be?
6. Tune compass system: is Claude updating meaningfully? Too often? Not enough?
7. Add save checkpointing at major location arrivals
8. **Milestone: Claude progresses through 3+ major locations through pure discovery**

### Phase 6: Full Game Completion (3-5 weeks iteration)
1. Continue the playthrough through mid-game and late-game
2. Monitor for: content refusals, build dead-ends, quest confusion, navigation failures
3. Iterate on system prompt and compass guidance
4. Handle endgame complexity (multiple factions, time pressure)
5. **Milestone: Claude completes the main quest through discovery-driven play**

### Phase 7: Analysis (1-2 weeks)
1. Compile full playthrough transcript from `journal.jsonl`
2. Compile final moral compass as standalone narrative document
3. Compile learnings directory as Claude's "game guide written from experience"
4. Generate statistics: combat efficiency, quest completion, karma arc, deaths, time stuck
5. Write analysis: how did discovery-first play differ from guided play? What surprised us?
6. **Milestone: Complete documented playthrough with all deliverables**

### Estimated Total: 15-22 weeks

Longer than a guided-play approach because discovery-first means Claude will get stuck, backtrack, and need iteration. That's the point.

---

## Success Metrics

| Metric | Target |
|--------|--------|
| Main quest completion | Yes — through discovery, not pre-knowledge |
| Quest discovery rate | Claude finds and attempts 60%+ of quests through exploration |
| Self-generated learnings | 100+ files across all categories |
| Compass evolution entries | 50+ significant moral shifts |
| Hints consumed | < 15 across the full game (less is better) |
| Deaths and reloads | < 40 (discovery play is harder) |
| Time stuck (per instance) | Resolves most blocks within 30 decision cycles |
| Dialogue engagement | Exhausts NPC dialogue trees, asks follow-up questions |
| Note-taking quality | Learnings are accurate, useful, and build on each other |
| Character build | Build is viable through endgame despite no build guide |
| Playthrough narrative | Reads as a coherent first-person account of discovery |

---

## Playthrough Transcript Format

Every significant decision logged as JSONL:

```json
{
  "timestamp": "2025-02-11T15:30:22Z",
  "game_time": "July 25, 2241 14:30",
  "location": "Unknown Settlement - East Side",
  "mode": "dialogue",
  "npc": "Unknown Man",
  "state_summary": "A rough-looking man is offering me a job. The settlement seems dangerous. I have 34 HP, $243, 3 stimpaks.",
  "learnings_consulted": ["places/the-den.md", "people/unknown-slavers.md"],
  "compass_consultation": "My compass has no entry for this man. But I notice people in cages nearby. My rule says: judge people by their actions.",
  "reasoning": "There are people locked in cages. This man seems to be involved with that. My gut says this is wrong — I would not want to be in a cage. I should learn more before agreeing to anything, but I already feel uneasy.",
  "action": { "action": "select_option", "index": 1 },
  "compass_update": {
    "attitudes": { "Cage_Man": { "trust": -1, "notes": "Keeps people in cages. Bad feeling about this." } }
  },
  "learnings_written": ["people/cage-man-the-den.md"],
  "result": "The man explains he's a slaver. He wants me to catch runaway slaves for payment."
}
```

Note: Claude doesn't call him "Metzger" until the game tells it his name. It doesn't call the location "The Den" until it learns the name. This IS the discovery-first experience.

---

## Key Deliverables

1. **The Playthrough Transcript** (`journal.jsonl`): Every decision, every piece of reasoning, every discovery. The primary deliverable.

2. **The Moral Compass** (`moral_compass.json`): The character arc from naive tribal to experienced wasteland survivor. A narrative document of ethical evolution.

3. **The Learnings Directory** (`learnings/`): A game guide written entirely from first-hand experience. Claude's own notes on the world it explored.

4. **The Agent Bridge** (`engine/src/agent_*.cc`): The technical contribution — a working API interface for Fallout 2.

5. **The SDK and MCP Tools** (`sdk/`, `mcp/`): A reusable toolkit for programmatic Fallout 2 interaction.
