---
name: code-reviewer-delete-agent
description: Remove a review agent from the active agent list.
argument-hint: <agent-name>
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)", Read]
---

# Delete Agent

Agent name: $ARGUMENTS

## Instructions

### Step 0 — Check setup

Read `~/.code-reviewer/config.json`. If it does not exist, tell the user:
> "code-reviewer has not been set up yet. Run `/code-reviewer:setup` first."
Then stop.

### Step 1 — Remove

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/agents.sh delete $ARGUMENTS
```

### Step 2 — Confirm

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/agents.sh list
```

Show the remaining active agents.
