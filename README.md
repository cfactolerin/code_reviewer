# code-reviewer — Pre-Push Multi-Agent Local Branch Review

[![version](https://img.shields.io/badge/dynamic/json?url=https://raw.githubusercontent.com/cfactolerin/code_reviewer/main/.claude-plugin/plugin.json&query=%24.version&label=version&color=blue)](.claude-plugin/plugin.json)

`code-reviewer` is a Claude Code plugin that runs a **non-interactive,
multi-agent code review on the current local branch before you push it to
GitHub**. Where `prr` is for the *reviewer* (after a PR is opened),
`code-reviewer` is for the *author* (right before they push): make the branch
ready for human review by catching bugs, security issues, regressions, and
missing tests automatically first.

Claude, Codex, Gemini, and opencode each review the branch diff against the
base branch in parallel. A Claude-powered arbiter cross-examines disagreements
and produces a single `FINAL_REVIEW_RESULTS.md` the implementing agent (and
you) can act on directly.

## Prerequisites

**Required:**

- [Claude Code CLI](https://claude.ai/code) — runs the plugin skills
- `git` — diff, log, merge-base
- `jq` — JSON config parsing
- `python3` — Jira fetch and HTML→Markdown (stdlib only; no `pip install`)

**Optional (enable additional reviewers):**

- [Codex CLI](https://github.com/openai/codex) — `codex` agent
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) — `gemini` agent (uses Vertex AI; needs `google_cloud_project` / `google_cloud_location`)
- [opencode](https://opencode.ai) — `opencode` agent. Requires `OPENAI_API_KEY` in your shell or `opencode auth`. The plugin does not store this key.

Project-side linters are auto-detected and run if present:

- **Ruby:** `rubocop` (uses `.rubocop.yml` if present)
- **Python:** `ruff`, `mypy`, `flake8`
- **JS/TS:** `eslint`, `tsc`
- **Go:** `golangci-lint` (or `go vet`)
- **Rust:** `cargo clippy`
- **Shell:** `shellcheck`

Plus tests: if the repo has a `README.md`, `CLAUDE.md`, `AGENTS.md`, or
`CONTRIBUTING.md` with a test/build/spec section, reviewers extract those
instructions and run the suite, flagging any regressions.

## Installation

Inside a Claude Code session:

```
/plugin marketplace add cfactolerin/code_reviewer
/plugin install code-reviewer@cfactolerin-code-reviewer
```

## Quick Start

Run once to configure agents and (optionally) Jira credentials:

```
/code-reviewer:setup
```

Then, when you have a branch ready to push:

```
/code-reviewer:start
```

Optional flags:

```
/code-reviewer:start --ticket ABC-123          # override Jira key
/code-reviewer:start --base origin/develop     # override base branch
/code-reviewer:start --delta                   # fast review: only material new since last review
/code-reviewer:start --full                    # re-download Jira/Confluence; review entire branch
/code-reviewer:start --no-prune               # keep all old round dirs (skip the 10-round prune)
/code-reviewer:start --ticket ABC-123 --base origin/release/v2
```

The skill runs all configured agents in parallel, the arbiter synthesises,
and a final report is written to:

```
<review_output_path>/<repo-slug>/<branch-slug>/<YYYYMMDD-HHMMSS>/FINAL_REVIEW_RESULTS.md
```

(`review_output_path` defaults to `/tmp/code-reviewer/` — see "Volatility note" below.)

After the review finishes, the skill hands back to the main Claude Code
session with a prompt:

> The code review found N findings (X critical, Y high, …). How would you
> like to proceed?
>
> - **Fix everything** — apply fixes finding-by-finding, re-run for regression check
> - **Fix a subset** — name the finding numbers to fix
> - **Discuss first** — Q&A about findings before deciding
> - **Skip for now** — leave the report and continue

Pick **Fix everything** for the typical case: the main session reads
`FINAL_REVIEW_RESULTS.md`, applies fixes one by one (running each finding's
acceptance check), then re-runs `/code-reviewer:start`. The previous report
is automatically included in the next review's context, so the arbiter
explicitly calls out regressions, items now fixed, and any newly introduced
issues.

## Skills

| Skill | Description |
|---|---|
| `/code-reviewer:setup` | First-time setup — agent list, Jira credentials, GCP project/location |
| `/code-reviewer:start [--ticket K] [--base R] [--delta\|--full] [--no-prune]` | Non-interactive multi-agent review of the current branch |
| `/code-reviewer:autodetect [true\|false]` | Toggle the `git push` review gate (`config.auto_trigger`). No-arg form prints the current state |
| `/code-reviewer:dismiss <fingerprint>` | Add a finding fingerprint to `DISMISSALS.md` so it is excluded from future gate checks |
| `/code-reviewer:add-agent <name>` | Enable an agent in your config (`claude`, `codex`, `gemini`, `opencode`) |
| `/code-reviewer:delete-agent <name>` | Disable an agent in your config |

## How It Works

1. **Context gathering.** The plugin determines the base branch (upstream →
   `origin/main` → `origin/master`, unless overridden), computes the branch
   diff, captures full commit messages, detects languages and linters,
   detects project test instructions, and pulls the linked Jira ticket if
   the branch name or commits reference one.
2. **Strict review prompt.** A review prompt is assembled containing the
   diff, commits (so reviewers understand *intent*), Jira context, prior
   `FINAL_REVIEW_RESULTS.md` (for regression detection), and detected
   linter/test commands.
3. **Parallel review.** All configured agents receive the same prompt and run
   simultaneously. Each writes an independent `<agent>-review.md` covering
   bugs, security, performance, regressions, intent mismatch, test coverage
   gaps, linter output, and test-suite status. Reviewers can write repro
   tests under the round's `repro/` directory to prove bugs.
4. **Arbiter synthesis.** A Claude arbiter reads all reviews, asks targeted
   follow-up questions of individual reviewers (up to `arbiter_rounds`
   rounds, default 3), then produces a single `FINAL_REVIEW_RESULTS.md` with:
   - `## Summary` — for the human, short and decision-oriented
   - `## Detailed Findings` — for the implementing agent, each finding
     self-contained with file/line/code/fix/acceptance-check
   - Reviewer agreement matrix, test/lint status, intent check, prioritised
     fix checklist

## Storage Layout

Reviews are written outside the repo so they never pollute the working tree:

```
<review_output_path>/<repo-slug>/<branch-slug>/
├── .review-ledger.json           # append-only review timeline (machine-readable)
├── REVIEW_LEDGER.md              # human-readable rendering of the ledger
├── DISMISSALS.md                 # branch-scoped dismissed findings (fingerprints)
├── .jira-cache/                  # cached Jira issue, attachments, Confluence pages
└── <YYYYMMDD-HHMMSS>/            # one directory per review round
    ├── FINAL_REVIEW_RESULTS.md   # the thing to read
    ├── findings.json             # machine-readable findings (arbiter output; authoritative)
    ├── prior_findings.json       # carry-forward from previous round (Delta mode only)
    ├── context/
    │   ├── context-manifest.md
    │   ├── commits.md            # full commit messages
    │   ├── diff.patch
    │   ├── diffstat.txt
    │   ├── files.txt
    │   ├── files-status.txt
    │   ├── languages.txt
    │   ├── linters.json
    │   └── test-instructions.md
    ├── results/
    │   ├── review-prompt.md
    │   ├── claude-review.md
    │   ├── codex-review.md
    │   ├── gemini-review.md
    │   ├── opencode-review.md
    │   ├── arbiter-prompt.md
    │   ├── arbiter-output.md
    │   ├── arbiter-log.md        # Q&A rounds
    │   ├── final-report.md
    │   └── health-check.md
    └── repro/                    # repro tests reviewers wrote to prove bugs
```

`review_output_path` defaults to `/tmp/code-reviewer/`. See the
"Volatility note" section below for persistence options.

Old round directories are pruned automatically (keeping the last 10 per
branch). Pass `--no-prune` to skip this on a given run.

## Volatility note

The default `review_output_path` is `/tmp/code-reviewer/`, which is wiped on
every reboot on most systems. If you want review history to survive reboots,
set `review_output_path` to a persistent path in `~/.code-reviewer/config.json`:

```json
{ "review_output_path": "~/.cache/code-reviewer" }
```

`~/.cache/code-reviewer` is a conventional, low-noise choice on macOS and Linux.

## Configuration

Config lives at `~/.code-reviewer/config.json`. All keys optional — defaults shown.

| Key | Default | Description |
|---|---|---|
| `agents` | `["claude"]` | Active reviewer agents |
| `claude_timeout` | `600` | Seconds before Claude reviewer times out |
| `codex_timeout` | `900` | Seconds before Codex reviewer times out |
| `gemini_timeout` | `300` | Seconds before Gemini reviewer times out |
| `opencode_timeout` | `900` | Seconds before opencode reviewer times out |
| `gemini_model` | `gemini-2.5-flash` | Gemini model name passed to the CLI |
| `arbiter_rounds` | `3` | Max Q&A rounds before the arbiter is forced to finalise |
| `google_cloud_project` | `fuga-prod` | GCP project for Vertex AI (gemini) |
| `google_cloud_location` | `europe-west4` | GCP location for Vertex AI (gemini) |
| `base_branch` | _(empty)_ | Override the auto-detected base branch (e.g. `origin/develop`) |
| `review_output_path` | `/tmp/code-reviewer` | Where reviews are written (outside the repo) |
| `auto_trigger` | `true` | Set to `false` to disable the `git push` gate globally |
| `skip_branches` | `[]` | Branch names to bypass the push gate permanently (e.g. `["main", "master"]`) |
| `keep_last_rounds` | `10` | Number of round directories to keep per branch before pruning |
| `jira_base_url` | _(empty)_ | Jira instance URL (e.g. `https://yourorg.atlassian.net`) |
| `jira_email` | _(empty)_ | Jira account email for Basic auth |
| `jira_api_token` | _(empty)_ | Jira API token |

### Base branch resolution order

1. `--base <ref>` flag on `/code-reviewer:start`
2. `base_branch` key in `~/.code-reviewer/config.json`
3. The current branch's upstream (`@{u}`)
4. `origin/main`, then `origin/master`, then `main`, then `master`

## Hook

`code-reviewer` installs a Claude Code `PreToolUse` hook that intercepts
`git push` commands and checks whether the branch has a passing review before
allowing the push to proceed.

When the gate denies a push, Claude presents four options via a question
prompt:

| Option | What happens |
|---|---|
| **Delta review** (recommended) | Fast review of only the material that is new since the last review. Re-uses Jira cache. |
| **Full review** | Re-downloads Jira/Confluence and reviews the entire branch diff from scratch. |
| **Skip review** | Push proceeds without a review. Claude retries the push with `CR_SKIP=1`. |
| **Discuss** | Q&A about the denial reason before deciding. |

### Bypassing the gate

**One-off skip (inline env):**

```bash
CR_SKIP=1 git push
```

**One-off skip (environment variable):**

```bash
export CR_SKIP=1
git push
unset CR_SKIP
```

**Permanent exclusion for a branch** — add it to `skip_branches` in
`~/.code-reviewer/config.json`:

```json
{ "skip_branches": ["main", "master", "release"] }
```

**Disable the gate globally** — set `auto_trigger` to `false`:

```json
{ "auto_trigger": false }
```

### Gate deny reasons

| Reason | Meaning |
|---|---|
| `no_ledger` | No prior review exists for this branch. Run `/code-reviewer:start --full` first. |
| `head_changed` | New commits have been added since the last review. |
| `commit_needed` | Branch was only reviewed with uncommitted changes. Commit and re-run `--delta`. |
| `base_drifted` | The target branch has new commits not covered by the prior review's base. Run `--full`. |
| `dismissals_changed` | `DISMISSALS.md` was modified since the last approval. Re-run `--delta`. |
| `not_approved` | The latest matching review verdict is not `APPROVE` / `APPROVE_WITH_COMMENTS`. |

## Dismissals

Dismissals let you permanently silence false-positive findings so the push
gate doesn't keep blocking you for issues you've intentionally accepted.

Dismissed findings are stored in `DISMISSALS.md` at the branch level:

```
<review_output_path>/<repo-slug>/<branch-slug>/DISMISSALS.md
```

Each entry uses the fingerprint format `<file>:<line>:<slug(summary)>`:

```
src/auth.rs:42:missing_null_check_on_session_token
```

The `/code-reviewer:dismiss <fingerprint>` skill adds an entry.
You can also edit `DISMISSALS.md` directly, but **any change to
`DISMISSALS.md` triggers a `dismissals_changed` denial on the next push**,
forcing a re-review so the arbiter can verify the dismissal is still valid.

Use dismissals for genuine false positives only. Do not dismiss findings to
bypass a failing review — the gate will remain denied.

## Data Storage

| What | Where |
|------|-------|
| Config (settings, Jira creds) | `~/.code-reviewer/config.json` |
| Reviews per branch + timestamp | `<review_output_path>/<repo-slug>/<branch-slug>/<YYYYMMDD-HHMMSS>/` |
| Ledger + dismissals | `<review_output_path>/<repo-slug>/<branch-slug>/` |
| Jira cache | `<review_output_path>/<repo-slug>/<branch-slug>/.jira-cache/` |

**Note:** `~/.code-reviewer/config.json` contains your Jira API token in
plaintext. Keep it private. Reviews live outside the repo by default, so no
`.gitignore` change is needed unless you customise `review_output_path` to a
path inside the repo.

## Uninstalling

Inside a Claude Code session:

```
/plugin uninstall code-reviewer@cfactolerin-code-reviewer
```

To also remove configuration:

```bash
rm -rf ~/.code-reviewer
```

To clear all review history (default location):

```bash
rm -rf /tmp/code-reviewer
```

Or if you customised `review_output_path`, remove that directory instead.

## Differences from `prr`

| Aspect | `prr` | `code-reviewer` |
|---|---|---|
| Audience | The reviewer (post-PR) | The author / implementing agent (pre-push) |
| Trigger | GitHub PR URL | Current local branch |
| Source | Cloned snapshot of the PR | Live working tree |
| Output | GitHub PR review comments | `FINAL_REVIEW_RESULTS.md` in the repo |
| Flow | Interactive (you accept/edit comments before posting) | Non-interactive (write a report and exit) |
| Storage | `~/.prr/workspace/` (per-PR) | `<review_output_path>/<repo-slug>/<branch-slug>/<ts>/` (outside repo) |
| Linters | Reviewers can choose | Auto-detected and surfaced in the prompt |
| Tests | Reviewers can choose | Auto-detected from README/CLAUDE.md/AGENTS.md |
| Regression check | N/A | Previous `FINAL_REVIEW_RESULTS.md` included in context |

Same multi-agent + arbiter pattern. Same setup model (config file, agent list,
Jira creds). Same supported agents.
