---
name: code-reviewer-autodetect
description: Toggle the automatic `git push` review gate (config.auto_trigger).
argument-hint: "[true|false]"
allowed-tools: ["Bash(jq *)", "Bash(cat *)", Read, Write]
---

# code-reviewer:autodetect

Toggle the PreToolUse hook that gates `git push` reviews.

## Usage

- `/code-reviewer:autodetect` — print the current state.
- `/code-reviewer:autodetect true` — enable the gate.
- `/code-reviewer:autodetect false` — disable the gate.

## Implementation

1. Read `~/.code-reviewer/config.json`. If it doesn't exist, tell the user:
   > "code-reviewer hasn't been set up yet. Run `/code-reviewer:setup` first."
   Then stop.

2. If $ARGUMENTS is empty, print the current `auto_trigger` value:
   ```bash
   jq -r '.auto_trigger // true' ~/.code-reviewer/config.json
   ```

3. If $ARGUMENTS is `true` or `false`, update the config atomically:
   ```bash
   tmp=$(mktemp)
   jq --argjson v $ARGUMENTS '.auto_trigger = $v' ~/.code-reviewer/config.json > "$tmp" && mv "$tmp" ~/.code-reviewer/config.json
   ```
   Then echo "Autodetect: $ARGUMENTS" to confirm.

4. If $ARGUMENTS is anything else, print a usage error.
