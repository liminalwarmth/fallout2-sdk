#!/usr/bin/env bash
# Regenerate engine patches from current submodule modifications.
# Run this after making changes to files inside engine/fallout2-ce/.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/engine/patches"
ENGINE_DIR="$REPO_ROOT/engine/fallout2-ce"

mkdir -p "$PATCH_DIR"

cd "$ENGINE_DIR"
if git diff HEAD --quiet; then
    echo "No modifications in engine submodule. Nothing to generate."
    exit 0
fi

PATCH_FILE="$PATCH_DIR/fallout2-ce-agent-bridge.patch"
git diff HEAD > "$PATCH_FILE"
lines=$(wc -l < "$PATCH_FILE")
echo "Generated $PATCH_FILE ($lines lines)"
echo ""
echo "Files modified:"
git diff HEAD --stat
