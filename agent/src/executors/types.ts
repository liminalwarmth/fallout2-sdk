import type { FalloutSDK, GameState } from "@fallout2-sdk/core";
import type { GameMemory } from "../memory.js";

export type ExecutorResult =
    | { status: "done"; message?: string }
    | { status: "working"; message?: string }
    | { status: "blocked"; reason: string }
    | { status: "error"; reason: string };

export interface ExecutorContext {
    sdk: FalloutSDK;
    memory: GameMemory;
    log: (msg: string) => void;
}
