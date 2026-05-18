---
name: code-reviewer-add-agent
description: Add a review agent to the active agent list. Supported agents are claude, codex, gemini, and opencode.
argument-hint: <agent-name>
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)", "Bash(echo * | codex *)", "Bash(echo * | gemini *)", "Bash(printf * | opencode *)", Read, AskUserQuestion]
---

# Add Agent

Agent name: $ARGUMENTS

Supported agents: `claude`, `codex`, `gemini`, `opencode`

## Instructions

### Step 0 — Check setup

Read `~/.code-reviewer/config.json`. If it does not exist, tell the user:
> "code-reviewer has not been set up yet. Run `/code-reviewer:setup` first."
Then stop.

### Step 1 — Verify the agent CLI is installed

Run a quick smoke test to confirm the CLI tool is available and working.

**`claude`:** Already running (you are Claude). Skip the smoke test — just add it.

**`codex`:**
```bash
echo "Say hello" | codex -a never exec -s read-only --ephemeral --color never -
```

**`gemini`:** Read `~/.code-reviewer/config.json` to get `gemini_model` (default: `gemini-2.5-flash`), then run:
```bash
echo "Say hello" | gemini -p "" -m <model> -o text --approval-mode yolo
```

**`opencode`:**
```bash
printf 'Reply with exactly: HELLO\n' | timeout 30 opencode run --model openai/gpt-5.5 --format json | jq -r 'select(.type == "text") | .part.text'
```

opencode reads `OPENAI_API_KEY` from the environment. If the smoke test fails
with an auth error, remind the user to either `export OPENAI_API_KEY=sk-...`
in their shell rc or run `opencode auth`.

### Step 2 — Handle smoke test result

**Succeeded** (exit 0, produced output): proceed to Step 3.

**Failed / command not found:** tell the user the CLI is not installed or not
working. Install hints:

- **codex**: `npm install -g @openai/codex`. Verify with `codex --version`.
- **gemini**: `npm install -g @anthropic-ai/gemini-cli`. Verify with `gemini --version`.
- **opencode**: install from https://opencode.ai or `npm install -g opencode-ai`, then verify with `opencode --version` and ensure `OPENAI_API_KEY` is exported.

Ask the user whether to add the agent anyway (they may plan to install it
later) or cancel.

### Step 3 — Add the agent

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/agents.sh add $ARGUMENTS
```

### Step 4 — Confirm

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/agents.sh list
```

Show the active agents to the user.
