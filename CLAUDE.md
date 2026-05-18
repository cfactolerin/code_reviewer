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

**Every commit bumps the version and keeps both manifest files in lockstep.**
No exceptions — even docs-only or skill-only changes. There is no compiled
binary so there is no rebuild step (this is the one difference from `prr`'s
versioning workflow).

### Version files (both must match, exactly)

1. `.claude-plugin/plugin.json` — `version` field
2. `.claude-plugin/marketplace.json` — `version` field under `plugins[0]`

If they drift, the marketplace install will be inconsistent. Use the helper
to check and bump:

```bash
./scripts/bump-version.sh patch   # 0.1.0 → 0.1.1
./scripts/bump-version.sh minor   # 0.1.0 → 0.2.0
./scripts/bump-version.sh major   # 0.1.0 → 1.0.0
./scripts/bump-version.sh check   # exit non-zero if the two files disagree
```

The helper edits both files in place. Always inspect with `git diff` before
committing.

### Bump rules (semver-ish, current `0.x.y`)

- **Logic changes** — `scripts/`, `agents/`, `skills/` → bump **minor**
  (e.g. `0.2.0` → `0.3.0`). Resets patch to 0.
- **Docs only** — `README.md`, `CLAUDE.md`, source comments → bump **patch**
  (e.g. `0.2.0` → `0.2.1`).
- **Breaking config or skill-arg changes** (e.g. renaming `config.json`
  fields, changing `/code-reviewer:start` argument syntax) → bump **major**
  once we are at `1.0.0`. Until then, bump minor and call it out in the
  commit message.

### Commit procedure (every commit)

```bash
# 1. Bump both manifest files
./scripts/bump-version.sh minor   # or patch / major

# 2. Verify they match
./scripts/bump-version.sh check

# 3. Stage manifests alongside your other changes
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
# ... plus whatever else you changed

# 4. Commit (mention the new version in the message)
git commit -m "..."
```

The bump is **mandatory** on every commit. There is no such thing as a "no
bump needed" change — pick the appropriate severity and bump.

### When working on this repo as Claude

If you are Claude editing this repo and you are about to commit:

1. Run `./scripts/bump-version.sh check` first. If it reports drift, fix it
   before doing anything else.
2. Decide the severity based on the rules above. When in doubt between
   patch and minor, prefer minor — it costs nothing.
3. Run the appropriate `bump-version.sh <severity>` before staging.
4. Include the new version number in the commit message subject (e.g.
   `feat: hand-off prompt and auto-gitignore (v0.2.0)`).

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
