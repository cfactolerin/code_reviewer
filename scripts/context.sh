#!/usr/bin/env bash
# Gather context for a code-reviewer run.
#
# Usage:
#   context.sh [--base <ref>] [--ticket <KEY>]
#
# Produces a timestamped round directory under <review_output_path>/<repo-slug>/<branch>/<timestamp>/
# with diff, commits, language/linter detection, prior-review pointer, optional
# Jira context, and a context-manifest.md.
#
# The LAST line of stdout is the absolute path to the round directory. Earlier
# lines are progress messages safe for human consumption.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

base_override=""
ticket_override=""
MODE=""
NO_PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base_override="$2"; shift 2 ;;
    --ticket) ticket_override="$2"; shift 2 ;;
    --delta) MODE="delta"; shift ;;
    --full)  MODE="full"; shift ;;
    --no-prune) NO_PRUNE=1; shift ;;
    *) echo "context.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT=$(cr_repo_root) || { echo "Not inside a git repo." >&2; exit 1; }
BRANCH=$(cr_current_branch)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "Detached HEAD — cannot review." >&2
  exit 1
fi
# skip_branches: check config for an explicit opt-out list (default empty).
if [ -f "$CR_CONFIG_FILE" ]; then
  if jq -e --arg b "$BRANCH" '.skip_branches[]? | select(. == $b)' "$CR_CONFIG_FILE" >/dev/null 2>&1; then
    echo "Refusing to run: branch '$BRANCH' is in config.skip_branches" >&2
    exit 1
  fi
fi

BASE=$(cr_base_branch "$base_override") || {
  echo "Could not resolve a base branch (no upstream, no origin/main, no origin/master)." >&2
  exit 1
}

# Verify the base ref actually exists.
if ! git -C "$REPO_ROOT" rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "Base ref '$BASE' does not exist locally. Try: git fetch origin" >&2
  exit 1
fi

BRANCH_SLUG=$(cr_branch_slug "$BRANCH")
TS=$(date +%Y%m%d-%H%M%S)
REVIEW_OUT=$(cr_review_output_path "$REPO_ROOT")
REPO_SLUG=$(cr_repo_slug "$REPO_ROOT")
BRANCH_DIR="$REVIEW_OUT/$REPO_SLUG/$BRANCH_SLUG"

# Mode selection: --delta or --full, default = delta if ledger exists, else full.
LEDGER_FILE="$BRANCH_DIR/.review-ledger.json"
if [ -z "$MODE" ]; then
  if [ -f "$LEDGER_FILE" ]; then MODE="delta"; else MODE="full"; fi
fi
if [ "$MODE" = "delta" ] && [ ! -f "$LEDGER_FILE" ]; then
  echo "code-reviewer: no prior review on this branch — run with --full first" >&2
  exit 1
fi

ROUND_DIR="$BRANCH_DIR/$TS"
# Handle same-second invocations: append -2, -3, ... until we find an unused dir.
if [ -d "$ROUND_DIR" ]; then
  suffix=2
  while [ -d "$BRANCH_DIR/$TS-$suffix" ]; do
    suffix=$((suffix + 1))
  done
  TS="$TS-$suffix"
  ROUND_DIR="$BRANCH_DIR/$TS"
fi
CONTEXT_DIR="$ROUND_DIR/context"
RESULTS_DIR="$ROUND_DIR/results"
REPRO_DIR="$ROUND_DIR/repro"


mkdir -p "$CONTEXT_DIR" "$RESULTS_DIR" "$REPRO_DIR"

# Acquire per-branch lock so concurrent reviews on the same branch don't
# corrupt the ledger or the round directory listing.
LOCK_FILE="$BRANCH_DIR/.review-ledger.lock"
bash "$SCRIPT_DIR/ledger.sh" acquire-lock "$LOCK_FILE" \
  || { echo "code-reviewer: could not acquire lock at $LOCK_FILE" >&2; rm -rf "$ROUND_DIR"; exit 1; }
trap "bash '$SCRIPT_DIR/ledger.sh' release-lock '$LOCK_FILE'" EXIT INT TERM

