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
│   ├── marketplace.json
│   └── hooks.json                 # registers the PreToolUse git-push gate
├── agents/
│   ├── claude-reviewer.md
│   ├── codex-reviewer.md
│   ├── gemini-reviewer.md
│   ├── opencode-reviewer.md
│   └── arbiter.md
├── skills/
│   ├── code-reviewer-setup/SKILL.md
│   ├── code-reviewer-start/SKILL.md         # v0.4.0: delta/full/no-prune flags + findings.json
│   ├── code-reviewer-autodetect/SKILL.md    # NEW: toggle git push review gate (config.auto_trigger)
│   ├── code-reviewer-dismiss/SKILL.md       # NEW: add fingerprint to DISMISSALS.md
│   ├── code-reviewer-add-agent/SKILL.md
│   └── code-reviewer-delete-agent/SKILL.md
├── scripts/
│   ├── lib.sh                     # shared helpers (config get, base-branch, repo-slug, hash helpers)
│   ├── context.sh                 # gather context: diff, commits, lang/linter detect, jira, prior review
│   ├── prompt.sh                  # build review/arbiter/question prompts
│   ├── agents.sh                  # list/add/delete agents in config
│   ├── ledger.sh                  # NEW: append/list/render-md/acquire-lock for .review-ledger.json
│   ├── dismiss.sh                 # NEW: add/remove/list entries in DISMISSALS.md
│   ├── validate-findings.py       # NEW: 9-rule validator for findings.json (stdlib only)
│   ├── hooks/
│   │   └── pre-push.sh            # NEW: PreToolUse hook — gate git push against the ledger
│   └── jira-fetch.py              # Jira REST + Confluence + attachments + HTML→Markdown (stdlib only)
├── tests/
│   ├── run.sh                     # NEW: test runner
│   ├── lib.sh                     # NEW: test helpers (assert_eq, assert_contains, …)
│   └── *.test.sh                  # NEW: test suites (11 total)
├── README.md
└── CLAUDE.md                      # this file
```

> **Spec:** `docs/superpowers/specs/2026-05-18-review-flow-design.md` (rev 13) is the
> authoritative design reference for all v0.4.0 logic. When in doubt, the spec wins.

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
  "review_output_path": "/tmp/code-reviewer",
  "auto_trigger": true,
  "skip_branches": [],
  "keep_last_rounds": 10,
  "jira_base_url": "",
  "jira_email": "",
  "jira_api_token": ""
}
```

The fields mirror `prr`'s config; `base_branch` and the four v0.4.0 additions
below are the only differences (and `workspace_path` is dropped, since reviews
now live in `review_output_path` rather than inside each repo).

**New keys added in v0.4.0:**

| Key | Default | Description |
|---|---|---|
| `review_output_path` | `/tmp/code-reviewer` | Root for all review output. Set to `~/.cache/code-reviewer` for persistence across reboots. |
| `auto_trigger` | `true` | When `false`, the `git push` gate is disabled globally. |
| `skip_branches` | `[]` | Branch names permanently excluded from the push gate (e.g. `["main", "master"]`). |
| `keep_last_rounds` | `10` | Number of round directories to keep per branch before pruning. Pass `--no-prune` to skip on a run. |

## Storage Layout

Branch-level (persists across rounds):

```
<review_output_path>/<repo_slug>/<branch_slug>/
├── .review-ledger.json      # append-only JSON array of review records
├── REVIEW_LEDGER.md         # human-readable rendering of the ledger
├── DISMISSALS.md            # fingerprints of dismissed findings (branch-scoped)
└── .jira-cache/             # Jira issue JSON, attachments, Confluence pages
```

Per-round directory:

