#!/usr/bin/env python3
"""Helpers for executor_dialogue.sh.

Keeps heavy dialogue/persona JSON/text processing out of shell heredocs.
"""

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List


def _load_json(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def _load_json_array(path: str) -> List[Any]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return data
    except Exception:
        pass
    return []


def _write_json(path: str, data: Any) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f)


def cmd_append_history(args: argparse.Namespace) -> int:
    state = _load_json(args.state)
    history = _load_json_array(args.history)

    dlg = state.get("dialogue", {})
    reply = str(dlg.get("reply_text", ""))[:200]
    options = dlg.get("options", [])
    idx = args.index

    option_text = ""
    if isinstance(options, list) and 0 <= idx < len(options):
        opt = options[idx]
        if isinstance(opt, str):
            option_text = opt
        elif isinstance(opt, dict):
            option_text = str(opt.get("text", "?"))
    option_text = option_text[:120]

    history.append(
        {
            "reply": reply,
            "selected": idx,
            "option_text": option_text,
        }
    )
    _write_json(args.history, history)
    return 0


def _quest_summary(q: Dict[str, Any]) -> str:
    name = str(q.get("name", "?") or "?")
    loc = str(q.get("location", "") or "")
    desc = str(q.get("description", "") or "")
    loc_str = f" ({loc})" if loc else ""
    return f"{name}{loc_str} -- {desc[:60]}"


def cmd_assess(args: argparse.Namespace) -> int:
    state = _load_json(args.state)
    dlg = state.get("dialogue", {})
    speaker = str(dlg.get("speaker_name", "Unknown"))
    reply = str(dlg.get("reply_text", ""))
    options = dlg.get("options", [])
    map_name = str(state.get("map", {}).get("name", "?"))

    print("=== DIALOGUE ===")
    print(f"NPC: {speaker} | Map: {map_name}")
    if reply:
        print(f'Reply: "{reply}"')
    if isinstance(options, list) and options:
        print("Options:")
        for i, opt in enumerate(options):
            text = opt if isinstance(opt, str) else str(opt.get("text", "?"))
            print(f'  [{i}] "{text}"')
    print()

    history = _load_json_array(args.history)
    if history:
        print("--- CONVERSATION SO FAR ---")
        for i, h in enumerate(history):
            h_reply = str(h.get("reply", "..."))[:80]
            h_opt = str(h.get("option_text", "?"))[:60]
            print(f'  ({i + 1}) "{h_reply}" -> You chose: "{h_opt}"')
        print()

    ch = state.get("character", {})
    ds = ch.get("derived_stats", {})
    inv = state.get("inventory", {})
    equipped = inv.get("equipped", {})
    weapon = "unarmed"
    for slot in ("right_hand", "left_hand"):
        eq = equipped.get(slot)
        if eq:
            weapon = str(eq.get("name", weapon))
            break
    armor_eq = equipped.get("armor")
    armor = str(armor_eq.get("name", "none")) if armor_eq else "none"
    caps = sum(
        int(it.get("quantity", 0))
        for it in inv.get("items", [])
        if int(it.get("pid", -1)) == 41
    )

    print("--- CHARACTER STATE ---")
    print(
        f'  HP: {ds.get("current_hp", "?")}/{ds.get("max_hp", "?")} | '
        f'Level: {ch.get("level", "?")} | Caps: {caps}'
    )
    print(f"  Weapon: {weapon} | Armor: {armor}")
    print()

    quests = state.get("quests", [])
    active = [q for q in quests if not q.get("completed", False)]
    if active:
        print("--- ACTIVE QUESTS ---")
        for q in active:
            print(f"  {_quest_summary(q)}")
        print()

    try:
        with open(args.objectives, "r", encoding="utf-8") as f:
            objectives = [line.strip() for line in f if line.strip()]
    except Exception:
        objectives = []

    if objectives:
        print("--- SUB-OBJECTIVES ---")
        for obj in objectives:
            print(f"  {obj}")
        print()

    print("--- REMINDERS ---")
    print('  You can RECALL knowledge: recall "keyword" to search notes')
    print("  You can BARTER with this NPC: select barter option or use barter command")
    print('  You can NOTE anything interesting: note "category" "text"')
    return 0


