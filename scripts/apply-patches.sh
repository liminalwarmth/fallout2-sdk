#!/usr/bin/env bash
# Apply engine patches to the fallout2-ce submodule.
# Safe to run multiple times — checks if already applied.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/engine/patches"
ENGINE_DIR="$REPO_ROOT/engine/fallout2-ce"

# Ensure submodule is initialized
if [ ! -f "$ENGINE_DIR/CMakeLists.txt" ]; then
    echo "Initializing submodule..."
    git -C "$REPO_ROOT" submodule update --init --recursive
fi

for patch in "$PATCH_DIR"/*.patch; do
    [ -f "$patch" ] || continue
    name=$(basename "$patch")
    # Check if already applied (reverse-apply test)
    if git -C "$ENGINE_DIR" apply --reverse --check "$patch" 2>/dev/null; then
        echo "Already applied: $name"
    else
        echo "Applying: $name"
        git -C "$ENGINE_DIR" apply "$patch"
    fi
done

echo "Engine patches applied."
