import Anthropic from "@anthropic-ai/sdk";
import { FalloutSDK } from "@fallout2-sdk/core";
import type {
    GameState,
    CharEditorState,
    GameplayExplorationState,
    GameplayCombatState,
    GameplayCombatWaitState,
    GameplayDialogueState,
    GameplayLootState,
    GameplayBarterState,
    GameplayWorldmapState,
    Command,
} from "@fallout2-sdk/core";
import { buildCharEditorPrompt, getSystemPrompt } from "./prompts.js";
import { Journal } from "./journal.js";
import { ObjectiveManager, type Objective } from "./objectives.js";
import { GameMemory } from "./memory.js";
import { Strategist } from "./strategist.js";
import { CombatExecutor } from "./executors/combat.js";
import { NavigationExecutor } from "./executors/navigation.js";
import { LootExecutor } from "./executors/loot.js";
import { InteractionExecutor } from "./executors/interaction.js";
import { WorldMapExecutor } from "./executors/worldmap.js";
import type { ExecutorContext } from "./executors/types.js";
import type { AgentResponse } from "./types.js";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface WrapperOptions {
    gameDir: string;
    outputDir: string;
    actionDelay?: number;
    pollInterval?: number;
    model?: string;
}

export class AgentWrapper {
    private sdk: FalloutSDK;
    private journal: Journal;
    private anthropic: Anthropic;
    private actionDelay: number;
    private pollInterval: number;
    private model: string;
    private running = false;

    // Strategic layer
    private strategist: Strategist;
    private objectives: ObjectiveManager;
    private memory: GameMemory;

    // Executors
    private combat: CombatExecutor;
    private navigation: NavigationExecutor;
    private loot: LootExecutor;
    private interaction: InteractionExecutor;
    private worldmap: WorldMapExecutor;

    // State tracking
    private lastContext = "";
    private lastMap = "";
    private lastElevation = -1;
    private ticksSinceEval = 0;
    private reEvalCooldown = 0;
    private readonly RE_EVAL_INTERVAL = 100; // ticks between periodic re-evaluations

    // Guards against duplicate actions in same context
    private handledContextTick = -1; // Tick when we last handled a one-shot context
    private lastDialogueReply = ""; // Track dialogue text to avoid duplicate Claude calls
    private barterHandled = false; // Guard for barter
    private lootHandled = false; // Guard for loot screen

    constructor(options: WrapperOptions) {
        this.sdk = new FalloutSDK(options.gameDir);
        this.journal = new Journal(options.outputDir);
        this.anthropic = new Anthropic();
        this.actionDelay = options.actionDelay ?? 500;
        this.pollInterval = options.pollInterval ?? 200;
        this.model = options.model ?? "claude-sonnet-4-5-20250929";

        // Initialize strategic systems
        this.memory = new GameMemory();
        this.objectives = new ObjectiveManager();

        const logFn = (msg: string) => this.log(msg);

        this.strategist = new Strategist({
            model: this.model,
            memory: this.memory,
            onLog: logFn,
        });

        // Initialize executors
        const execCtx: ExecutorContext = {
            sdk: this.sdk,
            memory: this.memory,
            log: logFn,
        };

        this.navigation = new NavigationExecutor(execCtx);
        this.combat = new CombatExecutor(execCtx);
        this.loot = new LootExecutor(execCtx, this.navigation);
        this.interaction = new InteractionExecutor(execCtx, this.navigation);
        this.worldmap = new WorldMapExecutor(execCtx);
    }

    async run(): Promise<void> {
        this.running = true;
        this.log("Agent wrapper started (objective-driven mode)");
        this.journal.logEvent("agent_started", { model: this.model, mode: "objective_driven" });

        while (this.running) {
            const state = this.sdk.getState();
            if (!state) {
                await sleep(this.pollInterval);
                continue;
            }

            // Detect context transitions
            if (state.context !== this.lastContext) {
                this.journal.logEvent("context_change", {
                    from: this.lastContext,
                    to: state.context,
                });
                // Reset guards on context change
                this.lastDialogueReply = "";
                this.barterHandled = false;
                this.lootHandled = false;
                this.handledContextTick = -1;
                this.lastContext = state.context;
            }

            await this.tick(state);
            await sleep(this.pollInterval);
        }
    }

