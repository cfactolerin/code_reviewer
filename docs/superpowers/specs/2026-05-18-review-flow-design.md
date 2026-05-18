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
   protected" in favour of an opt-in `skip_branches` list.

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
where reviews go.

> **Volatility note.** The default `/tmp/code-reviewer` is convenient (no
> repo pollution, no setup) but **not durable**: most OSes wipe `/tmp` on
> reboot, and macOS purges files there periodically. That means the per-
> branch ledger, `DISMISSALS.md`, and `.jira-cache/` can disappear without
> warning. Users who care about persistence (dismissals especially) should
> set `review_output_path` to a durable path like `~/.cache/code-reviewer`
> via `/code-reviewer:setup` or by editing `~/.code-reviewer/config.json`.
> The setup wizard explicitly surfaces this trade-off.

Resolved round directory:

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

**Auto-cleanup policy (changed from v0.3.0):**

- **Cross-branch auto-cleanup is removed.** Other branches' folders under
  `<repo-slug>/` are never touched by `/code-reviewer:start` — they contain
  `.review-ledger.json`, `DISMISSALS.md`, and `.jira-cache/` which must
  survive branch switches.
- **Within-branch timestamp pruning** runs as the **last step** of a
  successful `/code-reviewer:start` (after the ledger entry is appended
  and `findings.json` has been validated), unless `--no-prune` is passed.
  Algorithm:
  1. Enumerate timestamp directories on disk under `<branch-slug>/`,
     sorted by name (which equals chronological order since names are
     `YYYYMMDD-HHMMSS`).
  2. Determine the set to **preserve**: the current round (just created),
     the immediately-prior round (if one exists, so the next Delta can
     read its `findings.json`), and the most recent
     `keep_last_rounds - 2` rounds beyond those. Effective floor is 2
     rounds preserved on any branch with prior history, regardless of
     how low `keep_last_rounds` is set.
  3. Remove all other timestamp dirs.

  **Failed-review round dirs count toward the quota** (they live on disk
  regardless of ledger state; without this rule, failed dirs would leak
  forever). The per-branch state files (ledger, dismissals, jira-cache)
  are never affected.

  **Why "last step":** pruning before reading the prior round's
  `findings.json` would delete the very file Delta carry-forward needs.
  Pruning before ledger append would mean a crash leaves stale dirs and
  no ledger entry. Pruning after validation+ledger gives the cleanest
  invariant: a successful run ends with a coherent state.

- **`--no-prune`** skips the pruning step for the current
  `/code-reviewer:start` run only. It does not change `keep_last_rounds`;
  the next run without the flag prunes normally (which may remove rounds
  the prior `--no-prune` run preserved). Useful when debugging or
  comparing several rounds side-by-side.
- A manual `/code-reviewer:cleanup` skill that nukes whole branch folders
  is **out of scope** for this design (see §13).

Worktrees naturally get distinct `<repo-slug>` directories because their
`$REPO_ROOT` basenames differ. No cross-worktree pollution.

### 3.2 `.review-ledger.json`

Append-only timeline of reviews for the branch.