```
<review_output_path>/<repo_slug>/<branch_slug>/<YYYYMMDD-HHMMSS>/
├── FINAL_REVIEW_RESULTS.md          # human report (for author / reviewer)
├── findings.json                    # machine-readable findings emitted by arbiter (§3.3)
├── prior_findings.json              # carry-forward from previous round (Delta mode only)
├── context/
│   ├── context-manifest.md
│   ├── commits.md
│   ├── diff.patch
│   ├── diffstat.txt
│   ├── files.txt
│   ├── files-status.txt
│   ├── languages.txt
│   ├── linters.json
│   └── test-instructions.md
├── results/
│   ├── review-prompt.md
│   ├── <agent>-review.md
│   ├── arbiter-prompt.md
│   ├── arbiter-output.md
│   ├── arbiter-log.md               # Q&A rounds
│   ├── final-report.md
│   └── health-check.md
└── repro/                           # repro tests reviewers wrote to prove bugs
```

### findings.json schema (§3.3)

The arbiter emits `findings.json` alongside `FINAL_REVIEW_RESULTS.md`. It is
the **authoritative** source for carry-forward, dismissal matching, and any
machine consumer. The Markdown report is for humans only — never parse it.

Top-level fields: `round`, `verdict`, `confidence`, `head_sha`, `base_sha`,
`findings[]`, `open_questions[]`, `regression{}`, `obsolete_dismissals[]`,
`dismissed_active[]`.

Each `findings[]` entry: `id`, `severity`, `category`, `file`, `line`,
`end_line`, `summary`, `fingerprint` (`<file>:<line>:<slug(summary)>`),
`reviewers_agreeing[]`, `carried_from`.

Full schema with example values: spec §3.3.

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

## Hook — Pre-Push Gate

`scripts/hooks/pre-push.sh` is registered via `.claude-plugin/hooks.json` as
a `PreToolUse` hook for `Bash`. It intercepts `git push` commands and checks
the `.review-ledger.json` for a matching approved review.

### Hook deny reasons

When the gate denies a push, it emits a structured JSON payload with a
`permissionDecision: "deny"` and one of the following reason codes:

| Reason | Meaning |
|---|---|
| `no_ledger` | No `.review-ledger.json` exists for this branch. Run `--full` first. |
| `head_changed` | New commits exist beyond the last reviewed HEAD. |
| `commit_needed` | Branch was only reviewed with uncommitted changes. Commit them and re-run `--delta`. |
| `base_drifted` | The target branch has new commits not covered by the prior review's base SHA. Run `--full`. |
| `dismissals_changed` | `DISMISSALS.md` changed since the last approval. Re-run `--delta`. |
| `not_approved` | Latest matching review has a non-passing verdict. |

Six reasons are actually emitted by the hook (the plan mentioned 8 — audit
of `scripts/hooks/pre-push.sh` found 6 actual `deny` call-sites).

The deny payload also includes four user-facing options Claude must present
via `AskUserQuestion`: Delta review, Full review, Skip review, Discuss.

### Bypasses

- `CR_SKIP=1 git push` — one-off inline bypass
- `export CR_SKIP=1` in the shell environment — session bypass
- `skip_branches` config key — permanent per-branch bypass
- `auto_trigger: false` config key — disable gate globally

## Validator — findings.json

`scripts/validate-findings.py` implements the 9 validation rules from spec
§4.5. It is called by the `code-reviewer-start` skill after the arbiter
writes `findings.json`. If validation fails, the skill retries the arbiter
**once** with the validation errors appended to the prompt; if it fails again
the round is aborted and `findings.json.invalid` is written alongside the
failing file.

The 9 rules (spec §4.5):

1. Parseable JSON (`jq empty`)
2. Schema required fields present with correct types
3. Verdict is one of the allowed enum values
4. Every finding has a valid `fingerprint` in `<file>:<line>:<slug>` format
5. Every `carried_from` reference resolves to an entry in `prior_findings.json`
6. Every `dismissed_active` entry has a matching fingerprint in `DISMISSALS.md`
7. Every entry in `prior_findings.json` appears in exactly one of: `findings[]`, `dismissed_active[]`, or `regression.resolved[]`
8. No duplicate fingerprints in `findings[]`
9. No dismissed finding silently dropped — every DISMISSALS.md fingerprint accounted for

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
5. Inspect `<review_output_path>/<repo-slug>/<branch-slug>/<ts>/` (default: `/tmp/code-reviewer/`).

Iterate: edit scripts under `scripts/`, re-run `/code-reviewer:start`. No
rebuild step.
