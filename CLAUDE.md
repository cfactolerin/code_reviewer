# code-reviewer Plugin — Developer Reference

## Project Overview

`code-reviewer` is a Claude Code plugin that runs a strict, non-interactive
multi-agent review of the current local branch before push. Audience: the
implementing AI agent (so it can fix issues before pushing) and the author.

Architecturally it mirrors `prr` (multi-agent + arbiter), with two key
deviations:

1. **No Rust binary.** All non-LLM logic lives in shell scripts under
   `scripts/`, plus a single stdlib-only Python helper for Jira/Confluence
   fetch and HTML→Markdown. The flow has no heavy lifting (no clone, no
   GitHub API, no interactive PR posting) so a binary adds version-bump
   overhead without payoff. If a future feature genuinely needs one, add it
   then.
2. **Non-interactive flow.** The `/code-reviewer:start` skill drives the
   pipeline to a written `FINAL_REVIEW_RESULTS.md` without asking the user
   anything. No `AskUserQuestion` calls, no comment-review menus.

## Repository Structure

```
code-reviewer/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── agents/
│   ├── claude-reviewer.md
│   ├── codex-reviewer.md
│   ├── gemini-reviewer.md
│   ├── opencode-reviewer.md
│   └── arbiter.md
├── skills/
│   ├── code-reviewer-setup/SKILL.md
│   ├── code-reviewer-start/SKILL.md
│   ├── code-reviewer-add-agent/SKILL.md
│   └── code-reviewer-delete-agent/SKILL.md
├── scripts/
│   ├── lib.sh             # shared helpers (config get, base-branch resolution, ...)
│   ├── context.sh         # gather context: diff, commits, lang/linter detect, jira, prior review
│   ├── prompt.sh          # build review/arbiter/question prompts
│   ├── agents.sh          # list/add/delete agents in config
│   └── jira-fetch.py      # Jira REST + Confluence + HTML→Markdown (stdlib only)
├── README.md
└── CLAUDE.md              # this file
```

## Config

`~/.code-reviewer/config.json` — JSON (parseable via `jq`):

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
  "jira_api_token": ""
}
```

The fields mirror `prr`'s config; `base_branch` is the only addition (and
the `workspace_path` field is dropped, since reviews live inside each repo).

## Round Layout

Per run:

```
<repo>/tmp/code-reviews/<branch_slug>/<YYYYMMDD-HHMMSS>/
├── FINAL_REVIEW_RESULTS.md
├── context/
│   ├── context-manifest.md
│   ├── commits.md
│   ├── diff.patch
│   ├── diffstat.txt
│   ├── files.txt
│   ├── files-status.txt
│   ├── languages.txt
│   ├── linters.json
│   ├── test-instructions.md
│   ├── jira.md           # if Jira configured + key found
│   └── previous-review.md # last FINAL_REVIEW_RESULTS.md on this branch
├── results/
│   ├── review-prompt.md
│   ├── <agent>-review.md
│   ├── arbiter-prompt.md
│   ├── arbiter-output.md
│   ├── arbiter-log.md
│   ├── final-report.md
│   └── health-check.md
└── repro/                # repro tests reviewers wrote to prove bugs
```

## Pipeline Phases (drive from `code-reviewer-start` skill)

| Phase | Step |
|---|---|
| 1 | `scripts/context.sh` → creates round dir, writes context files, prints round dir path |
| 2 | `scripts/prompt.sh review <round_dir>` → writes `results/review-prompt.md` |
| 3 | Health-check non-claude CLIs (codex, gemini, opencode) |
| 4 | Dispatch all healthy reviewers in **parallel** via Agent tool; each writes `<agent>-review.md` |
| 5 | Arbiter loop: `prompt.sh arbiter <round_dir>` → dispatch arbiter → if JSON questions, run `prompt.sh question` per agent, dispatch agents to answer, append to `arbiter-log.md`, loop up to `arbiter_rounds`; otherwise treat output as final |
| 6 | Copy `final-report.md` → `FINAL_REVIEW_RESULTS.md` at round root |

The skill tracks round count itself. `prompt.sh arbiter <round_dir> final`
forces the prompt to instruct the arbiter to finalise (used on the last round
when questions persist).

## Conventions

- **All shell scripts are `set -u` + `set -o pipefail`.** No `set -e` — handle
  errors explicitly so a single failure doesn't blow up the orchestrator.
- **JSON config, not YAML.** `jq` parses cleanly from shell; no Python YAML
  dependency.
- **Last line of stdout = path** for scripts that produce a file or directory
  (`context.sh`, `prompt.sh review|arbiter|question`). Earlier lines are
  progress on stderr.
- **No Rust binary.** If you find yourself reaching for one, prefer a Python
  helper using stdlib only.
- **All paths are absolute** when passed between scripts and the skill.
- **Agent dispatches use `git -C <repo>` for git** to avoid permission prompts.

## Adding a New Reviewer Agent

1. Add the agent name to `KNOWN_AGENTS` in `scripts/agents.sh`.
2. Create `agents/<name>-reviewer.md` with the dispatcher persona and the
   exact CLI invocation pattern.
3. Add a dispatch block in `skills/code-reviewer-start/SKILL.md` Phase 4 with
   the agent's command line.
4. Add a health-check block in Phase 3 of the same skill.
5. Mention the agent in `README.md` Prerequisites.

## Adding a New Linter

Edit the Python block in `scripts/context.sh` (the heredoc invoked as
`python3 - "$REPO_ROOT" "$CONTEXT_DIR/files.txt" "$linter_json" <<'PY' ...`).
Append a new entry to the `linters` list with:

- `language`: tag matching `languages.txt`
- `tool`: linter binary
- `config_present`: whether the repo has the linter's config file
- `command`: argv list to run (scope to changed files where possible)

The review prompt automatically surfaces detected linters; the reviewer
agents run them as part of their review.

## Versioning

- `.claude-plugin/plugin.json` `version`
- `.claude-plugin/marketplace.json` `version` (under `plugins[0]`)

Bump both in lockstep on every change. There's no compiled binary to rebuild.

Suggested semver-ish bumps (current `0.x.y`):

- **Skill / script logic changes**: bump minor
- **Docs only**: bump patch

## Local Testing

In a project with a feature branch:

1. Install the plugin from a local clone:
   ```
   /plugin marketplace add /path/to/code_reviewer
   /plugin install code-reviewer@cfactolerin-code-reviewer
   ```
2. Run `/code-reviewer:setup` once.
3. Make some local changes on a non-protected branch.
4. Run `/code-reviewer:start`.
5. Inspect `tmp/code-reviews/<branch>/<ts>/`.

Iterate: edit scripts under `scripts/`, re-run `/code-reviewer:start`. No
rebuild step.