```json
{
  "branch": "feat_auth",
  "base_ref": "origin/main",
  "jira_keys": ["ABC-123", "ABC-124"],
  "jira_cached_at": "2026-05-18T14:00:00Z",
  "reviews": [
    {
      "timestamp": "20260518-140000",
      "type": "full",
      "head_sha": "abc123...",
      "base_ref": "origin/main",
      "base_sha": "f00ba8...",
      "commits_reviewed": ["abc123..."],
      "previous_head_sha": null,
      "worktree_hash": null,
      "dismissals_hash": null,
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
      "base_ref": "origin/main",
      "base_sha": "f00ba8...",
      "commits_reviewed": ["def456..."],
      "previous_head_sha": "abc123...",
      "worktree_hash": "7f3e1c4d8b...",
      "dismissals_hash": "a91b2e5f0c...",
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

- `jira_keys` (top-level on the ledger) = union of all Jira keys detected
  on this branch across reviews. Updated on each ledger append (adding any
  newly-detected keys). Informational only; the per-review keys aren't
  re-recorded on each entry.
- `head_sha` = `git rev-parse HEAD` at review start.
- `base_ref` = the symbolic base used for this review (e.g. `origin/main`),
  exactly as resolved by the base resolver (see §5.3 notes for the two
  distinct chains used by `context.sh` and the hook) or as the user passed
  via `--base`.
- `base_sha` = `git rev-parse <base_ref>` at review start. The SHA pins the
  base independently of the symbolic name (which can move).
- `commits_reviewed` for **Full** = every commit on the branch since
  `base_sha`; for **Delta** = only commits not in any prior entry's
  `commits_reviewed`.
- `worktree_hash` is computed from a **deterministic manifest** of the working
  tree state and is `null` when the tree is clean. Algorithm:

  ```
  # Tracked changes — full content diff vs HEAD, including binary, deletions,
  # mode changes, symlink target changes. Combines staged + unstaged.
  # `--no-ext-diff --no-color --no-textconv` neutralises user gitconfig
  # (external diff drivers, color output, textconv filters) so the hash is
  # deterministic across machines and shells.
  TRACKED = git diff --no-ext-diff --no-color --no-textconv --binary HEAD

  # Untracked-file content hashes (respects .gitignore)
  UNTRACKED = for each path in `git ls-files --others --exclude-standard -z`, sorted:
                emit  "<path>\0<file_mode>\0<file_type>\0sha256(content)\n"

  worktree_hash = sha256( TRACKED  +  "\0\0"  +  UNTRACKED )
  ```

  `TRACKED` and `UNTRACKED` are both empty iff the working tree is clean →
  `worktree_hash = null`.

  **Canonical hash format**: hexadecimal digest string only (no
  `"sha256:"` prefix). Examples: `"7f3e1c4d8b..."` (dirty),
  `null` (clean). The same convention applies to `dismissals_hash`. All
  comparisons elsewhere in the spec are string equality with `null`
  treated as a distinct value (so `null == null` allowed, `null != "<hex>"`
  denied, `"<hex1>" == "<hex2>"` byte-equal).

  Because `git diff --no-ext-diff --no-color --no-textconv --binary HEAD`
  includes base85-encoded binary content and the full text diff of
  modifications, two different working-tree edits to the same tracked file
  produce different TRACKED bytes and therefore different hashes. The
  earlier draft used `git status --porcelain=v2` which omits the
  working-tree blob SHA for unstaged tracked changes (only `hH` and `hI`
  are emitted; there is no `hW`) and was unsafe for unstaged edits.
- `previous_head_sha` (Delta) = `head_sha` of the prior review the Delta
  built on.
- `dismissals_hash` = `sha256(<DISMISSALS.md contents>)` at review start, or
  `null` if the file does not exist. Used by Delta's nothing-new
  short-circuit and by future debugging.
- `fallback_reason` is set when Delta auto-falls-back to Full (e.g.,
  `"rebase_detected"`).
- `findings` counts come from the arbiter's final report; counts of *Findings*
  only (not Open Questions, not linter output).
- Writes are atomic: write `.review-ledger.json.tmp` → `mv` into place.
  Concurrent invocations are guarded by a file-based lock at
  `<review_output_path>/<repo-slug>/<branch-slug>/.review-ledger.lock`.

- **Lock lifecycle.** The orchestrator acquires the lock via atomic file
  creation:

  ```bash
  ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null || {
    # Another run holds the lock. Check whether it's stale.
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && \
       [ "$(find "$LOCK_FILE" -mmin +60 2>/dev/null)" ]; then
      # PID owner is gone AND file is >1h old → stale, take over.
      rm -f "$LOCK_FILE"
      ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null \
        || exit_with "Could not acquire lock"
    else
      exit_with "Another review is in progress at <round_dir>"
    fi
  }
  trap 'rm -f "$LOCK_FILE" 2>/dev/null' EXIT INT TERM
  ```

  The lock is a regular file (not a directory) — `rm -f` is sufficient
  for cleanup. `set -o noclobber` makes the redirection fail (rather
  than overwrite) if the file already exists, giving us atomic create.
  This is portable across bash and zsh on macOS and Linux without
  external dependencies (no `flock(1)` required). The trap releases
  the lock on success, validation failure, `REVIEW_FAILED`, and any
  signal-driven exit.

`REVIEW_LEDGER.md` is rendered from the JSON on every ledger write — a table
with one row per review entry plus a per-entry section showing verdict and
finding counts. Never edited by hand.

### 3.3 `findings.json` (per round)

Every round directory contains, next to `FINAL_REVIEW_RESULTS.md`, a machine-
readable `findings.json` the arbiter emits. This is the **authoritative
source** for carry-forward verification, dismissal matching, and any other
machine consumer. The Markdown report is for humans only — never parsed.

Schema (one file per round; emitted by the arbiter as part of producing the
final report):

```json
{
  "round": "20260518-153000",
  "verdict": "REQUEST_CHANGES",
  "confidence": "HIGH",
  "head_sha": "def456...",
  "base_sha": "f00ba8...",
  "findings": [
    {
      "id": "F1",
      "severity": "CRITICAL",
      "category": "Bug",
      "file": "src/auth.rs",
      "line": 42,
      "end_line": null,
      "summary": "missing null check on session token",
      "fingerprint": "src/auth.rs:42:missing_null_check_on_session_token",
      "reviewers_agreeing": ["claude", "codex"],
      "carried_from": null
    },
    {
      "id": "F2",
      "severity": "HIGH",
      "category": "Bug",
      "file": "src/db.rs",
      "line": 120,
      "end_line": null,
      "summary": "N+1 query in load_users",
      "fingerprint": "src/db.rs:120:n_plus_1_query_in_load_users",
      "reviewers_agreeing": ["claude", "gemini"],
      "carried_from": "20260518-140000:F4"
    }
  ],
  "open_questions": [
    {
      "id": "OQ1",
      "category": "IntentAmbiguity",
      "file": "src/auth.rs",
      "line": 42,
      "summary": "Should expired tokens raise or return None?"
    }
  ],
  "regression": {
    "resolved":         ["20260518-140000:F1"],
    "newly_introduced": ["F1"]
  },
  "obsolete_dismissals": [
    {
      "fingerprint": "src/legacy.rb:50:obsolete_lookup_path",
      "reason":      "file removed in commit def456"
    }
  ],
  "dismissed_active": [
    {
      "id":          "D1",
      "ref":         "20260518-140000:F3",
      "fingerprint": "src/db.rs:120:n_plus_1_query_in_load_users",
      "severity":    "HIGH",
      "category":    "Performance",
      "file":        "src/db.rs",
      "line":        120,
      "end_line":    null,
      "summary":     "N+1 query in load_users"
    },
    {
      "id":          "D2",
      "ref":         null,
      "fingerprint": "src/auth.rs:88:weak_password_check",
      "severity":    "HIGH",
      "category":    "Security",
      "file":        "src/auth.rs",
      "line":        88,
      "end_line":    null,
      "summary":     "Weak password hash (pre-2018 style)"
    }
  ],
  "linter_summary": {
    "rubocop": { "ran": true, "issues": 3 },
    "ruff":    { "ran": false, "reason": "binary not installed" }
  },
  "tests": {
    "command": "bundle exec rspec",
    "ran": true,
    "passed": false,
    "failures": [
      { "test": "spec/models/user_spec.rb:42", "reason": "expected nil, got 0" }
    ]
  }
}
```

Conventions:

- **Stable IDs per round:** `F1`, `F2`, … assigned in order they appear in
  the report. References across rounds use `<round>:<id>` form, e.g.
  `20260518-140000:F4`.
- **`fingerprint`** = `<file>:<line>:<slug(summary)>` (lowercase, non-alnum →
  `_`). Used by `DISMISSALS.md` matching and by Delta carry-forward to
  identify the "same" finding across rounds.
- **`carried_from`** is `null` for findings raised fresh this round;
  `"<prev_round>:<prev_id>"` when the finding was carried forward from a
  prior round during a Delta's re-verification.
- `regression` records the disposition of prior findings *that are not
  dismissed*:
  - `resolved` — prior IDs whose code is no longer present.
  - `newly_introduced` — this round's own IDs (so a reader can quickly see
    what showed up since last time).
  - "still present and not dismissed" is implicit: those are the items in
    `findings[]` with `carried_from` set.
- `obsolete_dismissals` lists `DISMISSALS.md` fingerprints the arbiter
  believes are **no longer applicable** (file removed, code rewritten,
  reorganised so the original line no longer exists). Each entry has a
  short `reason`. Informational for the user — they can clean up
  `DISMISSALS.md` accordingly. Together with `dismissed_active[]`, every
  fingerprint in `DISMISSALS.md` must be accounted for in **every
  review** (Full and Delta both; enforced by §4.5 validation rule 9).
- `dismissed_active` is the **authoritative store** of findings whose code
  still exists in the branch but is dismissed via `DISMISSALS.md`. Each
  entry has:
  - `id` — stable per-round identifier, `D1`, `D2`, … assigned in order.
    Used so `regression.resolved` and the next round's `ref` field can
    address dismissed items the same way `F1`/`F2` address findings.
  - `ref` — provenance:
    - `"<prev_round>:<prev_id>"` (where `<prev_id>` is `F<n>` or `D<n>` of
      the prior round) — a prior entry carried forward.
    - `null` — first suppressed this round (Full mode fresh catch, or
      first-time-in-Delta).
  - Full finding detail (severity, category, file, line, summary,
    fingerprint).

  Carrying the structured detail is critical: when the user later removes
  a dismissal, Delta uses the carried detail to re-verify and either
  resurrect the finding into `findings[]` or mark it `resolved`. Without
  the detail here, a removed dismissal could silently allow an issue back.
  Items here do **not** count toward the verdict (they are suppressed).
  Validation requires every fingerprint to match an actual
  `DISMISSALS.md` entry.

**Prior reference forms (used by `carried_from`, `ref`, and
`regression.resolved`):** always `"<round>:<id>"` where `<id>` is either
`F<n>` (from prior `findings[]`) or `D<n>` (from prior `dismissed_active[]`).
This unifies addressing — every prior entry has exactly one stable
reference shape and validation can check it deterministically.
- `linter_summary` and `tests` are presence/issue counts only — full output
  remains in the Markdown report.

The arbiter is told: emit `findings.json` strictly per this schema, then
emit `FINAL_REVIEW_RESULTS.md` as a human-readable rendering of the same
data. If the two disagree, `findings.json` is authoritative.

### 3.4 `DISMISSALS.md`

Markdown with one section per dismissed finding. The heading is human-only;
machine matching uses a structured **Fingerprint:** line that the parser
relies on. This keeps the file readable while making the matching unambiguous.

Required section template (helper script writes this; manual edits must
preserve the `**Fingerprint:**` line):

```markdown
## src/auth.rs:42 — Missing null check on session token

