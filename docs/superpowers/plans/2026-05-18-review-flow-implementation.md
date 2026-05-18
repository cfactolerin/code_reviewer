# code-reviewer v0.4.0 — Review Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement v0.4.0 of the `code-reviewer` plugin: Delta/Full review modes, per-branch ledger with `dismissed_active` and `obsolete_dismissals`, PreToolUse hook on `git push` with verdict gating, Open Questions, DISMISSALS.md, validated `findings.json`, plus two new skills (`autodetect`, `dismiss`).

**Architecture:** Plugin is pure shell + small Python helpers (no Rust binary). Per-branch state at `<review_output_path>/<repo-slug>/<branch-slug>/` (default `/tmp/code-reviewer/`) contains `.review-ledger.json`, `REVIEW_LEDGER.md`, `DISMISSALS.md`, `.jira-cache/`, and one round directory per review with `findings.json`, `FINAL_REVIEW_RESULTS.md`, etc. A PreToolUse hook on `Bash` gates `git push` by reading the ledger and checking `(head_sha, worktree_hash=null, base-compatible, dismissals_hash, verdict approved)` predicates against the current state derived from the parsed push form.

**Tech Stack:** bash (zsh-compatible), jq, python3 stdlib, git. Test harness: pure-bash test runner + fixture git repos under `/tmp/cr-test-fixtures/`.

**Spec:** [`docs/superpowers/specs/2026-05-18-review-flow-design.md`](../specs/2026-05-18-review-flow-design.md) — approved rev 13.

---

## Phase ordering

The 20 tasks below are grouped into phases. Each phase produces useful artefacts even before the whole plan is complete, but the full v0.4.0 only works end-to-end after Task 20.

- **A. Foundations (Tasks 1–5):** test harness, hash helpers, ledger, dismissals helper, findings validator.
- **B. Hook (Task 6):** PreToolUse hook + hooks.json.
- **C. Orchestration (Tasks 7–9):** `context.sh` updates.
- **D. Prompts (Tasks 10–11):** `prompt.sh` updates for Delta/Full and validation feedback.
- **E. Jira (Task 12):** `jira-fetch.py` attachments + safe refresh.
- **F. Agents (Tasks 13–14):** reviewer-prompt and arbiter updates.
- **G. Skills (Tasks 15–18):** `setup`, `autodetect`, `dismiss`, `start`.
- **H. Docs + ship (Tasks 19–20):** README/CLAUDE.md, version bump, smoke test, commit.

---

## File structure

### New files

| Path | Purpose | Tested by |
|---|---|---|
| `.claude-plugin/hooks.json` | Hook registration manifest | Task 6 |
| `scripts/hooks/pre-push.sh` | PreToolUse hook gate | Task 6 |
| `scripts/ledger.sh` | Append/list/render `.review-ledger.json` and `REVIEW_LEDGER.md` | Task 3 |
| `scripts/dismiss.sh` | Add/remove/list dismissals in `DISMISSALS.md` | Task 4 |
| `scripts/validate-findings.py` | Validate `findings.json` per §4.5 (rules 1–9) | Task 5 |
| `skills/code-reviewer-autodetect/SKILL.md` | Toggle `auto_trigger` | Task 16 |
| `skills/code-reviewer-dismiss/SKILL.md` | Wrap `scripts/dismiss.sh` for natural-language dismissal | Task 17 |
| `tests/run.sh` | Test discovery + runner | Task 1 |
| `tests/lib.sh` | Test fixture helpers (`setup_fixture_repo`, `teardown_fixture_repo`) | Task 1 |
| `tests/*.test.sh` | Per-script tests (created alongside their targets) | Tasks 2–6 |

### Modified files

| Path | What changes | Tested by |
|---|---|---|
| `scripts/lib.sh` | Add `cr_worktree_hash`, `cr_dismissals_hash`, repo-slug helper, review_output_path resolver | Task 2 |
| `scripts/context.sh` | Drop hardcoded protected list; `--delta`/`--full`; new path layout; ledger append; read DISMISSALS; atomic write + lock; replace cross-branch cleanup with within-branch timestamp pruning; new validation phase | Tasks 7–9 |
| `scripts/prompt.sh` | Delta/Full variants; include DISMISSALS; include `prior_findings.json` framing; include obsolete_dismissals instructions in arbiter prompt | Tasks 10–11 |
| `scripts/jira-fetch.py` | Download attachments to `.jira-cache/<KEY>/attachments/`; cache Confluence pages; `--mode=full` flag forces refresh | Task 12 |
| `agents/claude-reviewer.md` | OQ rule, dismissals rule, linter rule, delta/full awareness, finding-vs-OQ guidance | Task 13 |
| `agents/codex-reviewer.md` | Same | Task 13 |
| `agents/gemini-reviewer.md` | Same | Task 13 |
| `agents/opencode-reviewer.md` | Same | Task 13 |
| `agents/arbiter.md` | Verdict rubric (incl. carry-forward), linter exclusion, OQ consolidation, dismissals, emit `findings.json` per §3.3 schema, `obsolete_dismissals` accounting | Task 14 |
| `skills/code-reviewer-setup/SKILL.md` | New keys: `review_output_path`, `auto_trigger`, `skip_branches`, `keep_last_rounds` | Task 15 |
| `skills/code-reviewer-start/SKILL.md` | `--delta`/`--full`, nothing-new early exit, Phase 7 refactor (rich-text + AskUserQuestion), failure-case Phase 7.1, post-review validation | Task 18 |
| `README.md` | New flags, hook, dismissals, OQs, override path | Task 19 |
| `CLAUDE.md` | Developer-side docs for new components | Task 19 |
| `.claude-plugin/plugin.json` | `version: "0.4.0"` | Task 20 |
| `.claude-plugin/marketplace.json` | `version: "0.4.0"` | Task 20 |

---

## Conventions used in this plan

- **Shell scripts:** `set -u` and `set -o pipefail` (no `set -e` — handle errors explicitly).
- **Tests:** each test file is `tests/<topic>.test.sh`. Exit 0 = pass, non-zero = fail. Source `tests/lib.sh` for fixture helpers. Each test cleans up its own fixtures with a trap.
- **Run tests:** `bash tests/run.sh` (discovers everything matching `tests/*.test.sh`).
- **Commits per task:** one commit at the end of each task with a `feat:`, `fix:`, `test:`, or `docs:` prefix. Keep test + impl in the same commit.
- **TDD discipline:** write the failing test first, run it (must fail), then implement, then run the test (must pass).

---

## Task 1: Test harness

**Files:**
- Create: `tests/run.sh`
- Create: `tests/lib.sh`
- Create: `tests/smoke.test.sh`

- [ ] **Step 1: Write `tests/lib.sh`** — fixture helpers used by every other test.

```bash
#!/usr/bin/env bash
# Test fixture helpers. Source from each tests/*.test.sh:
#   . "$(dirname "$0")/lib.sh"
# Provides:
#   setup_fixture_repo   — creates /tmp/cr-test-fixtures/$$/<name>/ as a git repo, prints its path
#   teardown_all         — wipes /tmp/cr-test-fixtures/$$/ (call from a trap)
#   assert_eq            — assert string equality, fail loudly
#   assert_contains      — assert substring presence
#   assert_exit          — assert exit code matches

CR_TEST_ROOT="/tmp/cr-test-fixtures/$$"

setup_fixture_repo() {
  local name="${1:-repo}"
  local dir="$CR_TEST_ROOT/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
  echo "initial" > "$dir/README"
  git -C "$dir" add README
  git -C "$dir" commit -qm "initial"
  git -C "$dir" branch -m main
  echo "$dir"
}

teardown_all() {
  rm -rf "$CR_TEST_ROOT"
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: ${msg:-assert_eq}" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *)
      echo "FAIL: ${msg:-assert_contains}" >&2
      echo "  haystack: $haystack" >&2
      echo "  needle:   $needle" >&2
      exit 1
      ;;
  esac
}

assert_exit() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: ${msg:-assert_exit} — expected exit $expected, got $actual" >&2
    exit 1
  fi
}
```

- [ ] **Step 2: Write `tests/run.sh`** — discovers and runs every `tests/*.test.sh`.

```bash
#!/usr/bin/env bash
set -u

cd "$(dirname "$0")"
failed=0
passed=0

for t in *.test.sh; do
  [ -f "$t" ] || continue
  printf "RUN  %s ... " "$t"
  if bash "$t" >/tmp/cr-test-out.$$ 2>&1; then
    echo "PASS"
    passed=$((passed + 1))
  else
    echo "FAIL"
    cat /tmp/cr-test-out.$$
    failed=$((failed + 1))
  fi
  rm -f /tmp/cr-test-out.$$
done

echo
echo "RESULT: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 3: Write `tests/smoke.test.sh`** — a one-liner sanity check that the harness works.

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
trap teardown_all EXIT

repo=$(setup_fixture_repo smoke)
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
assert_eq "$branch" "main" "fixture should start on main"
echo "smoke OK"
```

- [ ] **Step 4: Make scripts executable and run the smoke test.**

```bash
chmod +x tests/run.sh tests/lib.sh tests/smoke.test.sh
bash tests/run.sh
```

Expected output:

```
RUN  smoke.test.sh ... PASS

RESULT: 1 passed, 0 failed
```

- [ ] **Step 5: Commit.**

```bash
git add tests/
git commit -m "test: add bash test harness with fixture helpers"
```

---

## Task 2: Hash helpers + `review_output_path` resolver in `lib.sh`

**Files:**
- Modify: `scripts/lib.sh`
- Create: `tests/lib-helpers.test.sh`

- [ ] **Step 1: Write the failing test** — covers `cr_worktree_hash`, `cr_dismissals_hash`, `cr_repo_slug`, `cr_review_output_path`.

```bash
#!/usr/bin/env bash
# tests/lib-helpers.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
. "$SCRIPTS/lib.sh"
trap teardown_all EXIT

# --- cr_repo_slug ---
assert_eq "$(cr_repo_slug /tmp/foo-bar)"          "foo-bar"          "basic slug"
assert_eq "$(cr_repo_slug /tmp/My.Project!)"      "My_Project_"      "sanitise non-alnum"
assert_eq "$(cr_repo_slug /a/b/c/code_reviewer)"  "code_reviewer"    "underscore preserved"

# --- cr_review_output_path ---
unset CR_CONFIG_DIR
mkdir -p /tmp/cr-conf-$$ ; export CR_CONFIG_DIR=/tmp/cr-conf-$$
assert_eq "$(cr_review_output_path /tmp/repo)"    "/tmp/code-reviewer" "default when no config"
echo '{"review_output_path":"/tmp/custom"}' > "$CR_CONFIG_DIR/config.json"
assert_eq "$(cr_review_output_path /tmp/repo)"    "/tmp/custom"        "explicit absolute path"
echo '{"review_output_path":"~/reviews"}' > "$CR_CONFIG_DIR/config.json"
assert_eq "$(cr_review_output_path /tmp/repo)"    "$HOME/reviews"      "~ expansion"
echo '{"review_output_path":"tmp/code-reviews"}' > "$CR_CONFIG_DIR/config.json"
assert_eq "$(cr_review_output_path /tmp/repo)"    "/tmp/repo/tmp/code-reviews" "relative resolves against repo root"
rm -rf "$CR_CONFIG_DIR"; unset CR_CONFIG_DIR

# --- cr_worktree_hash ---
repo=$(setup_fixture_repo wt)
cd "$repo"

# clean tree → null
assert_eq "$(cr_worktree_hash)" "" "clean tree → empty"

# modified tracked file → non-empty
echo "modification" >> README
h1=$(cr_worktree_hash)
[ -n "$h1" ] || { echo "FAIL: dirty tree should produce hash"; exit 1; }

# different modification → different hash
echo "extra"        >> README
h2=$(cr_worktree_hash)
[ "$h1" != "$h2" ] || { echo "FAIL: different dirty states should differ"; exit 1; }

# revert → null again
git checkout -- README
assert_eq "$(cr_worktree_hash)" "" "reverted tree → empty"

# untracked file → non-empty
echo "new" > new.txt
h3=$(cr_worktree_hash)
[ -n "$h3" ] || { echo "FAIL: untracked file should produce hash"; exit 1; }

# changing untracked content → different hash
echo "newer" > new.txt
h4=$(cr_worktree_hash)
[ "$h3" != "$h4" ] || { echo "FAIL: untracked content change should change hash"; exit 1; }

# .gitignore'd file should not affect hash
echo "*.log" > .gitignore
git add .gitignore && git commit -qm "ignore logs"
rm new.txt
assert_eq "$(cr_worktree_hash)" "" "fully clean again"
echo "logfile" > debug.log
assert_eq "$(cr_worktree_hash)" "" "ignored file does not affect hash"
cd /

# --- cr_dismissals_hash ---
mkdir -p /tmp/cr-dh-$$
assert_eq "$(cr_dismissals_hash /tmp/cr-dh-$$/DISMISSALS.md)" "" "missing file → empty"
echo "content" > /tmp/cr-dh-$$/DISMISSALS.md
dh1=$(cr_dismissals_hash /tmp/cr-dh-$$/DISMISSALS.md)
[ -n "$dh1" ] || { echo "FAIL: present file should hash"; exit 1; }
echo "more"   >> /tmp/cr-dh-$$/DISMISSALS.md
dh2=$(cr_dismissals_hash /tmp/cr-dh-$$/DISMISSALS.md)
[ "$dh1" != "$dh2" ] || { echo "FAIL: changed contents → different hash"; exit 1; }
rm -rf /tmp/cr-dh-$$

echo "lib-helpers OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
bash tests/run.sh
```

Expected: `FAIL` on `lib-helpers.test.sh` because the new helpers don't exist yet.