    stop(): void {
        this.running = false;
    }

    // --- Main tick dispatcher ---

    private async tick(state: GameState): Promise<void> {
        const ctx = state.context;

        // === Immediate-action contexts ===

        if (ctx === "movie") {
            await this.sdk.skipMovie();
            await sleep(500);
            return;
        }

        if (ctx === "main_menu") {
            if (this.handledContextTick === state.tick) return;
            this.handledContextTick = state.tick;
            this.log("Main menu → selecting New Game");
            await this.sdk.mainMenuSelect("new_game");
            await sleep(2000);
            return;
        }

        if (ctx === "character_selector") {
            if (this.handledContextTick === state.tick) return;
            this.handledContextTick = state.tick;
            this.log("Character selector → creating custom character");
            await this.sdk.charSelectorSelect("create_custom");
            await sleep(2000);
            return;
        }

        if (ctx === "character_editor") {
            await this.handleCharacterEditor(state as CharEditorState);
            return;
        }

        // === Combat: deterministic executor ===

        if (ctx === "gameplay_combat") {
            const result = await this.combat.executeTurn(state as GameplayCombatState);
            if (result.status === "done") {
                await sleep(300);
            }
            return;
        }

        if (ctx === "gameplay_combat_wait") {
            // Wait for our turn — nothing to do
            return;
        }

        // === Dialogue: ask Claude ===

        if (ctx === "gameplay_dialogue") {
            await this.handleDialogue(state as GameplayDialogueState);
            return;
        }

        // === Loot screen: take and close ===

        if (ctx === "gameplay_loot") {
            if (this.lootHandled) return;
            this.lootHandled = true;
            await this.loot.handleLootScreen(state as GameplayLootState);
            return;
        }

        // === Barter: ask Claude ===

        if (ctx === "gameplay_barter") {
            await this.handleBarter(state as GameplayBarterState);
            return;
        }

        // === Inventory screen: close it and go back to exploration ===

        if (ctx === "gameplay_inventory") {
            // The agent doesn't need to manage inventory UI directly
            return;
        }

        // === World map: objective-driven ===

        if (ctx === "gameplay_worldmap") {
            await this.handleWorldmap(state as GameplayWorldmapState);
            return;
        }

        // === Exploration: objective-driven ===

        if (ctx === "gameplay_exploration") {
            await this.handleExploration(state as GameplayExplorationState);
            return;
        }

        // === Generic gameplay fallback ===

        if (ctx === "gameplay") {
            // Old generic context — treat as exploration if possible
            return;
        }
    }

    // --- Exploration (objective-driven) ---

    private async handleExploration(state: GameplayExplorationState): Promise<void> {
        const map = state.map;

        // Detect map/elevation change → full survey
        if (map.name !== this.lastMap || map.elevation !== this.lastElevation) {
            this.log(`=== New area: ${map.name} (elevation ${map.elevation}) ===`);
            this.lastMap = map.name;
            this.lastElevation = map.elevation;
            this.memory.setCurrentMap(map.name, map.elevation);
            this.memory.visitTile(state.player.tile);

            // Record exit grids
            if (state.objects.exit_grids.length > 0) {
                this.memory.recordExitGrids(state.objects.exit_grids);
            }

            // Ask Claude to survey and plan
            const result = await this.strategist.surveyAndPlan(state, this.objectives.objectives);
            if (result.objectives.length > 0) {
                this.objectives.replaceAll(result.objectives);
                this.log(`Objectives set: ${this.objectives.getSummary()}`);
            }
            if (result.notes) {
                this.memory.addMapNote(result.notes);
            }

            this.ticksSinceEval = 0;
            this.journal.logEvent("survey_complete", {
                map: map.name,
                objectives: result.objectives.length,
            });
            return;
        }

        // Track visited tile
        this.memory.visitTile(state.player.tile);

        // Check re-evaluation triggers
        this.ticksSinceEval++;
        if (this.reEvalCooldown > 0) {
            this.reEvalCooldown--;
        }

        if (this.objectives.needsReEvaluation() && this.reEvalCooldown <= 0) {
            this.log("All objectives done/blocked — re-evaluating...");
            await this.triggerReEvaluation(state, "all_complete_or_blocked");
            return;
        }

        if (this.ticksSinceEval > this.RE_EVAL_INTERVAL && this.reEvalCooldown <= 0) {
            this.log("Periodic re-evaluation...");
            await this.triggerReEvaluation(state, "periodic");
            return;
        }

        // Execute current objective
        const objective = this.objectives.getActive();
        if (!objective) return;

        await this.executeObjective(objective, state);
    }

