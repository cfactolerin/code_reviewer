---
name: code-reviewer-setup
description: First-time setup wizard for the code-reviewer plugin. Configures agent list, agent settings, and Jira/Confluence credentials at ~/.code-reviewer/config.json.
argument-hint: ""
allowed-tools: ["Bash(mkdir *)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)", Read, Write, AskUserQuestion]
---

# code-reviewer Setup

Run the setup wizard to configure your environment interactively. The wizard
writes `~/.code-reviewer/config.json`.

## Instructions

### Step 1 — Load existing config (if any)

Read `~/.code-reviewer/config.json` if it exists. Note the current values —
they will be shown as defaults in each prompt. If the file does not exist,
use these defaults:

| Field | Default |
|---|---|
| `agents` | `["claude"]` |
| `claude_timeout` | `600` |
| `codex_timeout` | `900` |
| `gemini_timeout` | `300` |
| `opencode_timeout` | `900` |
| `gemini_model` | `gemini-2.5-flash` |
| `arbiter_rounds` | `3` |
| `google_cloud_project` | `fuga-prod` |
| `google_cloud_location` | `europe-west4` |
| `base_branch` | _(empty — auto-detect upstream → origin/main → origin/master)_ |
| `jira_base_url` | _(empty)_ |
| `jira_email` | _(empty)_ |
| `jira_api_token` | _(empty)_ |
| `review_output_path` | `/tmp/code-reviewer` |
| `auto_trigger` | `true` |
| `skip_branches` | `[]` |
| `keep_last_rounds` | `10` |

### Step 2 — Ask the user for each value

Use `AskUserQuestion` to ask for each item, **one at a time**. Show the
current/default value so the user can keep it.

Ask in this order:

1. **Agents** — "Which agents should run reviews? Options: `claude`, `codex`, `gemini`, `opencode` (comma-separated)." (default: current `agents` joined by comma)
2. **Review output path** — "Where should reviews be stored? Default: `/tmp/code-reviewer`. Note: `/tmp` is volatile across reboots — pick `~/.cache/code-reviewer` if you want persistence." (default: current `review_output_path` or `/tmp/code-reviewer`)
3. **Auto trigger** — "Enable the `git push` gate hook? (true/false, default true)" (default: current `auto_trigger` or `true`). Must be the literal `true` or `false`; re-prompt if invalid.
4. **Skip branches** — "Comma-separated list of branches the plugin should never gate (default empty — runs on all branches including main/master). Example: `main, release`" (default: current `skip_branches` joined by comma, or blank). Split by commas, trim whitespace, filter empties.
5. **Keep last rounds** — "How many timestamp directories to keep per branch? (integer ≥ 1, default 10)" (default: current `keep_last_rounds` or `10`). Must be a positive integer; re-prompt if invalid.
6. **Base branch override** — "Override the auto-detected base branch? Leave blank to auto-detect (upstream → origin/main → origin/master). Example: `origin/develop`." (default: current `base_branch` or blank)
7. **Google Cloud Project** — Only ask if `gemini` is in the agents list. "What is your Google Cloud project ID for Vertex AI?" (default: current value)
8. **Google Cloud Location** — Only ask if `gemini` is in the agents list. "What is your Google Cloud location for Vertex AI?" (default: current value)
9. **Jira base URL** — "What is your Jira base URL? (e.g. `https://yourorg.atlassian.net`) Leave blank to skip Jira integration." (default: current value)
10. **Jira email** — Only ask if a Jira base URL was provided. "What email do you use for Jira?" (default: current value)
11. **Jira API token** — Only ask if a Jira base URL was provided. "What is your Jira API token?" (default: current value)

For each answer:
- Empty string or "keep" / "default" → retain the current value.
- For agents, split by commas, trim whitespace, filter empties.
- For `skip_branches`, split by commas, trim whitespace, filter empties.
- For `auto_trigger`, accept only `true` or `false` (re-prompt on any other input).
- For `keep_last_rounds`, accept only a positive integer (re-prompt on any other input).

### Step 3 — Write the config

Create `~/.code-reviewer/` if needed (`mkdir -p ~/.code-reviewer`). Then write
JSON to `~/.code-reviewer/config.json` using the Write tool. Format:

```json
{
  "agents": ["claude"],
  "claude_timeout": 600,
  "codex_timeout": 900,
  "gemini_timeout": 300,
  "opencode_timeout": 900,
  "gemini_model": "gemini-2.5-flash",
  "arbiter_rounds": 3,
  "google_cloud_project": "fuga-prod",
  "google_cloud_location": "europe-west4",
  "base_branch": "",
  "jira_base_url": "",
  "jira_email": "",
  "jira_api_token": "",
  "review_output_path": "/tmp/code-reviewer",
  "auto_trigger": true,
  "skip_branches": [],
  "keep_last_rounds": 10
}
```

Omit `jira_*` fields if the user left them blank. Omit `base_branch` if blank.

### Step 4 — Configure permissions

The code-reviewer sub-agents need `Write` and `Bash` permissions so they can
write reviews under `tmp/code-reviews/` and invoke linters/tests/CLIs. Add
these to the user's Claude Code settings so they're auto-approved.

1. Determine the settings file path: `$CLAUDE_CONFIG_DIR/settings.json` if
   `CLAUDE_CONFIG_DIR` is set, otherwise `~/.claude/settings.json`.
2. Read the current file (create `{"permissions":{"allow":[]}}` if missing).
3. Add these patterns to `permissions.allow` if not already present:
   - `"Write(/tmp/code-reviewer/**)"` — agents write reviews at the default external path
   - `"Write(**/tmp/code-reviews/**)"` — agents write reviews under the repo (legacy in-repo path)
   - `"Bash(*)"` — agents run linters/tests/codex/gemini/opencode CLIs
   
   If the user chose a custom `review_output_path` outside `/tmp/code-reviewer`, note that they may need to add an additional `Write(<custom_path>/*)` pattern manually.
4. Write the updated settings back.
5. Tell the user what was added and which settings file was updated.

### Step 5 — Confirm

Read back `~/.code-reviewer/config.json` and show the user a summary, then
inform them:

> Config saved to `~/.code-reviewer/config.json`. This file contains your
> agent list, timeouts, and Jira credentials (including your API token in
> plaintext). Keep this file private — do not commit it to any repository.
>
> Reviews are stored at `<review_output_path>/<repo>/<branch>/<timestamp>/`
> (default `/tmp/code-reviewer`). With the default path, no `.gitignore` entry
> is needed (it's outside the repo tree).

If the resolved `review_output_path` starts with `/tmp/`, also print:

> Note: review_output_path resolves under /tmp, which is wiped on reboot.
> Your DISMISSALS.md and ledger will not persist. To keep them, set
> review_output_path to ~/.cache/code-reviewer or similar in
> ~/.code-reviewer/config.json.

### Step 6 — Agent CLI requirements (informational)

If `opencode` is in the agents list, tell the user:

> The `opencode` agent reads `OPENAI_API_KEY` from your shell environment —
> the plugin does not store it. Make sure you have one of:
> - `export OPENAI_API_KEY=sk-...` in your shell rc (e.g. `~/.zshrc`), or
> - `opencode auth` configured.
>
> Without auth, the opencode reviewer will fail its health check and be
> skipped automatically.

If `gemini` is in the agents list, the `google_cloud_project` and
`google_cloud_location` values are passed to the gemini CLI — no extra shell
setup is required.

Required CLIs in general:
- `git`, `jq`, `python3` — required (built-in plugin dependencies)
- `codex`, `gemini`, `opencode` — required only if the corresponding agent is
  in the agents list
