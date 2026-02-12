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

    /** Wait for player animation to finish (animation_busy === false) */
    async waitForIdle(timeoutMs = 10000): Promise<GameState> {
        return this.ipc.waitForStateChange((s) => {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const player = (s as any)?.player;
            return player !== undefined && !player.animation_busy;
        }, timeoutMs);
    }

    /** Wait for combat to become the player's turn */
    async waitForCombatTurn(timeoutMs = 30000): Promise<GameState> {
        return this.ipc.waitForStateChange(
            (s) => s.context === "gameplay_combat",
            timeoutMs
        );
    }

    /** Wait for the context to change away from a given context */
    async waitForContextChange(from: string, timeoutMs = 15000): Promise<GameState> {
        return this.ipc.waitForStateChange(
            (s) => s.context !== from,
            timeoutMs
        );
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
        this.ipc.sendCommand({ type: "skip" });
    }

    async mainMenuSelect(option: string): Promise<void> {
        this.ipc.sendCommand({ type: "main_menu_select", option });
    }

    async charSelectorSelect(option: string): Promise<void> {
        this.ipc.sendCommand({ type: "char_selector_select", option });
    }

    // --- Movement ---

    async moveTo(tile: number): Promise<void> {
        this.ipc.sendCommand({ type: "move_to", tile });
    }

    async runTo(tile: number): Promise<void> {
        this.ipc.sendCommand({ type: "run_to", tile });
    }

    async combatMove(tile: number): Promise<void> {
        this.ipc.sendCommand({ type: "combat_move", tile });
    }

    // --- Combat ---

    async attack(targetId: number, hitLocation?: string, hitMode?: string): Promise<void> {
        this.ipc.sendCommands([{
            type: "attack",
            target_id: targetId,
            ...(hitLocation ? { hit_location: hitLocation } : {}),
            ...(hitMode ? { hit_mode: hitMode } : {}),
        } as Command]);
    }

    async endTurn(): Promise<void> {
        this.ipc.sendCommand({ type: "end_turn" });
    }

    async switchHand(): Promise<void> {
        this.ipc.sendCommand({ type: "switch_hand" });
    }

    async cycleAttackMode(): Promise<void> {
        this.ipc.sendCommand({ type: "cycle_attack_mode" });
    }

    async enterCombat(): Promise<void> {
        this.ipc.sendCommand({ type: "enter_combat" });
    }

    async fleeCombat(): Promise<void> {
        this.ipc.sendCommand({ type: "flee_combat" });
    }

    async useCombatItem(itemPid: number): Promise<void> {
        this.ipc.sendCommand({ type: "use_combat_item", item_pid: itemPid });
    }

    // --- Interaction ---

    async talkTo(objectId: number): Promise<void> {
        this.ipc.sendCommand({ type: "talk_to", object_id: objectId });
    }

    async useObject(objectId: number): Promise<void> {
        this.ipc.sendCommand({ type: "use_object", object_id: objectId });
    }

    async useSkillOn(skill: string, objectId: number): Promise<void> {
        this.ipc.sendCommand({ type: "use_skill", skill, object_id: objectId });
    }

    async useItemOn(itemPid: number, objectId: number): Promise<void> {
        this.ipc.sendCommand({ type: "use_item_on", item_pid: itemPid, object_id: objectId });
    }

    async pickUp(objectId: number): Promise<void> {
        this.ipc.sendCommand({ type: "pick_up", object_id: objectId });
    }

    async lookAt(objectId: number): Promise<void> {
        this.ipc.sendCommand({ type: "look_at", object_id: objectId });
    }

    async selectDialogue(index: number): Promise<void> {
        this.ipc.sendCommand({ type: "select_dialogue", index });
    }

    // --- Inventory ---

    async equipItem(itemPid: number, hand: string): Promise<void> {
        this.ipc.sendCommand({ type: "equip_item", item_pid: itemPid, hand });
    }

    async unequipItem(hand: string): Promise<void> {
        this.ipc.sendCommand({ type: "unequip_item", hand });
    }

    async useItem(itemPid: number): Promise<void> {
        this.ipc.sendCommand({ type: "use_item", item_pid: itemPid });
    }

    async reloadWeapon(): Promise<void> {
        this.ipc.sendCommand({ type: "reload_weapon" });
    }

    async dropItem(itemPid: number, quantity?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "drop_item",
            item_pid: itemPid,
            ...(quantity !== undefined ? { quantity } : {}),
        } as Command]);
    }

    async armExplosive(itemPid: number): Promise<void> {
        this.ipc.sendCommand({ type: "arm_explosive", item_pid: itemPid });
    }

    // --- Containers/Loot ---

    async openContainer(objectId: number): Promise<void> {
        this.ipc.sendCommand({ type: "open_container", object_id: objectId });
    }

    async lootTake(itemPid: number, quantity?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "loot_take",
            item_pid: itemPid,
            ...(quantity !== undefined ? { quantity } : {}),
        } as Command]);
    }

    async lootTakeAll(): Promise<void> {
        this.ipc.sendCommand({ type: "loot_take_all" });
    }

    async lootClose(): Promise<void> {
        this.ipc.sendCommand({ type: "loot_close" });
    }

    // --- Barter ---

    async barterOffer(itemPid: number, quantity?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "barter_offer",
            item_pid: itemPid,
            ...(quantity !== undefined ? { quantity } : {}),
        } as Command]);
    }

    async barterRemoveOffer(itemPid: number, quantity?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "barter_remove_offer",
            item_pid: itemPid,
            ...(quantity !== undefined ? { quantity } : {}),
        } as Command]);
    }

    async barterRequest(itemPid: number, quantity?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "barter_request",
            item_pid: itemPid,
            ...(quantity !== undefined ? { quantity } : {}),
        } as Command]);
    }

    async barterRemoveRequest(itemPid: number, quantity?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "barter_remove_request",
            item_pid: itemPid,
            ...(quantity !== undefined ? { quantity } : {}),
        } as Command]);
    }

    async barterConfirm(): Promise<void> {
        this.ipc.sendCommand({ type: "barter_confirm" });
    }

    async barterTalk(): Promise<void> {
        this.ipc.sendCommand({ type: "barter_talk" });
    }

    async barterCancel(): Promise<void> {
        this.ipc.sendCommand({ type: "barter_cancel" });
    }

    // --- World map ---

    async worldmapTravel(areaId: number): Promise<void> {
        this.ipc.sendCommand({ type: "worldmap_travel", area_id: areaId });
    }

    async worldmapEnterLocation(areaId: number, entrance?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "worldmap_enter_location",
            area_id: areaId,
            ...(entrance !== undefined ? { entrance } : {}),
        } as Command]);
    }

    // --- Map navigation ---

    async mapTransition(map?: number, tile?: number, elevation?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "map_transition",
            ...(map !== undefined ? { map } : {}),
            ...(tile !== undefined ? { tile } : {}),
            ...(elevation !== undefined ? { elevation } : {}),
        } as Command]);
    }

    // --- Level-up ---

    async skillAdd(skill: string): Promise<void> {
        this.ipc.sendCommand({ type: "skill_add", skill });
    }

    async skillSub(skill: string): Promise<void> {
        this.ipc.sendCommand({ type: "skill_sub", skill });
    }

    async perkAdd(perkId: number): Promise<void> {
        this.ipc.sendCommand({ type: "perk_add", perk_id: perkId });
    }

    // --- Interface ---

    async centerCamera(): Promise<void> {
        this.ipc.sendCommand({ type: "center_camera" });
    }

    async rest(hours?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "rest",
            ...(hours !== undefined ? { hours } : {}),
        } as Command]);
    }

    async pipBoy(): Promise<void> {
        this.ipc.sendCommand({ type: "pip_boy" });
    }

    async characterScreen(): Promise<void> {
        this.ipc.sendCommand({ type: "character_screen" });
    }

    async inventoryOpen(): Promise<void> {
        this.ipc.sendCommand({ type: "inventory_open" });
    }

    async skilldex(): Promise<void> {
        this.ipc.sendCommand({ type: "skilldex" });
    }

    async toggleSneak(): Promise<void> {
        this.ipc.sendCommand({ type: "toggle_sneak" });
    }

    // --- Save/Load ---

    async quicksave(): Promise<void> {
        this.ipc.sendCommand({ type: "quicksave" });
    }

    async quickload(): Promise<void> {
        this.ipc.sendCommand({ type: "quickload" });
    }

    async saveSlot(slot: number, description?: string): Promise<void> {
        this.ipc.sendCommands([{
            type: "save_slot",
            slot,
            ...(description ? { description } : {}),
        } as Command]);
    }

    async loadSlot(slot: number): Promise<void> {
        this.ipc.sendCommand({ type: "load_slot", slot });
    }

    // --- Main menu load game ---

    async mainMenuLoadGame(slot?: number): Promise<void> {
        this.ipc.sendCommands([{
            type: "main_menu",
            action: "load_game",
            ...(slot !== undefined ? { slot } : {}),
        } as Command]);
    }
}
