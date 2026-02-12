import type { FalloutSDK, GameplayWorldmapState } from "@fallout2-sdk/core";
import type { ExecutorContext, ExecutorResult } from "./types.js";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * WorldMapExecutor handles overland travel and location entry.
 */
export class WorldMapExecutor {
    private ctx: ExecutorContext;
    private travelStarted = false;
    private travelTargetArea = -1;

    constructor(ctx: ExecutorContext) {
        this.ctx = ctx;
    }

    /** Travel to a worldmap area */
    async travelTo(areaId: number, state: GameplayWorldmapState): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        // Check if we're already at the target area
        if (state.worldmap.current_area_id === areaId) {
            return { status: "done", message: `Already at area ${areaId}` };
        }

        // Check if the area is known
        const location = state.worldmap.locations.find((l) => l.area_id === areaId);
        if (!location) {
            return { status: "blocked", reason: `Area ${areaId} is unknown` };
        }

        // If already walking toward this area, just wait
        if (state.worldmap.is_walking && this.travelStarted && this.travelTargetArea === areaId) {
            return { status: "working", message: `Traveling to ${location.name}...` };
        }

        // Start travel
        log(`Traveling to ${location.name} (area ${areaId})`);
        await sdk.worldmapTravel(areaId);
        this.travelStarted = true;
        this.travelTargetArea = areaId;
        await sleep(300);

        return { status: "working", message: `Traveling to ${location.name}` };
    }

    /** Enter a specific location (map) */
    async enterLocation(areaId: number, state: GameplayWorldmapState, entrance?: number): Promise<ExecutorResult> {
        const { sdk, log } = this.ctx;

        // Check if we're at the area
        if (state.worldmap.current_area_id !== areaId) {
            // Need to travel there first
            return this.travelTo(areaId, state);
        }

        const location = state.worldmap.locations.find((l) => l.area_id === areaId);
        const name = location?.name ?? `area ${areaId}`;

        log(`Entering ${name}${entrance !== undefined ? ` (entrance ${entrance})` : ""}`);
        await sdk.worldmapEnterLocation(areaId, entrance);
        this.travelStarted = false;
        await sleep(500);

        return { status: "done", message: `Entering ${name}` };
    }

    /** Reset travel state */
    reset(): void {
        this.travelStarted = false;
        this.travelTargetArea = -1;
    }
}
