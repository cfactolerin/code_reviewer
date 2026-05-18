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
