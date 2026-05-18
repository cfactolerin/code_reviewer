# Design — Review Scope, Re-Review Tracking, Auto-Trigger Hook, Dismissals

**Date:** 2026-05-18
**Status:** Approved (pending user review of this written spec)
**Target version:** 0.4.0
**Author:** Cris Factolerin (with Claude)

## 1. Background

`code-reviewer` v0.3.0 reviews the commits ahead of a branch's base and writes
`FINAL_REVIEW_RESULTS.md` to the repo's `tmp/code-reviews/<branch>/<ts>/`. It
ignores uncommitted changes, has no concept of "what's already been reviewed",
and only auto-triggers when the user manually invokes `/code-reviewer:start`.

This design adds:

1. **Two review modes** — Delta (only new material) and Full (whole branch +
   refresh Jira cache).
2. **Per-branch ledger** that tracks reviewed commits, worktree state, and
   verdicts so re-reviews are fast and the hook can gate informed.
3. **Configurable storage location**, default `/tmp/code-reviewer/<repo>/<branch>/<ts>/`
   so reviews live outside the repo and don't pollute working trees.
4. **PreToolUse hook** on `git push` that blocks pushes which contain
   unreviewed material or a non-approved verdict.
5. **Open Questions** mechanism — reviewers raise unresolved intent or
   ambiguity questions that the main session must surface to the user.
6. **Dismissals** — when reviewers got something wrong, the user can mark a
   finding as dismissed so future reviews don't re-flag it.
7. **Explicit verdict rubric** — linters and Open Questions do not influence
   the verdict; only finding severity does.
8. **Trunk-style workflow support** — drop hardcoded "main/master/develop is
   protected" in favour of an opt-in `protected_branches` list.

## 2. Scope boundary

The plugin owns:

- Computing what to review (Delta vs Full).
- Running agents and arbiter.
- Writing `FINAL_REVIEW_RESULTS.md`.
- Appending to the ledger.
- Maintaining the Jira cache.
- Reading `DISMISSALS.md` and feeding it to reviewers.
- Gating `git push` via the PreToolUse hook.

The main session (not the plugin) owns:

- Surfacing Open Questions to the user and capturing answers.
- Applying fixes to code.
- `git commit` decisions.
- Looping "fix until approved" (the plugin doesn't loop — the main session
  re-invokes `/code-reviewer:start` between fix rounds).
- Writing dismissals to `DISMISSALS.md` (via helper script or direct edit) in
  response to user intent.
- Retrying `git push` after fixes; running `CR_SKIP=1 git push` if the user
  decides to push without addressing findings.

The Phase 7 hand-off uses `AskUserQuestion` with options like "Apply fixes /
Resolve OQs / Discuss / Skip", but the user's answer is **only a hint to the
main session** — the plugin takes no action on it.

## 3. Data model

### 3.1 Storage layout

A new config key `review_output_path` (default `/tmp/code-reviewer`) controls
where reviews go. Resolved round directory:

```
<review_output_path>/<repo-slug>/<branch-slug>/<timestamp>/
```

- `<repo-slug>` = `basename($REPO_ROOT)` with non-alphanumeric (except `-`,
  `_`) replaced by `_`.
- `<branch-slug>` = current branch with `/` → `_`.
- `<timestamp>` = `YYYYMMDD-HHMMSS`.

Per-branch state files live one level above the timestamp dir:

```
<review_output_path>/<repo-slug>/<branch-slug>/
├── .review-ledger.json       ← machine state (hook + delta runner read)
├── REVIEW_LEDGER.md          ← human view, regenerated from JSON every write
├── DISMISSALS.md             ← user-maintained false-positive list
├── .jira-cache/              ← cached tickets, attachments, confluence pages
│   ├── ABC-123.md
│   ├── ABC-123/attachments/
│   └── confluence/<page-id>.md
├── 20260518-140000/          ← per-run round dirs (unchanged shape)
└── 20260518-153000/
```

Path resolution rules:

- Absolute paths used as-is.
- `~` expanded to `$HOME`.
- Relative paths resolved against `$REPO_ROOT` (stable anchor, not CWD).
- If the resolved path is inside `$REPO_ROOT`, print a one-time per-run
  warning suggesting the user add it to `.gitignore` or
  `.git/info/exclude`. No auto-modification.

