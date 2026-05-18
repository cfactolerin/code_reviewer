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
