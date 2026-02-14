# CLAUDE.md

## Session Start

1. Read `docs/default-persona.md` and `docs/gameplay-guide.md` so they're in context
2. `source scripts/executor.sh` — all gameplay goes through executor functions
3. Run `executor_help` to see available functions — that listing IS the documentation
4. Never use subagents for gameplay — play directly in the main context

## Playing the Game (Fallout 2)

You are the strategic engine deciding what to do, and you carry out those intentions via the scripts, commands, and game state information that have been made available to you. Have fun, experiment, and play like a real player.

**Observe → Decide → Act.** One inspect call, one action call. 3+ calls means wrong abstraction level.

**Observe:** Run `status` (compact one-liner) or `look_around` (nearby objects) to see your situation. Never parse `agent_state.json` directly.

**Decide:** Run `executor_help` if you need to discover what functions are available. Pick the highest-level one that fits. The executor.sh header also documents action references, information boundaries, interaction tactics, and gotchas — read it when you need deeper guidance.

**Act:** Execute in a single Bash call. Batch muse + action: `muse "text"; sleep 1; <action>`.

Play like a real player: explore, loot, examine, reason from in-game clues and your guide. No warping between maps, no metagaming. Equip items to hand slots, use them from the game screen, press keys, select dialogue options — only bypass a UI element when there is no scriptable alternative, and document why.

Use `muse "text"` frequently for inner monologue in the character voice when interesting things happen.

Use `note`, `recall`, `game_log` (executor functions) to make and reference notes on in-game information. Also available as skills: `/game-note`, `/game-recall`, `/game-log`.

---

## Architecture

```
Claude Code (CLI) → reads game/agent_state.json, writes game/agent_cmd.json
Agent Bridge (C++ in fallout2-ce) → engine hooks, state serialization, command dispatch
fallout2-ce Engine + SDL2
```

Commands use `{"commands":[...]}` wrapper (executor's `cmd()` handles this automatically).

## Build & Deploy

```bash
cd engine/fallout2-ce/build
cmake .. -DAGENT_BRIDGE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make -j$(sysctl -n hw.ncpu)
cp -R "Fallout II Community Edition.app" ../../../game/
codesign --sign - --force --deep ../../../game/"Fallout II Community Edition.app"
cd ../../../game && open "Fallout II Community Edition.app"
```

Always test bridge changes in the running game: build → deploy → codesign → launch → verify JSON.

## Project Layout

- `engine/fallout2-ce/` — upstream engine submodule (never commit here directly)
- `src/` — agent bridge C++ (patches on top of CE)
- `scripts/` — executor shell + sub-modules, hooks, setup, patch scripts
  - `executor.sh` — core I/O, waits, state inspection, save/load, knowledge, help
  - `executor_world.sh` — movement (`move_and_wait`), exploration, interaction, healing, party
  - `executor_combat.sh` — `do_combat` monitoring loop (engine AI handles decisions)
  - `executor_dialogue.sh` — dialogue, persona, thought system
  - `executor_chargen.sh` — character creation & level-up helpers
  - `game_state_hook.py` — PreToolUse hook: injects `[GAME]` status before Bash calls
  - `float_response.sh` — renders Claude's text as in-game floating text
- `game/` — runtime data + JSON files (git-ignored); includes `knowledge/`, `debug/`, `persona.md`, `thought_log.md`, `objectives.md`
- `docs/` — gameplay guide, default persona (`default-persona.md` → copied to `game/persona.md`), journal
- `.claude/settings.json` — hooks (PreToolUse game state, float response, PreCompact status)
- `.claude/skills/` — slash commands (`/game-note`, `/game-recall`, `/game-log`, `/run-codex`)

## Engine Patches

Patches live in `engine/patches/`. Never commit directly to the submodule.

```bash
git submodule update --init --recursive && ./scripts/apply-patches.sh   # after clone/pull
./scripts/generate-patches.sh && git add engine/patches/                # after modifying engine
```

## Bridge & Engine Reference

**Bridge:** `src/agent_bridge.h` (API), `src/agent_bridge_internal.h` (internals), `src/agent_bridge.cc` (core/tick/context), `src/agent_state.cc` (state), `src/agent_commands.cc` (commands).

**Engine hooks:** `game.cc` (main loop), `combat.cc`, `game_dialog.cc`, `input.cc`, `inventory.cc`, `worldmap.cc`, `character_editor.cc`. Context hooks in `mainmenu.cc`, `character_selector.cc`, `character_editor.cc`, `main.cc`.

**Engine modifications:** `game_dialog.h/cc`, `display_monitor.h/cc`, `combat.h/cc`, `loadsave.h/cc`, `pipboy.h/cc`, `worldmap.h/cc` (accessors), `CMakeLists.txt` (bridge sources).

## Code Style & Dependencies

WebKit style via clang-format: 4 spaces, UTF-8, LF. `AllowShortIfStatementsOnASingleLine: WithoutElse`.

CMake 3.13+, C++17 compiler, SDL2 (bundled via `FALLOUT_VENDORED`), nlohmann/json (CMake FetchContent), Python 3.

## Codex Collaboration

Use `/run-codex <prompt>` to get a second opinion from Codex (OpenAI). Good for code review,
refactoring plans, architecture questions, or any task where cross-model input is valuable.
Synthesize Codex output with your own analysis — note agreements, disagreements, and blind spots.