Auto-cleanup of "other branches" folders applies inside
`<review_output_path>/<repo-slug>/`. Other repos' folders are never touched.

Worktrees naturally get distinct `<repo-slug>` directories because their
`$REPO_ROOT` basenames differ. No cross-worktree pollution.

### 3.2 `.review-ledger.json`

Append-only timeline of reviews for the branch.

```json
{
  "branch": "feat_auth",
  "base": "origin/main",
  "jira_keys": ["ABC-123", "ABC-124"],
  "jira_cached_at": "2026-05-18T14:00:00Z",
  "reviews": [
    {
      "timestamp": "20260518-140000",
      "type": "full",
      "head_sha": "abc123...",
      "commits_reviewed": ["abc123..."],
      "previous_head_sha": null,
      "worktree_hash": null,
      "verdict": "APPROVE",
      "findings": { "critical": 0, "high": 0, "medium": 0, "low": 0 },
      "open_questions": 0,
      "round_dir": "20260518-140000",
      "fallback_reason": null
    },
    {
      "timestamp": "20260518-153000",
      "type": "delta",
      "head_sha": "def456...",
      "commits_reviewed": ["def456..."],
      "previous_head_sha": "abc123...",
      "worktree_hash": "sha256:7f3e...",
      "verdict": "REQUEST_CHANGES",
      "findings": { "critical": 0, "high": 2, "medium": 1, "low": 0 },
      "open_questions": 1,
      "round_dir": "20260518-153000",
      "fallback_reason": null
    }
  ]
}
```

Invariants:

- `head_sha` = `git rev-parse HEAD` at review start.
- `commits_reviewed` for **Full** = every commit on the branch since base;
  for **Delta** = only commits not in any prior entry's `commits_reviewed`.
- `worktree_hash` = `sha256(git diff HEAD ++ sorted untracked file contents)`,
  or `null` if working tree clean.
- `previous_head_sha` (Delta) = `head_sha` of the prior review the Delta
  built on.
- `fallback_reason` is set when Delta auto-falls-back to Full (e.g.,
  `"rebase_detected"`).
- `findings` counts come from the arbiter's final report; counts of *Findings*
  only (not Open Questions, not linter output).
- Writes are atomic: write `.review-ledger.json.tmp` → `mv` into place. A
  `.review-ledger.lock` (`flock` if available, else `mkdir`-based) guards
  concurrent invocations.

`REVIEW_LEDGER.md` is rendered from the JSON on every ledger write — a table
with one row per review entry plus a per-entry section showing verdict and
finding counts. Never edited by hand.

### 3.3 `DISMISSALS.md`

Free-form Markdown, one `## <file>:<line> — <summary>` heading per dismissed
finding, with a body capturing date and reason. Reviewer agents are told to
not re-flag a dismissed finding without **new** evidence.

The plugin owns the file location and the suggested format; the main session
owns the conversational flow that triggers writes. A `scripts/dismiss.sh` helper
exposes `add`, `remove`, and `list` for consistency; direct file edits also
work.

Dismissals are branch-scoped and don't follow merges.

Open Questions are not dismissible — they are resolved by the user in
conversation, with the resolution landing in commit messages, code comments,
or the Jira ticket so reviewers see it on the next pass naturally.

## 4. Review modes

### 4.1 Mode selection

`/code-reviewer:start [--delta | --full]`:

| Flag | Ledger? | Behaviour |
|---|---|---|
| _(none)_ | yes | Delta |
| _(none)_ | no | Full |
| `--delta` | yes | Delta |
| `--delta` | no | Error: "no prior review to delta from; run --full first" |
| `--full` | _any_ | Full |

Rebase detection in Delta mode: if
`git merge-base --is-ancestor <prev.head_sha> HEAD` fails, the branch was
rewritten — Delta is unsafe. Auto-fall back to Full, record
`fallback_reason: "rebase_detected"` in the ledger entry.

### 4.2 Delta mode

