#!/usr/bin/env bash
# Check (or sync) duplicated bridge sources between top-level src/ and engine copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SRC_DIR="$ROOT/src"
ENGINE_SRC_DIR="$ROOT/engine/fallout2-ce/src"

# Only headers are duplicated — .cc files exist only in src/ and are referenced by path in CMakeLists
FILES=(
  agent_bridge.h
  agent_bridge_internal.h
)

SYNC=0
if [ "${1:-}" = "--sync" ]; then
  SYNC=1
fi

if [ ! -d "$ENGINE_SRC_DIR" ]; then
  echo "Engine source dir not found: $ENGINE_SRC_DIR"
  exit 2
fi

drift=0
for f in "${FILES[@]}"; do
  a="$SRC_DIR/$f"
  b="$ENGINE_SRC_DIR/$f"

  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    echo "Missing file pair: $a / $b"
    drift=1
    continue
  fi

  if ! cmp -s "$a" "$b"; then
    drift=1
    echo "DRIFT: $f"
    if [ "$SYNC" -eq 1 ]; then
      cp "$a" "$b"
      echo "  synced -> $b"
    else
      diff -u "$b" "$a" | sed -n '1,120p' || true
    fi
  fi
done

if [ "$drift" -eq 0 ]; then
  echo "OK: bridge sources are in sync."
  exit 0
fi

if [ "$SYNC" -eq 1 ]; then
  echo "DONE: drift resolved by syncing top-level sources into engine copy."
  exit 0
fi

echo "FAIL: bridge source drift detected. Run scripts/check_bridge_source_drift.sh --sync to sync."
exit 1
