---
name: run-codex
description: >
  Send a prompt to Codex (OpenAI) and get a response. Use for code review, refactoring,
  architecture questions, or any task where a second model's perspective is valuable.
  Synthesize Codex output with your own analysis.
allowed-tools: Bash, Read
argument-hint: "<prompt>"
---

# Codex CLI

Send `$ARGUMENTS` as a prompt to Codex via `codex exec`. The entire argument string is the prompt — no mode parsing needed.

## How to run

```bash
cd "$(git rev-parse --show-toplevel)"
OUTFILE=$(mktemp /tmp/codex_result.XXXXXX)
/opt/homebrew/bin/codex exec "$ARGUMENTS" \
  -m gpt-5.3-codex \
  -c model_reasoning_effort="xhigh" \
  --ephemeral --full-auto \
  -o "$OUTFILE" 2>&1
```

Read `$OUTFILE` for the output. If the exit code is non-zero, read `$OUTFILE` for the error.

## After running

1. Present Codex's output under a **Codex** heading
2. Add your own take under a **Claude** heading
3. Note agreements, disagreements (with resolution), and blind spots
4. List concrete next steps
