import type { FalloutSDK, GameplayExplorationState, InventoryItem } from "@fallout2-sdk/core";
import type { ExecutorContext, ExecutorResult } from "./types.js";
import { NavigationExecutor } from "./navigation.js";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * InteractionExecutor handles talking to NPCs, using items/skills on objects,
 * healing, and equipment management.
 */
export class InteractionExecutor {
    private ctx: ExecutorContext;
    private navigator: NavigationExecutor;

    constructor(ctx: ExecutorContext, navigator: NavigationExecutor) {
        this.ctx = ctx;
        this.navigator = navigator;
    }

    /** Navigate to an NPC and start talking */
    async talkTo(objectId: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log, memory } = this.ctx;

        const npc = state.objects.critters.find((c) => c.id === objectId);
        if (!npc) {
            return { status: "blocked", reason: `NPC ${objectId} not found` };
        }

        if (npc.dead) {
            return { status: "blocked", reason: `${npc.name} is dead` };
        }

        // If close enough, talk
        if (npc.distance <= 3) {
            log(`Talking to ${npc.name}`);
            await sdk.talkTo(objectId);
            memory.markNPCTalked(objectId);
            await sleep(500);
            return { status: "done", message: `Talking to ${npc.name}` };
        }

        // Navigate to NPC
        return this.navigator.navigateTo(npc.tile, state);
    }

    /** Use an item on an object (e.g., dynamite on door) */
    async useItemOn(itemPid: number, objectId: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        // Check we have the item
        const hasItem = state.inventory.items.some((i) => i.pid === itemPid);
        if (!hasItem) {
            return { status: "blocked", reason: `Don't have item PID ${itemPid} in inventory` };
        }

        // Find the target object
        const target = findObjectById(state, objectId);
        if (!target) {
            return { status: "blocked", reason: `Target object ${objectId} not found` };
        }

        // If close enough, use item on target
        if (target.distance <= 3) {
            log(`Using item ${itemPid} on ${target.name}`);
            await sdk.useItemOn(itemPid, objectId);
            await sleep(800);
            return { status: "done", message: `Used item on ${target.name}` };
        }

        // Navigate to target
        return this.navigator.navigateTo(target.tile, state);
    }

    /** Use a skill on an object (e.g., lockpick on door) */
    async useSkillOn(skillName: string, objectId: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        const target = findObjectById(state, objectId);
        if (!target) {
            return { status: "blocked", reason: `Target object ${objectId} not found` };
        }

        // If close enough, use skill
        if (target.distance <= 3) {
            log(`Using ${skillName} on ${target.name}`);
            await sdk.useSkillOn(skillName, objectId);
            await sleep(800);
            return { status: "done", message: `Used ${skillName} on ${target.name}` };
        }

        // Navigate to target
        return this.navigator.navigateTo(target.tile, state);
    }

    /** Heal using the best available healing item */
    async heal(state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        // Priority order: Super Stimpak, Stimpak, First Aid Kit, Healing Powder
        const healingItems = [
            { pid: 144, name: "Super Stimpak" },
            { pid: 40, name: "Stimpak" },
            { pid: 408, name: "First Aid Kit" },
            { pid: 273, name: "Healing Powder" },
        ];

        for (const item of healingItems) {
            const hasItem = state.inventory.items.some(
                (i) => i.pid === item.pid && i.quantity > 0
            );
            if (hasItem) {
                log(`Using ${item.name}`);
                await sdk.useItem(item.pid);
                await sleep(500);
                return { status: "done", message: `Used ${item.name}` };
            }
        }

        return { status: "blocked", reason: "No healing items available" };
    }

    /** Equip the best available gear */
    async equipBestGear(state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        // Find best weapon and equip it
        const weapons = state.inventory.items.filter((i) => i.type === "weapon");
        if (weapons.length > 0 && !state.inventory.equipped.right_hand) {
            const weapon = weapons[0]; // TODO: pick best weapon
            log(`Equipping ${weapon.name}`);
            await sdk.equipItem(weapon.pid, "right");
            await sleep(300);
            return { status: "working", message: `Equipping ${weapon.name}` };
        }

        // Find best armor and equip it
        const armors = state.inventory.items.filter((i) => i.type === "armor");
        if (armors.length > 0 && !state.inventory.equipped.armor) {
            const armor = armors[0]; // TODO: pick best armor
            log(`Equipping ${armor.name}`);
            await sdk.equipItem(armor.pid, "armor");
            await sleep(300);
            return { status: "working", message: `Equipping ${armor.name}` };
        }

        return { status: "done", message: "Already equipped with best available gear" };
    }

    /** Use an object (generic interaction) */
    async useObject(objectId: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        const target = findObjectById(state, objectId);
        if (!target) {
            return { status: "blocked", reason: `Object ${objectId} not found` };
        }

        if (target.distance <= 3) {
            log(`Using ${target.name}`);
            await sdk.useObject(objectId);
            await sleep(500);
            return { status: "done", message: `Used ${target.name}` };
        }

        return this.navigator.navigateTo(target.tile, state);
    }
}

/** Find any object by ID in the current state */
function findObjectById(
    state: GameplayExplorationState,
    objectId: number
): { name: string; tile: number; distance: number } | null {
    const critter = state.objects.critters.find((c) => c.id === objectId);
    if (critter) return critter;

    const item = state.objects.ground_items.find((i) => i.id === objectId);
    if (item) return item;

    const scenery = state.objects.scenery.find((s) => s.id === objectId);
    if (scenery) return scenery;

    return null;
}
