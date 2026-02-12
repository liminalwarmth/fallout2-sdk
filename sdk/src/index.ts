import { FileIPC } from "./ipc.js";
import type { GameState, Command } from "./types.js";

export { FileIPC } from "./ipc.js";
export type * from "./types.js";

export class FalloutSDK {
    private ipc: FileIPC;

    constructor(gameDir: string) {
        this.ipc = new FileIPC(gameDir);
    }

    // --- State reading ---

    getState(): GameState | null {
        return this.ipc.readState();
    }

    async waitForContext(ctx: string, timeoutMs?: number): Promise<GameState> {
        return this.ipc.waitForContext(ctx, timeoutMs);
    }

    async waitForStateChange(
        predicate: (s: GameState) => boolean,
        timeoutMs?: number
    ): Promise<GameState> {
        return this.ipc.waitForStateChange(predicate, timeoutMs);
    }

    async waitForTick(afterTick: number, timeoutMs?: number): Promise<GameState> {
        return this.ipc.waitForTick(afterTick, timeoutMs);
    }

    // --- Raw commands ---

    sendCommand(cmd: Command): void {
        this.ipc.sendCommand(cmd);
    }

    sendCommands(cmds: Command[]): void {
        this.ipc.sendCommands(cmds);
    }

    // --- Character editor (UI-level) ---

    async adjustStat(stat: string, direction: "up" | "down"): Promise<void> {
        this.ipc.sendCommand({ type: "adjust_stat", stat, direction });
    }

    async toggleTrait(trait: string): Promise<void> {
        this.ipc.sendCommand({ type: "toggle_trait", trait });
    }

    async toggleSkillTag(skill: string): Promise<void> {
        this.ipc.sendCommand({ type: "toggle_skill_tag", skill });
    }

    async setName(name: string): Promise<void> {
        this.ipc.sendCommand({ type: "set_name", name });
    }

    async finishCharacterCreation(): Promise<void> {
        this.ipc.sendCommand({ type: "editor_done" });
    }

    // --- Navigation ---

    async skipMovie(): Promise<void> {
        this.ipc.sendCommand({ type: "key_press", key: "escape" });
    }

    async mainMenuSelect(option: string): Promise<void> {
        this.ipc.sendCommand({ type: "main_menu_select", option });
    }

    async charSelectorSelect(option: string): Promise<void> {
        this.ipc.sendCommand({ type: "char_selector_select", option });
    }
}