**Fingerprint:** `src/auth.rs:42:missing_null_check_on_session_token`

Dismissed: 2026-05-18
Reason: Token is guaranteed non-null by the middleware at
`src/middleware/auth.rs:18-22`. Reviewer didn't see the middleware.
```

For multi-line findings (range), the heading uses `<file>:<start>-<end>` and
the matching `dismissed_active` entry stores `line: <start>` and
`end_line: <end>`:

```markdown
## src/db.rs:118-130 — Unsynchronised access to shared cache

**Fingerprint:** `src/db.rs:118:unsynchronised_access_to_shared_cache`

Dismissed: 2026-05-18
Reason: The cache is only mutated during single-threaded startup; the
multithreaded read-only phase doesn't need a lock.
```

Note the fingerprint always uses the start line (118 above), so dismissals
remain stable across small range adjustments. `end_line` is metadata, not
part of the fingerprint.

**Parser rules:**

1. Split the file into sections at each top-level `## ` heading. A section
   is everything from one `## ` heading up to the next (or EOF).
2. For each section, find the first line matching the regex
   `^\*\*Fingerprint:\*\*\s+\`([^\`]+)\`\s*$`. The captured group is the
   fingerprint. Backticks around the fingerprint are required by the
   strict parser; the helper script always emits them. If you hand-edit,
   keep them. Sections without a `**Fingerprint:**` line (or with the
   line malformed) are **ignored with a warning**.
   - When a review is in progress (round dir exists): warning is logged
     to `<round_dir>/context/dismiss.warn`.
   - When the hook is computing `dismissals_hash`: the hook computes the
     hash byte-wise over the file and does not parse sections, so
     malformed sections do not affect the hook's gate decision. (They
     will, however, affect any subsequent review run.)
3. Fingerprint format: `<file>:<line>:<slug(summary)>` where
   `slug = lowercase, non-alphanumeric → '_'`. This matches the
   `fingerprint` field emitted by the arbiter in `findings.json` (§3.3).
4. Duplicate fingerprints in `DISMISSALS.md` are tolerated (treated as
   one); the most recent section wins for display.

**`scripts/dismiss.sh` invariants:**

- `add <file:line> "<summary>" "<reason>"` computes the fingerprint
  deterministically and appends a section with the exact template above.
- `remove <file:line> [<summary-substring>]` finds matching sections by
  parsing fingerprints (not headings) and deletes them.
- `list` prints `<fingerprint> — <date> — <summary>` per dismissal.

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
2. **Prerequisite checks** (any failure → fallback to Full):
   - `git merge-base --is-ancestor prev.head_sha HEAD` (rebase detection;
     `fallback_reason: "rebase_detected"`)
   - Resolve `current_base_sha = git rev-parse <base_branch_ref>` where
     `<base_branch_ref>` is determined by `context.sh`'s base resolution
     chain (per §5.3 notes: `--base` flag → `config.base_branch` → `@{u}` →
     `origin/main` → `origin/master`). Require `prev.base_sha ==
     current_base_sha`; if not, the base shifted between reviews and the
     Delta's scope would diverge from what the prior review covered. Fall
     back to Full (`fallback_reason: "base_changed"`).
   - Verify `<prev.round_dir>/findings.json` exists and is readable. If
     missing (manual deletion or aggressive pruning below `keep_last_rounds`),
     fall back to Full (`fallback_reason: "prior_findings_missing"`).
3. Compute "new material":
   - new commits = `git log prev.head_sha..HEAD --reverse`
   - current `worktree_hash` per the manifest algorithm in §3.2.
   - current `dismissals_hash` = `sha256(<DISMISSALS.md>)` (or `null` if
     file missing).
4. **Nothing-new short-circuit:** if **all three** of the following are
   unchanged, exit early with
   `"Nothing new to review since <ts>; last verdict was <verdict>."` No new
   round directory, no ledger entry, no agent dispatch:
   - zero new commits
   - `worktree_hash == prev.worktree_hash`
   - `dismissals_hash == prev.dismissals_hash`

   In particular, **any change to `DISMISSALS.md` forces a real review** so
   the dismissal can affect the verdict and the gate.
