---
name: run-codex
description: >
  Invoke Codex (OpenAI) for cross-model code review, refactoring suggestions, or architectural input.
  Use by default for: code reviews of significant changes, refactoring plans, and design/architecture questions.
  Synthesize Codex output with your own analysis — flag agreements, disagreements, and blind spots.
allowed-tools: Bash, Read
argument-hint: "review [instructions] | refactor <description> | ask <question>"
---

# Cross-Model Collaboration via Codex CLI

Parse `$ARGUMENTS` to determine the mode (first word) and prompt (remainder).

## Common flags

All modes use: `-m gpt-5.3-codex -c model_reasoning_effort="xhigh" --ephemeral --full-auto`

## Mode: `review`

Run a code review of uncommitted changes. The remainder of `$ARGUMENTS` after "review" is an optional custom review prompt (passed as positional `[PROMPT]` to `codex exec review`).

`codex exec review` does NOT support `-o`, so redirect stdout to a temp file and strip noise lines.

```bash
cd "$(git rev-parse --show-toplevel)"
OUTFILE="$(mktemp /tmp/codex_review.XXXXXX.txt)"
CUSTOM="<remainder after 'review', if any>"

# With custom instructions (positional prompt):
/opt/homebrew/bin/codex exec review --uncommitted "$CUSTOM" \
  -m gpt-5.3-codex -c model_reasoning_effort="xhigh" \
  --ephemeral --full-auto > "$OUTFILE" 2>&1

# Without custom instructions (omit the positional arg entirely):
/opt/homebrew/bin/codex exec review --uncommitted \
  -m gpt-5.3-codex -c model_reasoning_effort="xhigh" \
  --ephemeral --full-auto > "$OUTFILE" 2>&1

# Strip codex CLI noise from the captured output:
grep -E -v '^(20[0-9]{2}-|tokens|OpenAI|---|workdir|model:|provider|approval|sandbox|reasoning|session|user$|mcp |$)' "$OUTFILE"
```

Then read the grep output. If the codex command exited non-zero, report the error from `$OUTFILE`.

## Mode: `refactor`

Get refactoring suggestions. The remainder of `$ARGUMENTS` after "refactor" is the description.

```bash
cd "$(git rev-parse --show-toplevel)"
OUTFILE="$(mktemp /tmp/codex_refactor.XXXXXX.txt)"
PROMPT="<remainder after 'refactor'>"
/opt/homebrew/bin/codex exec "$PROMPT" \
  -m gpt-5.3-codex -c model_reasoning_effort="xhigh" \
  --ephemeral --full-auto \
  -o "$OUTFILE" 2>&1
```

Then read `$OUTFILE` for the clean output.

## Mode: `ask`

Ask a codebase question or get architectural input. The remainder of `$ARGUMENTS` after "ask" is the question.

```bash
cd "$(git rev-parse --show-toplevel)"
OUTFILE="$(mktemp /tmp/codex_ask.XXXXXX.txt)"
PROMPT="<remainder after 'ask'>"
/opt/homebrew/bin/codex exec "$PROMPT" \
  -m gpt-5.3-codex -c model_reasoning_effort="xhigh" \
  --ephemeral --full-auto \
  -o "$OUTFILE" 2>&1
```

Then read `$OUTFILE` for the clean output.

## After Running Codex

1. Present Codex's output clearly under a **Codex Analysis** heading
2. Add your own analysis under a **Claude Analysis** heading
3. Synthesize under a **Synthesis** heading — explicitly note:
   - **Agreements**: Points both models align on
   - **Disagreements**: Where your assessment differs, and why — resolve each one with a decision
   - **Blind spots**: Anything one model caught that the other missed
4. Provide a final **Recommendations** list — each item should be a concrete, actionable next step