# Only add to .gitignore when the review output lives inside the repo tree.
# An absolute path like /tmp/code-reviewer doesn't need gitignoring.
case "$REVIEW_OUT" in
  "$REPO_ROOT"/*)
    rel_review_out="${REVIEW_OUT#$REPO_ROOT/}"
    gitignore_path="$REPO_ROOT/.gitignore"
    # Look for an existing line matching the relative path (with or without leading slash, trailing slash).
    if ! grep -qE "^/?${rel_review_out%/}/?$" "$gitignore_path" 2>/dev/null; then
      {
        [ -s "$gitignore_path" ] && [ -n "$(tail -c1 "$gitignore_path" 2>/dev/null)" ] && echo ""
        echo "# Added by code-reviewer plugin"
        echo "$rel_review_out/"
      } >> "$gitignore_path"
      echo "Added $rel_review_out/ to $gitignore_path" >&2
    fi
    ;;
esac

echo "Repo:    $REPO_ROOT" >&2
echo "Branch:  $BRANCH" >&2
echo "Base:    $BASE" >&2
echo "Round:   $ROUND_DIR" >&2

MERGE_BASE=$(git -C "$REPO_ROOT" merge-base "$BASE" HEAD 2>/dev/null || true)
if [ -z "$MERGE_BASE" ]; then
  echo "No merge-base between HEAD and $BASE. Aborting." >&2
  exit 1
fi

# ---- Diff & changed files -------------------------------------------------

git -C "$REPO_ROOT" diff --stat "$MERGE_BASE"...HEAD > "$CONTEXT_DIR/diffstat.txt"
git -C "$REPO_ROOT" diff "$MERGE_BASE"...HEAD > "$CONTEXT_DIR/diff.patch"
git -C "$REPO_ROOT" diff --name-only "$MERGE_BASE"...HEAD > "$CONTEXT_DIR/files.txt"
git -C "$REPO_ROOT" diff --name-status "$MERGE_BASE"...HEAD > "$CONTEXT_DIR/files-status.txt"

CHANGED_COUNT=$(wc -l < "$CONTEXT_DIR/files.txt" | tr -d ' ')
if [ "$CHANGED_COUNT" = "0" ]; then
  echo "No files changed between $BASE and HEAD. Nothing to review." >&2
  exit 1
fi

# ---- Delta machinery -------------------------------------------------------
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

# ---- Commits with full messages (so reviewers see intent) -----------------

{
  echo "# Commits on branch (\`$BRANCH\` vs \`$BASE\`)"
  echo
  git -C "$REPO_ROOT" log --reverse --pretty=fuller --stat "$MERGE_BASE"..HEAD
} > "$CONTEXT_DIR/commits.md"

COMMIT_COUNT=$(git -C "$REPO_ROOT" rev-list --count "$MERGE_BASE"..HEAD)

# ---- Language detection ---------------------------------------------------

# Best-effort: map file extensions to a language tag. The set deliberately
# covers common pairs so reviewers can apply syntax-highlighting and pick the
# right linter.
{
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      *.rb|Gemfile|Rakefile|*.rake) echo "ruby" ;;
      *.py)                          echo "python" ;;
      *.js|*.mjs|*.cjs)              echo "javascript" ;;
      *.ts|*.tsx)                    echo "typescript" ;;
      *.jsx)                         echo "jsx" ;;
      *.go)                          echo "go" ;;
      *.rs)                          echo "rust" ;;
      *.java)                        echo "java" ;;
      *.kt|*.kts)                    echo "kotlin" ;;
      *.swift)                       echo "swift" ;;
      *.cs)                          echo "csharp" ;;
      *.php)                         echo "php" ;;
      *.sh|*.bash)                   echo "bash" ;;
      *.zsh)                         echo "zsh" ;;
      *.tf|*.tfvars)                 echo "terraform" ;;
      *.yml|*.yaml)                  echo "yaml" ;;
      *.json)                        echo "json" ;;
      *.sql)                         echo "sql" ;;
      *.scala)                       echo "scala" ;;
      *.c|*.h)                       echo "c" ;;
      *.cpp|*.cc|*.cxx|*.hpp|*.hh)   echo "cpp" ;;
      *.ex|*.exs)                    echo "elixir" ;;
      *.erl|*.hrl)                   echo "erlang" ;;
      *.lua)                         echo "lua" ;;
      *.dart)                        echo "dart" ;;
      *.md|*.markdown)               echo "markdown" ;;
      Dockerfile|*Dockerfile*)       echo "dockerfile" ;;
      *)                             echo "other" ;;
    esac
  done < "$CONTEXT_DIR/files.txt"
} | sort -u > "$CONTEXT_DIR/languages.txt"

# ---- Linter detection -----------------------------------------------------
# Build a JSON array of detected linters: which linter, what file flagged it,
# and the command to run scoped to changed files.

linter_json="$CONTEXT_DIR/linters.json"
python3 - "$REPO_ROOT" "$CONTEXT_DIR/files.txt" "$linter_json" <<'PY'
import json, os, sys, shutil

repo = sys.argv[1]
files_list = sys.argv[2]
out_path = sys.argv[3]

with open(files_list) as f:
    changed = [l.strip() for l in f if l.strip()]

def exists(rel):
    return os.path.exists(os.path.join(repo, rel))

def cmd_available(cmd):
    return shutil.which(cmd) is not None

def filter_by_ext(exts):
    return [f for f in changed if any(f.endswith(e) for e in exts)]

linters = []

# Ruby
ruby_files = filter_by_ext([".rb", ".rake"]) + [f for f in changed if os.path.basename(f) in ("Gemfile", "Rakefile")]
if ruby_files:
    if (exists(".rubocop.yml") or exists("rubocop.yml")) and cmd_available("rubocop"):
        linters.append({"language": "ruby", "tool": "rubocop", "config_present": True,
                        "command": ["rubocop", "--no-server", "--format", "simple", "--"] + ruby_files})
    elif cmd_available("rubocop"):
        linters.append({"language": "ruby", "tool": "rubocop", "config_present": False,
                        "command": ["rubocop", "--no-server", "--format", "simple", "--"] + ruby_files})

# Python
py_files = filter_by_ext([".py"])
if py_files:
    if cmd_available("ruff"):
        linters.append({"language": "python", "tool": "ruff", "config_present": exists("pyproject.toml") or exists("ruff.toml"),
                        "command": ["ruff", "check", "--"] + py_files})
    if cmd_available("mypy") and (exists("mypy.ini") or exists("pyproject.toml")):
        linters.append({"language": "python", "tool": "mypy", "config_present": True,
                        "command": ["mypy", "--"] + py_files})
    if cmd_available("flake8") and not cmd_available("ruff"):
        linters.append({"language": "python", "tool": "flake8", "config_present": exists(".flake8") or exists("setup.cfg"),
                        "command": ["flake8", "--"] + py_files})

# JS/TS
js_ts_files = filter_by_ext([".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"])
if js_ts_files:
    eslint_present = exists(".eslintrc") or exists(".eslintrc.js") or exists(".eslintrc.json") or exists(".eslintrc.cjs") or exists("eslint.config.js") or exists("eslint.config.mjs")
    if eslint_present and (exists("node_modules/.bin/eslint") or cmd_available("eslint")):
        bin_ = "node_modules/.bin/eslint" if exists("node_modules/.bin/eslint") else "eslint"
        linters.append({"language": "javascript", "tool": "eslint", "config_present": True,
                        "command": [bin_, "--no-error-on-unmatched-pattern", "--"] + js_ts_files})
    ts_files = filter_by_ext([".ts", ".tsx"])
    if ts_files and exists("tsconfig.json"):
        bin_ = "node_modules/.bin/tsc" if exists("node_modules/.bin/tsc") else ("tsc" if cmd_available("tsc") else None)
        if bin_:
            linters.append({"language": "typescript", "tool": "tsc", "config_present": True,
                            "command": [bin_, "--noEmit"]})

# Go
go_files = filter_by_ext([".go"])
if go_files:
    if cmd_available("golangci-lint"):
        linters.append({"language": "go", "tool": "golangci-lint", "config_present": exists(".golangci.yml") or exists(".golangci.yaml"),
                        "command": ["golangci-lint", "run", "./..."]})
    elif cmd_available("go"):
        linters.append({"language": "go", "tool": "go vet", "config_present": True,
                        "command": ["go", "vet", "./..."]})

# Rust
rust_files = filter_by_ext([".rs"])
if rust_files and exists("Cargo.toml") and cmd_available("cargo"):
    linters.append({"language": "rust", "tool": "cargo clippy", "config_present": True,
                    "command": ["cargo", "clippy", "--all-targets", "--", "-D", "warnings"]})

# Shell
sh_files = filter_by_ext([".sh", ".bash", ".zsh"])
if sh_files and cmd_available("shellcheck"):
    linters.append({"language": "bash", "tool": "shellcheck", "config_present": exists(".shellcheckrc"),
                    "command": ["shellcheck", "--"] + sh_files})

with open(out_path, "w") as f:
    json.dump(linters, f, indent=2)
PY

LINTER_COUNT=$(jq 'length' "$linter_json" 2>/dev/null || echo 0)

# ---- Test instructions detection ------------------------------------------
# Pull anything that looks like test guidance from README / CLAUDE.md /
# AGENTS.md / AGENT.md so the reviewer can run the project's tests.

test_inst="$CONTEXT_DIR/test-instructions.md"
: > "$test_inst"
for f in README.md README.rst CLAUDE.md AGENTS.md AGENT.md docs/CONTRIBUTING.md CONTRIBUTING.md; do
  if [ -f "$REPO_ROOT/$f" ]; then
    {
      echo "## From $f"
      echo
      # Pull sections that mention test/spec/ci, plus a short global excerpt.
      awk '
        BEGIN{p=0}
        /^#+ /{p=0}
        /^#+ .*([Tt]est|[Ss]pec|[Ll]int|CI|[Bb]uild|[Rr]un)/ {p=1; print; next}
        p==1 {print}
      ' "$REPO_ROOT/$f" | head -n 200
      echo
    } >> "$test_inst"
  fi
done

# ---- Previous FINAL_REVIEW_RESULTS for this branch ------------------------

branch_dir="$BRANCH_DIR"
prev_final=""
if [ -d "$branch_dir" ]; then
  # The newest existing FINAL_REVIEW_RESULTS.md, excluding the round we just
  # created (which doesn't have one yet anyway).
  prev_final=$(find "$branch_dir" -maxdepth 2 -name FINAL_REVIEW_RESULTS.md -not -path "$ROUND_DIR/*" 2>/dev/null | sort | tail -n 1)
fi

if [ -n "$prev_final" ] && [ -f "$prev_final" ]; then
  cp "$prev_final" "$CONTEXT_DIR/previous-review.md"
  prev_round=$(dirname "$prev_final")
  prev_label=$(basename "$prev_round")
  echo "Previous review found: $prev_label"
fi

# ---- Jira ticket ----------------------------------------------------------

ticket="$ticket_override"
if [ -z "$ticket" ]; then
  ticket=$(cr_detect_jira_key || true)
fi

jira_base=$(cr_config_get jira_base_url "")
jira_email=$(cr_config_get jira_email "")
jira_token=$(cr_config_get jira_api_token "")

# Jira fetch — guarded by mode and config. Write to .jira-cache.new/, swap on success.
# In delta mode, re-use the branch-level cache rather than fetching again.
if [ "$MODE" = "full" ] && [ -n "$ticket" ] && [ -n "$jira_base" ] && [ -n "$jira_email" ] && [ -n "$jira_token" ]; then
  echo "Fetching Jira ticket $ticket..." >&2
  rm -rf "$BRANCH_DIR/.jira-cache.new" "$BRANCH_DIR/.jira-cache.old"
  mkdir -p "$BRANCH_DIR/.jira-cache.new"
  if CR_JIRA_BASE_URL="$jira_base" CR_JIRA_EMAIL="$jira_email" CR_JIRA_API_TOKEN="$jira_token" \
     python3 "$SCRIPT_DIR/jira-fetch.py" "$ticket" --out "$BRANCH_DIR/.jira-cache.new/jira.md" \
     >/dev/null 2>"$CONTEXT_DIR/jira.err"; then
    [ -d "$BRANCH_DIR/.jira-cache" ] && mv "$BRANCH_DIR/.jira-cache" "$BRANCH_DIR/.jira-cache.old"
    mv "$BRANCH_DIR/.jira-cache.new" "$BRANCH_DIR/.jira-cache"
    rm -rf "$BRANCH_DIR/.jira-cache.old"
    cp "$BRANCH_DIR/.jira-cache/jira.md" "$CONTEXT_DIR/jira.md"
  else
    rm -rf "$BRANCH_DIR/.jira-cache.new"
    # If a stale cache exists, copy it as a fallback
    [ -f "$BRANCH_DIR/.jira-cache/jira.md" ] && cp "$BRANCH_DIR/.jira-cache/jira.md" "$CONTEXT_DIR/jira.md"
    echo "Jira refresh failed; using stale cache if available. See $CONTEXT_DIR/jira.err" >> "$CONTEXT_DIR/jira.warn"
  fi
elif [ "$MODE" = "delta" ] && [ -f "$BRANCH_DIR/.jira-cache/jira.md" ]; then
  cp "$BRANCH_DIR/.jira-cache/jira.md" "$CONTEXT_DIR/jira.md"
fi

# ---- Manifest -------------------------------------------------------------

{
  echo "# Context Manifest"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Repo | \`$REPO_ROOT\` |"
  echo "| Branch | \`$BRANCH\` |"
  echo "| Base | \`$BASE\` |"
  echo "| Mode | $MODE |"
  echo "| Merge base | \`$(echo "$MERGE_BASE" | cut -c1-12)\` |"
  echo "| Commits | $COMMIT_COUNT |"
  echo "| Files changed | $CHANGED_COUNT |"
  echo "| Languages detected | $(paste -sd, "$CONTEXT_DIR/languages.txt") |"
  echo "| Linters detected | $LINTER_COUNT |"
  echo "| Jira ticket | ${ticket:-_(none)_} |"
  echo "| Previous review | ${prev_final:-_(first run on this branch)_} |"
  echo "| Round directory | \`$ROUND_DIR\` |"
  echo "| Timestamp | $TS |"
  echo "| code-reviewer version | $(cr_config_get _version 0.1.0) |"
  echo
  echo "## Diffstat"
  echo
  echo '```'
  cat "$CONTEXT_DIR/diffstat.txt"
  echo '```'
} > "$CONTEXT_DIR/context-manifest.md"

echo "Context gathered." >&2
echo "$ROUND_DIR"

# Pruning is the LAST step on a successful run. The lock is released by the
# trap that fires after this exits.
if [ "$NO_PRUNE" = "0" ]; then
  KEEP=$(cr_config_get keep_last_rounds 10)
  if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then KEEP=1; fi

  current_ts=$(basename "$ROUND_DIR")
  prev_ts=""
  if [ -f "$LEDGER_FILE" ]; then
    # Note: context.sh does NOT append to the ledger; the skill does that AFTER
    # this script exits. So .[-1] here is the last COMPLETED review, which is
    # the Delta carry-forward source. Do not change to .[-2].
    prev_ts=$(jq -r '.reviews | if length >= 1 then .[-1].round_dir else "" end' "$LEDGER_FILE")
  fi

  # Enumerate timestamp dirs; sort newest first. Use find to avoid ls color codes.
  # Pattern: YYYYMMDD-HHMMSS with an optional -N suffix (same-second runs).
  dirs=()
  while IFS= read -r d; do
    bname="$(basename "$d")"
    [[ "$bname" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] || continue
    dirs+=("$bname")
  done < <(find "$BRANCH_DIR" -maxdepth 1 -mindepth 1 -type d \
             2>/dev/null | sort -r)

  preserved=("$current_ts")
  [ -n "$prev_ts" ] && preserved+=("$prev_ts")
  count=${#preserved[@]}
  for d in "${dirs[@]+"${dirs[@]}"}"; do
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
  for d in "${dirs[@]+"${dirs[@]}"}"; do
    in_preserve=0
    for p in "${preserved[@]}"; do
      [ "$d" = "$p" ] && in_preserve=1 && break
    done
    if [ "$in_preserve" = "0" ]; then
      rm -rf "$BRANCH_DIR/$d"
    fi
  done
fi
