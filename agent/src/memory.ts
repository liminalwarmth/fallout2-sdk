import type { ExitGridInfo, GroundItemInfo } from "@fallout2-sdk/core";

export interface MapMemory {
    mapName: string;
    elevation: number;
    visitedTiles: Set<number>;
    lootedContainers: Set<number>;
    openedDoors: Set<number>;
    failedLockpicks: Map<number, number>;
    talkedToNPCs: Set<number>;
    killedCritters: Set<number>;
    knownExits: ExitGridInfo[];
    discoveredItems: GroundItemInfo[];
    notes: string[];
}

function createMapMemory(mapName: string, elevation: number): MapMemory {
    return {
        mapName,
        elevation,
        visitedTiles: new Set(),
        lootedContainers: new Set(),
        openedDoors: new Set(),
        failedLockpicks: new Map(),
        talkedToNPCs: new Set(),
        killedCritters: new Set(),
        knownExits: [],
        discoveredItems: [],
        notes: [],
    };
}

export class GameMemory {
    private maps: Map<string, MapMemory> = new Map();
    questLog: string[] = [];
    npcKnowledge: Map<string, string> = new Map();
    private currentMap = "";
    private currentElevation = -1;

    /** Get a key string for a map+elevation combo */
    private mapKey(mapName: string, elevation: number): string {
        return `${mapName}:${elevation}`;
    }

    /** Get current map key */
    currentMapKey(): string {
        return this.mapKey(this.currentMap, this.currentElevation);
    }

    /** Get or create memory for a specific map */
    getOrCreate(mapName: string, elevation: number): MapMemory {
        const key = this.mapKey(mapName, elevation);
        let mem = this.maps.get(key);
        if (!mem) {
            mem = createMapMemory(mapName, elevation);
            this.maps.set(key, mem);
        }
        return mem;
    }

    /** Update current map tracking */
    setCurrentMap(mapName: string, elevation: number): void {
        this.currentMap = mapName;
        this.currentElevation = elevation;
    }

    /** Get memory for current map */
    getCurrentMap(): MapMemory | null {
        if (!this.currentMap) return null;
        return this.getOrCreate(this.currentMap, this.currentElevation);
    }

    /** Record that we visited a tile */
    visitTile(tile: number): void {
        const mem = this.getCurrentMap();
        if (mem) mem.visitedTiles.add(tile);
    }

    /** Record that we looted a container */
    markContainerLooted(objectId: number): void {
        const mem = this.getCurrentMap();
        if (mem) mem.lootedContainers.add(objectId);
    }

    /** Check if a container has been looted */
    isContainerLooted(objectId: number): boolean {
        const mem = this.getCurrentMap();
        return mem ? mem.lootedContainers.has(objectId) : false;
    }

    /** Record that we opened a door */
    markDoorOpened(objectId: number): void {
        const mem = this.getCurrentMap();
        if (mem) mem.openedDoors.add(objectId);
    }

    /** Record a failed lockpick attempt */
    recordLockpickFail(objectId: number): number {
        const mem = this.getCurrentMap();
        if (!mem) return 0;
        const count = (mem.failedLockpicks.get(objectId) ?? 0) + 1;
        mem.failedLockpicks.set(objectId, count);
        return count;
    }

    /** Get number of failed lockpick attempts */
    getLockpickAttempts(objectId: number): number {
        const mem = this.getCurrentMap();
        return mem ? (mem.failedLockpicks.get(objectId) ?? 0) : 0;
    }

    /** Record that we talked to an NPC */
    markNPCTalked(objectId: number): void {
        const mem = this.getCurrentMap();
        if (mem) mem.talkedToNPCs.add(objectId);
    }

    /** Check if we've talked to an NPC */
    hasNPCBeenTalked(objectId: number): boolean {
        const mem = this.getCurrentMap();
        return mem ? mem.talkedToNPCs.has(objectId) : false;
    }

    /** Record a killed critter */
    markCritterKilled(objectId: number): void {
        const mem = this.getCurrentMap();
        if (mem) mem.killedCritters.add(objectId);
    }

    /** Store exit grid info */
    recordExitGrids(exits: ExitGridInfo[]): void {
        const mem = this.getCurrentMap();
        if (mem) {
            // Replace with latest (dedup by tile)
            const seen = new Set(exits.map((e) => e.tile));
            mem.knownExits = [
                ...exits,
                ...mem.knownExits.filter((e) => !seen.has(e.tile)),
            ];
        }
    }

    /** Add NPC knowledge */
    addNPCKnowledge(npcName: string, knowledge: string): void {
        const existing = this.npcKnowledge.get(npcName);
        if (existing) {
            this.npcKnowledge.set(npcName, existing + "\n" + knowledge);
        } else {
            this.npcKnowledge.set(npcName, knowledge);
        }
    }

    /** Add a quest log entry */
    addQuestNote(note: string): void {
        this.questLog.push(note);
    }

    /** Add a note to current map */
    addMapNote(note: string): void {
        const mem = this.getCurrentMap();
        if (mem) mem.notes.push(note);
    }

    /** Check if this is a new map (not visited before) */
    isNewMap(mapName: string, elevation: number): boolean {
        return !this.maps.has(this.mapKey(mapName, elevation));
    }

    /** Get all visited map keys */
    getVisitedMaps(): string[] {
        return Array.from(this.maps.keys());
    }

    /** Get a summary of memory for a map (for Claude context) */
    getMapSummary(mapName: string, elevation: number): string {
        const mem = this.maps.get(this.mapKey(mapName, elevation));
        if (!mem) return "No prior knowledge of this area.";

        const parts: string[] = [];
        if (mem.visitedTiles.size > 0)
            parts.push(`${mem.visitedTiles.size} tiles explored`);
        if (mem.lootedContainers.size > 0)
            parts.push(`${mem.lootedContainers.size} containers looted`);
        if (mem.openedDoors.size > 0)
            parts.push(`${mem.openedDoors.size} doors opened`);
        if (mem.talkedToNPCs.size > 0)
            parts.push(`${mem.talkedToNPCs.size} NPCs talked to`);
        if (mem.killedCritters.size > 0)
            parts.push(`${mem.killedCritters.size} critters killed`);
        if (mem.knownExits.length > 0)
            parts.push(`${mem.knownExits.length} exits found`);
        if (mem.notes.length > 0)
            parts.push(`Notes: ${mem.notes.join("; ")}`);

        return parts.join(", ") || "Visited but nothing notable recorded.";
    }

    /** Get a compact summary of all memory for Claude context */
    getFullSummary(): string {
        const parts: string[] = [];

        if (this.questLog.length > 0) {
            parts.push("Quest notes: " + this.questLog.slice(-10).join("; "));
        }

        if (this.npcKnowledge.size > 0) {
            const npcSummary = Array.from(this.npcKnowledge.entries())
                .map(([name, info]) => `${name}: ${info}`)
                .join("\n  ");
            parts.push("NPC knowledge:\n  " + npcSummary);
        }

        const visitedMaps = this.getVisitedMaps();
        if (visitedMaps.length > 0) {
            parts.push("Visited maps: " + visitedMaps.join(", "));
        }

        return parts.join("\n") || "No memories yet.";
    }
}