- [ ] **Step 3: Add helpers to `scripts/lib.sh`.** Append the following to the existing file (don't remove existing helpers):

```bash
# --- v0.4.0 helpers ---

# Sanitise a repo basename for use under <review_output_path>/<repo-slug>/
cr_repo_slug() {
  local path="$1"
  basename "$path" | tr -c 'A-Za-z0-9_-' '_'
}

# Resolve the configured review_output_path (default /tmp/code-reviewer).
# - absolute path: used as-is
# - leading `~`:   expanded to $HOME
# - relative path: resolved against the repo root passed as $1
cr_review_output_path() {
  local repo_root="$1"
  local cfg="${CR_CONFIG_DIR:-$HOME/.code-reviewer}/config.json"
  local p
  if [ -f "$cfg" ]; then
    p=$(jq -r '.review_output_path // empty' "$cfg" 2>/dev/null)
  fi
  : "${p:=/tmp/code-reviewer}"
  case "$p" in
    "~"|"~/"*) p="$HOME${p#'~'}" ;;
    /*) : ;;
    *)  p="$repo_root/$p" ;;
  esac
  echo "$p"
}

# Worktree hash per spec §3.2.
# Output: hex digest of (git diff HEAD --binary, neutralised) ++ "\0\0" ++ untracked-content-manifest.
# Empty when the tree is clean.
cr_worktree_hash() {
  local diff untracked manifest tmp
  diff=$(git diff --no-ext-diff --no-color --no-textconv --binary HEAD 2>/dev/null)
  # Untracked-content manifest, respecting .gitignore. Sorted by path so the
  # order is deterministic.
  untracked=$(git ls-files --others --exclude-standard -z 2>/dev/null \
              | tr '\0' '\n' | LC_ALL=C sort)
  if [ -z "$diff" ] && [ -z "$untracked" ]; then
    return 0   # empty output → clean
  fi
  tmp=$(mktemp)
  {
    printf '%s' "$diff"
    printf '\0\0'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      printf '%s\0' "$f"
      stat -f '%p\0%HT\0' "$f" 2>/dev/null \
        || stat -c '%a\0%F\0' "$f" 2>/dev/null \
        || printf '?\0?\0'
      shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    done <<< "$untracked"
  } > "$tmp"
  shasum -a 256 "$tmp" | awk '{print $1}'
  rm -f "$tmp"
}

# Hash of DISMISSALS.md contents at the given path. Empty if the file is
# absent.
cr_dismissals_hash() {
  local path="$1"
  [ -f "$path" ] || return 0
  shasum -a 256 "$path" | awk '{print $1}'
}
```

- [ ] **Step 4: Run the test to verify it passes.**

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit.**

```bash
git add scripts/lib.sh tests/lib-helpers.test.sh
git commit -m "feat: add worktree_hash, dismissals_hash, repo-slug, review-path helpers (lib.sh)"
```

---

## Task 3: `scripts/ledger.sh` (append / list / render-md / acquire-lock)

**Files:**
- Create: `scripts/ledger.sh`
- Create: `tests/ledger.test.sh`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/ledger.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

dir=$(mktemp -d "$CR_TEST_ROOT/ledger-XXXX")
mkdir -p "$dir"
LEDGER="$dir/.review-ledger.json"

# --- append (creates file when missing) ---
bash "$SCRIPTS/ledger.sh" append "$LEDGER" '{
  "timestamp": "20260518-140000",
  "type": "full",
  "head_sha": "abc123",
  "base_ref": "origin/main",
  "base_sha": "f00ba8",
  "commits_reviewed": ["abc123"],
  "previous_head_sha": null,
  "worktree_hash": null,
  "dismissals_hash": null,
  "verdict": "APPROVE",
  "findings": {"critical":0,"high":0,"medium":0,"low":0},
  "open_questions": 0,
  "round_dir": "20260518-140000",
  "fallback_reason": null
}'

n=$(jq '.reviews | length' "$LEDGER")
assert_eq "$n" "1" "first append should create reviews=[1]"
v=$(jq -r '.reviews[0].verdict' "$LEDGER")
assert_eq "$v" "APPROVE" "verdict preserved"

# --- append (extends existing file, preserves top-level metadata) ---
bash "$SCRIPTS/ledger.sh" append "$LEDGER" '{
  "timestamp": "20260518-153000",
  "type": "delta",
  "head_sha": "def456",
  "base_ref": "origin/main",
  "base_sha": "f00ba8",
  "commits_reviewed": ["def456"],
  "previous_head_sha": "abc123",
  "worktree_hash": "7f3e",
  "dismissals_hash": null,
  "verdict": "REQUEST_CHANGES",
  "findings": {"critical":0,"high":2,"medium":1,"low":0},
  "open_questions": 1,
  "round_dir": "20260518-153000",
  "fallback_reason": null
}'

n=$(jq '.reviews | length' "$LEDGER")
assert_eq "$n" "2" "second append should bring length to 2"

# --- list (prints the entries as a table or JSON-per-line) ---
out=$(bash "$SCRIPTS/ledger.sh" list "$LEDGER")
assert_contains "$out" "20260518-140000"
assert_contains "$out" "20260518-153000"
assert_contains "$out" "REQUEST_CHANGES"

# --- render-md (regenerates a human-readable summary) ---
MD="$dir/REVIEW_LEDGER.md"
bash "$SCRIPTS/ledger.sh" render-md "$LEDGER" "$MD"
[ -f "$MD" ] || { echo "FAIL: render-md should write the .md path"; exit 1; }
assert_contains "$(cat "$MD")" "20260518-140000"
assert_contains "$(cat "$MD")" "APPROVE"

# --- lock acquire + release ---
LOCK="$dir/.review-ledger.lock"
bash "$SCRIPTS/ledger.sh" acquire-lock "$LOCK"
[ -f "$LOCK" ] || { echo "FAIL: lock file should exist after acquire"; exit 1; }

# second acquire should fail (file exists, owner alive)
out=$(bash "$SCRIPTS/ledger.sh" acquire-lock "$LOCK" 2>&1) && rc=$? || rc=$?
assert_exit "1" "$rc" "second acquire should fail"
assert_contains "$out" "in progress" "deny message"

# release + re-acquire works
bash "$SCRIPTS/ledger.sh" release-lock "$LOCK"
[ -f "$LOCK" ] && { echo "FAIL: lock should be gone after release"; exit 1; }
bash "$SCRIPTS/ledger.sh" acquire-lock "$LOCK"
bash "$SCRIPTS/ledger.sh" release-lock "$LOCK"

echo "ledger OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
bash tests/run.sh
```

Expected: `FAIL` on `ledger.test.sh` because the script doesn't exist.

- [ ] **Step 3: Create `scripts/ledger.sh`.**

```bash
#!/usr/bin/env bash
# Append/list/render the per-branch ledger and acquire/release its lock.
#
# Usage:
#   ledger.sh append      <ledger.json>  <entry-json>
#   ledger.sh list        <ledger.json>
#   ledger.sh render-md   <ledger.json>  <output.md>
#   ledger.sh acquire-lock <lock-path>
#   ledger.sh release-lock <lock-path>

set -u
set -o pipefail

cmd="${1:-}"; shift || true

case "$cmd" in
  append)
    ledger="${1:-}"; entry="${2:-}"
    [ -n "$ledger" ] && [ -n "$entry" ] || { echo "Usage: ledger.sh append <ledger.json> <entry-json>" >&2; exit 2; }
    mkdir -p "$(dirname "$ledger")"
    tmp=$(mktemp)
    if [ -s "$ledger" ]; then
      jq --argjson e "$entry" '.reviews += [$e]' "$ledger" > "$tmp"
    else
      # Initialise: pull branch/base_ref/jira_keys from the entry itself.
      jq --argjson e "$entry" '
        {
          branch:         ($e.branch // null),
          base_ref:       ($e.base_ref // null),
          jira_keys:      [],
          jira_cached_at: null,
          reviews:        [$e]
        }
      ' <<< '{}' > "$tmp"
    fi
    mv "$tmp" "$ledger"
    ;;

  list)
    ledger="${1:-}"
    [ -n "$ledger" ] && [ -f "$ledger" ] || { echo "Usage: ledger.sh list <ledger.json>" >&2; exit 2; }
    jq -r '
      .reviews[] |
      "\(.timestamp)\t\(.type)\t\(.verdict)\thead=\(.head_sha[0:7])\tworktree=\((.worktree_hash // "clean")[0:8])"
    ' "$ledger"
    ;;

  render-md)
    ledger="${1:-}"; out="${2:-}"
    [ -n "$ledger" ] && [ -n "$out" ] || { echo "Usage: ledger.sh render-md <ledger.json> <out.md>" >&2; exit 2; }
    [ -f "$ledger" ] || { echo "ledger not found: $ledger" >&2; exit 1; }
    {
      branch=$(jq -r '.branch // "?"' "$ledger")
      echo "# Review Ledger — $branch"
      echo
      echo "| Timestamp | Type | Verdict | Head | Worktree | Findings (C/H/M/L) | OQs |"
      echo "|---|---|---|---|---|---|---|"
      jq -r '
        .reviews[] |
        [
          .timestamp, .type, .verdict,
          (.head_sha[0:7]),
          ((.worktree_hash // "clean")[0:8]),
          "\(.findings.critical)/\(.findings.high)/\(.findings.medium)/\(.findings.low)",
          (.open_questions | tostring)
        ] | "| " + join(" | ") + " |"
      ' "$ledger"
    } > "$out"
    ;;

  acquire-lock)
    lock="${1:-}"
    [ -n "$lock" ] || { echo "Usage: ledger.sh acquire-lock <lock-path>" >&2; exit 2; }
    mkdir -p "$(dirname "$lock")"
    if ( set -o noclobber; echo $$ > "$lock" ) 2>/dev/null; then
      exit 0
    fi
    # Lock exists. Check if stale.
    pid=$(cat "$lock" 2>/dev/null || echo "")
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && \
       [ "$(find "$lock" -mmin +60 2>/dev/null || true)" != "" ]; then
      rm -f "$lock"
      if ( set -o noclobber; echo $$ > "$lock" ) 2>/dev/null; then
        echo "code-reviewer: cleaned stale lock (pid=$pid)" >&2
        exit 0
      fi
    fi
    echo "code-reviewer: another review is in progress (lock $lock, pid=$pid)" >&2
    exit 1
    ;;

  release-lock)
    lock="${1:-}"
    [ -n "$lock" ] || { echo "Usage: ledger.sh release-lock <lock-path>" >&2; exit 2; }
    rm -f "$lock"
    ;;

  *)
    echo "Usage: ledger.sh append|list|render-md|acquire-lock|release-lock <args>" >&2
    exit 2
    ;;
esac
```

Make it executable: `chmod +x scripts/ledger.sh`.

- [ ] **Step 4: Run the test to verify it passes.**

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit.**

```bash
git add scripts/ledger.sh tests/ledger.test.sh
git commit -m "feat: ledger.sh — append/list/render-md and file-based lock helpers"
```

---

## Task 4: `scripts/dismiss.sh` (add / remove / list with `**Fingerprint:**` parser)

**Files:**
- Create: `scripts/dismiss.sh`
- Create: `tests/dismiss.test.sh`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/dismiss.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

dir=$(mktemp -d "$CR_TEST_ROOT/dismiss-XXXX")
DISM="$dir/DISMISSALS.md"

# --- add creates file + writes section with **Fingerprint:** line ---
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/auth.rs:42" "missing null check" "middleware handles null"
[ -f "$DISM" ] || { echo "FAIL: dismiss add should create the file"; exit 1; }
assert_contains "$(cat "$DISM")" "## src/auth.rs:42 — missing null check"
assert_contains "$(cat "$DISM")" "**Fingerprint:** \`src/auth.rs:42:missing_null_check\`"
assert_contains "$(cat "$DISM")" "Reason: middleware handles null"

# --- add is idempotent: same file:line + summary → no duplicate ---
before=$(wc -l < "$DISM")
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/auth.rs:42" "missing null check" "different reason"
after=$(wc -l < "$DISM")
assert_eq "$before" "$after" "idempotent add should not change line count"

# --- list outputs one line per dismissal ---
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "src/auth.rs:42:missing_null_check"

# --- add a second dismissal, then list shows both ---
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/db.rs:120" "N+1" "bounded dataset"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "src/auth.rs:42:missing_null_check"
assert_contains "$out" "src/db.rs:120:n_plus_1"

# --- remove by file:line ---
bash "$SCRIPTS/dismiss.sh" remove "$DISM" "src/auth.rs:42"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
case "$out" in *"src/auth.rs:42:missing_null_check"*) echo "FAIL: should be removed"; exit 1 ;; esac
assert_contains "$out" "src/db.rs:120:n_plus_1"

# --- remove non-existent is a no-op ---
bash "$SCRIPTS/dismiss.sh" remove "$DISM" "no/such:99"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "src/db.rs:120:n_plus_1"

# --- slug rules: spaces, capitals, punctuation normalised ---
bash "$SCRIPTS/dismiss.sh" add "$DISM" "foo.py:10" "Mixed CASE & punct!" "x"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "foo.py:10:mixed_case___punct_"

echo "dismiss OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
bash tests/run.sh
```

Expected: `FAIL` on `dismiss.test.sh`.

- [ ] **Step 3: Create `scripts/dismiss.sh`.**

```bash
#!/usr/bin/env bash
# Manage DISMISSALS.md per spec §3.4. Each entry is a `## file:line — summary`
# heading with a `**Fingerprint:**` line that the parser keys on.
#
# Usage:
#   dismiss.sh add    <dism.md> <file:line> <summary> <reason>
#   dismiss.sh remove <dism.md> <file:line> [<summary-substring>]
#   dismiss.sh list   <dism.md>

set -u
set -o pipefail

# Slug a summary: lowercase, non-alnum → "_", collapse repeats handled implicitly.
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_'
}

fingerprint_for() {
  local file_line="$1" summary="$2"
  printf '%s:%s' "$file_line" "$(slug "$summary")"
}

cmd="${1:-}"; shift || true
file="${1:-}"; shift || true

