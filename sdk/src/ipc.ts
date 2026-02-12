import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join } from "node:path";
import type { GameState, Command } from "./types.js";

export class FileIPC {
    private statePath: string;
    private cmdPath: string;
    private cmdTmpPath: string;

    constructor(private gameDir: string) {
        this.statePath = join(gameDir, "agent_state.json");
        this.cmdPath = join(gameDir, "agent_cmd.json");
        this.cmdTmpPath = join(gameDir, "agent_cmd.tmp");
    }

    readState(): GameState | null {
        try {
            if (!existsSync(this.statePath)) return null;
            const content = readFileSync(this.statePath, "utf-8");
            return JSON.parse(content) as GameState;
        } catch {
            return null;
        }
    }

    sendCommand(command: Command): void {
        this.sendCommands([command]);
    }

    sendCommands(commands: Command[]): void {
        const doc = { commands };
        const content = JSON.stringify(doc, null, 2);
        writeFileSync(this.cmdTmpPath, content, "utf-8");
        renameSync(this.cmdTmpPath, this.cmdPath);
    }

    async waitForContext(
        target: string,
        timeoutMs = 30000
    ): Promise<GameState> {
        const start = Date.now();
        while (Date.now() - start < timeoutMs) {
            const state = this.readState();
            if (state && state.context === target) return state;
            await sleep(100);
        }
        throw new Error(
            `Timeout waiting for context '${target}' after ${timeoutMs}ms`
        );
    }

    async waitForStateChange(
        predicate: (s: GameState) => boolean,
        timeoutMs = 10000
    ): Promise<GameState> {
        const start = Date.now();
        while (Date.now() - start < timeoutMs) {
            const state = this.readState();
            if (state && predicate(state)) return state;
            await sleep(100);
        }
        throw new Error(`Timeout waiting for state change after ${timeoutMs}ms`);
    }

    async waitForTick(afterTick: number, timeoutMs = 5000): Promise<GameState> {
        return this.waitForStateChange((s) => s.tick > afterTick, timeoutMs);
    }
}

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
