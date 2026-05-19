#!/usr/bin/env bash
# Assemble prompts for the review pipeline.
#
# Usage:
#   prompt.sh review  <round_dir>
#   prompt.sh arbiter <round_dir>
#   prompt.sh question <round_dir> <agent> <questions_json>
#
# Each subcommand writes the prompt to <round_dir>/results/<name>.md and prints
# the absolute path on the last line of stdout.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

cmd="${1:-}"; shift || true
round_dir="${1:-}"; shift || true
if [ -z "$cmd" ] || [ -z "$round_dir" ]; then
  echo "Usage: prompt.sh review|arbiter|question <round_dir> [args...]" >&2
  exit 2
fi

context_dir="$round_dir/context"
results_dir="$round_dir/results"
repro_dir="$round_dir/repro"

if [ ! -d "$context_dir" ]; then
  echo "Context dir not found: $context_dir" >&2
  exit 1
fi
mkdir -p "$results_dir"

slurp() {
  local path="$1"
  if [ -f "$path" ]; then
    cat "$path"
  fi
}

case "$cmd" in

  review)
    out="$results_dir/review-prompt.md"
    {
      cat <<'HDR'
# Code Review — Pre-Push, Multi-Agent

You are one of several independent reviewers examining the same local branch
**before it is pushed for human review**. Other agents are reviewing the same
diff in parallel. Be strict — your job is to catch real problems (bugs,
security issues, performance issues, regressions, missing tests, deviations
from stated intent) so the implementing agent can fix them before pushing.

## Output Format

Write your review in this exact structure (Markdown). Cite file paths and line
numbers for every finding.

```markdown
# Review by <your name>

**Verdict:** APPROVE | APPROVE_WITH_COMMENTS | REQUEST_CHANGES | BLOCK
**Confidence:** HIGH | MEDIUM | LOW
**Intent assessment:** (Did the diff achieve the stated goal? Brief paragraph.)

## Findings

### F1. <one-line title>
- **Severity:** CRITICAL | HIGH | MEDIUM | LOW
- **Category:** Bug | Security | Regression | Performance | Test Coverage | Style | Intent Mismatch | Other
- **File:** `<path>:<line>` (or `<path>:<start>-<end>`)

**Problem:** ...

**Why it matters:** ...

**Evidence:** code excerpt in a language-tagged fenced code block, plus any
linter output you reproduced or repro test you wrote.

**Required fix:** concrete instruction the implementing agent can apply.

### F2. ...

## Open Questions

For genuine intent/scope ambiguities that you cannot resolve from the diff and
context alone, list them here — do NOT mask uncertainty inside Findings. Each
Open Question uses this template:

### OQ1. <one-line summary>
- **ID:** OQ1
- **Category:** IntentAmbiguity | MissingContext | ConflictingSignals | OutOfScopeConcern
- **File:** `<path>:<line>` (or omit if not file-specific)
- **Question:** The precise question the arbiter should route back to you or
  escalate to the author.

## Test Coverage Gaps

For each new or changed function/class that lacks a corresponding test, list:
- File + symbol
- Suggested test description

## Linter Run

If you ran a linter against changed files, paste the relevant output (trim
unrelated noise).

## Test Suite Run

If the repo's test instructions are clear and you ran them, report:
- Command run
- Result (pass / fail)
- Failures (file::test — reason)

## Regression Check

If a previous review on this branch was supplied, list:
- Issues fixed since last round
- Issues that remain
- New issues introduced
```

## Standards

- **Strict + high effort.** This is the last automated gate before human
  review. Hedging hurts the implementing agent's ability to fix issues.
- **Bug ≠ feature.** Read the commit messages and (if present) the Jira ticket
  to understand *intent*. Flag intent mismatches as a category.
- **Prove bugs.** If you find a bug that needs proof, write a small repro test
  to `tmp/code-reviews/<branch>/<timestamp>/repro/` and reference its path.
- **Cover security, efficiency, regression risk.** Don't just review style.
- **Run linters** on changed files if the repo has a linter config (rubocop,
  eslint, ruff, golangci-lint, etc.). Suggested commands are listed below.
- **Run tests** if the repo's README/CLAUDE.md/AGENTS.md describes how.
- **Test coverage.** Flag every changed code path with no corresponding test.
- **Language-tagged code blocks only.** Use ` ```ruby `, ` ```python `,
  ` ```typescript `, etc., matching the actual file extension.
- **Cite line numbers.** Every finding has `<path>:<line>` (or a range).
- **Be conservative on style nits.** A handful at the end is fine; do not
  drown the implementing agent in cosmetic noise.
- **Linter output is never the basis for the verdict.** Treat linter output as
  evidence, not findings. The verdict rubric is determined by manual findings
  (CRITICAL/HIGH/MEDIUM/LOW); linter output supplements them but cannot
  escalate or set the verdict.
- **Honour the Previously Dismissed Findings section.** If a finding matches
  one of those fingerprints (`<file>:<line>:<slug(summary)>`), do NOT re-flag
  it unless you have new evidence that was not present when it was dismissed.

---

HDR

      echo "## Context Manifest"
      echo
      slurp "$context_dir/context-manifest.md"
      echo
      echo "## Commits (with full messages — read these for intent)"
      echo
      slurp "$context_dir/commits.md"
      echo
      echo "## Files Changed (status)"
      echo
      echo '```'
      slurp "$context_dir/files-status.txt"
      echo '```'
      echo
      if [ -f "$context_dir/jira.md" ]; then
        echo "## Jira Ticket (stated intent)"
        echo
        slurp "$context_dir/jira.md"
        echo
      fi
      if [ -f "$context_dir/previous-review.md" ]; then
        echo "## Previous FINAL_REVIEW_RESULTS.md (regression check)"
        echo
        echo "This is the most recent prior review on this branch. Use it to:"
        echo
        echo "- Confirm which previously-flagged issues are now fixed."
        echo "- Flag any previously-fixed issues that have regressed."
        echo "- Flag new issues introduced since the previous review."
        echo
        slurp "$context_dir/previous-review.md"
        echo
      fi
      if [ -s "$context_dir/test-instructions.md" ]; then
        echo "## Repo Test/Build Instructions (extracted)"
        echo
        slurp "$context_dir/test-instructions.md"
        echo
      fi
      if [ -s "$context_dir/linters.json" ] && [ "$(jq 'length' "$context_dir/linters.json" 2>/dev/null)" != "0" ]; then
        echo "## Detected Linters"
        echo
        echo "Run the relevant ones against changed files and include the output in"
        echo "your review's Linter Run section. Commands shown below are scoped to"
        echo "changed files where applicable."
        echo
        echo '```json'
        slurp "$context_dir/linters.json"
        echo '```'
        echo
      fi
      if [ -f "$context_dir/dismissals.md" ] || [ -f "${BRANCH_DIR:-}/DISMISSALS.md" ]; then
        echo "## Previously Dismissed Findings (do not re-flag without new evidence)"
        echo
        if [ -f "$context_dir/dismissals.md" ]; then
          cat "$context_dir/dismissals.md"
        else
          cat "${BRANCH_DIR:-}/DISMISSALS.md"
        fi
        echo
      fi
      echo "## Repro Test Directory"
      echo
      echo "Write any repro tests for bugs you find under:"
      echo
      echo "    $repro_dir/"
      echo
      echo "Reference each repro file's path in the Evidence section of its finding."
      echo
      echo "## Diff"
      echo
      echo '```diff'
      slurp "$context_dir/diff.patch"
      echo '```'
      echo
      echo "## Output Requirements"
      echo
      echo "Your individual review is consumed by the arbiter, which consolidates the"
      echo "reviews into a single authoritative \`findings.json\` (per spec §3.3 schema)"
      echo "and \`FINAL_REVIEW_RESULTS.md\`. To make consolidation accurate, ensure every"
      echo "finding in your review carries the fields the arbiter will need: severity,"
      echo "category, file, line, summary, and a deterministic identity (the arbiter"
      echo "computes a fingerprint as \`<file>:<line>:<slug(summary)>\`). The arbiter's"
      echo "findings.json will be validated against §4.5 rules and on failure your"
      echo "individual review will be re-examined for inconsistencies, so prefer"
      echo "precision over completeness."
    } > "$out"
    echo "$out"
    ;;

  arbiter)
    out="$results_dir/arbiter-prompt.md"
    is_final="${1:-}"  # optional "final" flag forces a final report
    {
      cat <<'HDR'
# Arbiter Prompt

You are the arbiter for a multi-agent pre-push code review. Synthesise the
agent reviews into a single FINAL_REVIEW_RESULTS.md the implementing agent
will act on.

Audience: the implementing AI agent (primary) and the human author (secondary).

## Decision

If agents disagree on any finding (severity, whether something is a real
issue, the verdict) and rounds remain, output a JSON questions block. Format:

```json
{
  "claude": ["question 1"],
  "codex": [],
  "gemini": ["question 1"],
  "opencode": []
}
```

Only include keys for agents that produced a review. Use empty arrays for
agents with no questions.

Otherwise produce the final report in the exact format below.

## Final Report Format

```markdown
# Code Review — <branch>

**Verdict:** `[APPROVE]` | `[APPROVE_WITH_COMMENTS]` | `[REQUEST_CHANGES]` | `[BLOCK]`
**Confidence:** HIGH | MEDIUM | LOW
**Branch:** `<branch>` vs `<base>`
**Commits reviewed:** N
**Files changed:** N (+X / -Y)
**Issues:** Critical: N · High: N · Medium: N · Low: N
**Regressions detected:** N
**Linter findings:** N
**Missing tests:** N

---

## Summary

3–8 sentences for the human. Cover: what the branch is trying to do; whether
it achieves it; top 1–3 reasons (if any) not to push; tests/coverage status;
clear verdict.

### Top Risks

3–5 bullets, each: severity + one sentence.

### Regression vs Previous Review

If a previous FINAL_REVIEW_RESULTS.md was supplied:
- Fixed: ...
- Still present: ...
- New: ...

Otherwise: _No prior review on this branch._

---

## Detailed Findings

Group by severity (Critical, High, Medium, Low — only sections with findings).

For each finding (self-contained — the implementing agent must be able to fix
it without re-reading any individual review):

#### F<N>. <one-line title>

- **Severity:** CRITICAL | HIGH | MEDIUM | LOW
- **Category:** Bug | Security | Regression | Performance | Test Coverage | Style | Intent Mismatch | Other
- **File:** `<path>:<line>` (or `<path>:<start>-<end>`)
- **Reviewers agreeing:** claude, codex, gemini, opencode (list those that flagged this)

**Problem**: precise description, reference lines, expected vs actual.

**Why it matters**: impact (correctness, security, perf, user-facing).

**Evidence**: code excerpt in a language-tagged fenced code block matching the
file extension; if a reviewer wrote a repro test, reference its path; if a
linter flagged this, include the linter output.

**Required fix**: concrete instruction. If multiple acceptable fixes exist,
list them and recommend one.

**Acceptance check**: how the implementing agent verifies the fix (test cmd,
linter cmd, manual check).

---

## Test Coverage Gaps

List code paths in the diff with no corresponding test.

## Linter Output

Per-linter, condensed.

## Test Suite Status

- Test command(s) detected: ...
- Result: pass / fail / not run (reason)
- Failed tests (if any)

## Intent Check (vs Jira Ticket)

If a Jira ticket was supplied:
- Ticket: <KEY> — <title>
- Stated goal: paraphrase
- Achieved? Yes / Partially / No — one-paragraph reasoning
- Out-of-scope changes (if any)

Otherwise: _No ticket linked._

---

## Reviewer Agreement Matrix

| Finding | claude | codex | gemini | opencode |
|---|---|---|---|---|
| F1 | yes | yes | — | yes |

(`yes` = flagged · `no` = explicitly disagreed · `—` = did not mention / did not run)

---

## Notes for the Implementing Agent

Prioritised checklist:
1. Fix F1 (Critical) — ...
2. Fix F2 (High) — ...
3. Run `<test cmd>` — confirm pass.
4. Run `<linter cmd>` — confirm clean.
5. Re-run `/code-reviewer:start` for a regression check before pushing.
```

## Principles

- Where agents agree, findings are likely correct.
- Where they disagree, ask if rounds remain — do not pick a side without
  evidence. Otherwise resolve transparently and note the disagreement.
- What one caught that others missed — ask the others if they agree, unless
  rounds are exhausted.
- Flag unsubstantiated or hallucinated claims — ask the claimant for proof.

---

HDR

      if [ "$is_final" = "final" ]; then
        echo "## Important: this is the FINAL round."
        echo
        echo "Maximum Q&A rounds have been reached. You MUST produce the final report now."
        echo "Do not output a questions block."
        echo
      fi

      echo "## Context Manifest"
      echo
      slurp "$context_dir/context-manifest.md"
      echo

      if [ -f "$context_dir/jira.md" ]; then
        echo "## Jira Ticket"
        echo
        slurp "$context_dir/jira.md"
        echo
      fi

      if [ -f "$context_dir/previous-review.md" ]; then
        echo "## Previous FINAL_REVIEW_RESULTS.md"
        echo
        slurp "$context_dir/previous-review.md"
        echo
      fi

      echo "## Agent Reviews"
      echo
      for review in "$results_dir"/*-review.md; do
        [ -f "$review" ] || continue
        agent_name=$(basename "$review" -review.md)
        echo "### $agent_name"
        echo
        slurp "$review"
        echo
        echo "---"
        echo
      done

      if [ -f "$results_dir/arbiter-log.md" ]; then
        echo "## Q&A History"
        echo
        slurp "$results_dir/arbiter-log.md"
      fi
    } > "$out"
    echo "$out"
    ;;

  question)
    agent="${1:-}"; shift || true
    questions_json="${1:-}"; shift || true
    if [ -z "$agent" ] || [ -z "$questions_json" ]; then
      echo "Usage: prompt.sh question <round_dir> <agent> <questions_json>" >&2
      exit 2
    fi
    round_n=$(($(ls "$results_dir"/round-*-"$agent"-question.md 2>/dev/null | wc -l) + 1))
    out="$results_dir/round-$round_n-$agent-question.md"
    agent_questions=$(echo "$questions_json" | jq -r --arg a "$agent" '.[$a][]?' 2>/dev/null)
    {
      echo "# Arbiter Follow-up — round $round_n — for $agent"
      echo
      echo "The arbiter has reviewed your initial review and the reviews of the other"
      echo "agents and has follow-up questions for you. Answer each one precisely with"
      echo "file paths, line numbers, and code excerpts. If you need to verify a claim,"
      echo "run a quick check in the repo at the path provided in your dispatch."
      echo
      echo "## Questions"
      echo
      i=1
      while IFS= read -r q; do
        [ -z "$q" ] && continue
        echo "$i. $q"
        i=$((i + 1))
      done <<< "$agent_questions"
      echo
      echo "## Your Original Review"
      echo
      slurp "$results_dir/$agent-review.md"
      echo
      if [ -f "$context_dir/context-manifest.md" ]; then
        echo "## Context Manifest"
        echo
        slurp "$context_dir/context-manifest.md"
      fi
    } > "$out"
    echo "$out"
    ;;

  *)
    echo "Unknown subcommand: $cmd" >&2
    exit 2
    ;;
esac
