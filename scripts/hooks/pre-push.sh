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
  # Only attempt if the remote ref actually resolves (i.e. remote branch exists).
  if git rev-parse --verify "$remote_ref" >/dev/null 2>&1; then
    if git merge-base --is-ancestor HEAD "$remote_ref" 2>/dev/null; then
      exit 0   # everything already on remote
    fi
    ahead=$(git rev-list --count "$remote_ref..HEAD" 2>/dev/null || echo "1")
    [ "$ahead" -eq 0 ] && exit 0
  fi
  # If remote ref doesn't resolve, remote branch doesn't exist yet → there IS
  # something to push; fall through to ledger check.
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
[ -n "$remote_ref" ] && current_base_sha=$(git rev-parse --verify "$remote_ref" 2>/dev/null || echo "")

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
if [ "$match_count" -gt 0 ]; then
  if [ -z "$current_base_sha" ]; then
    # Remote ref unknown (e.g. first push). Accept all matching reviews.
    compatible_indices=()
    for i in $(seq 0 $((match_count - 1))); do
      compatible_indices+=("$i")
    done
  else
    compatible_indices=()
    for i in $(seq 0 $((match_count - 1))); do
      bs=$(echo "$matching" | jq -r ".[$i].base_sha")
      if [ "$bs" = "$current_base_sha" ] || git merge-base --is-ancestor "$bs" "$current_base_sha" 2>/dev/null; then
        compatible_indices+=("$i")
      fi
    done
  fi
  if [ "${#compatible_indices[@]}" -gt 0 ]; then
    last=${compatible_indices[${#compatible_indices[@]}-1]}
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