def _persona_name_and_voice(path: str) -> (str, str):
    name = "Wanderer"
    persona = "sarcastic, witty, audacious rogue with main-character energy"
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        m = re.search(r"^# (.+)", text, re.MULTILINE)
        if m:
            name = m.group(1).strip()
        parts = []
        for section in ("Personality", "Values", "Dialogue Style"):
            m = re.search(rf"## {re.escape(section)}\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
            if m:
                parts.append(m.group(1).strip())
        if parts:
            persona = " | ".join(parts)
    except Exception:
        pass
    return name, persona


def cmd_muse_prompt(args: argparse.Namespace) -> int:
    state = _load_json(args.state)
    dlg = state.get("dialogue", {})
    speaker = str(dlg.get("speaker_name", "Unknown"))
    reply = str(dlg.get("reply_text", ""))
    options = dlg.get("options", [])
    map_name = str(state.get("map", {}).get("name", "?"))

    if not reply and not options:
        return 0

    name, persona = _persona_name_and_voice(args.persona)

    history = _load_json_array(args.history)
    history_str = ""
    if history:
        lines = []
        for h in history[-5:]:
            lines.append(
                f'NPC: "{str(h.get("reply", "..."))[:60]}" -> '
                f'You chose: "{str(h.get("option_text", "?"))[:40]}"'
            )
        history_str = "\n".join(lines)

    opt_lines = []
    if isinstance(options, list):
        for i, opt in enumerate(options):
            text = opt if isinstance(opt, str) else str(opt.get("text", "?"))
            opt_lines.append(f'[{i}] "{text}"')
    options_str = "\n".join(opt_lines)

    ch = state.get("character", {})
    ds = ch.get("derived_stats", {})
    inv = state.get("inventory", {})
    equipped = inv.get("equipped", {})
    weapon = "unarmed"
    for slot in ("right_hand", "left_hand"):
        eq = equipped.get(slot)
        if eq:
            weapon = str(eq.get("name", weapon))
            break
    armor_eq = equipped.get("armor")
    armor = str(armor_eq.get("name", "none")) if armor_eq else "none"
    caps = sum(
        int(it.get("quantity", 0))
        for it in inv.get("items", [])
        if int(it.get("pid", -1)) == 41
    )

    quests = state.get("quests", [])
    active = [q for q in quests if not q.get("completed", False)]
    quest_str = ", ".join(
        str(q.get("name") or q.get("description", "?"))[:40] for q in active[:5]
    ) if active else "none"

    try:
        with open(args.objectives, "r", encoding="utf-8") as f:
            objectives = [line.strip() for line in f if line.strip()]
        obj_str = ", ".join(objectives[:5]) if objectives else "none"
    except Exception:
        obj_str = "none"

    if history_str:
        hist_block = f"Conversation so far:\n{history_str}"
    else:
        hist_block = "This is the start of the conversation."

    prompt = (
        f"You are {name}. Voice: {persona}\n\n"
        f"Talking to {speaker} in {map_name}.\n"
        f"{hist_block}\n"
        f'Current NPC reply: "{reply[:200]}"\n'
        f"Your options:\n{options_str}\n\n"
        f"Your quests: {quest_str}\n"
        f"Your goals right now: {obj_str}\n"
        f'Your state: HP {ds.get("current_hp", "?")}/{ds.get("max_hp", "?")}, '
        f"Caps {caps}, wearing {armor}, wielding {weapon}\n\n"
        "Write a short in-character inner thought (under 25 words) reacting to these "
        "dialogue options. What catches your eye? What matters given your goals? "
        "No quotes, no narration."
    )
    print(prompt)
    return 0


def cmd_history_summary(args: argparse.Namespace) -> int:
    history = _load_json_array(args.history)
    if not history:
        return 0
    lines = []
    for h in history:
        reply = str(h.get("reply", ""))[:80]
        opt = str(h.get("option_text", ""))[:60]
        lines.append(f'  NPC: "{reply}" -> Chose: "{opt}"')
    print("\n".join(lines))
    return 0


def cmd_persona_section(args: argparse.Namespace) -> int:
    try:
        with open(args.persona, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        print("Persona file not found", file=sys.stderr)
        return 1

    pattern = rf"(## {re.escape(args.section)}\b.*?)(?=\n## |\Z)"
    m = re.search(pattern, content, re.DOTALL)
    if not m:
        print(f'Section "{args.section}" not found')
        return 1
    print(m.group(1).strip())
    return 0


def cmd_persona_append_evolution(args: argparse.Namespace) -> int:
    try:
        with open(args.persona, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return 1

    marker = "## Evolution Log"
    entry = args.entry
    idx = content.find(marker)
    if idx == -1:
        content = content.rstrip() + "\n\n## Evolution Log\n\n" + entry + "\n"
    else:
        next_sec = content.find("\n## ", idx + len(marker))
        if next_sec == -1:
            content = content.rstrip() + "\n" + entry + "\n"
        else:
            content = content[:next_sec] + entry + "\n" + content[next_sec:]

    with open(args.persona, "w", encoding="utf-8") as f:
        f.write(content)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Dialogue helper commands")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("append-history")
    p.add_argument("--state", required=True)
    p.add_argument("--history", required=True)
    p.add_argument("--index", required=True, type=int)
    p.set_defaults(func=cmd_append_history)

    p = sub.add_parser("assess")
    p.add_argument("--state", required=True)
    p.add_argument("--history", required=True)
    p.add_argument("--objectives", required=True)
    p.set_defaults(func=cmd_assess)

    p = sub.add_parser("muse-prompt")
    p.add_argument("--state", required=True)
    p.add_argument("--history", required=True)
    p.add_argument("--persona", required=True)
    p.add_argument("--objectives", required=True)
    p.set_defaults(func=cmd_muse_prompt)

    p = sub.add_parser("history-summary")
    p.add_argument("--history", required=True)
    p.set_defaults(func=cmd_history_summary)

    p = sub.add_parser("persona-section")
    p.add_argument("--persona", required=True)
    p.add_argument("--section", required=True)
    p.set_defaults(func=cmd_persona_section)

    p = sub.add_parser("persona-append-evolution")
    p.add_argument("--persona", required=True)
    p.add_argument("--entry", required=True)
    p.set_defaults(func=cmd_persona_append_evolution)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