    // --- Objective execution ---

    private async executeObjective(obj: Objective, state: GameplayExplorationState): Promise<void> {
        let result;

        switch (obj.type) {
            case "talk_to_npc":
                if (!obj.target?.objectId) {
                    this.objectives.block(obj.id, "No target objectId");
                    return;
                }
                result = await this.interaction.talkTo(obj.target.objectId, state);
                break;

            case "navigate_to_tile":
                if (!obj.target?.tile) {
                    this.objectives.block(obj.id, "No target tile");
                    return;
                }
                result = await this.navigation.navigateTo(obj.target.tile, state);
                break;

            case "navigate_to_exit":
                if (!obj.target?.exitGridTile) {
                    this.objectives.block(obj.id, "No exit grid tile");
                    return;
                }
                result = await this.navigation.navigateTo(obj.target.exitGridTile, state);
                break;

            case "loot_container":
                if (!obj.target?.objectId) {
                    this.objectives.block(obj.id, "No target objectId");
                    return;
                }
                result = await this.loot.lootContainer(obj.target.objectId, state);
                break;

            case "pick_up_item":
                if (!obj.target?.objectId) {
                    this.objectives.block(obj.id, "No target objectId");
                    return;
                }
                result = await this.loot.pickUpItem(obj.target.objectId, state);
                break;

            case "use_item_on":
                if (!obj.target?.itemPid || !obj.target?.objectId) {
                    this.objectives.block(obj.id, "Missing itemPid or objectId");
                    return;
                }
                result = await this.interaction.useItemOn(
                    obj.target.itemPid, obj.target.objectId, state
                );
                break;

            case "use_skill_on":
                if (!obj.target?.skillName || !obj.target?.objectId) {
                    this.objectives.block(obj.id, "Missing skillName or objectId");
                    return;
                }
                result = await this.interaction.useSkillOn(
                    obj.target.skillName, obj.target.objectId, state
                );
                break;

            case "explore_area":
                if (!obj.target?.tile) {
                    this.objectives.block(obj.id, "No explore target tile");
                    return;
                }
                result = await this.navigation.exploreToward(obj.target.tile, state);
                break;

            case "enter_worldmap":
                if (!obj.target?.exitGridTile) {
                    this.objectives.block(obj.id, "No exit grid tile");
                    return;
                }
                result = await this.navigation.navigateTo(obj.target.exitGridTile, state);
                break;

            case "heal":
                result = await this.interaction.heal(state);
                break;

            case "equip_gear":
                result = await this.interaction.equipBestGear(state);
                break;

            case "custom":
                // Custom objectives are informational — mark done after one attempt
                this.log(`Custom objective: ${obj.description}`);
                result = { status: "done" as const };
                break;

            default:
                this.objectives.block(obj.id, `Unknown objective type: ${obj.type}`);
                return;
        }

        // Handle executor result
        if (result.status === "done") {
            this.log(`Objective completed: ${obj.description}`);
            this.objectives.complete(obj.id, state.tick);
            this.navigation.resetStuck();
            this.journal.logEvent("objective_completed", { description: obj.description });
        } else if (result.status === "blocked") {
            this.log(`Objective blocked: ${obj.description} — ${result.reason}`);
            this.objectives.block(obj.id, result.reason);
            this.navigation.resetStuck();
            this.journal.logEvent("objective_blocked", {
                description: obj.description,
                reason: result.reason,
            });
        }
        // "working" status means the executor is making progress — continue next tick
    }

    // --- Re-evaluation ---

