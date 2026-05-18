# code-reviewer — Pre-Push Multi-Agent Local Branch Review

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
/code-reviewer:start --no-cleanup              # keep other branches' review folders
/code-reviewer:start --ticket ABC-123 --base origin/release/v2
```

The skill runs all configured agents in parallel, the arbiter synthesises,
and a final report is written to:

```
<repo>/tmp/code-reviews/<branch>/<YYYYMMDD-HHMMSS>/FINAL_REVIEW_RESULTS.md
```

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
| `/code-reviewer:start [--ticket K] [--base R]` | Non-interactive multi-agent review of the current branch |
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
   tests under `tmp/code-reviews/<branch>/<ts>/repro/` to prove bugs.
4. **Arbiter synthesis.** A Claude arbiter reads all reviews, asks targeted
   follow-up questions of individual reviewers (up to `arbiter_rounds`
   rounds, default 3), then produces a single `FINAL_REVIEW_RESULTS.md` with:
   - `## Summary` — for the human, short and decision-oriented
   - `## Detailed Findings` — for the implementing agent, each finding
     self-contained with file/line/code/fix/acceptance-check
   - Reviewer agreement matrix, test/lint status, intent check, prioritised
     fix checklist

## Output Layout

```
<repo>/tmp/code-reviews/<branch>/<YYYYMMDD-HHMMSS>/
├── FINAL_REVIEW_RESULTS.md       # The thing to read
├── context/
│   ├── context-manifest.md
│   ├── commits.md                # full commit messages
│   ├── diff.patch
│   ├── diffstat.txt
│   ├── files.txt
│   ├── files-status.txt
│   ├── languages.txt
│   ├── linters.json
│   ├── test-instructions.md
│   ├── jira.md                   # if Jira configured + key found
│   └── previous-review.md        # last FINAL_REVIEW_RESULTS.md on this branch
├── results/
│   ├── review-prompt.md
│   ├── claude-review.md
│   ├── codex-review.md
│   ├── gemini-review.md
│   ├── opencode-review.md
│   ├── arbiter-prompt.md
│   ├── arbiter-output.md
│   ├── arbiter-log.md            # Q&A rounds
│   ├── final-report.md
│   └── health-check.md
└── repro/                        # repro tests reviewers wrote to prove bugs
```

The plugin auto-adds `tmp/code-reviews/` to your project's `.gitignore` on
first run (idempotent — won't duplicate if it's already covered by `tmp/` or
`tmp/code-reviews/`). You don't need to do this by hand.

### Auto-cleanup

On every run, the plugin removes any `tmp/code-reviews/<other-branch>/`
folder so `tmp/` doesn't accumulate stale work when you switch branches. The
**current branch's history is preserved** so the previous
`FINAL_REVIEW_RESULTS.md` can feed into the regression check on the next
run. Pass `--no-cleanup` to skip the sweep if you're inspecting another
branch's prior review.

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
| `jira_base_url` | _(empty)_ | Jira instance URL (e.g. `https://yourorg.atlassian.net`) |
| `jira_email` | _(empty)_ | Jira account email for Basic auth |
| `jira_api_token` | _(empty)_ | Jira API token |

### Base branch resolution order

1. `--base <ref>` flag on `/code-reviewer:start`
2. `base_branch` key in `~/.code-reviewer/config.json`
3. The current branch's upstream (`@{u}`)
4. `origin/main`, then `origin/master`, then `main`, then `master`

## Data Storage

| What | Where |
|------|-------|
| Config (settings, Jira creds) | `~/.code-reviewer/config.json` |
| Reviews per branch + timestamp | `<repo>/tmp/code-reviews/<branch>/<YYYYMMDD-HHMMSS>/` |

**Note:** `~/.code-reviewer/config.json` contains your Jira API token in
plaintext. Keep it private. Reviews live inside each repo — make sure
`tmp/code-reviews/` is gitignored.

## Uninstalling

Inside a Claude Code session:

```
/plugin uninstall code-reviewer@cfactolerin-code-reviewer
```

To also remove configuration:

```bash
rm -rf ~/.code-reviewer
```

To clear per-repo review history in a project:

```bash
rm -rf tmp/code-reviews
```

## Differences from `prr`

| Aspect | `prr` | `code-reviewer` |
|---|---|---|
| Audience | The reviewer (post-PR) | The author / implementing agent (pre-push) |
| Trigger | GitHub PR URL | Current local branch |
| Source | Cloned snapshot of the PR | Live working tree |
| Output | GitHub PR review comments | `FINAL_REVIEW_RESULTS.md` in the repo |
| Flow | Interactive (you accept/edit comments before posting) | Non-interactive (write a report and exit) |
| Storage | `~/.prr/workspace/` (per-PR) | `<repo>/tmp/code-reviews/<branch>/<ts>/` |
| Linters | Reviewers can choose | Auto-detected and surfaced in the prompt |
| Tests | Reviewers can choose | Auto-detected from README/CLAUDE.md/AGENTS.md |
| Regression check | N/A | Previous `FINAL_REVIEW_RESULTS.md` included in context |

Same multi-agent + arbiter pattern. Same setup model (config file, agent list,
Jira creds). Same supported agents.