1. Read ledger; locate most recent entry `prev`.
2. Verify `prev.head_sha` is an ancestor of HEAD. If not → fallback to Full.
3. Compute "new material":
   - new commits = `git log prev.head_sha..HEAD --reverse`
   - new worktree state = current `git diff HEAD` + untracked file contents
   - hash both into `worktree_hash`.
4. **Nothing-new short-circuit:** if there are zero new commits AND
   `worktree_hash == prev.worktree_hash`, exit early with
   `"Nothing new to review since <ts>; last verdict was <verdict>."` No new
   round directory, no ledger entry, no agent dispatch.
5. Use cached Jira (`.jira-cache/<KEY>.md`) for any ticket already cached.
   Only download missing tickets.
6. Build the review prompt around **only the new material**, but include the
   prior `FINAL_REVIEW_RESULTS.md` verbatim as regression context.
7. Include `DISMISSALS.md` (if present) and the previous review's Open
   Questions section (as "open" status — reviewers may flag the same OQ
   again if still unresolved, or note resolution if they detect it in the
   new material).
8. Run agents → arbiter → write `FINAL_REVIEW_RESULTS.md`.
9. Append a `{"type": "delta", ...}` ledger entry. Regenerate
   `REVIEW_LEDGER.md`.

### 4.3 Full mode

1. **Refresh Jira cache:** delete `.jira-cache/` for this branch and
   re-download every detected Jira key, its attachments, and all linked
   Confluence pages. Update `jira_cached_at` in the ledger.
2. Compute the full diff: `git diff <merge-base>...HEAD` + working-tree state.
3. Build the review prompt around the entire branch diff. Any prior
   `FINAL_REVIEW_RESULTS.md` from this branch goes in as secondary context
   for regression checking.
4. Include `DISMISSALS.md` and previous Open Questions as in Delta.
5. Run agents → arbiter → write `FINAL_REVIEW_RESULTS.md`.
6. Append a `{"type": "full", ...}` ledger entry.

### 4.4 Multiple Jira keys

If the branch name or commits reference more than one Jira key (e.g.
`ABC-123 ABC-124`), fetch **all** distinct keys. Each gets its own
`<KEY>.md` and `<KEY>/attachments/` in the cache. The review prompt has a
single `## Jira Context` section with each ticket headed by its key.
Reviewers treat all tickets as equally authoritative. No "primary ticket"
concept.

## 5. PreToolUse hook

### 5.1 Activation

The plugin ships `.claude-plugin/hooks.json` registering a `PreToolUse` hook
on the `Bash` tool. The hook script `scripts/hooks/pre-push.sh` runs for
every Bash call but exits early unless the command line contains `git push`.

(The exact hook-manifest field names and output JSON will be verified against
the current Claude Code plugin spec before implementation. The conceptual
model below is firm.)

### 5.2 Hook flow

1. Read stdin JSON; extract the command. If not a `git push` → exit 0.
2. Read `~/.code-reviewer/config.json`. If missing/malformed → **exit 0
   silently** (don't gate users who haven't set up).
3. If `auto_trigger == false` → exit 0.
4. If `CR_SKIP=1` is in the env → exit 0.
5. Detect repo + branch. If not in a git repo → exit 0. If branch is in
   `protected_branches` → exit 0.
6. Resolve ledger path from `review_output_path` + repo-slug + branch-slug.
7. Run gate conditions (Section 5.3). On pass → exit 0. On fail → deny with
   structured reason.

### 5.3 Gate conditions

```
current_head_sha = git rev-parse HEAD
current_worktree_hash = sha256(diff HEAD + untracked) or null if clean

ledger exists
  AND ledger has an entry with head_sha == current_head_sha
  AND that latest matching entry's verdict ∈ {APPROVE, APPROVE_WITH_COMMENTS}
  AND that entry's worktree_hash == current_worktree_hash
```

If any check fails, deny with the specific reason:

| Failure | Reason key |
|---|---|
| Ledger missing | `no_ledger` |
| HEAD not in ledger | `head_changed` |
| Verdict not approved | `not_approved` |
| Worktree changed since last review | `worktree_changed` |

### 5.4 Hook output

