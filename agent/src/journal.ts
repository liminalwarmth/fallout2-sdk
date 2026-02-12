import { appendFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import type { GameState } from "@fallout2-sdk/core";
import type { AgentResponse } from "./types.js";

export class Journal {
    private path: string;

    constructor(outputDir: string) {
        this.path = join(outputDir, "journal.jsonl");
        mkdirSync(dirname(this.path), { recursive: true });
    }

    log(
        state: GameState,
        response: AgentResponse,
        resultState?: GameState | null
    ): void {
        const entry = {
            timestamp: new Date().toISOString(),
            context: state.context,
            tick: state.tick,
            thinking: response.thinking,
            action_groups: response.action_groups.map((g) => ({
                narration: g.narration,
                action_count: g.actions.length,
            })),
            result_context: resultState?.context ?? null,
        };

        appendFileSync(this.path, JSON.stringify(entry) + "\n", "utf-8");
    }

    logEvent(event: string, details?: Record<string, unknown>): void {
        const entry = {
            timestamp: new Date().toISOString(),
            event,
            ...details,
        };

        appendFileSync(this.path, JSON.stringify(entry) + "\n", "utf-8");
    }
}