    private async triggerReEvaluation(
        state: GameplayExplorationState | GameplayCombatState | GameplayWorldmapState,
        trigger: string,
        completedObjective?: Objective,
        blockedObjective?: Objective
    ): Promise<void> {
        const result = await this.strategist.reEvaluate(
            state,
            this.objectives.objectives,
            trigger,
            completedObjective,
            blockedObjective
        );

        if (result.objectives.length > 0) {
            this.objectives.replaceAll(result.objectives);
            this.log(`Re-evaluated objectives: ${this.objectives.getSummary()}`);
        }

        if (result.notes) {
            this.memory.addMapNote(result.notes);
        }

        this.ticksSinceEval = 0;
        this.reEvalCooldown = 10; // Don't re-evaluate again for 10 ticks
        this.navigation.resetStuck();

        this.journal.logEvent("reevaluation", {
            trigger,
            objectives: result.objectives.length,
        });
    }

    // --- Dialogue handling ---

    private async handleDialogue(state: GameplayDialogueState): Promise<void> {
        const dialogue = state.dialogue;
        if (!dialogue || dialogue.options.length === 0) return;

        // Guard: don't call Claude again if we already responded to this exact dialogue text
        const replyKey = `${dialogue.speaker_name}:${dialogue.reply_text}`;
        if (replyKey === this.lastDialogueReply) return;
        this.lastDialogueReply = replyKey;

        const choice = await this.strategist.chooseDialogue(state, this.objectives.objectives);
        if (!choice) {
            // Fallback: pick first option
            this.log("Claude returned no dialogue choice — picking option 0");
            await this.sdk.selectDialogue(0);
            return;
        }

        this.log(`Dialogue choice: ${choice.choice} — "${dialogue.options[choice.choice]?.text ?? "?"}"`);
        await this.sdk.selectDialogue(choice.choice);

        // Store any notes from the dialogue
        if (choice.notes && dialogue.speaker_name) {
            this.memory.addNPCKnowledge(dialogue.speaker_name, choice.notes);
        }

        this.journal.logEvent("dialogue_choice", {
            speaker: dialogue.speaker_name,
            choice: choice.choice,
            reasoning: choice.reasoning,
        });

        await sleep(300);
    }

    // --- Barter handling ---

    private async handleBarter(state: GameplayBarterState): Promise<void> {
        // Guard: only handle barter once per barter session
        if (this.barterHandled) return;
        this.barterHandled = true;

        const action = await this.strategist.handleBarter(state);

        if (!action || action.action === "cancel") {
            this.log("Canceling barter");
            await this.sdk.barterCancel();
            await sleep(500);
            return;
        }

        // Add items to offer
        for (const item of action.items_to_offer) {
            await this.sdk.barterOffer(item.pid, item.quantity);
            await sleep(200);
        }

        // Add items to request
        for (const item of action.items_to_request) {
            await this.sdk.barterRequest(item.pid, item.quantity);
            await sleep(200);
        }

        // Confirm the trade
        await this.sdk.barterConfirm();
        await sleep(500);

        this.journal.logEvent("barter", {
            merchant: state.barter.merchant_name,
            action: action.action,
            offered: action.items_to_offer.length,
            requested: action.items_to_request.length,
        });
    }

    // --- Worldmap handling ---

    private async handleWorldmap(state: GameplayWorldmapState): Promise<void> {
        // If already walking, just wait
        if (state.worldmap.is_walking) {
            return;
        }

        // Get active objective
        const objective = this.objectives.getActive();

        if (objective?.type === "travel_to_location" && objective.target?.areaId !== undefined) {
            const result = await this.worldmap.travelTo(objective.target.areaId, state);
            if (result.status === "done") {
                this.objectives.complete(objective.id, state.tick);
            } else if (result.status === "blocked") {
                this.objectives.block(objective.id, result.reason);
            }
            return;
        }

        if (objective?.type === "enter_location" && objective.target?.areaId !== undefined) {
            const result = await this.worldmap.enterLocation(
                objective.target.areaId, state, objective.target.entrance
            );
            if (result.status === "done") {
                this.objectives.complete(objective.id, state.tick);
            } else if (result.status === "blocked") {
                this.objectives.block(objective.id, result.reason);
            }
            return;
        }

        // No worldmap objective — ask Claude what to do
        if (this.objectives.needsReEvaluation() && this.reEvalCooldown <= 0) {
            const result = await this.strategist.planWorldmapTravel(
                state, this.objectives.objectives
            );
            if (result.objectives.length > 0) {
                this.objectives.replaceAll(result.objectives);
                this.log(`Worldmap objectives: ${this.objectives.getSummary()}`);
            }
            this.reEvalCooldown = 10;
        }
    }