5. **Carry-forward unresolved findings** (the verdict-correctness gate).
   Parse the previous round's `findings.json` from disk
   (`<prev.round_dir>/findings.json`, per §3.3). Throughout this step,
   `prior = parsed findings.json from the prior round dir` (NOT the
   ledger's `findings` counts object, which is a separate field
   per §3.2). Build `prior_findings.json` as a single array that is the
   union of:
   - `prior.findings[]` (each annotated with `_was_dismissed: false`)
   - `prior.dismissed_active[]` (each annotated with `_was_dismissed: true`)

   Write `prior_findings.json` to the new round dir
   (`<new_round_dir>/prior_findings.json`) before invoking the arbiter,
   so both the arbiter and the §4.5 validator read the same on-disk
   artifact (reproducibility + debuggability).

   The arbiter is explicitly instructed:

   > For each entry in `prior_findings.json` (each has a `<prev_round>:<prev_id>`
   > reference — `F<n>` for items from `prior.findings[]` or `D<n>` for items
   > from `prior.dismissed_active[]`), re-verify it against the current
   > branch state AND the current `DISMISSALS.md`. For each:
   >
   > - If the code at that file/line **no longer exhibits the issue** →
   >   list its `<prev_round>:<prev_id>` in `regression.resolved`.
   > - Else (issue still present):
   >   - If its fingerprint matches an active `DISMISSALS.md` entry →
   >     emit an entry in `dismissed_active[]` with the full finding
   >     detail and `ref: "<prev_round>:<prev_id>"` (preserving lineage).
   >   - Else (dismissal removed OR never dismissed) → emit a Finding in
   >     `findings[]` with `carried_from: "<prev_round>:<prev_id>"`.
   >
   > Do not silently drop any prior entry. Every entry in
   > `prior_findings.json` must end up in **exactly one** of:
   > `findings[].carried_from`, `dismissed_active[]` (with matching `ref`),
   > or `regression.resolved` — all using the same `<round>:<id>` reference
   > shape.

   The arbiter is also told to scan the new material (new commits +
   uncommitted) for issues. New findings whose fingerprint matches an
   active dismissal go to `dismissed_active[]` with `ref: null`. New
   un-dismissed findings go to `findings[]` with `carried_from: null`.

   This means a Delta whose only change is "user removed a dismissal" will
   see the previously suppressed entry move from `prev.dismissed_active[]`
   into the new `findings[]` — the verdict is recomputed correctly.

   This means the new Delta's verdict is computed from **all currently-present
   findings (carried forward + new)**, not just findings the agents found in
   the diff of new material. Because `findings.json` is structured, the
   carry-forward verification is deterministic — no Markdown parsing.
6. Use cached Jira (`.jira-cache/<KEY>.md`) for any ticket already cached.
   Only download missing tickets.
7. Build the review prompt around the new material, but include the prior
   `FINAL_REVIEW_RESULTS.md` verbatim as regression context AND the
   `prior_findings.json` for explicit re-verification.
8. Include `DISMISSALS.md` (if present) and the previous review's Open
   Questions section (as "open" status — reviewers may flag the same OQ
   again if still unresolved, or note resolution if they detect it in the
   new material).
9. Run agents → arbiter → write `FINAL_REVIEW_RESULTS.md`.
10. Append a `{"type": "delta", ...}` ledger entry whose `findings` counts
    reflect the **carried-forward + new** total. Regenerate
    `REVIEW_LEDGER.md`.

### 4.3 Full mode

> **First-ever Full on a branch** (no ledger yet): there is no prior round,
> so `prior_findings.json` is **not written** to the new round dir, the
> arbiter prompt does not include a "prior findings" section, and §4.5
> rule 5 (carry-forward accounting) is **skipped**. Rules 1–4, 6, 7 still
> apply.

1. **Refresh Jira cache safely:**
   - Download every detected Jira key, its attachments, and all linked
     Confluence pages into `.jira-cache.new/`.
   - On success: atomic swap that handles the no-existing-cache case:
     ```
     rm -rf .jira-cache.old        # clear any leftover from a prior swap
     [ -d .jira-cache ] && mv .jira-cache .jira-cache.old
     mv .jira-cache.new .jira-cache
     rm -rf .jira-cache.old
     ```
     Update `jira_cached_at` in the ledger.
   - On any failure (HTTP error, timeout, partial content):
     `rm -rf .jira-cache.new`, keep the existing `.jira-cache/` (if any)
     in place, and log a warning into the round dir's `context/jira.warn`
     file: "Jira refresh failed at <ts>; using stale cache from
     <prev_cached_at> (or no cache if first run)." Do not abort the
     review.
2. Compute the full diff: `git diff <merge-base>...HEAD` + working-tree state.
3. Build the review prompt around the entire branch diff. Any prior
   `FINAL_REVIEW_RESULTS.md` from this branch goes in as secondary context
   for regression checking.
4. Include `DISMISSALS.md` and previous Open Questions as in Delta.
5. **Dismissal accounting (also applies to Full).** The arbiter is told:
   - For every fingerprint in `DISMISSALS.md`, decide:
     - If the code at that file/line still exhibits the issue → emit a
       `dismissed_active[]` entry with `ref: null` (or `ref: "<prev>:<id>"`
       if a prior round carried it) and full finding detail.
     - If the code no longer exhibits the issue → emit an
       `obsolete_dismissals[]` entry with the fingerprint and a short
       `reason`.
   - No dismissal may be silently dropped (enforced by §4.5 rule 9).
6. Run agents → arbiter → write `FINAL_REVIEW_RESULTS.md`.
7. Append a `{"type": "full", ...}` ledger entry.

### 4.4 Multiple Jira keys

If the branch name or commits reference more than one Jira key (e.g.
`ABC-123 ABC-124`), fetch **all** distinct keys. Each gets its own
`<KEY>.md` and `<KEY>/attachments/` in the cache. The review prompt has a
single `## Jira Context` section with each ticket headed by its key.
Reviewers treat all tickets as equally authoritative. No "primary ticket"
concept.

### 4.5 `findings.json` validation gate

Before appending a ledger entry, the orchestrator script validates the
arbiter's output. **Validation failure → no ledger append** (so the hook
will keep denying, which is the safe direction).

Validation steps (run in this order):

1. **Parseable JSON.** Run `jq empty <round_dir>/findings.json`. If exit
   non-zero → fail.
2. **Schema required fields.** Required keys from §3.3, with correct type.
   "Required" means the key MUST be present (value may be `null` only
   where explicitly noted). "Optional" means the key MAY be omitted; if
   present it must have the documented type.
   - Top-level **required**: `round` (string), `verdict` (string),
     `confidence` (string), `head_sha` (string), `base_sha` (string),
     `findings` (array), `open_questions` (array of objects, each with
     `id`, `category`, `file`, `line`, `summary`),
     `regression` (object with `resolved` array-of-strings and
     `newly_introduced` array-of-strings),
     `dismissed_active` (array of objects per §3.3),
     `obsolete_dismissals` (array of `{fingerprint, reason}` objects per §3.3).
   - Top-level **optional**: `linter_summary` (object), `tests` (object).
     If omitted, treated as empty.
   - Each `findings[]` entry **required**: `id`, `severity`, `category`,
     `file`, `line` (positive integer, **not null** — file-level findings
     use `line: 1`), `end_line` (positive integer or `null`), `summary`,
     `fingerprint`, `reviewers_agreeing` (array of strings),
     `carried_from` (string or `null`).
   - Each `dismissed_active[]` entry **required**: `id`, `ref` (string or
     `null`), `fingerprint`, `severity`, `category`, `file`,
     `line` (positive integer), `end_line` (positive integer or `null`),
     `summary`.
