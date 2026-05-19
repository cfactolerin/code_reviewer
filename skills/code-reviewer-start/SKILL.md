---
name: code-reviewer-start
description: Non-interactive multi-agent review of the current branch vs its base. Supports --delta (only new commits/changes since last review) and --full (whole branch). Runs Claude/Codex/Gemini/opencode in parallel, arbiter synthesises results, validates findings.json, appends the ledger, writes FINAL_REVIEW_RESULTS.md, and hands off to the main session with a structured menu.
argument-hint: "[--delta | --full] [--ticket <KEY>] [--base <ref>] [--no-prune]"
allowed-tools: ["Bash(*)", Read, Write, Grep, Glob, Agent, TaskCreate, TaskUpdate, TaskList, AskUserQuestion]
---

# code-reviewer:start — Non-Interactive Multi-Agent Review

You are orchestrating a strict pre-push code review on the **current local
branch**. The multi-agent review itself is **non-interactive** — do not ask
the user questions during context gathering, agent dispatch, or arbiter
synthesis. Drive the pipeline to completion and produce
`FINAL_REVIEW_RESULTS.md`.

The **final hand-off** (Phase 7 or Phase 7.1) is the only place you talk to
the user: you show the review results and ask what to do next via
`AskUserQuestion`.

Throughout this skill:

- **PLUGIN_ROOT** = `${CLAUDE_PLUGIN_ROOT}`
- **CONFIG** = `~/.code-reviewer/config.json`
- **ARGS** = the value of `$ARGUMENTS`

## Usage

Flags inside `$ARGUMENTS`:

| Flag | Meaning |
|---|---|
| `--delta` | Delta mode — review only new material since last review. Requires an existing ledger entry. If no ledger, error and stop. |
| `--full` | Full mode — review the entire branch from scratch (re-downloads Jira cache). |
| _(neither)_ | Auto: Delta if ledger exists, else Full. |
| `--ticket <KEY>` | Override Jira issue key (otherwise auto-detected from branch name / commit messages). |
| `--base <ref>` | Override the base branch for diff computation. |
| `--no-prune` | Skip within-branch timestamp pruning for this run only (useful for debugging / comparing rounds side-by-side). |

## Preflight

1. **Check config.** Read `~/.code-reviewer/config.json`. If it does not
   exist, tell the user:
   > "code-reviewer has not been set up yet. Run `/code-reviewer:setup` first."
   Then **stop**.

2. **Check we are in a git repo and not on a skip-listed branch.** The
   context script enforces this; if it exits non-zero, surface the error and
   stop.

3. **Validate mode flag.** Parse `$ARGUMENTS` for `--delta` and `--full`. If
   **both** are present, tell the user they are mutually exclusive and stop.

## Phase 0: Task Tracking

Create the following tasks (pending). Mark each `in_progress` when starting
and `completed` when done:

1. "Gather context"
2. "Build review prompt"
3. "Health-check agents"
4. "Run agent reviews in parallel"
5. "Arbiter synthesis"
6. "Write FINAL_REVIEW_RESULTS.md"
7. "Validation gate"
8. "Hand off to user"

## Phase 1: Gather Context

**Update task 1 → in_progress.**

Parse `$ARGUMENTS` to extract the mode flag and other flags. Build the
context script invocation passing through all relevant flags:

