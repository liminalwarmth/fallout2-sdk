import { resolve } from "node:path";
import { AgentWrapper } from "./wrapper.js";

const gameDir = resolve(process.argv[2] ?? "./game");
const outputDir = resolve(process.argv[3] ?? ".");

console.log(`[Agent] Game directory: ${gameDir}`);
console.log(`[Agent] Output directory: ${outputDir}`);
console.log(`[Agent] Model: ${process.env.ANTHROPIC_MODEL ?? "claude-sonnet-4-5-20250929"}`);
console.log("");

const wrapper = new AgentWrapper({
    gameDir,
    outputDir,
    actionDelay: 500,
    pollInterval: 200,
    model: process.env.ANTHROPIC_MODEL ?? "claude-sonnet-4-5-20250929",
});

// Graceful shutdown
process.on("SIGINT", () => {
    console.log("\n[Agent] Shutting down...");
    wrapper.stop();
});

process.on("SIGTERM", () => {
    wrapper.stop();
});

wrapper.run().then(() => {
    console.log("[Agent] Done.");
    process.exit(0);
}).catch((err) => {
    console.error("[Agent] Fatal error:", err);
    process.exit(1);
});
