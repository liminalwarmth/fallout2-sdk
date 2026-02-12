import type { FalloutSDK, GameplayExplorationState, SceneryInfo } from "@fallout2-sdk/core";
import type { ExecutorContext, ExecutorResult } from "./types.js";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * NavigationExecutor handles pathfinding to tiles, door handling, and stuck detection.
 */
export class NavigationExecutor {
    private ctx: ExecutorContext;
    private lastTile = -1;
    private stuckCount = 0;
    private movementStarted = false;

    constructor(ctx: ExecutorContext) {
        this.ctx = ctx;
    }

    /** Navigate toward a target tile. Returns when arrived or blocked. */
    async navigateTo(targetTile: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log, memory } = this.ctx;
        const player = state.player;

        // Already there?
        if (player.tile === targetTile) {
            this.resetStuck();
            return { status: "done", message: `Arrived at tile ${targetTile}` };
        }

        // Wait if animation is busy
        if (player.animation_busy) {
            return { status: "working", message: "Moving..." };
        }

        // Wait if movement is in progress
        if (player.movement_waypoints_remaining && player.movement_waypoints_remaining > 0) {
            return { status: "working", message: `Moving... (${player.movement_waypoints_remaining} waypoints remaining)` };
        }

        // Check if we're stuck (same tile after starting movement, not animating)
        if (this.movementStarted && player.tile === this.lastTile && !player.animation_busy) {
            this.stuckCount++;
            if (this.stuckCount >= 5) {
                this.resetStuck();
                // Check if there's a door blocking the way
                const blockingDoor = this.findBlockingDoor(state, targetTile);
                if (blockingDoor) {
                    return await this.handleDoor(blockingDoor, state);
                }
                return { status: "blocked", reason: `Stuck at tile ${player.tile}, can't reach tile ${targetTile}` };
            }
        }

        // Record current tile and start movement
        this.lastTile = player.tile;
        this.movementStarted = true;

        // Track visited tile
        memory.visitTile(player.tile);

        // Send run_to command
        log(`Running toward tile ${targetTile} from current ${player.tile}`);
        await sdk.runTo(targetTile);
        await sleep(200);

        return { status: "working", message: `Moving to tile ${targetTile}` };
    }

    /** Explore toward a tile we haven't visited */
    async exploreToward(targetTile: number, state: GameplayExplorationState): Promise<ExecutorResult> {
        return this.navigateTo(targetTile, state);
    }

    /** Reset stuck detection state (call when starting a new navigation objective) */
    resetStuck(): void {
        this.lastTile = -1;
        this.stuckCount = 0;
        this.movementStarted = false;
    }

    /** Find a door that might be blocking our path */
    private findBlockingDoor(state: GameplayExplorationState, targetTile: number): SceneryInfo | null {
        // Look for nearby closed doors
        const doors = state.objects.scenery.filter(
            (s) => s.scenery_type === "door" && !s.open && s.distance <= 5
        );

        if (doors.length === 0) return null;

        // Return closest door
        return doors.sort((a, b) => a.distance - b.distance)[0];
    }

    /** Handle a blocking door — try to open or lockpick */
    private async handleDoor(door: SceneryInfo, state: GameplayExplorationState): Promise<ExecutorResult> {
        const { sdk, log, memory } = this.ctx;

        if (!door.locked) {
            // Door is closed but not locked — just open it
            log(`Opening door: ${door.name} (tile ${door.tile})`);
            await sdk.useObject(door.id);
            memory.markDoorOpened(door.id);
            await sleep(500);
            return { status: "working", message: `Opening door ${door.name}` };
        }

        // Door is locked — try lockpick
        const attempts = memory.getLockpickAttempts(door.id);
        if (attempts >= 3) {
            return { status: "blocked", reason: `Door ${door.name} is locked — lockpick failed ${attempts} times` };
        }

        log(`Lockpicking door: ${door.name} (attempt ${attempts + 1}/3)`);
        await sdk.useSkillOn("lockpick", door.id);
        await sleep(800);

        // Check if it worked by reading state
        const newState = sdk.getState();
        if (newState && "objects" in newState) {
            const updatedDoor = (newState as GameplayExplorationState).objects.scenery.find(
                (s) => s.id === door.id
            );
            if (updatedDoor && !updatedDoor.locked) {
                log(`Lockpick succeeded on ${door.name}!`);
                await sdk.useObject(door.id);
                memory.markDoorOpened(door.id);
                await sleep(500);
                return { status: "working", message: `Unlocked and opened ${door.name}` };
            }
        }

        memory.recordLockpickFail(door.id);
        return { status: "working", message: `Lockpick attempt on ${door.name}` };
    }
}