3. **Enum constraints.**
   - `verdict ∈ {APPROVE, APPROVE_WITH_COMMENTS, REQUEST_CHANGES, BLOCK}`.
   - `severity ∈ {CRITICAL, HIGH, MEDIUM, LOW}` in both `findings[]` and
     `dismissed_active[]`.
   - `confidence ∈ {HIGH, MEDIUM, LOW}`.
   - `category` in `findings[]` and `dismissed_active[]` ∈
     `{Bug, Security, Performance, Regression, TestCoverage, Style,
       IntentMismatch, Other}`.
   - `category` in `open_questions[]` ∈
     `{IntentAmbiguity, MissingContext, ConflictingSignals,
       OutOfScopeConcern}`. (Open questions are about ambiguity reasons;
     findings are about defect types — separate enums.)
   - Finding `id` matches regex `^F[0-9]+$`; `dismissed_active` `id`
     matches `^D[0-9]+$`. IDs are unique within their array.
4. **Verdict / severity consistency.** Apply the §7 rubric mechanically
   to `findings[]` only (`dismissed_active[]` does not count). The
   recorded `verdict` must equal the rubric output. Mismatch → fail.
5. **Carry-forward accounting (Delta only).** Source: the
   `<new_round_dir>/prior_findings.json` artifact written in §4.2 step 5
   (union of `prior.findings[]` and `prior.dismissed_active[]` from the
   parsed prior `findings.json`). Every entry must appear in **exactly
   one** of:
   - new `findings[]` with `carried_from` set to its prior reference
     (`"<prev_round>:F<n>"` or `"<prev_round>:D<n>"`), or
   - new `dismissed_active[]` with `ref` set to its prior reference, or
   - `regression.resolved` referencing the prior identifier in the same
     `"<round>:<id>"` shape.
   No prior entry may be silently dropped or double-counted.
   Every `carried_from` value must point to a real prior reference, and
   every non-`null` `ref` in `dismissed_active[]` must point to a real
   prior reference.
6. **Dismissal coherence (both modes).** For every entry in `findings[]`:
   - The finding's `fingerprint` must **not** match any active dismissal
     in `DISMISSALS.md`. Match → validation fails (the arbiter violated
     the suppression rule; on retry the arbiter is reminded explicitly).
   For every entry in `dismissed_active[]`:
   - Its `fingerprint` must match an active `DISMISSALS.md` entry. No
     match → validation fails (the arbiter cited a non-existent
     dismissal).
   These rules apply to both Full and Delta reviews so dismissals are
   honoured at the source of every report, not only via carry-forward.
7. **Fingerprint plausibility.** Each `fingerprint` in both
   `findings[]` and `dismissed_active[]` matches the pattern
   `<file>:<line>:<slug>` and the file+line+slug are internally
   consistent with the entry's own `file`, `line`, `summary` fields.
8. **Within-round uniqueness.** Fingerprints must be unique across
   `findings[]` and `dismissed_active[]` combined within a single
   `findings.json`. The same code issue cannot appear twice. Duplicate →
   validation fails.
9. **DISMISSALS.md coverage (both modes).** Let
   `D = {fingerprint | fingerprint ∈ DISMISSALS.md, parsed successfully
   per §3.4}`. Every entry in `D` must appear in **exactly one** of:
   - `dismissed_active[<entry>].fingerprint` (still present, suppressed), or
   - `obsolete_dismissals[<entry>].fingerprint` (no longer applicable;
     reason recorded).
   The arbiter cannot silently drop a dismissed item; it must classify
   each one. This rule applies in **both Full and Delta**. It's the
   invariant that lets "remove a dismissal" → "next review resurrects the
   issue" work consistently across review modes.

On failure:

1. Move the arbiter's output to
   `<round_dir>/findings.json.invalid` and write
   `<round_dir>/validation-errors.md` listing each failed check with the
   offending JSON path.
2. **Retry the arbiter once**, passing the validation errors in the
   correction prompt. If the retry passes validation → proceed normally.
3. If the retry also fails → write `<round_dir>/REVIEW_FAILED.md`
   explaining the situation and stop. **No ledger entry is appended.** The
   hook will continue denying any push that depends on this branch's
   review state, which is the correct safe behaviour. The user can re-run
   `/code-reviewer:start --full` or address the validation issue and
   re-run.