case "$cmd" in
  add)
    floc="${1:-}"; summary="${2:-}"; reason="${3:-}"
    [ -n "$file" ] && [ -n "$floc" ] && [ -n "$summary" ] && [ -n "$reason" ] \
      || { echo "Usage: dismiss.sh add <file> <file:line> <summary> <reason>" >&2; exit 2; }
    fp=$(fingerprint_for "$floc" "$summary")
    # Idempotent: if a section with this fingerprint already exists, no-op.
    if [ -f "$file" ] && grep -qF "**Fingerprint:** \`$fp\`" "$file"; then
      echo "code-reviewer: already dismissed: $fp" >&2
      exit 0
    fi
    mkdir -p "$(dirname "$file")"
    : > "${file}.append.$$"
    [ -f "$file" ] && cat "$file" > "${file}.append.$$"
    {
      [ -f "$file" ] && [ -s "$file" ] && echo ""
      printf '## %s — %s\n\n' "$floc" "$summary"
      printf '**Fingerprint:** `%s`\n\n' "$fp"
      printf 'Dismissed: %s\n' "$(date +%Y-%m-%d)"
      printf 'Reason: %s\n' "$reason"
    } >> "${file}.append.$$"
    mv "${file}.append.$$" "$file"
    ;;

  remove)
    floc="${1:-}"; summary_sub="${2:-}"
    [ -n "$file" ] && [ -n "$floc" ] || { echo "Usage: dismiss.sh remove <file> <file:line> [<summary-substring>]" >&2; exit 2; }
    [ -f "$file" ] || { echo "code-reviewer: no DISMISSALS.md found" >&2; exit 0; }
    awk -v fl="$floc" -v sub="$summary_sub" '
      BEGIN { keep=1; buf=""; have_fp=0; matches=0 }
      /^## / {
        # Flush previous section.
        if (buf != "") {
          if (keep) printf "%s", buf
          buf=""; have_fp=0; matches=0
        }
        keep=1
        # Examine heading: does it start with "## <file:line> —"?
        if ($0 ~ "^## "fl" — ") {
          matches=1
        }
      }
      matches && /^\*\*Fingerprint:\*\*/ {
        # Honour summary substring filter if provided
        if (sub != "" && index($0, sub) == 0) {
          # different summary, leave section in place
        } else {
          keep=0
        }
      }
      { buf = buf $0 "\n" }
      END {
        if (buf != "" && keep) printf "%s", buf
      }
    ' "$file" > "${file}.new.$$"
    mv "${file}.new.$$" "$file"
    ;;

  list)
    [ -n "$file" ] || { echo "Usage: dismiss.sh list <file>" >&2; exit 2; }
    [ -f "$file" ] || exit 0
    awk '
      /^\*\*Fingerprint:\*\*[ \t]+`([^`]+)`/ {
        match($0, /`[^`]+`/)
        fp = substr($0, RSTART+1, RLENGTH-2)
        print fp
      }
    ' "$file"
    ;;

  *)
    echo "Usage: dismiss.sh add|remove|list <args>" >&2
    exit 2
    ;;
esac
```

Make it executable: `chmod +x scripts/dismiss.sh`.

- [ ] **Step 4: Run the test to verify it passes.**

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit.**

```bash
git add scripts/dismiss.sh tests/dismiss.test.sh
git commit -m "feat: dismiss.sh — add/remove/list with Fingerprint-keyed parser"
```

---

## Task 5: `scripts/validate-findings.py` (rules 1–9 from §4.5)

**Files:**
- Create: `scripts/validate-findings.py`
- Create: `tests/validate-findings.test.sh`
- Create: `tests/fixtures/findings/valid-minimal.json`
- Create: `tests/fixtures/findings/invalid-missing-field.json`
- Create: `tests/fixtures/findings/invalid-bad-verdict.json`
- Create: `tests/fixtures/findings/invalid-rubric-mismatch.json`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/validate-findings.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
FIX="$(cd "$(dirname "$0")/fixtures/findings" && pwd)"
trap teardown_all EXIT

# Valid minimal findings.json → exit 0
python3 "$SCRIPTS/validate-findings.py" "$FIX/valid-minimal.json" >/dev/null
assert_exit 0 "$?" "valid-minimal should validate"

# Missing required field → exit non-zero, error mentions the field
out=$(python3 "$SCRIPTS/validate-findings.py" "$FIX/invalid-missing-field.json" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "missing"

# Bad verdict enum value → exit non-zero, error mentions verdict
out=$(python3 "$SCRIPTS/validate-findings.py" "$FIX/invalid-bad-verdict.json" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "verdict"

# Verdict/severity rubric mismatch (verdict APPROVE with CRITICAL finding)
out=$(python3 "$SCRIPTS/validate-findings.py" "$FIX/invalid-rubric-mismatch.json" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "rubric"

# Carry-forward accounting (Delta) — provide a prior_findings.json
prior=$(mktemp); echo '[{"id":"F1","fingerprint":"a.py:10:x","severity":"HIGH","_was_dismissed":false}]' > "$prior"
new=$(mktemp)
# Build a findings.json that DROPS the prior finding (no carried_from, no resolved, no dismissed)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],
  "obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" --prior "$prior" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "carry-forward"
rm -f "$prior" "$new"

# Dismissal coherence — finding fingerprint matches an active dismissal → fail
dism=$(mktemp)
cat > "$dism" <<'MD'
## src/auth.rs:42 — Token check

**Fingerprint:** `src/auth.rs:42:token_check`

Reason: x
MD
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"REQUEST_CHANGES","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[
    {"id":"F1","severity":"HIGH","category":"Bug","file":"src/auth.rs","line":42,
     "end_line":null,"summary":"Token check","fingerprint":"src/auth.rs:42:token_check",
     "reviewers_agreeing":["claude"],"carried_from":null}
  ],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":["F1"]},
  "dismissed_active":[],
  "obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" --dismissals "$dism" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "dismissal"
rm -f "$dism" "$new"

# DISMISSALS.md coverage rule — fingerprint in DISMISSALS but neither in
# dismissed_active nor obsolete_dismissals → fail.
dism=$(mktemp)
cat > "$dism" <<'MD'
## src/x.py:5 — issue

**Fingerprint:** `src/x.py:5:issue`

Reason: y
MD
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],
  "obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" --dismissals "$dism" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "coverage"
rm -f "$dism" "$new"

echo "validate-findings OK"
```

- [ ] **Step 2: Write the fixtures.**

`tests/fixtures/findings/valid-minimal.json`:

```json
{
  "round":   "20260518-140000",
  "verdict": "APPROVE",
  "confidence": "HIGH",
  "head_sha": "abc123",
  "base_sha": "f00ba8",
  "findings": [],
  "open_questions": [],
  "regression": {"resolved": [], "newly_introduced": []},
  "dismissed_active": [],
  "obsolete_dismissals": []
}
```

`tests/fixtures/findings/invalid-missing-field.json`:

```json
{
  "round":   "20260518-140000",
  "verdict": "APPROVE",
  "confidence": "HIGH",
  "findings": []
}
```

`tests/fixtures/findings/invalid-bad-verdict.json`:

```json
{
  "round":   "X", "verdict": "MAYBE", "confidence": "HIGH",
  "head_sha":"a","base_sha":"b","findings":[],"open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
```

`tests/fixtures/findings/invalid-rubric-mismatch.json`:

```json
{
  "round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[
    {"id":"F1","severity":"CRITICAL","category":"Bug","file":"x.py","line":1,
     "end_line":null,"summary":"oops","fingerprint":"x.py:1:oops",
     "reviewers_agreeing":["claude"],"carried_from":null}
  ],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":["F1"]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
```

- [ ] **Step 3: Run the test to verify it fails.**

```bash
bash tests/run.sh
```

Expected: `FAIL` on `validate-findings.test.sh`.

- [ ] **Step 4: Create `scripts/validate-findings.py`.**