- If `--delta` present: pass `--delta` to `context.sh`
- If `--full` present: pass `--full` to `context.sh`
- If neither: pass no mode flag (context.sh auto-selects)
- Pass `--ticket <KEY>` if present
- Pass `--base <ref>` if present
- Pass `--no-prune` if present

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/context.sh [--delta|--full] [--ticket <KEY>] [--base <ref>] [--no-prune]
```

**Capture the output carefully:**

- **Last line of stdout** = the absolute path to the round directory.
  Save it as `ROUND_DIR`.
- Check the exit code:
  - **Exit 0 with a valid round dir path** → normal path, continue to Phase 2.
  - **Exit 0 with output matching** `"Nothing new to review since"` → the
    nothing-new short-circuit fired. Print the message to the user verbatim
    and **stop**. No new review was started.
  - **Exit non-zero** → surface stderr and stop.

### Nothing-New Short-Circuit

If context.sh outputs a line beginning with `"Nothing new to review since"`,
that means all three of the following are unchanged since the last review:
zero new commits, same worktree hash, same dismissals hash. Print the message
as-is and stop. Example:

```
Nothing new to review since 20260518-140000; last verdict was APPROVE.
```

### After a valid ROUND_DIR

Save the branch-level directory as `BRANCH_DIR` = parent of `ROUND_DIR`
(i.e., `dirname $ROUND_DIR`).

Verify these paths exist:

- `<ROUND_DIR>/context/context-manifest.md`
- `<ROUND_DIR>/context/commits.md`
- `<ROUND_DIR>/context/diff.patch`
- `<ROUND_DIR>/results/`
- `<ROUND_DIR>/repro/`

Read `<ROUND_DIR>/context/context-manifest.md` so you have the high-level
shape of the change set in your context. Note the resolved mode (Delta or
Full) as written in the manifest — save as `MODE_USED`.

Read `~/.code-reviewer/config.json` and extract:
- `agents` array
- `gemini_model`
- `google_cloud_project`
- `google_cloud_location`
- `arbiter_rounds` (default `3`)

**Update task 1 → completed.**

## Phase 2: Build the Review Prompt

**Update task 2 → in_progress.**

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/prompt.sh review <ROUND_DIR>
```

This writes `<ROUND_DIR>/results/review-prompt.md` and prints its path. Save
the path as `PROMPT_PATH`.

**Update task 2 → completed.**

## Phase 3: Agent Health Checks (Preflight)

**Update task 3 → in_progress.**

Read `agents` from `~/.code-reviewer/config.json` via `jq`. Possible values:
`claude`, `codex`, `gemini`, `opencode` — in any combination.

Also read `gemini_model`, `google_cloud_project`, `google_cloud_location`, and
`arbiter_rounds` for later use.

Before dispatching agents, verify each non-claude CLI is working. **Run all
checks in parallel** (single message, multiple Bash calls).

### Codex health check (if `codex` is in agents)

```bash
echo "Say hello" | timeout 30 codex -a never exec -s read-only --ephemeral --color never -p "Reply with exactly: HELLO" 2>&1 | head -5
```

### Gemini health check (if `gemini` is in agents)

```bash
export GOOGLE_CLOUD_PROJECT="<GOOGLE_CLOUD_PROJECT>" GOOGLE_CLOUD_LOCATION="<GOOGLE_CLOUD_LOCATION>" && echo "Reply with exactly: HELLO" | timeout 30 gemini -p "" -m "<GEMINI_MODEL>" -o text --approval-mode yolo 2>&1 | head -5
```

### Opencode health check (if `opencode` is in agents)

```bash
printf 'Reply with exactly: HELLO\n' | timeout 30 opencode run --model openai/gpt-5.5 --format json 2>&1 | jq -r 'select(.type == "text") | .part.text' | head -5
```

If opencode fails, also check whether `OPENAI_API_KEY` is set. If missing,
note this in the run summary (do not stop the pipeline — just skip opencode).

Claude does not need a health check (native sub-agent).

After all checks:
1. Remove any failing agents from the active list for this run.
2. Record results in `<ROUND_DIR>/results/health-check.md` (concise table).
3. If **all** configured agents fail and claude is not in the list, write a
   short FINAL_REVIEW_RESULTS.md explaining no reviewers were available and
   stop.
4. Otherwise proceed with the healthy agents.

**Update task 3 → completed.**

## Phase 4: Dispatch Agents in Parallel

**Update task 4 → in_progress.**

Set these path variables:

- `PROMPT_PATH` = `<ROUND_DIR>/results/review-prompt.md`
- `REPO_PATH`   = output of `git rev-parse --show-toplevel` run in the repo
- `RESULTS_PATH` = `<ROUND_DIR>/results`

Dispatch every healthy agent **in a single message** so they run in parallel.

### Claude agent (if active)

Dispatch with sub-agent: `claude-reviewer`.

Instructions:

```
Review this branch. Paths:
- Review prompt: <PROMPT_PATH>
- Repo: <REPO_PATH>
- Write your review to: <RESULTS_PATH>/claude-review.md
- Repro test dir (if you find a bug): <ROUND_DIR>/repro/

Read the review prompt first, follow it exactly, then write your complete
review to the output path.
```

