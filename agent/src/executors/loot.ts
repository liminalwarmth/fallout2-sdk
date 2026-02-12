import type { FalloutSDK, GameplayLootState, GameplayExplorationState } from "@fallout2-sdk/core";
import type { ExecutorContext, ExecutorResult } from "./types.js";
import { NavigationExecutor } from "./navigation.js";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * LootExecutor handles looting containers and picking up ground items.
 */
export class LootExecutor {
    private ctx: ExecutorContext;
    private navigator: NavigationExecutor;

    constructor(ctx: ExecutorContext, navigator: NavigationExecutor) {
        this.ctx = ctx;
        this.navigator = navigator;
    }

    /** Handle the loot screen when it's already open */
    async handleLootScreen(state: GameplayLootState): Promise<ExecutorResult> {
        const { sdk, log, memory } = this.ctx;
        const loot = state.loot;

        if (loot.container_items.length > 0) {
            log(`Taking all ${loot.container_items.length} items from ${loot.target_name}`);
            await sdk.lootTakeAll();
            await sleep(300);
        }

        // Close the loot screen
        log("Closing loot screen");
        await sdk.lootClose();
        await sleep(300);

        // Mark container as looted
        memory.markContainerLooted(loot.target_id);

        return { status: "done", message: `Looted ${loot.target_name}` };
    }

    /** Navigate to and loot a container */
    async lootContainer(objectId: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log, memory } = this.ctx;

        // Already looted?
        if (memory.isContainerLooted(objectId)) {
            return { status: "done", message: "Container already looted" };
        }

        // Find the container in scenery (containers are scenery objects, not ground items)
        const container = state.objects.scenery.find((s) => s.id === objectId);

        if (!container) {
            return { status: "blocked", reason: `Container ${objectId} not found in current objects` };
        }

        // If we're close enough, open it
        if (container.distance <= 3) {
            log(`Opening container: ${container.name}`);
            await sdk.openContainer(objectId);
            await sleep(500);
            return { status: "working", message: `Opening ${container.name}` };
        }

        // Navigate to the container
        return this.navigator.navigateTo(container.tile, state);
    }

    /** Navigate to and pick up a ground item */
    async pickUpItem(objectId: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        const item = state.objects.ground_items.find((i) => i.id === objectId);
        if (!item) {
            return { status: "blocked", reason: `Item ${objectId} not found on ground` };
        }

        // If close enough, pick it up
        if (item.distance <= 3) {
            log(`Picking up: ${item.name}`);
            await sdk.pickUp(objectId);
            await sleep(500);
            return { status: "done", message: `Picked up ${item.name}` };
        }

        // Navigate to the item
        return this.navigator.navigateTo(item.tile, state);
    }
}
