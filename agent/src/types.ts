import type { Command } from "@fallout2-sdk/core";

export interface ActionGroup {
    narration: string;
    actions: Command[];
}

export interface AgentResponse {
    thinking: string;
    action_groups: ActionGroup[];
}
