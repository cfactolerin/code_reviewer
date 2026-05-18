#!/usr/bin/env bash
# Bump the plugin version in both manifest files (plugin.json + marketplace.json)
# in lockstep, or verify they already agree.
#
# Usage:
#   bump-version.sh patch          # 0.1.0 -> 0.1.1
#   bump-version.sh minor          # 0.1.0 -> 0.2.0
#   bump-version.sh major          # 0.1.0 -> 1.0.0
#   bump-version.sh set X.Y.Z      # set explicitly
#   bump-version.sh check          # exit non-zero if they disagree
#   bump-version.sh print          # echo the current version

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

if [ ! -f "$PLUGIN_JSON" ] || [ ! -f "$MARKETPLACE_JSON" ]; then
  echo "Missing manifest files. Expected:" >&2
  echo "  $PLUGIN_JSON" >&2
  echo "  $MARKETPLACE_JSON" >&2
  exit 1
fi

get_plugin_version() {
  jq -r '.version' "$PLUGIN_JSON"
}

get_marketplace_version() {
  jq -r '.plugins[0].version' "$MARKETPLACE_JSON"
}

set_plugin_version() {
  local v="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg v "$v" '.version = $v' "$PLUGIN_JSON" > "$tmp" && mv "$tmp" "$PLUGIN_JSON"
}

set_marketplace_version() {
  local v="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg v "$v" '.plugins[0].version = $v' "$MARKETPLACE_JSON" > "$tmp" && mv "$tmp" "$MARKETPLACE_JSON"
}

bump() {
  local current="$1" level="$2"
  IFS=. read -r MAJ MIN PAT <<< "$current"
  case "$level" in
    patch) PAT=$((PAT + 1)) ;;
    minor) MIN=$((MIN + 1)); PAT=0 ;;
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
    *) echo "unknown level: $level" >&2; return 2 ;;
  esac
  echo "$MAJ.$MIN.$PAT"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  print)
    get_plugin_version
    ;;

  check)
    pv=$(get_plugin_version)
    mv_=$(get_marketplace_version)
    if [ "$pv" != "$mv_" ]; then
      echo "Version drift detected." >&2
      echo "  plugin.json:      $pv" >&2
      echo "  marketplace.json: $mv_" >&2
      exit 1
    fi
    echo "$pv (in sync)"
    ;;

  patch|minor|major)
    current=$(get_plugin_version)
    new=$(bump "$current" "$cmd")
    set_plugin_version "$new"
    set_marketplace_version "$new"
    echo "$current -> $new"
    ;;

  set)
    new="${1:-}"
    if [[ ! "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Usage: bump-version.sh set <X.Y.Z>" >&2
      exit 2
    fi
    current=$(get_plugin_version)
    set_plugin_version "$new"
    set_marketplace_version "$new"
    echo "$current -> $new"
    ;;

  *)
    echo "Usage: bump-version.sh patch|minor|major|set X.Y.Z|check|print" >&2
    exit 2
    ;;
esac
