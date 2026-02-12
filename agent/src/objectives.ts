export type ObjectiveType =
    | "talk_to_npc"
    | "navigate_to_tile"
    | "navigate_to_exit"
    | "loot_container"
    | "pick_up_item"
    | "use_item_on"
    | "use_skill_on"
    | "explore_area"
    | "enter_worldmap"
    | "travel_to_location"
    | "enter_location"
    | "heal"
    | "equip_gear"
    | "rest"
    | "custom";

export type ObjectiveStatus = "pending" | "active" | "completed" | "blocked" | "abandoned";

export interface ObjectiveTarget {
    objectId?: number;
    tile?: number;
    npcName?: string;
    itemPid?: number;
    areaId?: number;
    entrance?: number;
    exitGridTile?: number;
    skillName?: string;
    description?: string;
}

export interface Objective {
    id: string;
    type: ObjectiveType;
    description: string;
    priority: number; // 1 = highest
    status: ObjectiveStatus;
    target?: ObjectiveTarget;
    reason?: string;
    blockedReason?: string;
    completedAt?: number;
    createdAt: number;
}

let nextId = 1;

function generateId(): string {
    return `obj_${nextId++}`;
}

export class ObjectiveManager {
    objectives: Objective[] = [];
    private completedLog: Objective[] = [];

    /** Get the highest-priority actionable objective */
    getActive(): Objective | null {
        // First check if there's already an active one
        const active = this.objectives.find((o) => o.status === "active");
        if (active) return active;

        // Otherwise activate the highest-priority pending one
        const pending = this.objectives
            .filter((o) => o.status === "pending")
            .sort((a, b) => a.priority - b.priority);

        if (pending.length > 0) {
            pending[0].status = "active";
            return pending[0];
        }

        return null;
    }

    /** Mark an objective as completed */
    complete(id: string, tick?: number): void {
        const obj = this.objectives.find((o) => o.id === id);
        if (obj) {
            obj.status = "completed";
            obj.completedAt = tick ?? Date.now();
            this.completedLog.push(obj);
        }
    }

    /** Mark an objective as blocked */
    block(id: string, reason: string): void {
        const obj = this.objectives.find((o) => o.id === id);
        if (obj) {
            obj.status = "blocked";
            obj.blockedReason = reason;
        }
    }

    /** Abandon an objective */
    abandon(id: string, reason?: string): void {
        const obj = this.objectives.find((o) => o.id === id);
        if (obj) {
            obj.status = "abandoned";
            obj.blockedReason = reason;
        }
    }

    /** Replace all objectives with a new set from Claude */
    replaceAll(newObjectives: Objective[]): void {
        // Move any non-completed objectives to abandoned
        for (const obj of this.objectives) {
            if (obj.status === "pending" || obj.status === "active") {
                obj.status = "abandoned";
            }
        }
        this.objectives = newObjectives;
    }

    /** Add objectives to the existing list */
    addObjectives(newObjectives: Objective[]): void {
        this.objectives.push(...newObjectives);
    }

    /** Check if we need Claude to re-evaluate (all done or blocked) */
    needsReEvaluation(): boolean {
        const actionable = this.objectives.filter(
            (o) => o.status === "pending" || o.status === "active"
        );
        return actionable.length === 0;
    }

    /** Get recently completed objectives (for reporting to Claude) */
    getRecentlyCompleted(count = 5): Objective[] {
        return this.completedLog.slice(-count);
    }

    /** Get blocked objectives (for reporting to Claude) */
    getBlocked(): Objective[] {
        return this.objectives.filter((o) => o.status === "blocked");
    }

    /** Get a summary of current state for logging */
    getSummary(): string {
        const active = this.objectives.filter((o) => o.status === "active");
        const pending = this.objectives.filter((o) => o.status === "pending");
        const blocked = this.objectives.filter((o) => o.status === "blocked");
        const completed = this.objectives.filter((o) => o.status === "completed");

        const parts: string[] = [];
        if (active.length > 0) parts.push(`active: ${active.map((o) => o.description).join(", ")}`);
        if (pending.length > 0) parts.push(`${pending.length} pending`);
        if (blocked.length > 0) parts.push(`${blocked.length} blocked`);
        if (completed.length > 0) parts.push(`${completed.length} completed`);

        return parts.join(" | ") || "no objectives";
    }
}

/** Create an Objective from Claude's JSON response */
export function createObjective(
    type: ObjectiveType,
    description: string,
    priority: number,
    target?: ObjectiveTarget,
    reason?: string
): Objective {
    return {
        id: generateId(),
        type,
        description,
        priority,
        status: "pending",
        target,
        reason,
        createdAt: Date.now(),
    };
}

/** Parse objectives from Claude's JSON response */
export function parseObjectives(data: unknown[]): Objective[] {
    const objectives: Objective[] = [];

    for (const item of data) {
        const obj = item as Record<string, unknown>;
        const type = (obj["type"] as ObjectiveType) || "custom";
        const description = (obj["description"] as string) || "Unknown objective";
        const priority = (obj["priority"] as number) || 5;
        const reason = obj["reason"] as string | undefined;
        const target = obj["target"] as ObjectiveTarget | undefined;

        objectives.push(createObjective(type, description, priority, target, reason));
    }

    return objectives;
}
