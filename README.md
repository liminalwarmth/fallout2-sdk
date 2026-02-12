# fallout2-sdk

A Claude Code Gameplay Enablement Project that allows [Claude](https://claude.ai/) to play Fallout 2.

## Overview

fallout2-sdk bridges Claude Code and Fallout 2 by modifying the [Fallout 2 Community Edition (CE)](https://github.com/alexbatalov/fallout2-ce) open-source engine to emit structured game state information that Claude can read and act upon. This enables Claude to observe the game world, reason about it, and issue commands — effectively playing Fallout 2 autonomously.

## How It Works

1. **Game State Emission** — A modified Fallout 2 CE build exports game state (map, inventory, dialogue, combat, NPCs, etc.) in a machine-readable format.
2. **Claude Code Integration** — Claude reads the emitted game state, reasons about objectives and tactics, and sends input commands back to the game.
3. **Gameplay Loop** — The observe → reason → act loop runs continuously, allowing Claude to navigate the wasteland, engage in dialogue, manage inventory, and fight through encounters.

## Project Status

Early development. Not yet playable.

## License

This project is licensed under the [MIT License](LICENSE).