This sits between Phase 6 (arbiter completes) and the existing Phase 7
(hand-off). The hand-off rich text on a failed validation surfaces the
failure prominently rather than the would-be report.

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
2. **Parse leading env assignments** off the command text. A command like
   `CR_SKIP=1 git push origin feat-X` has `CR_SKIP=1` as part of the
   command string, not the hook's own environment (the hook fires before
   Bash evaluates the command). The hook strips leading `KEY=VALUE`
   tokens from the command and, if `CR_SKIP=1` is among them, **exits 0**.
   Supported form: env assignments must precede the `git` token, e.g.
   `CR_SKIP=1 git push …` or `CR_SKIP=1 OTHER=2 git push …`. The hook
   also honours `CR_SKIP=1` set via `export` in a prior turn (it appears in
   the hook's own env then).
3. Read `~/.code-reviewer/config.json`. If missing/malformed → **exit 0
   silently** (don't gate users who haven't set up).
4. If `auto_trigger == false` → exit 0.
5. Detect repo + branch. If not in a git repo → exit 0. If branch is in
   `skip_branches` → exit 0.
6. Resolve ledger path from `review_output_path` + repo-slug + branch-slug.
7. Run gate conditions (Section 5.3). On pass → exit 0. On fail → deny with
   structured reason.

### 5.3 Gate conditions

The gate proceeds in this order; the first short-circuit decides:

```
# 0. Nothing-to-push bypass — derive the *effective remote ref* the push
#    will move, from the parsed push form (see §5.7), and check whether
#    HEAD has any commits ahead of it. Local dirty state is irrelevant.
#
#    effective_remote_ref derivation (matches the intercepted forms in §5.7):
#
#      `git push` (no args) — depends on push.default. Read once via
#          `git config --get push.default` (treat empty/unset as `simple`,
#          which is git's modern default).
#        - push.default == simple   → @{u}    (git also requires upstream
#                                              and current-branch names to
#                                              match; if they don't, the
#                                              push would fail anyway — the
#                                              gate matches what would have
#                                              been pushed had it worked)
#        - push.default == upstream → @{u}
#        - push.default == current  → origin/<current-branch>
#                                     (NOT @{u} — `current` pushes to the
#                                     remote ref of the same name as the
#                                     local branch, regardless of where
#                                     @{u} happens to point)
#        - push.default == matching / nothing / anything else
#                                   → NOT INTERCEPTED (per §5.7); the
#                                     hook exits 0 silently and no
#                                     derivation is attempted
#
#      `git push origin HEAD`                          → @{u}
#      `git push origin <current-branch>`              → origin/<current-branch>
#      `git push origin HEAD:<current-branch>`         → origin/<current-branch>
#      `git push -u origin <current-branch>` / --set-upstream
#                                                       → origin/<current-branch>
#                                                         if it exists, else
#                                                         "everything is new"
#                                                         (no bypass)
#      `git push --force[-with-lease] <inner-form>`    → derive from the
#                                                         inner form
#
#    If the effective remote ref doesn't resolve (first push to this
#    branch, no remote ref yet), there is "everything to gate" — do not
#    bypass.
if effective_remote_ref resolves AND no commits ahead of effective_remote_ref:
  exit 0  # nothing to gate

# 1. Ledger must exist for this branch
if not ledger.exists:
  deny("no_ledger")

# 2. Compute the current base SHA before filtering, so base compatibility
#    can be part of the matching predicate (not a post-filter).
#    The hook uses its own resolution chain (no --base, no config lookup):
#      current_base_ref = first of {@{u}, origin/main, origin/master, main, master} that resolves
#      current_base_sha = git rev-parse <current_base_ref>   (empty if nothing resolves)
current_base_ref = resolve_first(@{u}, origin/main, origin/master, main, master)
current_base_sha = git rev-parse "$current_base_ref" 2>/dev/null  # empty for brand-new repo

def base_compatible(r):
  if not current_base_sha:    # no upstream → skip base check
    return True
  if r.base_sha == current_base_sha:
    return True
  return git merge-base --is-ancestor r.base_sha current_base_sha

# 3. Find entries matching state + base compatibility + clean review
#    + dismissals match.
#    `git push` only ships commits — never uncommitted work. So an approval
#    authorises a push when the approval itself was of a CLEAN tree
#    (worktree_hash == null). The CURRENT worktree state is irrelevant.
#    Dismissals affect verdicts, so the approval is only valid while the
#    DISMISSALS.md is in the same state it was at review time.
current_dismissals_hash = sha256(DISMISSALS.md contents) or null
matching = [r for r in ledger.reviews
            if r.head_sha == current_head_sha
            and r.worktree_hash == null              # clean review only
            and r.dismissals_hash == current_dismissals_hash
            and base_compatible(r)]

if not matching:
  # Categorise the failure for a useful deny reason
  same_head_any   = [r for r in ledger.reviews if r.head_sha == current_head_sha]
  same_head_clean = [r for r in same_head_any  if r.worktree_hash == null]
  same_head_clean_baseok = [r for r in same_head_clean if base_compatible(r)]
  if not same_head_any:
    deny("head_changed")
  elif not same_head_clean:
    deny("commit_needed")        # HEAD only reviewed with a dirty worktree
  elif not same_head_clean_baseok:
    deny("base_drifted")
  else:
    deny("dismissals_changed")   # DISMISSALS.md changed since approval

# 4. Latest matching entry decides
latest = matching[-1]
if latest.verdict in {APPROVE, APPROVE_WITH_COMMENTS}:
  exit 0
else:
  deny("not_approved")
```

Notes on the base check:

- Base compatibility is part of the **matching predicate**, not a
  post-filter. This matters when the same `(head_sha, worktree_hash)` was
  reviewed against different bases: an older compatible approval is not
  ignored just because a newer incompatible review was logged.
- **The hook and `context.sh` use different base-resolution chains** on
  purpose:
  - `context.sh` (review-time): `--base <ref>` flag → `config.base_branch`
    → `@{u}` → `origin/main` → `origin/master`. The user can target an
    arbitrary base for a review.
  - **Hook (push-time):** `@{u}` (what `git push` actually targets) →
    `origin/main` → `origin/master`. The hook never honours the historical
    `--base` flag because it has no access to the slash command's arguments
    — it can only see the current git state. This is intentional: the gate
    must compare against what the push will move, not what the review
    happened to target.
- Consequence: an ad-hoc `/code-reviewer:start --base origin/develop` whose
  result is then used to push to `origin/main` may produce a `base_drifted`
  deny if `origin/develop` is not an ancestor of `origin/main`. The
  operator fix is to either (a) set `config.base_branch` so the review
  consistently uses the same base the push will use, or (b) re-run the
  review without `--base` so it picks up the upstream automatically.
- A review entry is **base-compatible** with the current state when its
  `base_sha` equals `current_base_sha` OR is an ancestor of it (i.e., the
  review covered at least what the push will move).
- If the upstream / base ref has never existed locally (brand-new repo),
  the base predicate returns true (no current_base_sha to compare against).

Two important properties of this gate:

- **Matching on the (`head_sha`, `worktree_hash`) tuple** means a previously
  approved clean state, then a dirty rejected state, then a return to clean
  → allow. The most recent review of *this exact state* is what matters.
- **Verdict reflects current findings** (because of the §4.2 carry-forward
  rule). A Delta that produces APPROVE is asserting that no prior
  finding remains unresolved. The gate doesn't need to walk the entire
  history.

Deny reason keys:

| Failure | Reason key |
|---|---|
| Ledger missing | `no_ledger` |
| HEAD never reviewed at any state | `head_changed` |
| HEAD was only reviewed with a dirty worktree (no clean approval exists) | `commit_needed` |
| Base has commits not covered by the review | `base_drifted` |
| `DISMISSALS.md` changed since the approval | `dismissals_changed` |
| Latest matching entry's verdict is BLOCK or REQUEST_CHANGES | `not_approved` |

> **Why no `worktree_changed`?** A dirty-tree review never authorises a
> push (it covers content that isn't being pushed). And the gate doesn't
> care about the **current** worktree state at all — `git push` only ships
> commits, so local uncommitted work (related or unrelated) is invisible
> to the push. The only worktree-related deny is `commit_needed`, which
> fires when the user's HEAD has *only* been reviewed in dirty states and
> no clean approval exists.

### 5.4 Hook output

Conceptual JSON output on stdout when denying:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "code-reviewer: <human_message>\n\n<orchestration_block>"
  }
}
```

On allow, exit 0 with no output.

**`<human_message>` map** — substituted by the hook from the deny reason
key (raw keys read poorly):

| Deny reason key | `<human_message>` |
|---|---|
| `no_ledger` | "No prior review exists for branch `<branch>`. Run `/code-reviewer:start --full` first." |
| `head_changed` | "Branch `<branch>` has commits beyond the last reviewed HEAD. The new commits have not been reviewed." |
| `commit_needed` | "Branch `<branch>` was only reviewed with uncommitted changes in the working tree. Commit them and re-run `/code-reviewer:start --delta` so a clean approval exists." |
| `base_drifted` | "The base ref (`<current_base_ref>`) has commits not covered by the prior review's base (`<prev_base_sha_short>`). Re-run `/code-reviewer:start --full`." |
| `dismissals_changed` | "`DISMISSALS.md` has changed since the last approval. Re-run `/code-reviewer:start --delta` to re-evaluate." |
| `not_approved` | "The latest matching review verdict is `<verdict>`. Address the findings or use `CR_SKIP=1 git push` to override." |

**`<orchestration_block>`** is the fixed text below; the hook always emits
this verbatim so Claude has a stable signal to detect:

```
Claude: present these options to the user via AskUserQuestion before
retrying:

  • Delta review (recommended — fast review of new material since last review)
  • Full review (re-download Jira/Confluence; review entire branch)
  • Skip review (push without review; retry with CR_SKIP=1)
  • Discuss

