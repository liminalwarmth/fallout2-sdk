import Anthropic from "@anthropic-ai/sdk";
import type {
    GameState,
    GameplayExplorationState,
    GameplayCombatState,
    GameplayDialogueState,
    GameplayBarterState,
    GameplayWorldmapState,
} from "@fallout2-sdk/core";
import type { Objective } from "./objectives.js";
import { parseObjectives } from "./objectives.js";
import { GameMemory } from "./memory.js";
import {
    getSystemPrompt,
    buildSurveyPrompt,
    buildDialoguePrompt,
    buildReEvaluatePrompt,
    buildBarterPrompt,
    buildWorldmapPrompt,
} from "./prompts.js";

export interface BarterAction {
    action: "buy" | "sell" | "cancel";
    items_to_offer: Array<{ pid: number; quantity: number }>;
    items_to_request: Array<{ pid: number; quantity: number }>;
    notes?: string;
}

export interface DialogueChoice {
    choice: number;
    reasoning: string;
    notes?: string;
}

export interface StrategistOptions {
    model: string;
    memory: GameMemory;
    onLog?: (msg: string) => void;
}

export class Strategist {
    private anthropic: Anthropic;
    private memory: GameMemory;
    private model: string;
    private conversationHistory: Array<{ role: "user" | "assistant"; content: string }> = [];
    private onLog: (msg: string) => void;

    constructor(options: StrategistOptions) {
        this.anthropic = new Anthropic();
        this.memory = options.memory;
        this.model = options.model;
        this.onLog = options.onLog ?? (() => {});
    }

    /** Called when entering a new map — full survey and objective setting */
    async surveyAndPlan(
        state: GameplayExplorationState | GameplayCombatState,
        currentObjectives: Objective[]
    ): Promise<{ objectives: Objective[]; notes?: string }> {
        const systemPrompt = getSystemPrompt("survey");
        const userPrompt = buildSurveyPrompt(state, this.memory, currentObjectives);

        this.onLog("Calling Claude for map survey...");
        const response = await this.callClaude(systemPrompt, userPrompt);
        if (!response) {
            return { objectives: [] };
        }

        const parsed = this.parseJSON(response);
        if (!parsed) return { objectives: [] };

        if (parsed.thinking) {
            this.onLog(`[Claude] ${parsed.thinking}`);
        }

        const objectives = parseObjectives(
            Array.isArray(parsed.objectives) ? parsed.objectives : []
        );
        return {
            objectives,
            notes: parsed.notes as string | undefined,
        };
    }

    /** Called when current objective completes or is blocked */
    async reEvaluate(
        state: GameplayExplorationState | GameplayCombatState | GameplayWorldmapState,
        currentObjectives: Objective[],
        trigger: string,
        completedObjective?: Objective,
        blockedObjective?: Objective
    ): Promise<{ objectives: Objective[]; notes?: string }> {
        const systemPrompt = getSystemPrompt("reevaluate");
        const userPrompt = buildReEvaluatePrompt(
            state, this.memory, currentObjectives, trigger,
            completedObjective, blockedObjective
        );

        this.onLog(`Calling Claude for re-evaluation (trigger: ${trigger})...`);
        const response = await this.callClaude(systemPrompt, userPrompt);
        if (!response) return { objectives: [] };

        const parsed = this.parseJSON(response);
        if (!parsed) return { objectives: [] };

        if (parsed.thinking) {
            this.onLog(`[Claude] ${parsed.thinking}`);
        }

        const objectives = parseObjectives(
            Array.isArray(parsed.objectives) ? parsed.objectives : []
        );
        return {
            objectives,
            notes: parsed.notes as string | undefined,
        };
    }

