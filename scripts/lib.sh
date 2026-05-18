#!/usr/bin/env bash
# Common helpers sourced by other code-reviewer scripts.
# All functions must be safe to call when sourced (no `exit`, no `set -e` here).

CR_CONFIG_DIR="${CR_CONFIG_DIR:-$HOME/.code-reviewer}"
CR_CONFIG_FILE="$CR_CONFIG_DIR/config.json"

cr_die() {
  echo "code-reviewer: $*" >&2
  return 1
}

cr_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

cr_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Resolve the base branch to diff against.
# Priority: explicit override ($1) > config.base_branch > upstream > origin/main > origin/master.
# Echoes the resolved ref (e.g. "origin/main"). Returns non-zero if nothing resolves.
cr_base_branch() {
  local override="${1:-}"
  if [ -n "$override" ]; then
    echo "$override"
    return 0
  fi

  if [ -f "$CR_CONFIG_FILE" ]; then
    local cfg_base
    cfg_base=$(jq -r '.base_branch // empty' "$CR_CONFIG_FILE" 2>/dev/null)
    if [ -n "$cfg_base" ]; then
      echo "$cfg_base"
      return 0
    fi
  fi

  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  if [ -n "$upstream" ] && [ "$upstream" != "$(cr_current_branch)" ]; then
    echo "$upstream"
    return 0
  fi

  if git show-ref --verify --quiet refs/remotes/origin/main; then
    echo "origin/main"
    return 0
  fi
  if git show-ref --verify --quiet refs/remotes/origin/master; then
    echo "origin/master"
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/main; then
    echo "main"
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/master; then
    echo "master"
    return 0
  fi
  return 1
}

# Sanitise a branch name for use in a directory path.
cr_branch_slug() {
  local branch="$1"
  echo "$branch" | tr '/ ' '__'
}

cr_config_get() {
  local key="$1"
  local default="${2:-}"
  if [ -f "$CR_CONFIG_FILE" ]; then
    local val
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$CR_CONFIG_FILE" 2>/dev/null)
    if [ -n "$val" ]; then
      echo "$val"
      return 0
    fi
  fi
  echo "$default"
}

cr_config_get_agents() {
  if [ -f "$CR_CONFIG_FILE" ]; then
    jq -r '.agents[]?' "$CR_CONFIG_FILE" 2>/dev/null
  fi
}

# Detect a Jira issue key from the current branch name or recent commits.
# Echoes the key (e.g. "ABC-123") or nothing.
cr_detect_jira_key() {
  local branch
  branch=$(cr_current_branch)
  local key
  key=$(echo "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n 1)
  if [ -n "$key" ]; then
    echo "$key"
    return 0
  fi

  local base
  base=$(cr_base_branch) || return 0
  key=$(git log --pretty=format:%B "$base..HEAD" 2>/dev/null | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n 1)
  if [ -n "$key" ]; then
    echo "$key"
  fi
}

# --- v0.4.0 helpers ---

# Sanitise a repo basename for use under <review_output_path>/<repo-slug>/
cr_repo_slug() {
  local path="$1"
  basename "$path" | tr -c 'A-Za-z0-9_-\n' '_'
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