Conceptual JSON output on stdout when denying:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "code-reviewer: <reason>\n\nClaude, present these options via AskUserQuestion:\n  • Delta review\n  • Full review\n  • Skip review (push with CR_SKIP=1)\n  • Discuss\n\nThen run /code-reviewer:start with the appropriate flag and retry."
  }
}
```

On allow, exit 0 with no output.

### 5.5 Claude orchestration

When the hook denies, Claude sees the `permissionDecisionReason` and:

1. Presents the 4 options via `AskUserQuestion`.
2. Acts on the user's choice:
   - **Delta** → run `/code-reviewer:start --delta`, then retry push.
   - **Full** → run `/code-reviewer:start --full`, then retry push.
   - **Skip** → run `CR_SKIP=1 git push` once.
   - **Discuss** → enter Q&A about the gate or the prior review.

The "fix until approved" workflow emerges naturally: after a Delta with
`REQUEST_CHANGES`, the user asks Claude to fix; Claude applies fixes,
retries the push; the hook fires again; Claude offers the same options;
loop until verdict is `APPROVE`. The plugin does not orchestrate this loop.

### 5.6 Override mechanisms

| Mechanism | Scope |
|---|---|
| `CR_SKIP=1 git push` | Single push |
| `auto_trigger: false` in config | Global, until re-enabled via `/code-reviewer:autodetect true` |
| `protected_branches: ["main", ...]` | Per-branch opt-out from the plugin entirely |

`CR_SKIP=1` is **not** recorded in the ledger. The absence of an approved
ledger entry alongside a push tells that story implicitly.

## 6. Phase 7 hand-off & Open Questions

### 6.1 Open Questions section

Every individual reviewer is instructed: when intent is unclear from the
diff + commits + Jira ticket, do not guess — file an Open Question. Format
in their `## Open Questions` section:

```markdown
### OQ. <one-line summary>

- **Category:** Intent ambiguity | Missing context | Conflicting signals | Out-of-scope concern
- **File:** `<path>:<line>` (if applicable)

**The question:** <the question>

**Why flagged:** <one paragraph>

**Proposed paths forward:**
- A: <interpretation A and what the code would look like>
- B: <interpretation B and what the code would look like>
```

The arbiter consolidates OQs from all reviewers in its final
`## Open Questions` section above `## Detailed Findings`. It uses Q&A rounds
to merge near-duplicates.

### 6.2 Rich-text output (Phase 7)

```
# Code review complete

**Report:** <round_dir>/FINAL_REVIEW_RESULTS.md
**Mode:** <Delta|Full> [since <ts>] · **Verdict:** [<VERDICT>] · **Confidence:** <H|M|L>
**Findings:** C critical · H high · M medium · L low
**Open Questions:** N
**Active dismissals:** N (see DISMISSALS.md)        ← only when >0
**Ledger:** updated (entry #N)

## Summary
<verbatim arbiter Summary>

### Top Risks
<verbatim>

### Regression vs Previous Review
<verbatim, if any>

## Open Questions (N) — resolve with the user before applying fixes
- OQ1 <file>:<line> — <one-line> *(Category, agent(s))*
- OQ2 ...

## Findings (N)
- F1 (CRITICAL) <file>:<line> — <one-line>
- F2 (HIGH)     <file>:<line> — <one-line>
- ...

## Linter & Test Status
- Linters: <list>
- Tests: <command, result, failures>
- Coverage gaps: <count>           ← count of findings whose Category is "Test Coverage"

## Intent Check vs Jira <KEY>
Goal: <paraphrase>
Achieved? <Yes|Partially|No> — <one paragraph>
```

When the verdict is not `[APPROVE]`, append:

> *To push anyway without addressing findings: ask me to push and I'll run `CR_SKIP=1 git push` for that single push.*

When the report has findings, append:

> *To dismiss a finding as a false positive: ask me to dismiss it with a reason.*
> *To undo a previous dismissal: ask me to remove it. Future reviews will be free to re-flag it.*

### 6.3 AskUserQuestion (hint to main session)

> **What's next?**

Options:

- **Resolve Open Questions first** *(shown only if OQs exist)*
- **Apply fixes**
- **Discuss the report**
- **Skip for now**

Plus the standard "Other" / free-text for things like "fix F1-F3 only".

