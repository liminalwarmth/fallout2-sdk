import type { FalloutSDK, GameplayCombatState, HostileInfo, CombatState } from "@fallout2-sdk/core";
import type { ExecutorContext, ExecutorResult } from "./types.js";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * CombatExecutor handles combat turns entirely deterministically.
 * No Claude calls — pure algorithmic target selection, AP management, and weapon use.
 */
export class CombatExecutor {
    private ctx: ExecutorContext;

    constructor(ctx: ExecutorContext) {
        this.ctx = ctx;
    }

    /** Execute a combat turn. Called when context is gameplay_combat. */
    async executeTurn(state: GameplayCombatState): Promise<ExecutorResult> {
        const combat = state.combat;
        const { sdk, log } = this.ctx;

        // Check if there are pending attacks (wait for animations)
        if (combat.pending_attacks > 0) {
            return { status: "working", message: "Waiting for attack animations..." };
        }

        // Check if animation is busy
        if (state.player.animation_busy) {
            return { status: "working", message: "Animation in progress..." };
        }

        const ap = combat.current_ap;
        const hostiles = combat.hostiles.filter((h) => h.hp > 0);

        // No hostiles — end turn
        if (hostiles.length === 0) {
            log("No hostiles remaining — ending turn");
            await sdk.endTurn();
            return { status: "done", message: "No hostiles, ended turn" };
        }

        // Check if we need healing (HP < 30%)
        const currentHp = state.character.derived_stats.current_hp ?? 0;
        const maxHp = state.character.derived_stats.max_hp;
        if (currentHp < maxHp * 0.3) {
            const healed = await this.tryHeal(state);
            if (healed) {
                return { status: "working", message: "Used healing item" };
            }
        }

        // Select target
        const target = this.selectTarget(hostiles, combat);
        if (!target) {
            log("No reachable target — ending turn");
            await sdk.endTurn();
            return { status: "done", message: "No reachable target" };
        }

        const weapon = combat.active_weapon;
        const primaryApCost = weapon.primary.ap_cost;
        const primaryRange = weapon.primary.range;

        // Can we attack the target?
        if (target.distance <= primaryRange && ap >= primaryApCost) {
            // Pick hit location
            const hitLocation = this.selectHitLocation(target);
            log(`Attacking ${target.name} (${target.hp}/${target.max_hp} HP) at ${hitLocation} — ${ap} AP`);
            await sdk.attack(target.id, hitLocation);
            await sleep(300);
            return { status: "working", message: `Attacking ${target.name}` };
        }

        // Can't reach — try to move closer
        const moveAp = ap - primaryApCost; // Save AP for at least one attack
        if (moveAp > 0 || combat.free_move > 0) {
            log(`Moving toward ${target.name} (dist: ${target.distance})`);
            await sdk.combatMove(target.tile);
            await sleep(300);
            return { status: "working", message: `Moving toward ${target.name}` };
        }

        // Not enough AP for anything useful
        log(`Not enough AP (${ap}) — ending turn`);
        await sdk.endTurn();
        return { status: "done", message: "Insufficient AP, ended turn" };
    }

    /** Select the best target to attack */
    private selectTarget(hostiles: HostileInfo[], combat: CombatState): HostileInfo | null {
        const range = combat.active_weapon.primary.range;

        // Priority 1: Wounded targets in range (finish them off)
        const woundedInRange = hostiles
            .filter((h) => h.distance <= range && h.hp < h.max_hp * 0.5)
            .sort((a, b) => a.hp - b.hp);
        if (woundedInRange.length > 0) return woundedInRange[0];

        // Priority 2: Any target in range (closest first)
        const inRange = hostiles
            .filter((h) => h.distance <= range)
            .sort((a, b) => a.distance - b.distance);
        if (inRange.length > 0) return inRange[0];

        // Priority 3: Closest target (we'll move toward them)
        const sorted = [...hostiles].sort((a, b) => a.distance - b.distance);
        return sorted[0] ?? null;
    }

    /** Select the best hit location based on chances */
    private selectHitLocation(target: HostileInfo): string {
        const chances = target.hit_chances;

        // If eyes chance is decent, go for eyes (big crit bonus)
        if (chances.eyes >= 60) return "eyes";

        // If target is low HP, use uncalled for reliability
        if (target.hp < target.max_hp * 0.3) return "uncalled";

        // If head chance is good, aim for head
        if (chances.head >= 50) return "head";

        // Default: uncalled shot (highest base chance)
        return "uncalled";
    }

    /** Try to use a healing item in combat */
    private async tryHeal(state: GameplayCombatState): Promise<boolean> {
        // Look for stimpaks (PID 40 = Stimpak, PID 144 = Super Stimpak)
        const stimpakPids = [40, 144];
        for (const pid of stimpakPids) {
            const hasItem = state.inventory.items.some(
                (i) => i.pid === pid && i.quantity > 0
            );
            if (hasItem && state.combat.current_ap >= 2) {
                this.ctx.log(`Using healing item (pid ${pid})`);
                await this.ctx.sdk.useCombatItem(pid);
                return true;
            }
        }
        return false;
    }
}
