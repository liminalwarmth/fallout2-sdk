# Fallout 2 — Gameplay Mechanics Guide

A general reference for how Fallout 2 works. This covers game mechanics, not specific solutions. Think of it as the user manual the agent should internalize before playing.

---

## Character System

### SPECIAL Stats (1–10 each)
- **Strength**: Carry weight, melee damage, weapon requirements
- **Perception**: Ranged accuracy, sequence (turn order), detecting traps
- **Endurance**: Hit points per level, poison/radiation resistance, healing rate
- **Charisma**: NPC reactions, party size limit (CHA/2), barter modifier
- **Intelligence**: Skill points per level (2×INT + 5), dialogue options (low INT = different dialogue)
- **Agility**: Action points (5 + AG/2), armor class
- **Luck**: Critical hit chance, random encounter quality, gambling

### Derived Stats
- **Hit Points**: 15 + STR + (2 × END) + (END/3 × level)
- **Action Points**: 5 + AG/2 (floored). Everything in combat costs AP.
- **Carry Weight**: 25 + 25 × STR pounds
- **Sequence**: 2 × PE. Determines turn order in combat.
- **Healing Rate**: END/3 (min 1). HP recovered per rest period.
- **Armor Class**: Base AG. Modified by armor worn.
- **Damage Resistance**: From armor. Separate for Normal, Laser, Fire, Plasma, Explode.

### Skills (0–300%)
Skills start at base values derived from SPECIAL and increase with skill points at level-up. Higher skill = higher success chance. Key skills:
- **Small/Big Guns, Energy Weapons**: Combat accuracy with weapon types
- **Unarmed/Melee**: Close combat accuracy
- **Lockpick**: Open locked doors and containers
- **Steal**: Take items from NPCs without detection
- **Traps**: Detect and disarm traps, arm explosives
- **Science**: Use computers, interact with tech
- **Repair**: Fix broken machinery
- **Speech**: Persuade NPCs, unlock dialogue options
- **Barter**: Better buy/sell prices
- **First Aid**: Heal minor injuries (1/day, 1-3 AP)
- **Doctor**: Heal crippled limbs and major injuries (1/day)
- **Outdoorsman**: Avoid random encounters, forage, better world map travel
- **Sneak**: Move undetected

**Tagged Skills**: At character creation, choose 3 skills to "tag" — they start higher and gain 2 points per point spent.

### Traits (pick 0-2 at creation)
Traits give one benefit and one penalty. They're permanent. Examples:
- **Heavy Handed**: +4 melee damage, -30% critical hit table results
- **Fast Shot**: 1 less AP per ranged attack, but no aimed shots
- **Gifted**: +1 to all SPECIAL, but -10% to all skills and 5 fewer skill points/level
- **Small Frame**: +1 AG, but 25% less carry weight
- **Finesse**: +10% critical chance, but -30% damage

### Perks (every 3 levels starting at level 3)
Perks provide bonuses. Each has SPECIAL/level/skill requirements. Some highlights:
- **Awareness**: See exact HP/weapon of target when examining
- **Bonus Move**: +2 movement AP in combat (free move)
- **Quick Pockets**: Inventory access costs 2 AP instead of 4
- **Bonus Rate of Fire**: -1 AP for ranged attacks
- **Toughness**: +10% damage resistance
- **Better Criticals**: +20% to critical hit effects

### Leveling
- Gain XP from quests, combat kills, skill usage, and quest completion
- Each level: gain HP, skill points, and a perk every 3 levels
- XP thresholds increase per level (1000, 3000, 6000, 10000, 15000, ...)

---

## Combat

### Action Points
Everything costs AP. When you're out of AP, your turn ends (or you manually end it to let AP regenerate faster for armor class).
- **Move**: 1 AP per hex
- **Unarmed/Melee attack**: 3 AP (varies by weapon)
- **Ranged attack**: 5 AP (varies; aimed shots cost +1)
- **Reload**: 2 AP
- **Use item**: 2 AP (stimpak, etc.)
- **Free move**: Some bonus AP can only be used for movement, not attacks

### Attack Modes
Weapons have multiple attack modes. Cycle through them to access:
- **Unarmed**: Punch, Kick (Kick does more damage, costs more AP)
- **Melee**: Swing, Thrust (varies by weapon)
- **Ranged**: Single shot, Burst fire, Aimed shot
- Aimed shots target specific body parts: Head (hardest, most damage), Eyes (blinding), Torso (easiest), Arms (disarm), Legs (cripple), Groin

