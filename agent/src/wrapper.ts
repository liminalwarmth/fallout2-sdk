import Anthropic from "@anthropic-ai/sdk";
import { FalloutSDK } from "@fallout2-sdk/core";
import type { GameState, CharEditorState, Command } from "@fallout2-sdk/core";
import { getSystemPrompt, buildPrompt } from "./prompts.js";
import { Journal } from "./journal.js";
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
    private lastContext = "";
    private contextHandled = false;

    constructor(options: WrapperOptions) {
        this.sdk = new FalloutSDK(options.gameDir);
        this.journal = new Journal(options.outputDir);
        this.anthropic = new Anthropic();
        this.actionDelay = options.actionDelay ?? 500;
        this.pollInterval = options.pollInterval ?? 200;
        this.model = options.model ?? "claude-sonnet-4-5-20250929";
    }

    async run(): Promise<void> {
        this.running = true;
        this.log("Agent wrapper started");
        this.journal.logEvent("agent_started", { model: this.model });

        while (this.running) {
            const state = this.sdk.getState();
            if (!state) {
                await sleep(this.pollInterval);
                continue;
            }

            // Detect context transitions
            if (state.context !== this.lastContext) {
                this.lastContext = state.context;
                this.contextHandled = false;
            }

            if (!this.contextHandled) {
                await this.handleContext(state);
            }
            await sleep(this.pollInterval);
        }
    }

    stop(): void {
        this.running = false;
    }

    private async handleContext(state: GameState): Promise<void> {
        switch (state.context) {
            case "movie":
                // Don't mark as handled — movies repeat (intro sequence)
                // so we keep sending escape until the context changes
                this.log("Skipping movie...");
                await this.sdk.skipMovie();
                await sleep(1000);
                break;

            case "main_menu":
                this.log("Main menu → selecting New Game");
                await this.sdk.mainMenuSelect("new_game");
                this.contextHandled = true;
                await sleep(2000);
                break;

            case "character_selector":
                this.log("Character selector → creating custom character");
                await this.sdk.charSelectorSelect("create_custom");
                this.contextHandled = true;
                await sleep(2000);
                break;

            case "character_editor":
                this.log("Character editor → asking Claude to create a character...");
                this.contextHandled = true;
                await this.handleCharacterEditor(state as CharEditorState);
                break;

            case "gameplay":
                this.log("Gameplay — character is in the game world!");
                this.logCharacterSummary(state);
                this.journal.logEvent("gameplay_reached");
                this.contextHandled = true;
                this.running = false;
                break;

            default:
                break;
        }
    }

    private async handleCharacterEditor(state: CharEditorState): Promise<void> {
        const response = await this.decide(state);
        if (!response) {
            this.log("Claude returned no response, retrying...");
            return;
        }

        // Print Claude's overall thinking
        if (response.thinking) {
            this.log("");
            this.logClaude(response.thinking);
            this.log("");
        }

        // Execute action groups with narration
        for (const group of response.action_groups) {
            if (group.narration) {
                this.logClaude(group.narration);
            }

            for (const action of group.actions) {
                await this.executeAction(action, state);
                await sleep(this.actionDelay);
            }

            // Brief pause between groups
            await sleep(200);
        }

        // Wait for state to settle after all actions
        await sleep(500);

        // Read final state and log result
        const resultState = this.sdk.getState();
        if (resultState) {
            this.journal.log(state, response, resultState);
        }

        // After character creation, wait for context to change
        // (editor_done triggers context transition)
        this.log("Waiting for context transition...");
        try {
            await this.sdk.waitForStateChange(
                (s) => s.context !== "character_editor",
                15000
            );
        } catch {
            this.log("Warning: timeout waiting for context transition after editor_done");
        }
    }

    private async decide(state: GameState): Promise<AgentResponse | null> {
        const systemPrompt = getSystemPrompt(state.context);
        const userPrompt = buildPrompt(state);

        try {
            const message = await this.anthropic.messages.create({
                model: this.model,
                max_tokens: 4096,
                system: systemPrompt,
                messages: [{ role: "user", content: userPrompt }],
            });

            const text =
                message.content[0].type === "text"
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
            // Strip markdown code fences if present
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

    private async executeAction(
        action: Command,
        _state: GameState
    ): Promise<void> {
        const desc = this.describeAction(action);
        this.log(`  → ${desc}`);
        this.sdk.sendCommand(action);
    }

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
            case "key_press":
                return `key_press ${action.key}`;
            case "main_menu_select":
                return `main_menu_select ${action.option}`;
            case "char_selector_select":
                return `char_selector_select ${action.option}`;
            default:
                return JSON.stringify(action);
        }
    }

    private logCharacterSummary(state: GameState): void {
        if (state.context !== "gameplay" && state.context !== "character_editor")
            return;
        const c = (state as CharEditorState).character;
        if (!c) return;

        const s = c.special;
        this.log(
            `Character: "${c.name}" S${s.strength}/P${s.perception}/E${s.endurance}/C${s.charisma}/I${s.intelligence}/A${s.agility}/L${s.luck}`
        );
        if (c.traits.length > 0) {
            this.log(`Traits: ${c.traits.join(", ")}`);
        }
        if (c.tagged_skills.length > 0) {
            this.log(`Tagged: ${c.tagged_skills.join(", ")}`);
        }
    }

    private log(msg: string): void {
        console.log(`[Agent] ${msg}`);
    }

    private logClaude(msg: string): void {
        // Wrap long lines for readability
        const lines = msg.split("\n");
        for (const line of lines) {
            console.log(`[Claude] ${line}`);
        }
    }
}