After the user picks, run /code-reviewer:start with the appropriate flag
and retry the push. If "Skip" was chosen, retry with CR_SKIP=1 in env.
```

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
| `skip_branches: ["main", ...]` | Per-branch opt-out from the plugin entirely |

`CR_SKIP=1` is **not** recorded in the ledger. The absence of an approved
ledger entry alongside a push tells that story implicitly.

### 5.7 Supported push forms

The hook only intercepts **simple** `git push` invocations from Claude's
Bash tool. For anything else, it exits 0 silently — the user is doing
something deliberate and the gate would be guessing.

**Intercepted (gated)** — only forms where we can prove the push is the
current branch's HEAD:

- `git push origin <current-branch>`            ← explicit current branch
- `git push origin HEAD`                        ← explicit HEAD
- `git push -u origin <current-branch>` / `--set-upstream`
- `git push origin HEAD:<current-branch>`       ← explicit src=HEAD
- `git push --force` / `--force-with-lease` when combined with one of the
  above explicit forms                          ← force still gates
- `git push` (no args) **only when** `git config --get push.default`
  resolves to one of `simple`, `current`, or `upstream`. Treat empty /
  unset as `simple` (git's modern default). The hook reads
  `push.default` once and intercepts only if the resolved value is in
  this allow-list. The push target derivation differs by value (see
  §5.3 step 0 for the full mapping). Other values (`matching`,
  `nothing`, deprecated `tracking`, etc.) → not intercepted.

**Not intercepted (allowed silently)** — anywhere the gate would be guessing:

- `git -C <path> push …`                       ← different repo path
- `cd <path> && git push …`                    ← shell dir change before push
- `git push origin` (bare, without explicit ref) when `push.default` is not
  in the allow-list above
- `git push <remote> <ref1> <ref2> …`          ← multiple refspecs
- `git push origin <local>:<remote>` where `<local>` is not HEAD or the
  current branch                                ← refspec to non-current
- `git push --tags` / `git push --follow-tags`  ← tags can point at refs
  unrelated to HEAD
- `git push --delete origin <ref>`              ← deletion, not a content push
- `git push --mirror` / `--all`                 ← pushes everything
- Any push command parsed via shell substitution Claude cannot statically
  analyse (e.g. `git push $(detect_branch)`)

Rationale: detecting these reliably requires either re-implementing git's
argument parser in the hook or running the command in dry-run mode (which
has its own side effects). Both are over-engineering. If the user wants the
gate to fire on a non-simple push, they re-arrange the command, or accept
that the gate is bypassed and `/code-reviewer:start` can be run explicitly.

Not-intercepted forms exit 0 with **no output**. The user is presumed to
know they're doing something the hook doesn't gate; adding stderr noise on
every such push would be more annoying than useful. If the user wants a
review for one of those forms, they run `/code-reviewer:start` explicitly.

## 6. Phase 7 hand-off & Open Questions

### 6.1 Open Questions section

Every individual reviewer is instructed: when intent is unclear from the
diff + commits + Jira ticket, do not guess — file an Open Question. Format
in their `## Open Questions` section:

```markdown
### OQ. <one-line summary>

- **Category:** `IntentAmbiguity` | `MissingContext` | `ConflictingSignals` | `OutOfScopeConcern` (per the §4.5 enum for `open_questions[]`)
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
- Coverage gaps: <count>           ← count of findings whose `category` is `TestCoverage` (per the §4.5 enum)

## Intent Check vs Jira <KEY>
Goal: <paraphrase>
Achieved? <Yes|Partially|No> — <one paragraph>
```

When the verdict is not `[APPROVE]`, append:

> *To push anyway without addressing findings: ask me to push and I'll run `CR_SKIP=1 git push` for that single push.*

When the working tree was dirty during this review, the rich-text output
also includes:

> *This review covered uncommitted changes (`worktree_hash != null`). It
> does NOT authorise `git push` — pushes only ship commits. Commit the
> changes and re-run `/code-reviewer:start --delta` (a fast incremental
> review of just the new commit) so the ledger has a clean approval at
> the new HEAD, which the push gate can use.*

When the report has findings, append:

> *To dismiss a finding as a false positive: ask me to dismiss it with a reason.*
> *To undo a previous dismissal: ask me to remove it. Future reviews will be free to re-flag it.*

### 6.2.1 Phase 7 rich-text — failure path

When the §4.5 validation gate failed (no ledger entry was appended, a
`REVIEW_FAILED.md` was written), Phase 7 does **not** render the standard
template above. Instead it emits a tight failure report:

