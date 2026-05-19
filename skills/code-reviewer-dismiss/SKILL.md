---
name: code-reviewer-dismiss
description: Add, remove, or list dismissed findings in the current branch's DISMISSALS.md.
argument-hint: "add <file:line> <summary> <reason> | remove <file:line> [<summary>] | list"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)", "Bash(jq *)", "Bash(git *)", Read]
---

# code-reviewer:dismiss

Manage dismissals for the current branch via `scripts/dismiss.sh`.

## Usage

- `/code-reviewer:dismiss add <file:line> "<summary>" "<reason>"`
- `/code-reviewer:dismiss remove <file:line> ["<summary-substring>"]`
- `/code-reviewer:dismiss list`

## Implementation

1. Resolve the current branch's `DISMISSALS.md`:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
BRANCH=$(git rev-parse --abbrev-ref HEAD)
REVIEW_OUT=$(cr_review_output_path "$REPO_ROOT")
REPO_SLUG=$(cr_repo_slug "$REPO_ROOT")
BRANCH_SLUG=$(echo "$BRANCH" | tr '/' '_')
DISM_PATH="$REVIEW_OUT/$REPO_SLUG/$BRANCH_SLUG/DISMISSALS.md"
```

2. Parse $ARGUMENTS into `ACTION` (first word) and `REST` (remaining words), then dispatch to `dismiss.sh` with the file path as the second argument — matching `dismiss.sh`'s API where `$1=action` and `$2=file`:

```bash
ACTION=$(echo "$ARGUMENTS" | awk '{print $1}')
REST=$(echo "$ARGUMENTS" | cut -d' ' -f2-)

bash "${CLAUDE_PLUGIN_ROOT}/scripts/dismiss.sh" "$ACTION" "$DISM_PATH" $REST
```

Note: do NOT pass `$ARGUMENTS` directly to `dismiss.sh` — the script expects the file path as `$2`, not at the end. The correct call order is always `dismiss.sh <action> <dism_file> [remaining-args]`.

3. After mutating commands (add/remove), echo: "Dismissal updated. The next `/code-reviewer:start` will see the change (DISMISSALS.md hash differs)." This nudges the user that the gate will fire on next push until they re-review.