### Codex agent (if active)

Dispatch with sub-agent: `codex-reviewer`.

Instructions:

```
Run the Codex CLI to review this branch. Paths:
- Review prompt: <PROMPT_PATH>
- Repo: <REPO_PATH>
- Results dir: <RESULTS_PATH>
- Output: <RESULTS_PATH>/codex-review.md
- Repro test dir: <ROUND_DIR>/repro/

Run this exact command:
cat "<PROMPT_PATH>" | codex -a never exec -C "<REPO_PATH>" -s workspace-write --add-dir "<RESULTS_PATH>" --add-dir "<ROUND_DIR>/repro" --ephemeral --color never --output-last-message "<RESULTS_PATH>/codex-review.md" -
```

### Gemini agent (if active)

Dispatch with sub-agent: `gemini-reviewer`.

Instructions:

```
Run the Gemini CLI to review this branch. Paths:
- Review prompt: <PROMPT_PATH>
- Repo: <REPO_PATH>
- Model: <GEMINI_MODEL>
- Google Cloud Project: <GOOGLE_CLOUD_PROJECT>
- Google Cloud Location: <GOOGLE_CLOUD_LOCATION>
- Output: <RESULTS_PATH>/gemini-review.md

Run this exact command:
export GOOGLE_CLOUD_PROJECT="<GOOGLE_CLOUD_PROJECT>" GOOGLE_CLOUD_LOCATION="<GOOGLE_CLOUD_LOCATION>" && cat "<PROMPT_PATH>" | gemini -p "" -m "<GEMINI_MODEL>" -o text --approval-mode yolo --include-directories "<REPO_PATH>" > "<RESULTS_PATH>/gemini-review.md"
```

### Opencode agent (if active)

Dispatch with sub-agent: `opencode-reviewer`.

Instructions:

```
Run the opencode CLI to review this branch. Paths:
- Review prompt: <PROMPT_PATH>
- Repo: <REPO_PATH>
- Output: <RESULTS_PATH>/opencode-review.md

Run this exact command:
cat "<PROMPT_PATH>" | opencode run --model openai/gpt-5.5 --dir "<REPO_PATH>" --format json --dangerously-skip-permissions | jq -r 'select(.type == "text") | .part.text' > "<RESULTS_PATH>/opencode-review.md"
```

### Verify outputs

After all dispatched agents complete, verify each expected output file exists
and is non-empty:

- `<RESULTS_PATH>/claude-review.md`   (if claude was dispatched)
- `<RESULTS_PATH>/codex-review.md`    (if codex was dispatched)
- `<RESULTS_PATH>/gemini-review.md`   (if gemini was dispatched)
- `<RESULTS_PATH>/opencode-review.md` (if opencode was dispatched)

If an agent's output is missing or empty, note the failure in
`<RESULTS_PATH>/health-check.md` and continue. At least one review must
succeed; otherwise write FINAL_REVIEW_RESULTS.md explaining the failure and
stop.

**Update task 4 → completed.**

## Phase 5: Arbiter Synthesis Loop

**Update task 5 → in_progress.**

Read `arbiter_rounds` from config (default `3`).

Set `ROUND = 1`.

### 5a. Build the arbiter prompt

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/prompt.sh arbiter <ROUND_DIR>
```

If this is the last allowed round (`ROUND == arbiter_rounds`), append `final`
as a flag so the script forces a final report:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/prompt.sh arbiter <ROUND_DIR> final
```

The script writes `<ROUND_DIR>/results/arbiter-prompt.md`.

### 5b. Dispatch the arbiter

Dispatch with sub-agent: `arbiter`.

Instructions:

```
Synthesise the agent reviews. Paths:
- Arbiter prompt: <ROUND_DIR>/results/arbiter-prompt.md
- Write output to: <ROUND_DIR>/results/arbiter-output.md

Read the arbiter prompt and follow it exactly. Either output a JSON questions
block, or produce the final report in the format the prompt specifies.
The final report must include both FINAL_REVIEW_RESULTS.md content AND
emit a findings.json file to <ROUND_DIR>/findings.json per the schema
in the prompt.
```

### 5c. Inspect arbiter output