```python
#!/usr/bin/env python3
"""
Validate findings.json against the rules in spec §4.5.

Usage:
  validate-findings.py <findings.json> [--prior <prior_findings.json>] [--dismissals <DISMISSALS.md>]

Exits 0 on success; 1 with one error per line on stderr on failure.
"""
import argparse
import json
import re
import sys
from pathlib import Path

VERDICTS = {"APPROVE", "APPROVE_WITH_COMMENTS", "REQUEST_CHANGES", "BLOCK"}
SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}
CONFIDENCES = {"HIGH", "MEDIUM", "LOW"}
FINDING_CATEGORIES = {
    "Bug", "Security", "Performance", "Regression",
    "TestCoverage", "Style", "IntentMismatch", "Other",
}
OQ_CATEGORIES = {
    "IntentAmbiguity", "MissingContext", "ConflictingSignals", "OutOfScopeConcern",
}
ID_FINDING_RE = re.compile(r"^F[0-9]+$")
ID_DISMISSED_RE = re.compile(r"^D[0-9]+$")
FINGERPRINT_LINE_RE = re.compile(r"^\*\*Fingerprint:\*\*\s+`([^`]+)`\s*$")
REF_RE = re.compile(r"^[0-9]{8}-[0-9]{6}:(F|D)[0-9]+$")


def fail(errors: list[str], msg: str):
    errors.append(msg)


def require_keys(obj, keys, where, errors):
    for k in keys:
        if k not in obj:
            fail(errors, f"{where}: missing required key '{k}'")


def parse_dismissal_fingerprints(path: Path) -> set[str]:
    fps = set()
    if not path or not path.exists():
        return fps
    for line in path.read_text(encoding="utf-8").splitlines():
        m = FINGERPRINT_LINE_RE.match(line)
        if m:
            fps.add(m.group(1))
    return fps


def expected_verdict(findings):
    if any(f.get("severity") == "CRITICAL" for f in findings):
        return "BLOCK"
    if any(f.get("severity") == "HIGH" for f in findings):
        return "REQUEST_CHANGES"
    if findings:
        return "APPROVE_WITH_COMMENTS"
    return "APPROVE"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("findings")
    ap.add_argument("--prior", default=None, help="path to prior_findings.json (Delta only)")
    ap.add_argument("--dismissals", default=None, help="path to DISMISSALS.md")
    args = ap.parse_args()

    errors: list[str] = []

    # Rule 1: parseable JSON
    try:
        data = json.loads(Path(args.findings).read_text(encoding="utf-8"))
    except Exception as e:
        print(f"rule 1 (parseable JSON): {e}", file=sys.stderr)
        return 1

    # Rule 2: required top-level fields
    top_required = ["round", "verdict", "confidence", "head_sha", "base_sha",
                    "findings", "open_questions", "regression",
                    "dismissed_active", "obsolete_dismissals"]
    require_keys(data, top_required, "top-level", errors)

    findings = data.get("findings", [])
    dismissed = data.get("dismissed_active", [])
    obsolete = data.get("obsolete_dismissals", [])
    regression = data.get("regression", {}) or {}
    open_questions = data.get("open_questions", [])

    # Per-finding required fields + types
    for i, f in enumerate(findings):
        where = f"findings[{i}]"
        require_keys(f, ["id", "severity", "category", "file", "line", "end_line",
                         "summary", "fingerprint", "reviewers_agreeing",
                         "carried_from"], where, errors)
        if "line" in f and not (isinstance(f["line"], int) and f["line"] >= 1):
            fail(errors, f"{where}: 'line' must be a positive integer (got {f.get('line')!r})")
        if "id" in f and not ID_FINDING_RE.match(str(f.get("id", ""))):
            fail(errors, f"{where}: 'id' must match ^F[0-9]+$ (got {f.get('id')!r})")

    for i, d in enumerate(dismissed):
        where = f"dismissed_active[{i}]"
        require_keys(d, ["id", "ref", "fingerprint", "severity", "category",
                         "file", "line", "end_line", "summary"], where, errors)
        if "id" in d and not ID_DISMISSED_RE.match(str(d.get("id", ""))):
            fail(errors, f"{where}: 'id' must match ^D[0-9]+$ (got {d.get('id')!r})")

    # Rule 3: enums
    if data.get("verdict") not in VERDICTS:
        fail(errors, f"verdict: invalid value {data.get('verdict')!r}; must be one of {sorted(VERDICTS)}")
    if data.get("confidence") not in CONFIDENCES:
        fail(errors, f"confidence: invalid value {data.get('confidence')!r}")
    for i, f in enumerate(findings):
        if f.get("severity") not in SEVERITIES:
            fail(errors, f"findings[{i}].severity: invalid value {f.get('severity')!r}")
        if f.get("category") not in FINDING_CATEGORIES:
            fail(errors, f"findings[{i}].category: invalid value {f.get('category')!r}")
    for i, d in enumerate(dismissed):
        if d.get("severity") not in SEVERITIES:
            fail(errors, f"dismissed_active[{i}].severity: invalid value {d.get('severity')!r}")
        if d.get("category") not in FINDING_CATEGORIES:
            fail(errors, f"dismissed_active[{i}].category: invalid value {d.get('category')!r}")
    for i, q in enumerate(open_questions):
        if q.get("category") not in OQ_CATEGORIES:
            fail(errors, f"open_questions[{i}].category: invalid value {q.get('category')!r}")

    # Rule 4: verdict vs severity rubric (findings only)
    expected = expected_verdict(findings)
    if data.get("verdict") and data["verdict"] != expected:
        fail(errors, f"rubric mismatch: findings imply verdict {expected!r}, got {data['verdict']!r}")

    # Dismissals on disk
    dism_fps = parse_dismissal_fingerprints(Path(args.dismissals) if args.dismissals else None)

    # Rule 6: dismissal coherence (findings must not match an active dismissal;
    # dismissed_active fingerprints must be in DISMISSALS).
    for i, f in enumerate(findings):
        fp = f.get("fingerprint")
        if fp and fp in dism_fps:
            fail(errors, f"findings[{i}]: fingerprint {fp!r} matches an active dismissal — should have been suppressed")
    if args.dismissals:
        for i, d in enumerate(dismissed):
            fp = d.get("fingerprint")
            if fp and fp not in dism_fps:
                fail(errors, f"dismissed_active[{i}]: fingerprint {fp!r} does not match any active dismissal in DISMISSALS.md")
        for i, o in enumerate(obsolete):
            fp = (o or {}).get("fingerprint")
            if fp and fp not in dism_fps:
                fail(errors, f"obsolete_dismissals[{i}]: fingerprint {fp!r} does not match any active dismissal in DISMISSALS.md")

    # Rule 7: fingerprint plausibility + 8: within-round uniqueness
    seen = {}
    for i, f in enumerate(findings):
        fp = f.get("fingerprint")
        if fp:
            if fp in seen:
                fail(errors, f"fingerprint {fp!r} duplicated (findings[{i}] and {seen[fp]})")
            seen[fp] = f"findings[{i}]"
            parts = fp.split(":", 2)
            if len(parts) != 3:
                fail(errors, f"findings[{i}]: fingerprint {fp!r} does not match <file>:<line>:<slug>")
            elif parts[0] != f.get("file") or str(f.get("line")) != parts[1]:
                fail(errors, f"findings[{i}]: fingerprint {fp!r} not consistent with file={f.get('file')!r} line={f.get('line')!r}")
    for i, d in enumerate(dismissed):
        fp = d.get("fingerprint")
        if fp and fp in seen:
            fail(errors, f"fingerprint {fp!r} duplicated (dismissed_active[{i}] and {seen[fp]})")
        if fp:
            seen[fp] = f"dismissed_active[{i}]"

    # Rule 9: DISMISSALS.md coverage (both modes) — every dism fp must be in
    # dismissed_active ∪ obsolete_dismissals.
    if args.dismissals:
        active_fps = {d.get("fingerprint") for d in dismissed if d.get("fingerprint")}
        obsolete_fps = {(o or {}).get("fingerprint") for o in obsolete if (o or {}).get("fingerprint")}
        for fp in dism_fps:
            if fp not in active_fps and fp not in obsolete_fps:
                fail(errors, f"coverage: DISMISSALS.md entry {fp!r} not classified (neither dismissed_active nor obsolete_dismissals)")

    # Rule 5: carry-forward accounting (Delta only — when --prior is given)
    if args.prior:
        try:
            prior = json.loads(Path(args.prior).read_text(encoding="utf-8"))
        except Exception as e:
            print(f"could not read --prior {args.prior}: {e}", file=sys.stderr)
            return 1
        if not isinstance(prior, list):
            print("--prior must be a JSON array of objects", file=sys.stderr)
            return 1
        carried_refs = {f.get("carried_from") for f in findings if f.get("carried_from")}
        dismissed_refs = {d.get("ref") for d in dismissed if d.get("ref")}
        resolved_refs = set((regression.get("resolved") or []))
        accounted = carried_refs | dismissed_refs | resolved_refs
        for p in prior:
            ref = None
            # Each prior entry must carry a stable ref. We synthesise from id+round here.
            # Convention used in the spec: <round>:<id>. Round comes from prior round dir's findings.json.
            if "id" in p and "_round" in p:
                ref = f"{p['_round']}:{p['id']}"
            elif "ref_self" in p:
                ref = p["ref_self"]
            else:
                # Skip — caller annotated incorrectly
                continue
            if ref not in accounted:
                fail(errors, f"carry-forward: prior entry {ref!r} not in findings.carried_from, dismissed_active.ref, or regression.resolved")

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Make it executable: `chmod +x scripts/validate-findings.py`.

- [ ] **Step 5: Run the test to verify it passes.**

```bash
bash tests/run.sh
```

Expected: all tests pass. (If `valid-minimal.json` fails because the current `findings.json` example has a `confidence` field but the test fixture omits it, double-check — the fixture above includes `"confidence": "HIGH"`.)

- [ ] **Step 6: Commit.**

```bash
git add scripts/validate-findings.py tests/validate-findings.test.sh tests/fixtures/
git commit -m "feat: validate-findings.py — schema + rubric + dismissal + carry-forward rules"
```

---

## Task 6: PreToolUse hook (`scripts/hooks/pre-push.sh`) + `hooks.json`

**Files:**
- Create: `.claude-plugin/hooks.json`
- Create: `scripts/hooks/pre-push.sh`
- Create: `tests/hook-pre-push.test.sh`

The hook is the most subtle script in the plan — implement it incrementally, testing each branch.

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/hook-pre-push.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

HOOK="$SCRIPTS/hooks/pre-push.sh"

run_hook() {
  # Pipe a minimal PreToolUse JSON to the hook. $1 = the command string.
  local cmd="$1"
  jq -nc --arg c "$cmd" '{toolInput:{command:$c}}' | bash "$HOOK"
}

# Non-push commands → exit 0, no output
out=$(run_hook "ls -la")
assert_eq "$?" "0"
assert_eq "$out" ""

# git push command without config → exit 0 silently (no setup)
unset CR_CONFIG_DIR
out=$(run_hook "git push")
assert_eq "$?" "0"

# Set up a fixture repo + ledger and verify the gate flows.
repo=$(setup_fixture_repo hook-test)
cd "$repo"
git checkout -qb feat
echo hi >> README; git commit -qam "feat commit"

# Create config that points review_output_path at a writable temp dir.
CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
cat > "$CR_CONFIG_DIR/config.json" <<JSON
{
  "review_output_path": "$ROUT",
  "auto_trigger": true,
  "skip_branches": [],
  "keep_last_rounds": 10
}
JSON

# 1) auto_trigger=false → silent allow
jq '. + {auto_trigger:false}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"
out=$(run_hook "git push origin feat")
assert_eq "$?" "0"
jq '. + {auto_trigger:true}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"

# 2) CR_SKIP=1 prefix in command string → silent allow
out=$(run_hook "CR_SKIP=1 git push origin feat")
assert_eq "$?" "0"

# 3) Skip branches matching skip_branches → silent allow
jq '. + {skip_branches:["feat"]}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"
out=$(run_hook "git push origin feat")
assert_eq "$?" "0"
jq '. + {skip_branches:[]}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"

# 4) No ledger → deny with `no_ledger` reason
out=$(run_hook "git push origin feat" 2>&1) && rc=$? || rc=$?
assert_eq "$rc" "0" "hook returns 0 even on deny; uses permissionDecision payload"
assert_contains "$out" "permissionDecision"
assert_contains "$out" "no_ledger"

# 5) Ledger entry that approves the current HEAD with clean worktree → allow
mkdir -p "$ROUT/$(basename "$repo")/feat"
HEAD_SHA=$(git rev-parse HEAD)
BASE_SHA=$(git rev-parse origin/main 2>/dev/null || git rev-parse main)
cat > "$ROUT/$(basename "$repo")/feat/.review-ledger.json" <<JSON
{
  "branch": "feat", "base_ref": "main", "jira_keys": [], "jira_cached_at": null,
  "reviews": [
    {"timestamp":"20260518-140000","type":"full","head_sha":"$HEAD_SHA","base_ref":"main",
     "base_sha":"$BASE_SHA","commits_reviewed":["$HEAD_SHA"],"previous_head_sha":null,
     "worktree_hash":null,"dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260518-140000","fallback_reason":null}
  ]
}
JSON
out=$(run_hook "git push origin feat" 2>&1) && rc=$? || rc=$?
assert_eq "$rc" "0"
# allow → no decision payload
case "$out" in *permissionDecision*) echo "FAIL: allow should produce no payload"; exit 1 ;; esac

# 6) Now add a commit beyond what was reviewed → deny with head_changed
echo more >> README; git commit -qam "another"
out=$(run_hook "git push origin feat" 2>&1)
assert_contains "$out" "head_changed"

echo "hook OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
bash tests/run.sh
```

Expected: `FAIL` because the hook doesn't exist.

- [ ] **Step 3: Create `.claude-plugin/hooks.json`.**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/pre-push.sh"
          }
        ]
      }
    ]
  }
}
```

Note: the exact field shape (`hooks[].hooks[].command` vs `hooks[].command`) follows the Claude Code plugin hook spec. If the format differs from what the engineer finds in the current docs, update the JSON to match — the behaviour is fully encoded in `pre-push.sh`.

- [ ] **Step 4: Create `scripts/hooks/pre-push.sh`.**

```bash
#!/usr/bin/env bash
# PreToolUse hook gating `git push` per spec §5.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib.sh"

# --- Helpers ----------------------------------------------------------

# Read planned command from stdin. Empty / non-Bash → exit 0 silently.
input=$(cat 2>/dev/null || true)
cmd=$(echo "$input" | jq -r '.toolInput.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Step 1: Quick filter — only git push commands.
case "$cmd" in
  *"git push"*) : ;;
  *) exit 0 ;;
esac

# Step 2: Strip leading KEY=VALUE pairs (inline env). Capture CR_SKIP.
working="$cmd"
inline_cr_skip=""
while [[ "$working" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]*)[[:space:]]+ ]]; do
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  if [ "$key" = "CR_SKIP" ]; then inline_cr_skip="$val"; fi
  working="${working#${key}=${val} }"
done
if [ "${CR_SKIP:-}" = "1" ] || [ "$inline_cr_skip" = "1" ]; then
  exit 0   # explicit bypass
fi

# Step 3: Config check
CR_CONFIG_DIR="${CR_CONFIG_DIR:-$HOME/.code-reviewer}"
CR_CONFIG_FILE="$CR_CONFIG_DIR/config.json"
[ -f "$CR_CONFIG_FILE" ] || exit 0   # no setup → don't gate

auto_trigger=$(jq -r '.auto_trigger // true' "$CR_CONFIG_FILE" 2>/dev/null)
[ "$auto_trigger" = "false" ] && exit 0

# Step 4: Must be in a git repo.
repo=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
[ "$branch" = "HEAD" ] && exit 0   # detached → silent allow

# Skip branches
skip=$(jq -r --arg b "$branch" '.skip_branches[]? | select(. == $b)' "$CR_CONFIG_FILE" 2>/dev/null)
[ -n "$skip" ] && exit 0

# Step 5: Parse push form → derive effective_remote_ref (per spec §5.7).
remote_ref=""
intercepted=1
tokens=( $working )
# Strip --force, --force-with-lease (no arg) at any position
filtered=()
for t in "${tokens[@]}"; do
  case "$t" in
    --force|--force-with-lease|--force-with-lease=*) : ;;
    *) filtered+=("$t") ;;
  esac
done

if [ "${filtered[0]:-}" != "git" ] || [ "${filtered[1]:-}" != "push" ]; then
  exit 0   # shouldn't happen given the early filter; safety
fi

case "${filtered[2]:-}" in
  "")
    # bare `git push`
    push_default=$(git config --get push.default 2>/dev/null || echo "simple")
    [ -z "$push_default" ] && push_default="simple"
    case "$push_default" in
      simple|upstream) remote_ref=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "") ;;
      current)         remote_ref="origin/$branch" ;;
      *)               intercepted=0 ;;
    esac
    ;;
  origin)
    case "${filtered[3]:-}" in
      "")
        # bare `git push origin` — depends on push.default; not intercepted
        intercepted=0
        ;;
      "$branch")                  remote_ref="origin/$branch" ;;
      "HEAD")                     remote_ref="origin/$branch" ;;
      "HEAD:$branch")             remote_ref="origin/$branch" ;;
      *)
        # Any other refspec (multi, --tags, --mirror, --all, etc.) → not intercepted
        intercepted=0
        ;;
    esac
    # extra positional args → not intercepted
    if [ -n "${filtered[4]:-}" ]; then intercepted=0; fi
    ;;
  -u|--set-upstream)
    if [ "${filtered[3]:-}" = "origin" ] && [ "${filtered[4]:-}" = "$branch" ]; then
      if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
        remote_ref="origin/$branch"
      else
        # First push: nothing to compare against, no bypass possible.
        remote_ref=""
      fi
    else
      intercepted=0
    fi
    ;;
  *)
    intercepted=0
    ;;
esac

[ "$intercepted" = "0" ] && exit 0   # silently not intercepted per §5.7

# Step 6: Nothing-to-push bypass.
if [ -n "$remote_ref" ]; then
  if git merge-base --is-ancestor HEAD "$remote_ref" 2>/dev/null; then
    exit 0   # everything already on remote
  fi
  ahead=$(git rev-list --count "$remote_ref..HEAD" 2>/dev/null || echo "0")
  [ "$ahead" -eq 0 ] && exit 0
fi

# Step 7: Compute ledger path + current state.
review_output_path=$(cr_review_output_path "$repo")
repo_slug=$(cr_repo_slug "$repo")
branch_slug=$(echo "$branch" | tr '/' '_')
branch_dir="$review_output_path/$repo_slug/$branch_slug"
ledger="$branch_dir/.review-ledger.json"

head_sha=$(git rev-parse HEAD)
worktree_hash=$(cr_worktree_hash)
dismissals_hash=$(cr_dismissals_hash "$branch_dir/DISMISSALS.md")
current_base_sha=""
[ -n "$remote_ref" ] && current_base_sha=$(git rev-parse "$remote_ref" 2>/dev/null || echo "")

deny() {
  local reason="$1" msg="$2"
  cat <<JSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "code-reviewer: $msg [reason: $reason]\n\nClaude: present these options to the user via AskUserQuestion before retrying:\n  • Delta review (recommended — fast review of new material since last review)\n  • Full review (re-download Jira/Confluence; review entire branch)\n  • Skip review (push without review; retry with CR_SKIP=1)\n  • Discuss\n\nAfter the user picks, run /code-reviewer:start with the appropriate flag and retry the push. If \"Skip\" was chosen, retry with CR_SKIP=1 in env."
  }
}
JSON
  exit 0   # hook always exits 0; the JSON payload is what denies
}

[ -f "$ledger" ] || deny "no_ledger" "No prior review exists for branch '$branch'. Run /code-reviewer:start --full first."

# Step 8: Find matching reviews (head_sha, worktree_hash==null, base-compatible, dismissals match).
# base_compatible: r.base_sha == current_base_sha OR git merge-base --is-ancestor r.base_sha current_base_sha
matching=$(jq --arg h "$head_sha" --arg d "$dismissals_hash" '
  .reviews
  | map(select(.head_sha == $h and (.worktree_hash == null) and ((.dismissals_hash // null) == ($d | select(. != "") // null))))
' "$ledger")

# Filter by base compatibility (done in shell because git is not in jq).
match_count=$(echo "$matching" | jq 'length')
if [ "$match_count" -gt 0 ] && [ -n "$current_base_sha" ]; then
  compatible_indices=()
  for i in $(seq 0 $((match_count - 1))); do
    bs=$(echo "$matching" | jq -r ".[$i].base_sha")
    if [ "$bs" = "$current_base_sha" ] || git merge-base --is-ancestor "$bs" "$current_base_sha" 2>/dev/null; then
      compatible_indices+=("$i")
    fi
  done
  if [ "${#compatible_indices[@]}" -gt 0 ]; then
    last=${compatible_indices[-1]}
    verdict=$(echo "$matching" | jq -r ".[$last].verdict")
    case "$verdict" in
      APPROVE|APPROVE_WITH_COMMENTS) exit 0 ;;
      *) deny "not_approved" "Latest matching review verdict is $verdict; address findings or use CR_SKIP=1." ;;
    esac
  fi
fi

# Step 9: Categorise the failure.
same_head_any=$(jq --arg h "$head_sha" '.reviews | map(select(.head_sha == $h)) | length' "$ledger")
same_head_clean=$(jq --arg h "$head_sha" '.reviews | map(select(.head_sha == $h and .worktree_hash == null)) | length' "$ledger")
same_head_clean_dism=$(jq --arg h "$head_sha" --arg d "$dismissals_hash" '
  .reviews | map(select(.head_sha == $h and .worktree_hash == null and ((.dismissals_hash // null) == ($d | select(. != "") // null)))) | length
' "$ledger")

if [ "$same_head_any" -eq 0 ]; then
  deny "head_changed" "Branch '$branch' has commits beyond the last reviewed HEAD."
elif [ "$same_head_clean" -eq 0 ]; then
  deny "commit_needed" "Branch '$branch' was only reviewed with uncommitted changes. Commit them and re-run /code-reviewer:start --delta."
elif [ "$same_head_clean_dism" -eq 0 ]; then
  deny "dismissals_changed" "DISMISSALS.md has changed since the last approval. Re-run /code-reviewer:start --delta."
else
  deny "base_drifted" "The base ref has commits not covered by the prior review's base. Re-run /code-reviewer:start --full."
fi
```

Make it executable: `chmod +x scripts/hooks/pre-push.sh`.

- [ ] **Step 5: Run the test to verify it passes.**

```bash
bash tests/run.sh
```

If a single sub-case fails, the test output will show which assertion. Iterate on the hook script until all sub-cases pass.

- [ ] **Step 6: Commit.**

```bash
git add .claude-plugin/hooks.json scripts/hooks/pre-push.sh tests/hook-pre-push.test.sh
git commit -m "feat: PreToolUse hook gating git push (no_ledger/head_changed/commit_needed/base_drifted/dismissals_changed/not_approved)"
```

---

## Task 7: `context.sh` — storage path + `skip_branches` + drop hardcoded protected list

**Files:**
- Modify: `scripts/context.sh`
- Create: `tests/context-storage.test.sh`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/context-storage.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo storage)
cd "$repo"
git checkout -qb feat
echo x >> README; git commit -qam "feat"

