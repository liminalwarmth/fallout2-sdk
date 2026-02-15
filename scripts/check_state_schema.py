#!/usr/bin/env python3
"""Lightweight schema-contract checks for game/agent_state.json."""

import argparse
import json
import sys
from typing import Any, Dict, List


def err(errors: List[str], path: str, msg: str) -> None:
    errors.append(f"{path}: {msg}")


def ensure_type(errors: List[str], obj: Dict[str, Any], key: str, typ, path: str) -> None:
    if key not in obj:
        err(errors, f"{path}.{key}", "missing")
        return
    if not isinstance(obj[key], typ):
        err(errors, f"{path}.{key}", f"expected {typ.__name__}, got {type(obj[key]).__name__}")


def check_dialogue_contract(data: Dict[str, Any], errors: List[str]) -> None:
    ctx = str(data.get("context", ""))
    in_dialogue = "dialogue" in ctx
    dlg = data.get("dialogue")
    if in_dialogue and not isinstance(dlg, dict):
        err(errors, "dialogue", "required object when context contains 'dialogue'")
        return
    if not isinstance(dlg, dict):
        return
    ensure_type(errors, dlg, "speaker_name", str, "dialogue")
    options = dlg.get("options")
    if options is not None and not isinstance(options, list):
        err(errors, "dialogue.options", f"expected list, got {type(options).__name__}")


def check_quests_contract(data: Dict[str, Any], errors: List[str]) -> None:
    quests = data.get("quests")
    if quests is None:
        return
    if not isinstance(quests, list):
        err(errors, "quests", f"expected list, got {type(quests).__name__}")
        return
    for i, q in enumerate(quests):
        path = f"quests[{i}]"
        if not isinstance(q, dict):
            err(errors, path, f"expected object, got {type(q).__name__}")
            continue
        ensure_type(errors, q, "location", str, path)
        ensure_type(errors, q, "description", str, path)
        ensure_type(errors, q, "completed", bool, path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate bridge state schema contracts")
    parser.add_argument("--state", required=True, help="Path to agent_state.json")
    args = parser.parse_args()

    try:
        with open(args.state, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"FAIL: unable to read state file: {e}")
        return 2

    if not isinstance(data, dict):
        print("FAIL: root must be a JSON object")
        return 2

    errors: List[str] = []
    check_dialogue_contract(data, errors)
    check_quests_contract(data, errors)

    if errors:
        print("FAIL: schema contract violations")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("OK: state schema contracts passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