Read `<ROUND_DIR>/results/arbiter-output.md`.

Detect questions: search for a fenced ` ```json ` code block whose content is
an object with agent-name keys mapping to arrays of strings. Example:

```json
{
  "claude": ["What about the race condition on line 42?"],
  "codex": [],
  "gemini": ["Did you verify the SQL injection fix?"],
  "opencode": []
}
```

**If questions are found AND `ROUND < arbiter_rounds`:**

1. Parse the JSON questions object.
2. For each agent with a non-empty array, build a per-agent question prompt:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/prompt.sh question <ROUND_DIR> <agent> '<QUESTIONS_JSON>'
   ```
   The script writes `<ROUND_DIR>/results/round-<N>-<agent>-question.md`.
3. Dispatch the relevant agent to answer **in parallel** (one Agent call per
   agent in a single message):
   - **claude** → dispatch `claude-reviewer`, write answer to `round-<N>-claude-answer.md`.
   - **codex** → dispatch `codex-reviewer`, run:
     ```
     cat "<question_prompt_path>" | codex -a never exec -C "<REPO_PATH>" -s read-only --add-dir "<RESULTS_PATH>" --ephemeral --color never --output-last-message "<answer_path>" -
     ```
     (use `read-only` for Q&A, not workspace-write).
   - **gemini** → dispatch `gemini-reviewer`, pipe the question prompt to gemini, save to the answer path.
   - **opencode** → dispatch `opencode-reviewer`, run:
     ```
     cat "<question_prompt_path>" | opencode run --model openai/gpt-5.5 --dir "<REPO_PATH>" --format json --dangerously-skip-permissions | jq -r 'select(.type == "text") | .part.text' > "<answer_path>"
     ```
4. Append the Q&A round to `<ROUND_DIR>/results/arbiter-log.md`:
   ```
   ## Round <N>

   ### <Agent> Questions
   <questions>

   ### <Agent> Answers
   <answers>

   ---
   ```
5. Increment `ROUND` and go back to step 5a.

**If questions are found AND `ROUND == arbiter_rounds`:**

The arbiter still has questions but the round budget is exhausted. Re-run the
arbiter with the `final` flag so the prompt instructs it to finalise now:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/prompt.sh arbiter <ROUND_DIR> final
```

Then dispatch the arbiter once more (step 5b). Treat its next output as the
final report.

**If NO questions are found:**

Treat the arbiter's output as the final report. Save it as
`<ROUND_DIR>/results/final-report.md`:

```bash
cp <ROUND_DIR>/results/arbiter-output.md <ROUND_DIR>/results/final-report.md
```

**Update task 5 → completed.**

## Phase 6: Write FINAL_REVIEW_RESULTS.md

**Update task 6 → in_progress.**

Copy the final report to the round root as `FINAL_REVIEW_RESULTS.md`:

```bash
cp <ROUND_DIR>/results/final-report.md <ROUND_DIR>/FINAL_REVIEW_RESULTS.md
```

The arbiter should also have written `<ROUND_DIR>/findings.json`. Verify this
file exists. If it is missing, write a brief error note to
`<ROUND_DIR>/results/health-check.md` and proceed — the validation phase will
report the failure.

**Update task 6 → completed.**

## Phase 6.5: Validation Gate

**Update task 7 → in_progress.**

Run `validate-findings.py` against the arbiter's output:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/validate-findings.py \
    "<ROUND_DIR>/findings.json" \
    --prior "<ROUND_DIR>/prior_findings.json" \
    --dismissals "<BRANCH_DIR>/DISMISSALS.md"
```

Omit `--prior` if `<ROUND_DIR>/prior_findings.json` does not exist (Full mode
first run, or any Full run). Omit `--dismissals` if
`<BRANCH_DIR>/DISMISSALS.md` does not exist.

`BRANCH_DIR` = `dirname <ROUND_DIR>`.

### On Exit 0 (validation passed)

Proceed to ledger append (see below), then Phase 7.

### On Exit 1 (validation failed)

1. Move `findings.json` to `findings.json.invalid`:
   ```bash
   mv <ROUND_DIR>/findings.json <ROUND_DIR>/findings.json.invalid
   ```
2. The validator wrote `<ROUND_DIR>/validation-errors.md`. Read the first
   error line from it.
