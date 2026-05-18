#!/usr/bin/env bash
# Manage the agents list in ~/.code-reviewer/config.json.
#
# Usage:
#   agents.sh list
#   agents.sh add <name>
#   agents.sh delete <name>

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

KNOWN_AGENTS=(claude codex gemini opencode)

is_known_agent() {
  local target="$1"
  for a in "${KNOWN_AGENTS[@]}"; do
    [ "$a" = "$target" ] && return 0
  done
  return 1
}

ensure_config() {
  mkdir -p "$CR_CONFIG_DIR"
  if [ ! -f "$CR_CONFIG_FILE" ]; then
    cat > "$CR_CONFIG_FILE" <<'JSON'
{
  "agents": ["claude"],
  "claude_timeout": 600,
  "codex_timeout": 900,
  "gemini_timeout": 300,
  "opencode_timeout": 900,
  "gemini_model": "gemini-2.5-flash",
  "arbiter_rounds": 3,
  "google_cloud_project": "fuga-prod",
  "google_cloud_location": "europe-west4"
}
JSON
  fi
}

cmd="${1:-}"; shift || true

case "$cmd" in
  list)
    ensure_config
    jq -r '.agents[]?' "$CR_CONFIG_FILE"
    ;;

  add)
    name="${1:-}"
    if [ -z "$name" ]; then
      echo "Usage: agents.sh add <name>" >&2
      exit 2
    fi
    if ! is_known_agent "$name"; then
      echo "Unknown agent: $name. Known: ${KNOWN_AGENTS[*]}" >&2
      exit 1
    fi
    ensure_config
    tmp=$(mktemp)
    jq --arg name "$name" '
      .agents = ((.agents // []) + [$name] | unique)
    ' "$CR_CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CR_CONFIG_FILE"
    jq -r '.agents[]?' "$CR_CONFIG_FILE"
    ;;

  delete)
    name="${1:-}"
    if [ -z "$name" ]; then
      echo "Usage: agents.sh delete <name>" >&2
      exit 2
    fi
    ensure_config
    tmp=$(mktemp)
    jq --arg name "$name" '
      .agents = ((.agents // []) | map(select(. != $name)))
    ' "$CR_CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CR_CONFIG_FILE"
    jq -r '.agents[]?' "$CR_CONFIG_FILE"
    ;;

  *)
    echo "Usage: agents.sh list|add|delete [name]" >&2
    exit 2
    ;;
esac