# Default review_output_path → /tmp/code-reviewer/<repo-slug>/<branch>/<ts>
unset CR_CONFIG_DIR
out=$(bash "$SCRIPTS/context.sh" 2>&1 | tail -1)
case "$out" in
  /tmp/code-reviewer/*/feat/*) : ;;
  *) echo "FAIL: default path should be /tmp/code-reviewer/<repo>/feat/<ts>; got $out"; exit 1 ;;
esac

# Custom review_output_path
CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\"}" > "$CR_CONFIG_DIR/config.json"
out=$(bash "$SCRIPTS/context.sh" 2>&1 | tail -1)
case "$out" in
  "$ROUT"/*/feat/*) : ;;
  *) echo "FAIL: custom path should be $ROUT/<repo>/feat/<ts>; got $out"; exit 1 ;;
esac

# skip_branches: feat is in the list → refuses to run
echo "{\"review_output_path\":\"$ROUT\",\"skip_branches\":[\"feat\"]}" > "$CR_CONFIG_DIR/config.json"
out=$(bash "$SCRIPTS/context.sh" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc" "feat in skip_branches should refuse"
assert_contains "$out" "skip_branches"

# On main with empty skip_branches → should run, not refuse
git checkout -q main
echo y >> README; git commit -qam "on main"
echo "{\"review_output_path\":\"$ROUT\",\"skip_branches\":[]}" > "$CR_CONFIG_DIR/config.json"
out=$(bash "$SCRIPTS/context.sh" 2>&1 | tail -1)
case "$out" in
  "$ROUT"/*/main/*) : ;;
  *) echo "FAIL: main should now be reviewable; got $out"; exit 1 ;;
esac

echo "context-storage OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

```bash
bash tests/run.sh
```

Expected: FAIL (hardcoded `main|master|develop` refusal in v0.3.0 context.sh blocks main; storage path still under `$REPO_ROOT/tmp/...`).

- [ ] **Step 3: Update `scripts/context.sh`** — replace the protected-branch block and the round-dir derivation.

Find this block in `context.sh`:

```bash
case "$BRANCH" in
  main|master|develop)
    echo "Refusing to run on protected branch: $BRANCH" >&2
    exit 1
    ;;
esac
```

Replace it with:

```bash
# skip_branches: check config for an explicit opt-out list (default empty).
if [ -f "$CR_CONFIG_FILE" ]; then
  if jq -e --arg b "$BRANCH" '.skip_branches[]? | select(. == $b)' "$CR_CONFIG_FILE" >/dev/null 2>&1; then
    echo "Refusing to run: branch '$BRANCH' is in config.skip_branches" >&2
    exit 1
  fi
fi
```

Find the existing round-dir derivation:

```bash
BRANCH_SLUG=$(cr_branch_slug "$BRANCH")
TS=$(date +%Y%m%d-%H%M%S)
REVIEWS_ROOT="$REPO_ROOT/tmp/code-reviews"
ROUND_DIR="$REVIEWS_ROOT/$BRANCH_SLUG/$TS"
```

Replace with:

```bash
BRANCH_SLUG=$(cr_branch_slug "$BRANCH")
TS=$(date +%Y%m%d-%H%M%S)
REVIEW_OUT=$(cr_review_output_path "$REPO_ROOT")
REPO_SLUG=$(cr_repo_slug "$REPO_ROOT")
BRANCH_DIR="$REVIEW_OUT/$REPO_SLUG/$BRANCH_SLUG"
REVIEWS_ROOT="$REVIEW_OUT/$REPO_SLUG"
ROUND_DIR="$BRANCH_DIR/$TS"
```

Also drop the existing cross-branch cleanup block (the loop that iterates `"$REVIEWS_ROOT"/*` and removes non-current dirs). Within-branch pruning will be added in Task 9.

- [ ] **Step 4: Run the test to verify it passes.**

```bash
bash tests/run.sh
```

- [ ] **Step 5: Commit.**

```bash
git add scripts/context.sh tests/context-storage.test.sh
git commit -m "feat(context): configurable review_output_path, skip_branches, drop hardcoded protected list"
```

---

## Task 8: `context.sh` — Delta/Full mode, ledger interaction, `prior_findings.json`

**Files:**
- Modify: `scripts/context.sh`
- Create: `tests/context-delta-full.test.sh`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/context-delta-full.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo modes)
cd "$repo"
git checkout -qb feat
echo a >> README; git commit -qam "c1"

CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\"}" > "$CR_CONFIG_DIR/config.json"

REPO_SLUG=$(basename "$repo")
BRANCH_DIR="$ROUT/$REPO_SLUG/feat"

# 1) No ledger → context.sh runs as Full (no `--delta` flag possible).
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR=$(echo "$out" | tail -1)
[ -d "$ROUND_DIR/context" ] || { echo "FAIL: round dir missing"; exit 1; }
# Mode must be FULL since no ledger
grep -q "Mode.*full" "$ROUND_DIR/context/context-manifest.md" \
  || { echo "FAIL: first run should be FULL"; exit 1; }

# Simulate a successful review by creating a ledger entry.
mkdir -p "$BRANCH_DIR"
HEAD_SHA=$(git rev-parse HEAD)
BASE_SHA=$(git rev-parse main 2>/dev/null)
cat > "$BRANCH_DIR/.review-ledger.json" <<JSON
{
  "branch":"feat","base_ref":"main","jira_keys":[],"jira_cached_at":null,
  "reviews":[
    {"timestamp":"$(basename $ROUND_DIR)","type":"full","head_sha":"$HEAD_SHA",
     "base_ref":"main","base_sha":"$BASE_SHA","commits_reviewed":["$HEAD_SHA"],
     "previous_head_sha":null,"worktree_hash":null,"dismissals_hash":null,
     "verdict":"APPROVE","findings":{"critical":0,"high":0,"medium":0,"low":0},
     "open_questions":0,"round_dir":"$(basename $ROUND_DIR)","fallback_reason":null}
  ]
}
JSON
# Also populate the prior round dir with a tiny findings.json so Delta can read it.
cat > "$ROUND_DIR/findings.json" <<'JSON'
{"round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
 "findings":[],"open_questions":[],"regression":{"resolved":[],"newly_introduced":[]},
 "dismissed_active":[],"obsolete_dismissals":[]}
JSON

# 2) Second run with a new commit → defaults to DELTA, writes prior_findings.json
echo b >> README; git commit -qam "c2"
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR2=$(echo "$out" | tail -1)
grep -q "Mode.*delta" "$ROUND_DIR2/context/context-manifest.md" \
  || { echo "FAIL: should default to DELTA when ledger exists"; exit 1; }
[ -f "$ROUND_DIR2/prior_findings.json" ] \
  || { echo "FAIL: prior_findings.json must be written"; exit 1; }
jq -e 'type == "array"' "$ROUND_DIR2/prior_findings.json" \
  || { echo "FAIL: prior_findings.json must be an array"; exit 1; }

# 3) --full forces FULL even when ledger exists
out=$(bash "$SCRIPTS/context.sh" --full 2>&1)
ROUND_DIR3=$(echo "$out" | tail -1)
grep -q "Mode.*full" "$ROUND_DIR3/context/context-manifest.md" || \
  { echo "FAIL: --full should override"; exit 1; }
[ ! -f "$ROUND_DIR3/prior_findings.json" ] || \
  { echo "FAIL: Full mode should not write prior_findings.json"; exit 1; }

# 4) --delta with no ledger errors clearly
rm -rf "$BRANCH_DIR/.review-ledger.json"
out=$(bash "$SCRIPTS/context.sh" --delta 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "no prior review"

# 5) Nothing-new short-circuit on Delta
# Re-seed the ledger to point at the new HEAD.
HEAD_SHA=$(git rev-parse HEAD)
cat > "$BRANCH_DIR/.review-ledger.json" <<JSON
{
  "branch":"feat","base_ref":"main","jira_keys":[],"jira_cached_at":null,
  "reviews":[
    {"timestamp":"$(basename $ROUND_DIR2)","type":"delta","head_sha":"$HEAD_SHA",
     "base_ref":"main","base_sha":"$BASE_SHA","commits_reviewed":["$HEAD_SHA"],
     "previous_head_sha":null,"worktree_hash":null,"dismissals_hash":null,
     "verdict":"APPROVE","findings":{"critical":0,"high":0,"medium":0,"low":0},
     "open_questions":0,"round_dir":"$(basename $ROUND_DIR2)","fallback_reason":null}
  ]
}
JSON
cat > "$ROUND_DIR2/findings.json" <<'JSON'
{"round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
 "findings":[],"open_questions":[],"regression":{"resolved":[],"newly_introduced":[]},
 "dismissed_active":[],"obsolete_dismissals":[]}
JSON
out=$(bash "$SCRIPTS/context.sh" 2>&1) && rc=$? || rc=$?
# Nothing-new exits with a known message; could be exit 0 or a special code.
assert_contains "$out" "Nothing new"

echo "context-delta-full OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

- [ ] **Step 3: Update `scripts/context.sh`** with mode handling. Append a new section after the existing arg parsing:

```bash
# Mode selection: --delta or --full, default = delta if ledger exists, else full.
MODE=""
for a in "$@"; do
  case "$a" in
    --delta) MODE="delta" ;;
    --full)  MODE="full" ;;
  esac
done
LEDGER_FILE="$BRANCH_DIR/.review-ledger.json"
if [ -z "$MODE" ]; then
  if [ -f "$LEDGER_FILE" ]; then MODE="delta"; else MODE="full"; fi
fi
if [ "$MODE" = "delta" ] && [ ! -f "$LEDGER_FILE" ]; then
  echo "code-reviewer: no prior review on this branch — run with --full first" >&2
  exit 1
fi
```

Add Delta-specific machinery (after creating ROUND_DIR but before building the prompt):

```bash
# Delta: read prior round, build prior_findings.json, check rebase / base compat.
if [ "$MODE" = "delta" ]; then
  prev=$(jq -r '.reviews[-1]' "$LEDGER_FILE")
  prev_round_dir=$(echo "$prev" | jq -r '.round_dir')
  prev_findings_json="$BRANCH_DIR/$prev_round_dir/findings.json"
  prev_head_sha=$(echo "$prev" | jq -r '.head_sha')
  prev_base_sha=$(echo "$prev" | jq -r '.base_sha // empty')

  # Rebase detection
  if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$prev_head_sha" HEAD 2>/dev/null; then
    echo "code-reviewer: prev HEAD not ancestor of current HEAD — falling back to FULL" >&2
    MODE="full"
  fi

  # Base compatibility
  if [ "$MODE" = "delta" ]; then
    current_base_sha=$(git -C "$REPO_ROOT" rev-parse "$BASE" 2>/dev/null || echo "")
    if [ -n "$prev_base_sha" ] && [ -n "$current_base_sha" ] && [ "$prev_base_sha" != "$current_base_sha" ]; then
      echo "code-reviewer: base shifted ($prev_base_sha -> $current_base_sha) — falling back to FULL" >&2
      MODE="full"
    fi
  fi

  # Prior findings.json available?
  if [ "$MODE" = "delta" ] && [ ! -f "$prev_findings_json" ]; then
    echo "code-reviewer: prior findings.json missing — falling back to FULL" >&2
    MODE="full"
  fi

  # Nothing-new short-circuit
  if [ "$MODE" = "delta" ]; then
    current_worktree_hash=$(cd "$REPO_ROOT" && cr_worktree_hash)
    prev_worktree_hash=$(echo "$prev" | jq -r '.worktree_hash // empty')
    new_commits=$(git -C "$REPO_ROOT" rev-list "${prev_head_sha}..HEAD" 2>/dev/null | wc -l | tr -d ' ')
    current_dismissals_hash=$(cr_dismissals_hash "$BRANCH_DIR/DISMISSALS.md")
    prev_dismissals_hash=$(echo "$prev" | jq -r '.dismissals_hash // empty')
    if [ "$new_commits" = "0" ] \
       && [ "$current_worktree_hash" = "$prev_worktree_hash" ] \
       && [ "$current_dismissals_hash" = "$prev_dismissals_hash" ]; then
      prev_verdict=$(echo "$prev" | jq -r '.verdict')
      echo "Nothing new to review since $prev_round_dir (last verdict: $prev_verdict)." >&2
      # Remove the freshly-created round dir; we're not running a review.
      rm -rf "$ROUND_DIR"
      exit 0
    fi

    # Build prior_findings.json
    jq --arg round "$prev_round_dir" '
      ((.findings // []) | map(. + {_was_dismissed: false, _round: $round}))
      +
      ((.dismissed_active // []) | map(. + {_was_dismissed: true, _round: $round}))
    ' "$prev_findings_json" > "$ROUND_DIR/prior_findings.json"
  fi
fi
```

Update the manifest to record `Mode: <delta|full>`:

```bash
# In the manifest builder, add:
echo "| Mode | $MODE |"
```

- [ ] **Step 4: Run the test to verify it passes.**

- [ ] **Step 5: Commit.**

```bash
git add scripts/context.sh tests/context-delta-full.test.sh
git commit -m "feat(context): delta/full modes, prior_findings.json, rebase/base/prior-missing fallbacks, nothing-new short-circuit"
```

---

## Task 9: `context.sh` — pruning (last step), Jira cache safe swap, lock acquisition

**Files:**
- Modify: `scripts/context.sh`
- Create: `tests/context-pruning.test.sh`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/context-pruning.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo prune)
cd "$repo"
git checkout -qb feat
echo a >> README; git commit -qam "c1"

CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\",\"keep_last_rounds\":2}" > "$CR_CONFIG_DIR/config.json"

REPO_SLUG=$(basename "$repo")
BRANCH_DIR="$ROUT/$REPO_SLUG/feat"

# Simulate three completed runs by manually creating timestamp dirs + a ledger.
mkdir -p "$BRANCH_DIR/20260101-100000" "$BRANCH_DIR/20260101-110000" "$BRANCH_DIR/20260101-120000"
HEAD_SHA=$(git rev-parse HEAD)
cat > "$BRANCH_DIR/.review-ledger.json" <<JSON
{
  "branch":"feat","base_ref":"main","jira_keys":[],"jira_cached_at":null,
  "reviews":[
    {"timestamp":"20260101-100000","type":"full","head_sha":"x","base_ref":"main","base_sha":"x",
     "commits_reviewed":["x"],"previous_head_sha":null,"worktree_hash":null,
     "dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260101-100000","fallback_reason":null},
    {"timestamp":"20260101-110000","type":"delta","head_sha":"y","base_ref":"main","base_sha":"x",
     "commits_reviewed":["y"],"previous_head_sha":"x","worktree_hash":null,
     "dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260101-110000","fallback_reason":null},
    {"timestamp":"20260101-120000","type":"delta","head_sha":"$HEAD_SHA","base_ref":"main","base_sha":"x",
     "commits_reviewed":["$HEAD_SHA"],"previous_head_sha":"y","worktree_hash":null,
     "dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260101-120000","fallback_reason":null}
  ]
}
JSON
# Each prior round dir needs a findings.json for Delta carry-forward
for d in 20260101-100000 20260101-110000 20260101-120000; do
  cat > "$BRANCH_DIR/$d/findings.json" <<'JSON'
{"round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
 "findings":[],"open_questions":[],"regression":{"resolved":[],"newly_introduced":[]},
 "dismissed_active":[],"obsolete_dismissals":[]}
JSON
done

# Add a new commit so Delta will actually run
echo b >> README; git commit -qam "c2"

# Run context.sh — pruning should run as last step, keep_last_rounds=2, so it
# should preserve only the 2 most recent timestamp dirs at the END of the run
# (current + previous; older dirs removed).
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR=$(echo "$out" | tail -1)
TS=$(basename "$ROUND_DIR")

# Survivors should be: the new TS, AND the immediately-prior round (20260101-120000),
# AND at most keep_last_rounds-2 older. With keep_last_rounds=2, expect just those two.
[ -d "$BRANCH_DIR/$TS" ]                || { echo "FAIL: new round missing"; exit 1; }
[ -d "$BRANCH_DIR/20260101-120000" ]    || { echo "FAIL: prev round must be preserved (carry-forward source)"; exit 1; }
[ ! -d "$BRANCH_DIR/20260101-100000" ]  || { echo "FAIL: 20260101-100000 should have been pruned"; exit 1; }
[ ! -d "$BRANCH_DIR/20260101-110000" ]  || { echo "FAIL: 20260101-110000 should have been pruned"; exit 1; }

# --no-prune skips pruning
mkdir -p "$BRANCH_DIR/20260101-100000"   # restore older round
out=$(bash "$SCRIPTS/context.sh" --no-prune 2>&1)
[ -d "$BRANCH_DIR/20260101-100000" ] || { echo "FAIL: --no-prune should preserve old rounds"; exit 1; }

echo "context-pruning OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

- [ ] **Step 3: Add pruning + lock to `scripts/context.sh`.**

At the top of the script, parse the `--no-prune` flag (extend the existing flag loop):

```bash
NO_PRUNE=0
for a in "$@"; do
  case "$a" in
    --no-prune) NO_PRUNE=1 ;;
  esac
done
```

After the round directory is created, acquire the lock:

```bash
LOCK_FILE="$BRANCH_DIR/.review-ledger.lock"
bash "$SCRIPT_DIR/ledger.sh" acquire-lock "$LOCK_FILE" \
  || { echo "code-reviewer: could not acquire lock at $LOCK_FILE" >&2; exit 1; }
trap "bash '$SCRIPT_DIR/ledger.sh' release-lock '$LOCK_FILE'" EXIT INT TERM
```

(`$SCRIPT_DIR` must point to `scripts/`; if it isn't defined yet, set it at the top of `context.sh`.)

At the very end of the script (after the manifest is written and the round dir path is echoed to stdout), add the pruning step:

```bash
# Pruning is the LAST step on a successful run. The lock is released by the
# trap that fires after this exits.
if [ "$NO_PRUNE" = "0" ]; then
  KEEP=$(cr_config_get keep_last_rounds 10)
  if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then KEEP=1; fi

  current_ts=$(basename "$ROUND_DIR")
  prev_ts=""
  if [ -f "$LEDGER_FILE" ]; then
    # The immediately-prior round (the second-most-recent ledger entry).
    prev_ts=$(jq -r '.reviews | if length >= 2 then .[-2].round_dir else "" end' "$LEDGER_FILE")
  fi

  # Enumerate timestamp dirs; sort newest first.
  dirs=( $(ls -1 "$BRANCH_DIR" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r) )
  preserved=("$current_ts")
  [ -n "$prev_ts" ] && preserved+=("$prev_ts")
  count=${#preserved[@]}
  for d in "${dirs[@]}"; do
    in_preserve=0
    for p in "${preserved[@]}"; do
      [ "$d" = "$p" ] && in_preserve=1 && break
    done
    if [ "$in_preserve" = "0" ]; then
      if [ "$count" -lt "$KEEP" ]; then
        preserved+=("$d")
        count=$((count + 1))
      fi
    fi
  done
  # Remove anything not preserved.
  for d in "${dirs[@]}"; do
    in_preserve=0
    for p in "${preserved[@]}"; do
      [ "$d" = "$p" ] && in_preserve=1 && break
    done
    if [ "$in_preserve" = "0" ]; then
      rm -rf "$BRANCH_DIR/$d"
    fi
  done
fi
```

Also: add the Jira-cache safe-swap helper. In context.sh, find the Jira fetch invocation and wrap it so it writes to `.jira-cache.new/`, then atomically swaps on success:

```bash
# Jira fetch — guarded by mode and config. Write to .new/, swap on success.
if [ "$MODE" = "full" ] && [ -n "$JIRA_KEY" ] && [ -n "$jira_base" ]; then
  rm -rf "$BRANCH_DIR/.jira-cache.new" "$BRANCH_DIR/.jira-cache.old"
  mkdir -p "$BRANCH_DIR/.jira-cache.new"
  if CR_JIRA_BASE_URL="$jira_base" CR_JIRA_EMAIL="$jira_email" \
     CR_JIRA_API_TOKEN="$jira_token" \
     python3 "$SCRIPT_DIR/jira-fetch.py" "$JIRA_KEY" \
        --out-dir "$BRANCH_DIR/.jira-cache.new"  --mode full \
        >/dev/null 2>"$CONTEXT_DIR/jira.err"; then
    [ -d "$BRANCH_DIR/.jira-cache" ] && mv "$BRANCH_DIR/.jira-cache" "$BRANCH_DIR/.jira-cache.old"
    mv "$BRANCH_DIR/.jira-cache.new" "$BRANCH_DIR/.jira-cache"
    rm -rf "$BRANCH_DIR/.jira-cache.old"
  else
    rm -rf "$BRANCH_DIR/.jira-cache.new"
    echo "Jira refresh failed; using stale cache (if any). See $CONTEXT_DIR/jira.err" >> "$CONTEXT_DIR/jira.warn"
  fi
fi
```

- [ ] **Step 4: Run the test to verify it passes.**

- [ ] **Step 5: Commit.**

```bash
git add scripts/context.sh tests/context-pruning.test.sh
git commit -m "feat(context): within-branch pruning (post-ledger), safe Jira cache swap, file lock"
```

---

## Task 10: `prompt.sh` — review prompt: include DISMISSALS, OQ rules, dismissal rules

**Files:**
- Modify: `scripts/prompt.sh`
- Create: `tests/prompt-review.test.sh`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/prompt-review.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

# Build a minimal round dir layout the prompt builder expects.
dir=$(mktemp -d "$CR_TEST_ROOT/pr-XXXX")
mkdir -p "$dir/context" "$dir/results" "$dir/repro"
echo "# manifest" > "$dir/context/context-manifest.md"
echo "commits" > "$dir/context/commits.md"
echo "diff"    > "$dir/context/diff.patch"
echo "files"   > "$dir/context/files-status.txt"
echo "[]"      > "$dir/context/linters.json"
echo ""        > "$dir/context/test-instructions.md"
echo "# jira"  > "$dir/context/jira.md"
echo "## src/x.py:1 — issue\n\n**Fingerprint:** \`src/x.py:1:issue\`\n\nReason: x" > "$dir/context/dismissals.md"

bash "$SCRIPTS/prompt.sh" review "$dir"
prompt="$dir/results/review-prompt.md"
[ -f "$prompt" ] || { echo "FAIL: prompt file missing"; exit 1; }

# Must instruct reviewers about Open Questions
assert_contains "$(cat $prompt)" "Open Questions"
# Must instruct about dismissals
assert_contains "$(cat $prompt)" "Previously Dismissed Findings"
# Must include the dismissals.md content
assert_contains "$(cat $prompt)" "src/x.py:1:issue"
# Must instruct about linter exclusion from verdict
assert_contains "$(cat $prompt)" "Linter output is never the basis"
# Must mention findings.json emission requirement
assert_contains "$(cat $prompt)" "findings.json"

echo "prompt-review OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

- [ ] **Step 3: Update `scripts/prompt.sh`** — the `review` case.

In the existing `prompt.sh review` block:

1. Replace the static review header with a longer text that includes the new rules (Open Questions, Dismissals, Linter exclusion, findings.json emission). Embed (verbatim) the format specification from spec §3.3 + §6.1 + §7. Keep the existing context-manifest / commits / diff / linters sections.

2. After "Detected linters" and before "Diff", add (when present):

```bash
if [ -f "$context_dir/dismissals.md" ] || [ -f "$BRANCH_DIR/DISMISSALS.md" ]; then
  echo "## Previously Dismissed Findings (do not re-flag without new evidence)"
  echo
  if [ -f "$context_dir/dismissals.md" ]; then
    cat "$context_dir/dismissals.md"
  else
    cat "$BRANCH_DIR/DISMISSALS.md"
  fi
  echo
fi
```

3. Append a "## Output requirements" section at the end of the prompt, repeating the §3.3 schema for `findings.json` plus the explicit instruction:

> Emit two files into the results directory:
>
> 1. `findings.json` — machine-readable per §3.3 schema (this is authoritative for validation and carry-forward).
> 2. `FINAL_REVIEW_RESULTS.md` — human-readable rendering of the same data (Summary + Top Risks + Open Questions + Detailed Findings + Linter & Test Status + Intent Check + Notes for the Implementing Agent).
>
> If the two disagree, `findings.json` is authoritative. Validation will reject malformed JSON; on failure the orchestrator will retry once with the validation errors fed back, then mark the review as failed if it still fails.

Reference the spec for the full text; the key sections to fold in are §3.3 (schema), §4.5 (validation rules — must enumerate), §6.1 (Open Question template), §7 (verdict rubric).

- [ ] **Step 4: Run the test to verify it passes.**

- [ ] **Step 5: Commit.**

```bash
git add scripts/prompt.sh tests/prompt-review.test.sh
git commit -m "feat(prompt): review prompt includes DISMISSALS, OQ rules, dismissal rules, findings.json schema"
```

---

## Task 11: `prompt.sh` — arbiter prompt: dismissed_active, obsolete_dismissals, prior_findings.json

**Files:**
- Modify: `scripts/prompt.sh`
- Create: `tests/prompt-arbiter.test.sh`

- [ ] **Step 1: Write the failing test.**

```bash
#!/usr/bin/env bash
# tests/prompt-arbiter.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

dir=$(mktemp -d "$CR_TEST_ROOT/arb-XXXX")
mkdir -p "$dir/context" "$dir/results"
echo "# manifest" > "$dir/context/context-manifest.md"
# Two reviewer reviews
echo "claude review body"  > "$dir/results/claude-review.md"
echo "gemini review body"  > "$dir/results/gemini-review.md"

# Without prior_findings → arbiter prompt must mention dismissed_active+obsolete_dismissals
bash "$SCRIPTS/prompt.sh" arbiter "$dir"
prompt="$dir/results/arbiter-prompt.md"
[ -f "$prompt" ] || { echo "FAIL: arbiter prompt missing"; exit 1; }
assert_contains "$(cat $prompt)" "dismissed_active"
assert_contains "$(cat $prompt)" "obsolete_dismissals"
assert_contains "$(cat $prompt)" "findings.json"
assert_contains "$(cat $prompt)" "verdict rubric"

# With prior_findings.json → arbiter prompt must include the carry-forward instructions
echo '[{"id":"F1","_round":"20260518-140000","fingerprint":"x.py:1:bad","severity":"HIGH"}]' > "$dir/prior_findings.json"
bash "$SCRIPTS/prompt.sh" arbiter "$dir"
prompt="$dir/results/arbiter-prompt.md"
assert_contains "$(cat $prompt)" "prior_findings.json"
assert_contains "$(cat $prompt)" "carried_from"
assert_contains "$(cat $prompt)" "regression.resolved"

echo "prompt-arbiter OK"
```

- [ ] **Step 2: Run the test to verify it fails.**

- [ ] **Step 3: Update `scripts/prompt.sh`** — the `arbiter` case. The new arbiter prompt must:

1. Embed the full §3.3 findings.json schema.
2. Embed §7 verdict rubric (with linter exclusion + carry-forward rule).
3. Embed §4.5 validation rules so the arbiter knows what will be checked.
4. If `<round_dir>/prior_findings.json` exists, include it and the §4.2 step 5 carry-forward instructions verbatim.
5. Otherwise (Full mode), include the §4.3 step 5 dismissal-accounting instructions.
6. Include all reviewer reviews (one section per agent).
7. Append `arbiter-log.md` if present (Q&A history).

Reference the spec for the full text — preserve the precise wording for the JSON schema, the verdict rubric, and the carry-forward rules.

- [ ] **Step 4: Run the test to verify it passes.**

- [ ] **Step 5: Commit.**

```bash
git add scripts/prompt.sh tests/prompt-arbiter.test.sh
git commit -m "feat(prompt): arbiter prompt includes findings.json schema, rubric, carry-forward, dismissal accounting"
```

---

## Task 12: `jira-fetch.py` — attachments + Confluence + safe refresh

**Files:**
- Modify: `scripts/jira-fetch.py`

- [ ] **Step 1: Add CLI args + output structure.**

Update the `argparse` block:

```python
ap = argparse.ArgumentParser()
ap.add_argument("key")
ap.add_argument("--out-dir", required=True, help="cache directory to populate")
ap.add_argument("--mode", choices=["delta", "full"], default="delta",
                help="full re-downloads everything; delta skips files that already exist")
args = ap.parse_args()
```

- [ ] **Step 2: Add an attachment downloader.** Each issue's `fields.attachment` array carries entries with a `content` URL. Download to `<out_dir>/<key>/attachments/<sanitised-filename>`.

```python
def download_attachment(att: dict, dest_dir: Path, email: str, token: str) -> bool:
    url = att.get("content")
    name = att.get("filename") or att.get("id", "attachment")
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    out = dest_dir / safe_name
    out.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={
        "Authorization": auth_header(email, token),
        "User-Agent": "code-reviewer/0.4",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            with open(out, "wb") as f:
                f.write(resp.read())
        return True
    except Exception as e:
        sys.stderr.write(f"[jira-fetch] attachment {name}: {type(e).__name__}: {e}\n")
        return False
```

Call it from `render_issue_markdown` after rendering the body:

```python
attachments = fields.get("attachment") or []
if attachments:
    parts.append("\n## Attachments\n")
    att_dir = Path(args.out_dir) / args.key / "attachments"
    for att in attachments:
        ok = download_attachment(att, att_dir, email, token)
        marker = "✓" if ok else "✗"
        parts.append(f"- {marker} `{att.get('filename', att.get('id', '?'))}` — saved to `{att_dir}/`\n")
```

- [ ] **Step 3: Cache Confluence pages.** Update `fetch_confluence_page` to write the resulting markdown to `<out_dir>/confluence/<page-id>.md` in addition to returning the string.

```python
def fetch_confluence_page(page_url: str, email: str, token: str, out_dir: Path) -> str | None:
    m = re.search(r"/wiki/(?:spaces/[^/]+/)?pages/(\d+)", page_url)
    if not m:
        return None
    base = page_url.split("/wiki/")[0]
    page_id = m.group(1)
    cache_path = out_dir / "confluence" / f"{page_id}.md"
    if cache_path.exists():
        return cache_path.read_text(encoding="utf-8")
    api = f"{base}/wiki/api/v2/pages/{page_id}?body-format=storage"
    data = http_get_json(api, email, token)
    if not data:
        return None
    title = data.get("title", page_id)
    storage = (data.get("body", {}) or {}).get("storage", {}).get("value", "")
    md = html_to_markdown(storage)
    rendered = f"### Confluence: {title}\n\nSource: {page_url}\n\n{md}\n"
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(rendered, encoding="utf-8")
    return rendered
```

- [ ] **Step 4: Write the issue body markdown to a stable path.** The output filename is `<out_dir>/<KEY>.md` regardless of mode. The caller decides whether the directory itself is `.jira-cache.new/` or `.jira-cache/`.

```python
out_md = Path(args.out_dir) / f"{args.key}.md"
out_md.parent.mkdir(parents=True, exist_ok=True)
out_md.write_text(msg, encoding="utf-8")
print(out_md)
```

- [ ] **Step 5: Manually smoke-test against a real Jira ticket** (skip if you don't have credentials — this script is integration-tested via the full `/code-reviewer:start` smoke test in Task 20).

- [ ] **Step 6: Commit.**

```bash
git add scripts/jira-fetch.py
git commit -m "feat(jira): download attachments, cache Confluence pages, --mode full|delta"
```

---

## Task 13: Reviewer agent prompts (claude / codex / gemini / opencode)

**Files:**
- Modify: `agents/claude-reviewer.md`
- Modify: `agents/codex-reviewer.md`
- Modify: `agents/gemini-reviewer.md`
- Modify: `agents/opencode-reviewer.md`

For each file, add the following sections to the body. The dispatcher-style agents (codex/gemini/opencode) only need the new sections in their persona description; the actual rules live in the review prompt that `prompt.sh review` assembles.

- [ ] **Step 1: Add the new rule block at the end of each `*-reviewer.md`.**

```markdown
## V0.4.0 review standards

You will receive a structured review prompt from `prompt.sh review`. Follow it
verbatim, with these additional rules:

- **Open Questions vs Findings.** If intent is unclear (the diff, commits, or
  Jira ticket leave a question unanswered), do **not** guess and file a
  Finding. Open the `## Open Questions` section of your review and add an
  `OQ.<n>` block per the schema in the review prompt. Each Open Question
  must have a category (`IntentAmbiguity` / `MissingContext` /
  `ConflictingSignals` / `OutOfScopeConcern`), a file/line, the actual
  question, why it was flagged, and 2+ proposed paths forward.

- **Dismissals.** A `## Previously Dismissed Findings` section may appear in
  the prompt. Do **not** re-flag a finding whose file/line/summary matches a
  dismissal unless you have new evidence: a different vector, a different
  file, or proof the dismissal's reason no longer holds. If neither holds,
  omit the finding entirely (do not list it as "dismissed and confirmed" —
  that's noise).

- **Linter findings** are project-specific and **do not promote to Findings**
  unless you argue the case independently as a real defect (cite the same
  file/line; the linter output becomes Evidence, not the source). The
  arbiter's verdict will explicitly exclude linter output.

- **Delta vs Full.** The prompt declares the review mode. In a Delta you
  focus on the new material since the last review (the prompt includes the
  prior `FINAL_REVIEW_RESULTS.md`); in a Full you cover the entire branch
  diff. Either way, your output format is the same.

- **Severity assignments.** Use the rubric:
  - CRITICAL — security exploit, data loss, broken contract, exposed secret.
  - HIGH — real bug, intent mismatch, regression, missing required test for
    new code.
  - MEDIUM — meaningful but non-blocking defect.
  - LOW — stylistic, non-blocking.
```

- [ ] **Step 2: For the dispatchers (codex / gemini / opencode), verify their CLI command lines still reflect any path changes** in Task 9 — specifically, the `--add-dir` arguments should include the new round directory's `repro/` path so reviewers can write repro tests. If you renamed any paths, update the dispatcher commands.

- [ ] **Step 3: Manually inspect the rendered review prompt** (run a test review on a fixture branch) to confirm reviewers receive the new rules. This is integration-tested in Task 20.

- [ ] **Step 4: Commit.**

```bash
git add agents/claude-reviewer.md agents/codex-reviewer.md agents/gemini-reviewer.md agents/opencode-reviewer.md
git commit -m "feat(agents): reviewer prompts include OQ / dismissals / linter / delta-full rules"
```

---

## Task 14: Arbiter prompt — verdict rubric, findings.json emission, dismissed_active accounting

**Files:**
- Modify: `agents/arbiter.md`

- [ ] **Step 1: Replace the existing `## Final Report Format` section** with the full spec from §3.3 (findings.json schema), §4.3 step 5 (dismissal accounting for Full), §4.2 step 5 (carry-forward for Delta), §7 (verdict rubric), and §6 (rich-text FINAL_REVIEW_RESULTS.md template).

The arbiter's responsibilities (per the new spec):

```markdown
## Arbiter output

You must emit BOTH:

1. **`findings.json`** in the results directory — machine-readable per the
   schema below. This is the authoritative artifact used for ledger
   updates, carry-forward verification, and the push gate.
2. **`FINAL_REVIEW_RESULTS.md`** in the results directory — human-readable
   rendering of the same data with Summary + Top Risks + Open Questions +
   Detailed Findings + Linter & Test Status + Intent Check + Notes for the
   Implementing Agent.

If the two disagree, `findings.json` is authoritative. Validation will run
on `findings.json` (rules 1–9 per spec §4.5); on failure, you'll be re-
prompted with the errors and asked to retry once.

### findings.json schema

[Embed the full §3.3 schema verbatim — fields, types, required/optional,
enum constraints. Use the full JSON example from §3.3 with `dismissed_active`,
`obsolete_dismissals`, `regression`, etc.]

### Verdict rubric

[Embed §7 verbatim. Key bullets:
- Tier = highest unresolved finding severity across findings[] (carried + new).
- Linter output does NOT influence the verdict.
- Open Questions do NOT influence the verdict.
- Intent mismatch under dispute → Open Question, not Finding (unless evidence is unambiguous).]

### Dismissal accounting (both modes)

For every fingerprint in `DISMISSALS.md`, classify into exactly one of:
- `dismissed_active[]` — code still exhibits the issue but is suppressed.
- `obsolete_dismissals[]` — code no longer exhibits the issue; record a `reason`.

No silent drops (validation rule 9 will catch them).

### Carry-forward (Delta only)

When `prior_findings.json` is provided, for each entry route to exactly one of:
- `findings[]` with `carried_from: "<prev>:<id>"` — still present, not dismissed.
- `dismissed_active[]` with `ref: "<prev>:<id>"` — still present, dismissed.
- `regression.resolved` as `"<prev>:<id>"` — no longer present.

No silent drops (validation rule 5).
```

- [ ] **Step 2: Add the failure-retry handling.** Append:

```markdown
## On validation failure

If the orchestrator re-prompts you with validation errors, treat them as
authoritative. Re-emit `findings.json` correcting EVERY listed issue.
Common failure modes:

- Missing prior-finding carry-forward → add the entry to findings[],
  dismissed_active[], or regression.resolved as appropriate.
- Verdict-rubric mismatch → recompute the verdict from the severity tiers.
- Fingerprint not consistent with file:line → fix the fingerprint to match.
- Dismissal coherence — fingerprint matches DISMISSALS.md but in findings[] →
  move to dismissed_active[] with full detail.
```

- [ ] **Step 3: Commit.**

```bash
git add agents/arbiter.md
git commit -m "feat(agents): arbiter emits findings.json per schema, verdict rubric, carry-forward + dismissal accounting, failure-retry guidance"
```

---

## Task 15: `code-reviewer-setup` SKILL — new config keys

**Files:**
- Modify: `skills/code-reviewer-setup/SKILL.md`

- [ ] **Step 1: Add the four new keys to the setup wizard.** In the existing setup flow, after the "agents" prompt, add four new prompts (one per key):

1. `review_output_path` — "Where should reviews be stored? Default: `/tmp/code-reviewer`. Note: `/tmp` is volatile across reboots — pick `~/.cache/code-reviewer` if you want persistence."
2. `auto_trigger` — "Enable the `git push` gate hook? (true/false, default true)"
3. `skip_branches` — "Comma-separated list of branches the plugin should never gate (default empty — runs on all branches including main/master). Example: `main, release`"
4. `keep_last_rounds` — "How many timestamp directories to keep per branch? (integer ≥ 1, default 10)"

Validate each input:
- `keep_last_rounds`: must be a positive integer; reject otherwise.
- `auto_trigger`: must be the literal `true` or `false`.

Write all four keys to `~/.code-reviewer/config.json`.

- [ ] **Step 2: Surface the volatility note in the wizard output.** After writing config, if `review_output_path` resolves to `/tmp/...`, print:

```
Note: review_output_path resolves under /tmp, which is wiped on reboot.
Your DISMISSALS.md and ledger will not persist. To keep them, set
review_output_path to ~/.cache/code-reviewer or similar in
~/.code-reviewer/config.json.
```

- [ ] **Step 3: Commit.**

```bash
git add skills/code-reviewer-setup/SKILL.md
git commit -m "feat(setup): prompt for review_output_path, auto_trigger, skip_branches, keep_last_rounds"
```

---

## Task 16: `code-reviewer-autodetect` SKILL (new)

**Files:**
- Create: `skills/code-reviewer-autodetect/SKILL.md`

- [ ] **Step 1: Write the SKILL.**

```markdown
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
```

- [ ] **Step 2: Commit.**

```bash
git add skills/code-reviewer-autodetect/SKILL.md
git commit -m "feat(skills): /code-reviewer:autodetect toggle"
```

---

## Task 17: `code-reviewer-dismiss` SKILL (new)

**Files:**
- Create: `skills/code-reviewer-dismiss/SKILL.md`

- [ ] **Step 1: Write the SKILL.**

```markdown
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

2. Dispatch to `dismiss.sh`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dismiss.sh" $ARGUMENTS "$DISM_PATH"
```

(Adjust arg order so $1 is the action and $2 is the file path — match the `dismiss.sh` API.)

3. After mutating commands (add/remove), echo: "Dismissal updated. The next `/code-reviewer:start` will see the change (DISMISSALS.md hash differs)." This nudges the user that the gate will fire on next push until they re-review.
```

- [ ] **Step 2: Commit.**

```bash
git add skills/code-reviewer-dismiss/SKILL.md
git commit -m "feat(skills): /code-reviewer:dismiss wraps scripts/dismiss.sh for current branch"
```

---

## Task 18: `code-reviewer-start` SKILL — major update

**Files:**
- Modify: `skills/code-reviewer-start/SKILL.md`

This is the orchestration skill. It changes substantially:
- New `--delta` / `--full` flags
- Nothing-new short-circuit
- Validation phase between arbiter and Phase 7
- Phase 7 rich-text refactor (Summary + Open Questions + Findings list + dismissal + push-anyway hints + dirty-tree caveat)
- Phase 7.1 failure-case template
- AskUserQuestion (hint to main session) at the end

- [ ] **Step 1: Add the new flag-parsing block at the top.** Document `[--delta | --full]`, `[--ticket K]`, `[--base R]`, `[--no-prune]`, and the fall-through default (Delta if ledger exists, else Full).

- [ ] **Step 2: Rewrite the "Phase 1: Gather Context" block.** The skill now invokes `context.sh` with the mode flag and consumes its output (round dir path, mode actually used after fallbacks, JSON-encoded fallback reasons). Add the nothing-new short-circuit handling — if `context.sh` exited 0 without producing a new round dir, render a one-line summary and stop.

- [ ] **Step 3: Insert a new "Phase 6.5: Validation" block** between the arbiter dispatch and Phase 7:

```markdown
## Phase 6.5: Validation

After the arbiter emits `findings.json` + `FINAL_REVIEW_RESULTS.md`, run:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/validate-findings.py \
    "<ROUND_DIR>/findings.json" \
    --prior "<ROUND_DIR>/prior_findings.json" \
    --dismissals "<BRANCH_DIR>/DISMISSALS.md"
```

(Omit `--prior` if the file doesn't exist — Full mode.)

- **Exit 0:** validation passed. Append the ledger entry, render the
  human ledger markdown via `ledger.sh render-md`, then proceed to
  Phase 7.
- **Exit 1:** validation failed. Move `findings.json` to
  `findings.json.invalid`, write `validation-errors.md`, and re-dispatch
  the arbiter ONCE with the errors fed back. If the retry also fails,
  write `REVIEW_FAILED.md` (no ledger append), then jump to Phase 7.1.
```

- [ ] **Step 4: Replace "Phase 7" entirely.** New template (success case):

```markdown
## Phase 7: Hand off to the user (success)

Read `<ROUND_DIR>/findings.json` (the authoritative artefact). Render
the rich-text output per spec §6.2 — header line, Summary section,
Open Questions section (with explicit "resolve with user first" hint),
Findings list (one bullet per F<n>), Linter & Test Status, Intent Check,
and the conditional caveat lines (push-anyway, dirty-tree, dismiss).

Then call AskUserQuestion exactly once:

> What's next?
>
> Options:
> - Resolve Open Questions first   (only if OQs exist)
> - Apply fixes
> - Discuss the report
> - Skip for now

The answer is a hint — the plugin takes no action. End the skill.
```

- [ ] **Step 5: Add "Phase 7.1: Failure-case hand-off"** per spec §6.2.1:

```markdown
## Phase 7.1: Hand off (validation failure)

When the validation gate (Phase 6.5) failed and a `REVIEW_FAILED.md`
exists, render the failure rich-text per spec §6.2.1 — pointer to
report, validation-errors, invalid arbiter output, mode, retry count,
first-error summary, likely causes, next-step menu.

Then AskUserQuestion:

> What now?
>
> Options:
> - Retry as Full review
> - Inspect the failure
> - Skip this push
```

- [ ] **Step 6: Confirm a smoke run produces the expected layout.** Use a tiny fixture branch with a single trivial diff. Run `/code-reviewer:start --full` and inspect the round dir for `findings.json`, `FINAL_REVIEW_RESULTS.md`, `prior_findings.json` (absent on Full), ledger updated, REVIEW_LEDGER.md regenerated.

- [ ] **Step 7: Commit.**

```bash
git add skills/code-reviewer-start/SKILL.md
git commit -m "feat(skills): /code-reviewer:start delta/full, validation phase, Phase 7 + 7.1 hand-offs"
```

---

## Task 19: README + CLAUDE.md updates

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update README.md.** Add or rewrite the relevant sections so they reflect v0.4.0:

- Add commands to the "Skills" table: `/code-reviewer:autodetect`, `/code-reviewer:dismiss`.
- Add `--delta`, `--full`, `--no-prune` to the `/code-reviewer:start` usage examples.
- Replace the existing "Storage" / "Output Layout" section with the new per-branch layout (ledger.json, REVIEW_LEDGER.md, DISMISSALS.md, .jira-cache, timestamp rounds with findings.json + FINAL_REVIEW_RESULTS.md).
- Add a "Hook" section explaining the PreToolUse gate, the four user-facing options when it denies, and the `CR_SKIP=1` override.
- Add a "Dismissals" section explaining DISMISSALS.md (when, how, what the gate does on changes).
- Add a "Volatility note" — default `/tmp/code-reviewer/` is wiped on reboot; suggest `~/.cache/code-reviewer` for persistence.

- [ ] **Step 2: Update CLAUDE.md** with developer-facing docs for the new components:

- File inventory (six new files, ~nine changed).
- The five new config keys.
- The eight new deny reasons from the hook.
- Where the validator lives and what it checks.
- The findings.json schema (in-band or by reference to the spec).
- A short note that the spec lives at `docs/superpowers/specs/2026-05-18-review-flow-design.md` (rev 13).

- [ ] **Step 3: Commit.**

```bash
git add README.md CLAUDE.md
git commit -m "docs: v0.4.0 — README + CLAUDE.md updated for delta/full, hook, dismissals, OQs"
```

---

## Task 20: Version bump + integration smoke test + final commit

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Create: `tests/integration-smoke.test.sh`

- [ ] **Step 1: Bump the version.**

```bash
./scripts/bump-version.sh minor
./scripts/bump-version.sh check
```

Expected:

```
0.3.0 -> 0.4.0
0.4.0 (in sync)
```

- [ ] **Step 2: Write an integration smoke test.**

```bash
#!/usr/bin/env bash
# tests/integration-smoke.test.sh
#
# End-to-end smoke: fixture repo, /code-reviewer:start full → ledger + findings.json,
# then /code-reviewer:start delta with no new commits → nothing-new short-circuit,
# then /code-reviewer:start delta after a new commit → second ledger entry.
#
# Stubs out the actual agent dispatch by short-circuiting the prompt run and
# writing a hand-crafted findings.json + FINAL_REVIEW_RESULTS.md that pass
# validation. The point is to exercise the orchestration glue, not the agents.

set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo smoke-int)
cd "$repo"
git checkout -qb feat
echo a >> README; git commit -qam "c1"

CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\",\"agents\":[\"claude\"],\"keep_last_rounds\":5}" > "$CR_CONFIG_DIR/config.json"

# 1) context.sh full run → produces a round dir.
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR=$(echo "$out" | tail -1)
[ -d "$ROUND_DIR" ] || { echo "FAIL: round dir not created"; exit 1; }

# 2) Inject a hand-crafted findings.json + FINAL_REVIEW_RESULTS.md as if the agents produced them.
mkdir -p "$ROUND_DIR/results"
HEAD_SHA=$(git rev-parse HEAD)
BASE_SHA=$(git rev-parse main)
cat > "$ROUND_DIR/findings.json" <<JSON
{
  "round":"$(basename $ROUND_DIR)","verdict":"APPROVE","confidence":"HIGH",
  "head_sha":"$HEAD_SHA","base_sha":"$BASE_SHA",
  "findings":[],"open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
JSON
cp "$ROUND_DIR/findings.json" "$ROUND_DIR/FINAL_REVIEW_RESULTS.md"   # placeholder body

# 3) Validate it.
python3 "$SCRIPTS/validate-findings.py" "$ROUND_DIR/findings.json" >/dev/null
assert_exit 0 "$?"

# 4) Append the ledger entry manually (simulating Phase 6.5 success).
REPO_SLUG=$(basename "$repo")
BRANCH_DIR="$ROUT/$REPO_SLUG/feat"
bash "$SCRIPTS/ledger.sh" append "$BRANCH_DIR/.review-ledger.json" "$(jq -n \
  --arg ts "$(basename $ROUND_DIR)" --arg head "$HEAD_SHA" --arg base "$BASE_SHA" \
  '{branch:"feat",base_ref:"main",jira_keys:[],jira_cached_at:null,
    timestamp:$ts,type:"full",head_sha:$head,base_ref:"main",base_sha:$base,
    commits_reviewed:[$head],previous_head_sha:null,worktree_hash:null,
    dismissals_hash:null,verdict:"APPROVE",
    findings:{critical:0,high:0,medium:0,low:0},open_questions:0,
    round_dir:$ts,fallback_reason:null}')"

# 5) Delta with no changes → nothing-new short-circuit.
out=$(bash "$SCRIPTS/context.sh" 2>&1) && rc=$? || rc=$?
assert_contains "$out" "Nothing new"

# 6) New commit → Delta runs.
echo b >> README; git commit -qam "c2"
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR2=$(echo "$out" | tail -1)
[ -d "$ROUND_DIR2" ] || { echo "FAIL: second round dir not created"; exit 1; }
[ -f "$ROUND_DIR2/prior_findings.json" ] || { echo "FAIL: prior_findings.json must exist on Delta"; exit 1; }

# 7) Hook denies because no ledger entry for the new HEAD.
HOOK="$SCRIPTS/hooks/pre-push.sh"
out=$(jq -nc --arg c "git push origin feat" '{toolInput:{command:$c}}' | bash "$HOOK")
assert_contains "$out" "head_changed"

echo "integration-smoke OK"
```

- [ ] **Step 3: Run the full test suite.**

```bash
bash tests/run.sh
```

All tests must pass. Iterate on any failure before the final commit.

- [ ] **Step 4: Create a single capstone commit that bundles the version bump, smoke test, and any final adjustments.**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json tests/integration-smoke.test.sh
git commit -m "release(v0.4.0): bump version, add integration smoke test

Implements the v0.4.0 design spec (docs/superpowers/specs/2026-05-18-review-flow-design.md
rev 13): Delta/Full review modes, per-branch ledger with dismissed_active and
obsolete_dismissals, validated findings.json schema, PreToolUse hook gating
git push by verdict, Open Questions in reports, DISMISSALS.md with
Fingerprint-keyed parser, autodetect/dismiss skills, trunk-style workflow
support."
```

- [ ] **Step 5: Push.**

```bash
git push
```

---

## Done

The plugin is now at v0.4.0. Users can:

- `/code-reviewer:setup` — configure including the new keys.
- `/code-reviewer:start [--delta|--full]` — run a review; Delta carries findings forward, Full re-downloads Jira and rebuilds dismissed_active.
- `/code-reviewer:autodetect true|false` — toggle the hook.
- `/code-reviewer:dismiss add|remove|list` — manage false-positive dismissals.
- `git push` — automatically gated by the hook unless `CR_SKIP=1`, the branch is in `skip_branches`, or `auto_trigger=false`.

Subsequent maintenance:

- Re-run `bash tests/run.sh` before any commit.
- Bump version via `./scripts/bump-version.sh patch|minor|major` before every commit per CLAUDE.md rules.
- For Claude Code plugin hook spec changes, re-verify `.claude-plugin/hooks.json` field names match the current Claude Code docs.