3. **Retry the arbiter once.** Build a correction prompt: rebuild the arbiter
   prompt with `final` flag, then dispatch the arbiter sub-agent again with
   the validation errors appended to the instructions:
   ```
   The previous arbiter output failed validation. Errors:
   <contents of validation-errors.md>

   Rewrite your findings.json to fix all listed errors. Emit both
   findings.json (to <ROUND_DIR>/findings.json) and the corrected
   FINAL_REVIEW_RESULTS.md.
   ```
4. After retry, run `validate-findings.py` again (same invocation as above).
   - **Retry exit 0:** copy `arbiter-output.md` to `final-report.md` and
     `FINAL_REVIEW_RESULTS.md` again (to capture the corrected versions),
     then proceed to ledger append and Phase 7.
   - **Retry exit 1:** write `<ROUND_DIR>/REVIEW_FAILED.md` with content:
     ```
     Code review validation failed after 1 retry.
     Mode: <MODE_USED>
     Round dir: <ROUND_DIR>
     See validation-errors.md for details.
     ```
     Set `VALIDATION_FAILED=true`. Jump to Phase 7.1. **Do not append the ledger.**

### Ledger append (after successful validation)

After validation passes, append a ledger entry. Do this using shell
commands and `jq` to build the JSON entry, then call:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh append "<BRANCH_DIR>/.review-ledger.json" '<ENTRY_JSON>'
```

Build `<ENTRY_JSON>` as follows (all values extracted from `findings.json`,
`context-manifest.md`, and git commands):

```json
{
  "timestamp": "<TS>",
  "type": "<MODE_USED>",
  "head_sha": "<head_sha from findings.json>",
  "base_ref": "<base_ref from context-manifest.md>",
  "base_sha": "<base_sha from findings.json>",
  "commits_reviewed": ["<sha1>", ...],
  "previous_head_sha": "<prior head_sha from ledger, or null>",
  "worktree_hash": "<worktree_hash from context-manifest.md, or null>",
  "dismissals_hash": "<dismissals_hash from context-manifest.md, or null>",
  "verdict": "<verdict from findings.json>",
  "findings": {
    "critical": <count of findings[] where severity=="CRITICAL">,
    "high": <count of findings[] where severity=="HIGH">,
    "medium": <count of findings[] where severity=="MEDIUM">,
    "low": <count of findings[] where severity=="LOW">
  },
  "open_questions": <length of open_questions[] array in findings.json>,
  "round_dir": "<basename of ROUND_DIR>",
  "fallback_reason": <null or "rebase_detected" or "base_changed" or "prior_findings_missing">
}
```

Where:
- `<TS>` = `basename <ROUND_DIR>` (the timestamp is the round dir name)
- `MODE_USED` = `delta` or `full` as read from `context-manifest.md`
- `head_sha` and `base_sha` come from `findings.json` (`jq -r .head_sha` etc.)
- `base_ref` comes from the `context-manifest.md` (look for a line like
  `Base ref: <ref>`)
- `commits_reviewed`: for **Full** mode = `git rev-list <base_sha>..<head_sha>` in the repo;
  for **Delta** mode = `git rev-list <prev_head_sha>..<head_sha>` in the repo
  (where `prev_head_sha` = the most recent prior entry in the ledger, or
  fall back to `git rev-list <base_sha>..<head_sha>` if no prior entry)
- `previous_head_sha`: read the most recent `head_sha` from the existing
  ledger (if any); otherwise `null`
- `worktree_hash` and `dismissals_hash`: compute them directly via the
  `cr_worktree_hash` and `cr_dismissals_hash` helpers sourced from
  `${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh`. Treat empty output as `null`
  (per spec §3.2). Example invocations:
  ```bash
  WORKTREE_HASH=$(cd "$REPO_ROOT" && bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"; cr_worktree_hash')
  DISMISSALS_HASH=$(bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"; cr_dismissals_hash '"$BRANCH_DIR"'/DISMISSALS.md')
  ```
  Use JSON `null` if either command returns empty output.
- `findings` counts: use `jq` to count entries in `findings.json`'s
  `findings[]` array filtered by severity
- `open_questions`: `jq '.open_questions | length'`
- `fallback_reason`: read from `context-manifest.md` (look for
  `Fallback reason: <value>`); if not present or the value is `null`,
  use JSON `null` — it is acceptable to write `null` here when the
  manifest doesn't record a specific reason

After `ledger.sh append`, regenerate the human-readable ledger markdown:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh render-md "<BRANCH_DIR>/.review-ledger.json"
```

This writes `<BRANCH_DIR>/REVIEW_LEDGER.md`.

**Update task 7 → completed.**

## Phase 7: Hand Off to the User (Success)

**Update task 8 → in_progress.**

This is the **only** phase where you talk to the user on the success path.

Read `<ROUND_DIR>/findings.json` (the authoritative artifact). Extract:
- `verdict`, `confidence`
- `findings[]` array and count by severity
- `open_questions[]` array
- `dismissed_active[]` array
- `linter_summary` (if present)
- `tests` (if present)
- `head_sha`, `base_sha`

Read `MODE_USED` from the context manifest. Read `BRANCH` = current branch
from `git rev-parse --abbrev-ref HEAD`.

Render the following rich-text to the user (populate all placeholders):

```
# Code review complete

**Report:** <ROUND_DIR>/FINAL_REVIEW_RESULTS.md
**Mode:** <Delta|Full> [since <prev_round_ts if Delta>] · **Verdict:** [<VERDICT>] · **Confidence:** <H|M|L>
**Findings:** <C> critical · <H> high · <M> medium · <L> low
**Open Questions:** <N>
**Active dismissals:** <N> (see <BRANCH_DIR>/DISMISSALS.md)        ← only when dismissed_active[] has entries
**Ledger:** updated (entry #<count from REVIEW_LEDGER.md>)

## Summary
<verbatim arbiter Summary section from FINAL_REVIEW_RESULTS.md>

### Top Risks
<verbatim Top Risks subsection, if present>

### Regression vs Previous Review
<verbatim Regression section, if present>

## Open Questions (<N>) — resolve with the user before applying fixes
- OQ1 <file>:<line> — <one-line summary>  *(Category, agent(s))*
- OQ2 ...
(omit this section entirely if open_questions[] is empty)
(agent(s) attribution comes from FINAL_REVIEW_RESULTS.md prose — the arbiter
records which reviewers flagged each OQ; populate from that context)

## Findings (<N>)
- F1 (<SEVERITY>) <file>:<line> — <one-line summary>
- F2 (<SEVERITY>) <file>:<line> — <one-line summary>
- ...
(if no findings, write "No findings.")

## Linter & Test Status
- Linters: <summarise linter_summary — which ran, issue counts>
- Tests: <command, ran/not ran, passed/failed, failure count>
- Coverage gaps: <count of findings[] where category=="TestCoverage">

## Intent Check vs Jira <KEY>
Goal: <paraphrase from FINAL_REVIEW_RESULTS.md>
Achieved? <Yes|Partially|No> — <one paragraph>
(omit this section if no Jira key was present in the context)
```

### Conditional caveats (append after the main body)

**Push-anyway hint** — append when `verdict` is not `APPROVE`:

> *To push anyway without addressing findings: ask me to push and I'll run `CR_SKIP=1 git push` for that single push.*

**Dirty-tree caveat** — append when `worktree_hash` is not `null` (the review
covered uncommitted changes):

> *This review covered uncommitted changes (`worktree_hash != null`). It does NOT authorise `git push` — pushes only ship commits. Commit the changes and re-run `/code-reviewer:start --delta` (a fast incremental review of just the new commit) so the ledger has a clean approval at the new HEAD, which the push gate can use.*

**Dismissal hint** — append when `findings[]` is non-empty:

> *To dismiss a finding as a false positive: ask me to dismiss it with a reason. To undo a previous dismissal: ask me to remove it. Future reviews will be free to re-flag it.*

### AskUserQuestion

Call `AskUserQuestion` exactly once with:

```
What's next?
```

Options:
- **Resolve Open Questions first** *(include this option only if open_questions[] is non-empty)*
- **Apply fixes**
- **Discuss the report**
- **Skip for now**

The answer is a hint to the main session — the plugin takes **no action**
on it. End the skill.

**Update task 8 → completed.**

## Phase 7.1: Hand Off (Validation Failure)

When `VALIDATION_FAILED=true` (the §4.5 validation gate failed after one
retry, and `<ROUND_DIR>/REVIEW_FAILED.md` was written), render this failure
report to the user instead of the normal Phase 7 output.

Read `<ROUND_DIR>/validation-errors.md` and extract the first error line.

Render:

```
# Code review FAILED

The arbiter produced output that failed validation. No ledger entry was
written — the push gate will continue to deny.

**Round dir:** <ROUND_DIR>
**Failure marker:** <ROUND_DIR>/REVIEW_FAILED.md
**Validation errors:** <ROUND_DIR>/validation-errors.md
**Invalid arbiter output:** <ROUND_DIR>/findings.json.invalid

**Mode attempted:** <Delta|Full>
**Retries used:** 1
**First error:** <first error line from validation-errors.md>

The most likely causes are:
- The arbiter dropped or invented a finding ID
- The arbiter cited a dismissal that doesn't exist in DISMISSALS.md
- The arbiter emitted a finding whose fingerprint matches an active
  dismissal (it should have suppressed the finding instead)
- The recorded verdict doesn't match what the listed findings would
  produce per the §7 rubric

What to do next:
- Re-run `/code-reviewer:start --full` to rebuild from scratch.
- Inspect `<ROUND_DIR>/validation-errors.md` for the full list.
- If you suspect a transient agent failure, retry first.
```

Then call `AskUserQuestion` exactly once with:

```
What now?
```

Options:
- **Retry as Full review** — invokes `/code-reviewer:start --full`
- **Inspect the failure** — opens the validation errors with the user
- **Skip this push** — user runs `CR_SKIP=1 git push` if they understand the risk

The answer is a hint to the main session — the plugin takes no action on it.
End the skill.

---

## Error Handling

- If the context script fails, surface stderr and stop.
- If an agent dispatch fails, continue with the others; record the failure in
  `health-check.md`. At least one review must succeed.
- If the arbiter fails on all retries, write a FINAL_REVIEW_RESULTS.md that
  contains the raw individual reviews and a note explaining synthesis failed.
- If `validate-findings.py` fails with an unexpected error (not exit 1),
  surface the error and stop.
- Never silently swallow errors.

## Key Reminders

- The **review pipeline** (Phases 1–6.5) is non-interactive. No
  `AskUserQuestion` in those phases. Drive the pipeline to a written artifact.
- **Phase 7** (or **7.1**) is the only place you call `AskUserQuestion`.
- All file paths must be absolute.
- Agent dispatches for review and Q&A use the Agent tool. Dispatch in
  parallel where possible (single message, multiple tool calls).
- For Q&A dispatches to codex, use `-s read-only`.
- Reviews live in the **`review_output_path`** from config (default
  `/tmp/code-reviewer/<repo-slug>/<branch-slug>/<timestamp>/`).
- The arbiter loop can run up to `arbiter_rounds` iterations. Track the count
  yourself; the script supports a `final` flag but does not track rounds for
  you.
- `BRANCH_DIR` = `dirname <ROUND_DIR>`. The per-branch state files
  (`.review-ledger.json`, `DISMISSALS.md`, `REVIEW_LEDGER.md`) live there.
- **Ledger append is performed by the skill**, not by context.sh. Only append
  after successful validation.
- The `findings.json` emitted by the arbiter is the authoritative machine
  artifact. The Markdown `FINAL_REVIEW_RESULTS.md` is for humans only.
- **Inspecting `findings.json`:** the arbiter writes pretty-printed,
  multi-line JSON. Always read it with `jq` directly
  (e.g. `jq '.verdict' "<ROUND_DIR>/findings.json"`,
  `jq '.findings | length' "<ROUND_DIR>/findings.json"`,
  `jq -r '.head_sha' "<ROUND_DIR>/findings.json"`). Never pipe through
  `head` first — `head -1 | jq` will fail because the first line is
  only `{`. There is no need to "peek" at validity before calling the
  validator; Phase 6.5 runs `validate-findings.py` which is the
  authoritative correctness check.
- When `fallback_reason` cannot be determined from the context manifest
  (context.sh didn't emit a structured field), write JSON `null` in the
  ledger entry. This is a known gap and acceptable for now.