### Hit Chance
`Base = skill% - distance_penalty - target_AC - cover + modifiers`
- Distance reduces accuracy for ranged weapons
- Aimed shots have an additional penalty (-40% for head, -60% for eyes, etc.)
- Light conditions matter (darkness = penalty)
- Minimum 1% hit chance in most cases

### Damage
`Damage = (weapon_damage_roll - target_DT) × (1 - target_DR%)`
- **DT** (Damage Threshold): Flat damage absorbed. If your damage is below DT, you do nothing.
- **DR** (Damage Resistance): Percentage reduction after DT.
- Different armor has different DT/DR for each damage type (Normal, Laser, Fire, Plasma, Explode)
- Critical hits multiply damage and can cause special effects (knockout, crippled limb, bypass armor, instant death)

### Damage Types
- **Normal**: Most bullets, melee, unarmed
- **Laser**: Laser pistol/rifle
- **Fire**: Flamer, Molotov cocktails
- **Plasma**: Plasma pistol/rifle
- **Explosive**: Grenades, rockets, dynamite, plastic explosives
- **EMP**: Effective vs robots, useless vs organic

### Combat Strategy
- Close distance before attacking with melee/unarmed
- Use cover and doorways as chokepoints
- Heal when HP drops below ~40%
- End turn early if you can't reach or hurt enemies — remaining AP adds to AC
- Use aimed shots to the eyes to blind dangerous enemies
- Use burst fire against groups (careful: hits friendlies too!)
- Switch to the correct hand that has your weapon equipped

### Combat Initiation
- Walking into hostile creatures triggers combat
- `enter_combat` command to initiate from exploration
- Some dialogues end in combat
- Running away: `flee_combat` if near a map edge

---

## Exploration

### General Strategy
1. **Check every container**: Pots, chests, shelves, desks, lockers, bookshelves — all may hold items
2. **Examine unusual objects**: Use `look_at` on anything interesting. Signs, notes, and books provide clues.
3. **Talk to everyone**: NPCs give quests, hints, and background. Exhaust dialogue trees.
4. **Try skills on interactive objects**: Lockpick on locked doors/containers, Repair on broken machinery, Science on computers, Traps on trapped containers
5. **Pick up loose items**: Ground items are free loot. Look for ammo, healing items, quest items.
6. **Map multiple elevations**: Many maps have 2-3 floors/levels. Look for stairs, ladders, elevators.

### Doors
- **Try opening first** (use_object). Many doors are unlocked.
- **Locked doors**: Use Lockpick skill. Higher skill = better chance. Some locks are too hard for low skill.
- **Reinforced/Impenetrable doors**: Can't be lockpicked. Require explosives (arm near door, move away, wait for detonation) or a key found elsewhere.
- **Trapped doors**: Traps skill to detect/disarm before opening. Failed disarm may trigger the trap.
- **Doors auto-close**: After opening, move through promptly before it closes.
- **Some doors require keys**: Keys are quest items found in the world or given by NPCs.

### Explosives
Explosives require a multi-step process — they can't just be "used on" a target:
1. **Arm the explosive** (sets a timer, places it on the ground)
2. **Move away** from the blast radius (at least 5-8 hexes)
3. **Wait for detonation** (timer expires, explosion occurs)
4. **Check results** (target destroyed? path clear?)

Types: Dynamite (weaker, found more often) and Plastic Explosives (stronger). Both work on destructible scenery.

### Containers
- Containers include: Pots, Chests, Lockers, Shelves, Desks, Bookshelves, Footlockers, Dressers, Tables
- Some are locked (use Lockpick) or trapped (use Traps)
- Container state persists — looted containers stay empty
- Dead bodies are also containers — loot after combat

---

## Skills in the Field

| Skill | Use On | Effect |
|-------|--------|--------|
| Lockpick | Locked doors, containers | Opens them. Critical failure may jam the lock. |
| Traps | Trapped containers, doors | Disarms trap. Also arms explosives. |
| Repair | Broken generators, machinery | Fixes them, often for quest progress. |
| Science | Computers, terminals | Accesses data, unlocks doors, quest info. |
| First Aid | Self, party members | Heals 1-5 HP per use. Limited per day. |
| Doctor | Self, party members | Heals crippled limbs, larger HP restore. Limited per day. |
| Steal | NPCs | Takes items from their inventory. Failed = hostile. |
| Outdoorsman | World map (passive) | Avoids random encounters, better travel. |
| Sneak | Toggle (passive) | Move without being detected. Useful for stealing, avoiding combat. |