    /** Called for dialogue choices */
    async chooseDialogue(
        state: GameplayDialogueState,
        objectives: Objective[]
    ): Promise<DialogueChoice | null> {
        const systemPrompt = getSystemPrompt("dialogue");
        const userPrompt = buildDialoguePrompt(state, this.memory, objectives);

        this.onLog("Calling Claude for dialogue choice...");
        const response = await this.callClaude(systemPrompt, userPrompt);
        if (!response) return null;

        const parsed = this.parseJSON(response);
        if (!parsed) return null;

        if (parsed.reasoning) {
            this.onLog(`[Claude] ${parsed.reasoning}`);
        }

        return {
            choice: (parsed.choice ?? 0) as number,
            reasoning: (parsed.reasoning ?? "") as string,
            notes: parsed.notes as string | undefined,
        };
    }

    /** Called for barter decisions */
    async handleBarter(
        state: GameplayBarterState
    ): Promise<BarterAction | null> {
        const systemPrompt = getSystemPrompt("barter");
        const userPrompt = buildBarterPrompt(state, this.memory);

        this.onLog("Calling Claude for barter decision...");
        const response = await this.callClaude(systemPrompt, userPrompt);
        if (!response) return null;

        const parsed = this.parseJSON(response);
        if (!parsed) return null;

        if (parsed.thinking) {
            this.onLog(`[Claude] ${parsed.thinking}`);
        }

        return {
            action: ((parsed.action ?? "cancel") as string) as BarterAction["action"],
            items_to_offer: (parsed.items_to_offer ?? []) as BarterAction["items_to_offer"],
            items_to_request: (parsed.items_to_request ?? []) as BarterAction["items_to_request"],
            notes: parsed.notes as string | undefined,
        };
    }

    /** Called on worldmap for travel decisions */
    async planWorldmapTravel(
        state: GameplayWorldmapState,
        objectives: Objective[]
    ): Promise<{ objectives: Objective[]; notes?: string }> {
        const systemPrompt = getSystemPrompt("survey");
        const userPrompt = buildWorldmapPrompt(state, this.memory, objectives);

        this.onLog("Calling Claude for worldmap planning...");
        const response = await this.callClaude(systemPrompt, userPrompt);
        if (!response) return { objectives: [] };

        const parsed = this.parseJSON(response);
        if (!parsed) return { objectives: [] };

        if (parsed.thinking) {
            this.onLog(`[Claude] ${parsed.thinking}`);
        }

        const objectives2 = parseObjectives(
            Array.isArray(parsed.objectives) ? parsed.objectives : []
        );
        return {
            objectives: objectives2,
            notes: parsed.notes as string | undefined,
        };
    }

    // --- Internal helpers ---

    private async callClaude(systemPrompt: string, userPrompt: string): Promise<string | null> {
        // Add to conversation history for context continuity
        this.conversationHistory.push({ role: "user", content: userPrompt });

        // Keep conversation history manageable (last 10 exchanges)
        if (this.conversationHistory.length > 20) {
            this.conversationHistory = this.conversationHistory.slice(-20);
        }

        try {
            const message = await this.anthropic.messages.create({
                model: this.model,
                max_tokens: 4096,
                system: systemPrompt,
                messages: this.conversationHistory,
            });

            const text = message.content[0].type === "text"
                ? message.content[0].text
                : "";

            // Add assistant response to history
            this.conversationHistory.push({ role: "assistant", content: text });

            return text;
        } catch (err) {
            this.onLog(`Claude API error: ${err}`);
            // Remove the failed user message from history
            this.conversationHistory.pop();
            return null;
        }
    }

    private parseJSON(text: string): Record<string, unknown> | null {
        try {
            let cleaned = text.trim();
            if (cleaned.startsWith("```")) {
                cleaned = cleaned
                    .replace(/^```(?:json)?\s*\n?/, "")
                    .replace(/\n?```\s*$/, "");
            }
            return JSON.parse(cleaned);
        } catch (err) {
            this.onLog(`Failed to parse Claude response: ${err}`);
            this.onLog(`Raw: ${text.substring(0, 200)}`);
            return null;
        }
    }

    /** Reset conversation history (e.g., on major context change) */
    resetHistory(): void {
        this.conversationHistory = [];
    }
}