The plugin takes no action on the answer. The main session reads the
conversation context and proceeds.

## 7. Verdict rubric

The arbiter is instructed:

| Verdict | Trigger | Hook behaviour |
|---|---|---|
| `[BLOCK]` | At least one CRITICAL finding | Hook denies (`not_approved`) |
| `[REQUEST_CHANGES]` | At least one HIGH finding, no CRITICAL | Hook denies (`not_approved`) |
| `[APPROVE_WITH_COMMENTS]` | Only MEDIUM/LOW findings | Hook allows |
| `[APPROVE]` | No findings | Hook allows |

Rules baked into the arbiter prompt:

- Verdict tier = highest unresolved finding severity.
- **Linter output is never the basis for a finding's severity.** If a linter
  flag represents a real defect, the reviewer must argue the case
  independently as a Finding citing the same file/line; the linter output
  becomes Evidence, not the source.
- **Open Questions do not influence the verdict.** They're tracked separately
  and shown in Phase 7, but the verdict reflects findings only.
- **Confidence is independent of verdict.** A `[BLOCK]` can be HIGH or LOW
  confidence.
- **Intent mismatch under dispute** between reviewers → arbiter converts to
  an Open Question rather than a Finding, unless evidence is unambiguous.

## 8. Trunk-style workflow support

Drop the hardcoded `main|master|develop` refusal in `context.sh`. Replace
with `protected_branches: []` config (default empty). When the current
branch is in `protected_branches`:

- `context.sh` refuses to run with a clear message.
- Hook exits 0 silently.

When it's not, the gate logic works regardless of branch name. On `main` with
local commits ahead of `origin/main`, the plugin reviews those commits;
the hook gates the push until reviewed. Trunk-based teams are served by the
same gate as gitflow teams.

## 9. Configuration

Full `~/.code-reviewer/config.json` schema:

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
  "protected_branches": [],

  "jira_base_url": "",
  "jira_email": "",
  "jira_api_token": ""
}
```

New keys are additive — existing v0.3.0 configs continue to work; missing
new keys default.

## 10. New commands

| Slash command | Status | Purpose |
|---|---|---|
| `/code-reviewer:setup` | Changed | Adds the three new keys to the wizard |
| `/code-reviewer:start [--delta\|--full] [--ticket K] [--base R] [--no-cleanup]` | Changed | New `--delta` / `--full` mode flags |
| `/code-reviewer:autodetect true\|false` | **New** | Toggle `auto_trigger`. Empty arg → print current |
| `/code-reviewer:dismiss add\|remove\|list ...` | **New** | Manage `DISMISSALS.md` for the current branch |
| `/code-reviewer:add-agent <name>` | Unchanged | — |
| `/code-reviewer:delete-agent <name>` | Unchanged | — |

`/code-reviewer:dismiss` syntax:

```
/code-reviewer:dismiss add <file:line> "<summary>" "<reason>"
/code-reviewer:dismiss remove <file:line> [<summary-substring>]
/code-reviewer:dismiss list
```

`add` is idempotent (same file:line + summary → no-op). `remove` is
idempotent (no match → no-op message).

## 11. File inventory

Five new files, nine changed files.

```
.claude-plugin/
  plugin.json                                ← bump 0.3.0 → 0.4.0
  marketplace.json                           ← bump
  hooks.json                                 ← NEW

agents/
  arbiter.md                                 ← UPDATED: verdict rubric, linter exclusion, OQ consolidation, dismissals
  claude-reviewer.md                         ← UPDATED: OQ rule, dismissals rule, linter rule, delta/full awareness
  codex-reviewer.md                          ← UPDATED: same
  gemini-reviewer.md                         ← UPDATED: same
  opencode-reviewer.md                       ← UPDATED: same

skills/
  code-reviewer-setup/SKILL.md               ← UPDATED: new config keys
  code-reviewer-start/SKILL.md               ← UPDATED: --delta/--full, nothing-new early exit, Phase 7 refactor
  code-reviewer-add-agent/SKILL.md           ← unchanged
  code-reviewer-delete-agent/SKILL.md        ← unchanged
  code-reviewer-autodetect/SKILL.md          ← NEW
  code-reviewer-dismiss/SKILL.md             ← NEW