---

## Inventory Management

- **Carry weight** is limited by Strength. Drop items if overloaded (movement slowed/blocked).
- **Equip best available gear**: Armor in armor slot, weapon in a hand slot.
- **Two hand slots**: Left and right. Switch between them to access different weapons. Default is left hand (unarmed).
- **Keep healing items accessible**: Stimpaks (pid 40) are the primary healing item. Super Stimpaks heal more.
- **Save ammo**: Don't waste ranged ammo on weak enemies you can punch. Check ammo count regularly and reload when empty.
- **Sell excess loot**: Trade unnecessary items for caps, healing, and ammo at merchants.
- **Quest items**: Don't sell items that NPCs have asked for or that seem unique/important.

---

## World Map Travel

- **Movement**: Click destination areas to travel. Travel takes in-game time and may trigger encounters.
- **Random encounters**: Based on Outdoorsman skill, luck, and terrain. Can be hostile (raiders, animals), neutral (merchants), or special.
- **Area discovery**: New locations appear on the map when NPCs tell you about them, or when you explore nearby.
- **Car**: Once acquired, greatly speeds travel and can carry extra inventory. Requires fuel cells.
- **Rest stops**: Use `rest` to heal between destinations. Time passes.
- **Terrain**: Desert, mountain, city — affects travel speed and encounter types.

---

## Economy & Barter

- **Caps** are the currency. Also a trade medium.
- **Barter skill** directly affects prices:
  - Formula: `cost = base_price × 2 × (160 + npc_barter) / (160 + your_barter)`
  - At low barter (~16%), items cost about 2× base price to buy
  - At high barter (~100%+), prices approach base price
- **Sell loot regularly**: Excess weapons, armor, and junk have value.
- **Buy priorities**: Healing items > ammo > better armor > better weapons
- **Trading**: You offer items + caps, merchant offers items + caps. Both sides must balance.
- **Different merchants carry different stock**: Some specialize in weapons, others in medical supplies.

---

## Quests

- **Pip-Boy** tracks active quests with descriptions and status
- **Talk to NPCs** to receive quests — exhaust all dialogue options
- **Multiple solutions**: Many quests can be solved through combat, speech, stealth, or skill use
- **Quest XP** is often larger than combat XP — prioritize quest completion
- **Read everything**: Quest hints come from dialogue, holodisks, and notes found in the world
- **Time-sensitive quests** exist but are rare. The main quest has a soft time limit.
- **Quest chains**: Completing one quest may unlock another from the same or different NPC

---

## Reputation & Karma

- **Karma**: Global moral score. Positive actions (helping people, fighting evil) increase it. Negative actions (theft, murder, slaving) decrease it.
- **Town reputation**: Each town tracks how residents feel about you. Reputation comes from completing local quests and behaving well/badly.
- **Consequences**: Some NPCs won't talk to you with low karma. Some quests require good/bad reputation. Party members may leave if karma conflicts with their values.
- **Titles**: Karma thresholds grant titles (Berserker, Champion, etc.) that affect NPC reactions.

---

## Party Members

- **Recruitment**: Talk to potential companions. Some require quests completed, karma thresholds, or payment.
- **Party size**: Limited by Charisma (CHA/2 members).
- **Equipment**: Give party members better weapons and armor — they'll use them.
- **Combat behavior**: Party members act autonomously in combat. They may use burst fire and hit you — position carefully.
- **Healing**: Use Doctor/First Aid on injured party members. They don't heal on their own (except between map transitions).
- **Death**: Party members can die permanently. Save before dangerous fights.

---

## Tips for AI Agents

- **Explore before assuming**: Don't guess where items are. Search containers, examine objects, and talk to NPCs.
- **Try the obvious first**: Before using explosives on a door, try opening it, then try lockpicking.
- **Read feedback**: Check `message_log` and `last_command_debug` after every action to understand what happened.
- **Save often**: Quicksave before risky actions (combat, explosive usage, stealing).
- **Be resourceful**: Use skills you have. Low Lockpick? Maybe there's a key. Low Speech? Try a different approach.
- **Manage HP**: Don't enter combat at low HP. Rest or heal between fights.
- **Understand AP**: Don't try to attack if you don't have enough AP. End turn instead.
- **Watch ammo**: Ranged weapons are powerful but limited by ammo. Switch to melee/unarmed when ammo is scarce.