```
# Code review FAILED

The arbiter produced output that failed validation. No ledger entry was
written — the push gate will continue to deny.

**Round dir:** <round_dir>
**Failure marker:** <round_dir>/REVIEW_FAILED.md
**Validation errors:** <round_dir>/validation-errors.md
**Invalid arbiter output:** <round_dir>/findings.json.invalid

**Mode attempted:** <Delta|Full>
**Retries used:** <0 or 1>
**First error:** <one-line summary from validation-errors.md>

The most likely causes are:
- The arbiter dropped or invented a finding ID
- The arbiter cited a dismissal that doesn't exist in DISMISSALS.md
- The arbiter emitted a finding whose fingerprint matches an active
  dismissal (it should have suppressed the finding instead)
- The recorded verdict doesn't match what the listed findings would
  produce per the §7 rubric

What to do next:
- Re-run `/code-reviewer:start --full` to rebuild from scratch.
- Inspect `<round_dir>/validation-errors.md` for the full list.
- If you suspect a transient agent failure, retry first.
```

Then a single AskUserQuestion follow-up (hint to main session):

> **What now?**

Options:
- **Retry as Full review** — invokes `/code-reviewer:start --full`.
- **Inspect the failure** — opens the validation errors with the user.
- **Skip this push** — user runs `CR_SKIP=1 git push` if they understand
  the risk.

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

- Verdict tier = highest unresolved finding severity across **all currently
  present findings**, including those carried forward from a prior review
  (per §4.2 step 5). A Delta cannot APPROVE while any prior finding remains
  unresolved against the current branch state.
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
with `skip_branches: []` config (default empty). When the current
branch is in `skip_branches`:

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
  "skip_branches": [],
  "keep_last_rounds": 10,


  "jira_base_url": "",
  "jira_email": "",
  "jira_api_token": ""
}
```

New keys are additive — existing v0.3.0 configs continue to work; missing
new keys default.

**Constraints:**

- `keep_last_rounds`: integer, must be `>= 1`. The setup wizard and
  `context.sh` reject smaller values. Pruning will never delete the most
  recent round directory even when `keep_last_rounds == 1`.
- `review_output_path`: string. `~` is expanded; relative paths resolve
  against `$REPO_ROOT`.
- `auto_trigger`: boolean. When `false`, the hook exits 0 silently.
- `skip_branches`: array of strings. Exact-match against `git rev-parse
  --abbrev-ref HEAD`.

## 10. New commands

| Slash command | Status | Purpose |
|---|---|---|
| `/code-reviewer:setup` | Changed | Adds the four new keys to the wizard (`review_output_path`, `auto_trigger`, `skip_branches`, `keep_last_rounds`) |
| `/code-reviewer:start [--delta\|--full] [--ticket K] [--base R] [--no-prune]` | Changed | New `--delta` / `--full` mode flags; `--no-prune` skips within-branch timestamp pruning for this run (debugging / history preservation) |
| `/code-reviewer:autodetect [true\|false]` | **New** | Toggle `auto_trigger`. No-arg form prints current state |
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

Six new files (counted below), plus changes to existing files.

```
.claude-plugin/
  plugin.json                                ← bump 0.3.0 → 0.4.0
  marketplace.json                           ← bump
  hooks.json                                 ← NEW

agents/
  arbiter.md                                 ← UPDATED: verdict rubric (incl. carry-forward), linter exclusion, OQ consolidation, dismissals, emit findings.json per §3.3 schema
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
  context.sh                                 ← UPDATED: drop hardcoded protected list, --delta/--full, new path layout, ledger append, read DISMISSALS, atomic write + lock, replace cross-branch cleanup with within-branch timestamp pruning (keep_last_rounds)
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
- **Concurrent runs:** atomic ledger writes + a per-branch file lock
  created via `set -o noclobber; echo $$ > $LOCK_FILE` (see §3.2 for the
  full lifecycle). Second runner sees "another review is in progress at
  `<round_dir>`" and exits.
- **Missing or malformed config when hook fires:** hook exits 0 silently.

### Documented behaviour (no extra design needed)

| Edge case | Behaviour |
|---|---|
| Brand-new repo, no `origin/main` | Base resolution fails; user passes `--base` |
| Detached HEAD | Hook exits 0; start refuses |
| No commits ahead + clean tree | Start exits "nothing to review"; hook exits 0 via §5.3 step 0 |
| Same HEAD reviewed twice with different worktree states | Gate matches on (head_sha, worktree_hash) tuple; latest matching entry decides (§5.3) |
| Stale `.jira-cache/` and Full mode Jira fetch fails | Stale cache is preserved; warning written to `context/jira.warn` (§4.3) |
| More than `keep_last_rounds` round dirs accumulated | Oldest timestamp dirs are pruned on next `/code-reviewer:start`; ledger/dismissals/cache untouched |
| `git -C <path> push` / `cd <path> && git push` / multi-refspec push | Hook exits 0 silently (§5.7); user invokes `/code-reviewer:start` manually if they want review |
| Carried-forward finding is fixed by new diff | Arbiter lists it under Regression as "Resolved since last review" and drops from the new findings list (§4.2 step 5) |
| First-ever branch review | No ledger → Full |
| `--delta` with no ledger | Error: run `--full` first |
| Rebase / force-push in Delta | Auto-fallback to Full, `fallback_reason` recorded |
| `git push --dry-run` | Falls under the matching intercepted form (e.g. `git push` alone is gated only when `push.default ∈ {simple, current, upstream}`; an explicit-current-branch form is always gated). `--dry-run` itself doesn't change the interception decision. `CR_SKIP=1` bypasses |
| Force push | Gated normally |
| Push refspec to other branch (`git push origin local:other`) | **Not** intercepted (§5.7). User invokes `/code-reviewer:start` manually if they want review. Documented here for clarity |
| Non-Claude shell pushes | Not intercepted (out of scope) |
| Branch in `skip_branches` | Plugin refuses; hook exits 0 |
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
- (Resolved in rev 10: the lock is a regular file created via
  `set -o noclobber; echo $$ > $LOCK_FILE`. Portable across macOS and
  Linux without `flock(1)`. No mkdir fallback needed.)

## 13. Out of scope for this design

- A git-side `pre-push` hook (would gate CLI-issued pushes, not just
  Claude-initiated). Server-side enforcement is a separate feature.
- Cross-branch dismissal inheritance (e.g., dismissals on a merged feature
  branch propagating to main).
- Chunked review of very large diffs.
- A `/code-reviewer:cleanup` skill that nukes whole branch folders or
  cross-branch state. Within-branch timestamp pruning (controlled by
  `keep_last_rounds`) handles routine accumulation; users who want to wipe
  a branch's state can `rm -rf <review_output_path>/<repo-slug>/<branch>/`
  manually. A dedicated cleanup skill can come in a later version.
- Per-finding fingerprinting beyond `file:line + summary` — not needed for
  v1 dismissals.
- Telemetry / observability (phase timing, agent cost reporting).
- A SessionStart hook for nudging "you have unreviewed commits" — explicitly
  declined in favour of "A only" hook strategy.
