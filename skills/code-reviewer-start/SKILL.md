---
name: code-reviewer-start
description: Non-interactive multi-agent review of the current branch vs its base. Runs Claude/Codex/Gemini/opencode in parallel, arbiter synthesises results, writes FINAL_REVIEW_RESULTS.md the implementing agent can act on, and hands off to the main session with a fix/skip prompt. Optional flags - --ticket <KEY> --base <ref>.
argument-hint: "[--ticket <KEY>] [--base <ref>]"
allowed-tools: ["Bash(*)", Read, Write, Grep, Glob, Agent, TaskCreate, TaskUpdate, TaskList, AskUserQuestion]
---

# code-reviewer Start — Non-Interactive Multi-Agent Review

You are orchestrating a strict pre-push code review on the **current local
branch**. The multi-agent review itself is **non-interactive** — do not ask
the user questions during context gathering, agent dispatch, or arbiter
synthesis. Drive the pipeline to completion and produce
`FINAL_REVIEW_RESULTS.md`.

The **final hand-off** (Phase 7) is the only place you talk to the user: you
show the Summary and ask whether to fix the findings now, fix a subset, or
leave the report for later.

Throughout this skill:

- **PLUGIN_ROOT** = `${CLAUDE_PLUGIN_ROOT}`
- **CONFIG** = `~/.code-reviewer/config.json`
- **ARGS** = the value of `$ARGUMENTS`

Optional flags inside `$ARGUMENTS`:
- `--ticket <KEY>` — override Jira issue key (otherwise auto-detected from
  branch name / commit messages)
- `--base <ref>` — override the base branch (otherwise auto: upstream →
  origin/main → origin/master, unless `base_branch` is set in config)

## Preflight

1. **Check config.** Read `~/.code-reviewer/config.json`. If it does not
   exist, tell the user:
   > "code-reviewer has not been set up yet. Run `/code-reviewer:setup` first."
   Then **stop**.

2. **Check we are in a git repo and not on a protected branch.** The context
   script enforces this; if it exits non-zero, surface the error and stop.

## Phase 0: Task Tracking

Create the following tasks (pending). Mark each `in_progress` when starting
and `completed` when done:

1. "Gather context"
2. "Build review prompt"
3. "Health-check agents"
4. "Run agent reviews in parallel"
5. "Arbiter synthesis"
6. "Write FINAL_REVIEW_RESULTS.md"
7. "Hand off to user"

## Phase 1: Gather Context

**Update task 1 → in_progress.**

Run the context script. Pass through the user's flags from `$ARGUMENTS`
(any of `--ticket`, `--base`):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/context.sh [--ticket <KEY>] [--base <ref>]
```

- Capture the **last line of stdout** — this is the absolute path to the
  round directory. Save it as `ROUND_DIR`.
- Example: `<repo>/tmp/code-reviews/feature_xyz/20260518-150045`

Verify these paths exist:

- `<ROUND_DIR>/context/context-manifest.md`
- `<ROUND_DIR>/context/commits.md`
- `<ROUND_DIR>/context/diff.patch`
- `<ROUND_DIR>/results/`
- `<ROUND_DIR>/repro/`

Read `<ROUND_DIR>/context/context-manifest.md` once so you have the high-level
shape of the change set in your context.

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
- `REPO_PATH`   = output of `git rev-parse --show-toplevel` in the round dir
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

**Update task 6 → completed.**

## Phase 7: Hand Off to the User

**Update task 7 → in_progress.**

This is the **only** phase where you talk to the user.

### 7a. Print the report summary

Read `<ROUND_DIR>/FINAL_REVIEW_RESULTS.md` and print to the user (as regular
text output, not a tool call) the verdict line plus the `## Summary` section
including its `### Top Risks` subsection. Append a line with the file path so
the user can open the full report:

```
# Code review complete

**Report:** <ROUND_DIR>/FINAL_REVIEW_RESULTS.md

<copy the verdict / confidence / counts line from the report>

## Summary
<verbatim copy of the Summary section, including Top Risks>
```

Then list the findings in `## Detailed Findings`, one per line, with their
finding number, severity, file:line, and one-line title — so the user can
reference them by number in their reply. Example:

```
## Findings
- F1 (CRITICAL) src/auth.rs:42 — missing null check on session token
- F2 (HIGH) src/db.rs:120 — N+1 query in `load_users`
- F3 (MEDIUM) src/api.rs:88 — missing test for new branch in `validate_input`
```

### 7b. Ask the user how to proceed

Use AskUserQuestion. The question text:

```
The code review found N findings (X critical, Y high, Z medium, W low). How would you like to proceed?
```

Options (single-select):

- **Fix everything** — Recommended if there are CRITICAL or HIGH findings. The
  main session will read FINAL_REVIEW_RESULTS.md and start applying fixes
  finding-by-finding, running the acceptance check for each, then re-run
  `/code-reviewer:start` for a regression check.
- **Fix a subset** — User will name the finding numbers to fix (e.g. "F1, F3, F5").
  Skip everything else.
- **Discuss first** — Don't fix yet. The user wants to read the report and
  ask questions about specific findings before deciding.
- **Skip for now** — Leave the report on disk. Do nothing. User will push or
  re-review later.

### 7c. Handle the response

- **Fix everything**: read FINAL_REVIEW_RESULTS.md (full file), confirm to the
  user: "Fixing all N findings. I'll apply changes finding-by-finding,
  running the acceptance check after each. After all fixes, I'll re-run
  `/code-reviewer:start` for a regression check before you push."
  Then begin fixing. Do not push the branch.

- **Fix a subset**: ask "Which finding numbers? e.g. F1, F3, F5". After they
  reply, read FINAL_REVIEW_RESULTS.md and fix only the named findings. Same
  acceptance-check + regression-rerun discipline.

- **Discuss first**: tell the user "Report is at <path>. Ask me about any
  finding by number (e.g. 'tell me more about F2') or by area (e.g.
  'walk me through the security findings')." Then enter Q&A mode using
  AskUserQuestion if needed.

- **Skip for now**: print "Report saved at <path>. Re-run `/code-reviewer:start`
  after fixes for a regression check — the previous report is automatically
  included in the next review's context." Then stop.

**Update task 7 → completed.**

---

## Error Handling

- If the context script fails, surface stderr and stop.
- If an agent dispatch fails, continue with the others; record the failure in
  `health-check.md`. At least one review must succeed.
- If the arbiter fails on all retries, write a FINAL_REVIEW_RESULTS.md that
  contains the raw individual reviews and a note explaining synthesis failed.
- Never silently swallow errors.

## Key Reminders

- The **review pipeline** (Phases 1–6) is non-interactive. No `AskUserQuestion`
  in those phases. Drive the pipeline to a written artifact.
- The **hand-off** (Phase 7) is the only place you call `AskUserQuestion`.
- All file paths must be absolute.
- Agent dispatches for review and Q&A use the Agent tool. Dispatch in
  parallel where possible (single message, multiple tool calls).
- For Q&A dispatches to codex, use `-s read-only`.
- Reviews live in the **repo's** `tmp/code-reviews/<branch>/<timestamp>/` —
  not in the user's home directory.
- The arbiter loop can run up to `arbiter_rounds` iterations. Track the count
  yourself; the script supports a `final` flag but does not track rounds for
  you.