    // --- Character editor (unchanged from original) ---

    private charEditorAttempts = 0;

    private async handleCharacterEditor(state: CharEditorState): Promise<void> {
        if (this.charEditorAttempts >= 5) {
            this.log("Character editor: too many failed attempts, waiting...");
            await sleep(5000);
            this.charEditorAttempts = 0;
            return;
        }

        const response = await this.decideCharEditor(state);
        if (!response) {
            this.charEditorAttempts++;
            this.log(`Claude returned no response for character editor (attempt ${this.charEditorAttempts}/5), retrying in 2s...`);
            await sleep(2000);
            return;
        }
        this.charEditorAttempts = 0;

        if (response.thinking) {
            this.log("");
            this.logClaude(response.thinking);
            this.log("");
        }

        for (const group of response.action_groups) {
            if (group.narration) {
                this.logClaude(group.narration);
            }

            for (const action of group.actions) {
                this.log(`  → ${this.describeAction(action)}`);
                this.sdk.sendCommand(action);
                await sleep(this.actionDelay);
            }

            await sleep(200);
        }

        await sleep(500);

        const resultState = this.sdk.getState();
        if (resultState) {
            this.journal.log(state, response, resultState);
        }

        this.log("Waiting for context transition from character editor...");
        try {
            await this.sdk.waitForContextChange("character_editor", 15000);
        } catch {
            this.log("Warning: timeout waiting for context transition after editor_done");
        }
    }

    private async decideCharEditor(state: CharEditorState): Promise<AgentResponse | null> {
        const systemPrompt = getSystemPrompt("character_editor");
        const userPrompt = buildCharEditorPrompt(state);

        try {
            const message = await this.anthropic.messages.create({
                model: this.model,
                max_tokens: 4096,
                system: systemPrompt,
                messages: [{ role: "user", content: userPrompt }],
            });

            const text = message.content[0].type === "text"
                ? message.content[0].text
                : "";

            return this.parseResponse(text);
        } catch (err) {
            this.log(`Claude API error: ${err}`);
            return null;
        }
    }

    private parseResponse(text: string): AgentResponse | null {
        try {
            let cleaned = text.trim();
            if (cleaned.startsWith("```")) {
                cleaned = cleaned
                    .replace(/^```(?:json)?\s*\n?/, "")
                    .replace(/\n?```\s*$/, "");
            }

            const parsed = JSON.parse(cleaned) as AgentResponse;

            if (!parsed.action_groups || !Array.isArray(parsed.action_groups)) {
                this.log("Warning: response missing action_groups");
                return null;
            }

            return parsed;
        } catch (err) {
            this.log(`Failed to parse Claude response: ${err}`);
            this.log(`Raw response: ${text.substring(0, 500)}`);
            return null;
        }
    }

    // --- Logging helpers ---

    private describeAction(action: Command): string {
        switch (action.type) {
            case "adjust_stat":
                return `adjust_stat ${action.stat} ${action.direction}`;
            case "toggle_trait":
                return `toggle_trait ${action.trait}`;
            case "toggle_skill_tag":
                return `toggle_skill_tag ${action.skill}`;
            case "set_name":
                return `set_name "${action.name}"`;
            case "editor_done":
                return "editor_done";
            default:
                return JSON.stringify(action);
        }
    }

    private log(msg: string): void {
        console.log(`[Agent] ${msg}`);
    }

    private logClaude(msg: string): void {
        const lines = msg.split("\n");
        for (const line of lines) {
            console.log(`[Claude] ${line}`);
        }
    }
}