scripts/
  lib.sh                                     ← UPDATED: review_output_path resolver, repo-slug, worktree-hash helpers
  context.sh                                 ← UPDATED: drop hardcoded protected list, --delta/--full, new path layout, ledger append, read DISMISSALS, atomic write + lock
  prompt.sh                                  ← UPDATED: delta/full variants, include DISMISSALS, include previous OQs
  agents.sh                                  ← unchanged
  jira-fetch.py                              ← UPDATED: download attachments, save to .jira-cache/, full-mode flag forces re-download
  ledger.sh                                  ← NEW: append/list/render REVIEW_LEDGER.md
  dismiss.sh                                 ← NEW: add/remove/list DISMISSALS
  bump-version.sh                            ← unchanged
  hooks/
    pre-push.sh                              ← NEW: PreToolUse hook

README.md                                    ← UPDATED
CLAUDE.md                                    ← UPDATED
```

## 12. Edge cases & explicit decisions

### Explicit decisions

- **Multiple Jira keys:** fetch all distinct keys; cache each separately;
  prompt includes all under `## Jira Context`.
- **Concurrent runs:** atomic ledger writes + a per-branch lock (`flock`
  with `mkdir` fallback). Second runner sees "another review is in progress
  at <round_dir>" and exits.
- **Missing or malformed config when hook fires:** hook exits 0 silently.

### Documented behaviour (no extra design needed)

| Edge case | Behaviour |
|---|---|
| Brand-new repo, no `origin/main` | Base resolution fails; user passes `--base` |
| Detached HEAD | Hook exits 0; start refuses |
| No commits ahead + clean tree | Start exits "nothing to review"; hook exits 0 |
| First-ever branch review | No ledger → Full |
| `--delta` with no ledger | Error: run `--full` first |
| Rebase / force-push in Delta | Auto-fallback to Full, `fallback_reason` recorded |
| `git push --dry-run` | Gated normally; `CR_SKIP=1` to bypass |
| Force push | Gated normally |
| Push refspec to other branch | Gated based on current HEAD; `CR_SKIP=1` to bypass |
| Non-Claude shell pushes | Not intercepted (out of scope) |
| Branch in `protected_branches` | Plugin refuses; hook exits 0 |
| Two worktrees, same branch | Divergent ledgers — documented as "don't do that" |
| Repo-name collision | User sets explicit `review_output_path` |
| Jira fetch failure | Continue without ticket context; error saved |
| Linter missing | Reviewer notes "linter not run"; no verdict impact |
| Test failure | Reviewer notes; only a finding if failure is on a diff-touched test |
| OQ "dismissed" attempt | OQs aren't dismissible; user resolves them in conversation |
| Massive diff > token limit | Reviewer may truncate; arbiter notes "partial review". Chunking is future work |
| Ledger corruption | Backup as `.review-ledger.json.bak`, fallback to Full |
| User deletes branch tmp dir mid-session | Next run treats branch as new → Full |
| `CR_SKIP=1` push then later review | Fine; new ledger entry. Skip itself not recorded |

### Open items to verify during implementation, not blocking

- Exact hook output JSON field names (`permissionDecision` etc.) per current
  Claude Code plugin spec — verify via `claude-code-guide` agent when
  writing the plan.
- Whether `hooks.json` lives in `.claude-plugin/` or `hooks/`.
- Cross-platform `flock` availability on macOS (likely missing in base
  system; use `mkdir`-based lock fallback).

## 13. Out of scope for this design

- A git-side `pre-push` hook (would gate CLI-issued pushes, not just
  Claude-initiated). Server-side enforcement is a separate feature.
- Cross-branch dismissal inheritance (e.g., dismissals on a merged feature
  branch propagating to main).
- Chunked review of very large diffs.
- A `/code-reviewer:reset` or `/code-reviewer:cleanup-all` skill (auto-cleanup
  on every run already handles the common case).
- Per-finding fingerprinting beyond `file:line + summary` — not needed for
  v1 dismissals.
- Telemetry / observability (phase timing, agent cost reporting).
- A SessionStart hook for nudging "you have unreviewed commits" — explicitly
  declined in favour of "A only" hook strategy.
