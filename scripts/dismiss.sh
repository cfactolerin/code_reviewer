#!/usr/bin/env bash
# Manage DISMISSALS.md per spec §3.4. Each entry is a `## file:line — summary`
# heading with a `**Fingerprint:**` line that the parser keys on.
#
# Usage:
#   dismiss.sh add    <dism.md> <file:line> <summary> <reason>
#   dismiss.sh remove <dism.md> <file:line> [<summary-substring>]
#   dismiss.sh list   <dism.md>

set -u
set -o pipefail

# Slug a summary: lowercase, non-alnum → "_", collapse repeats handled implicitly.
# "+" expands to "_plus_" before the general substitution so e.g. "N+1" → "n_plus_1".
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/+/_plus_/g' | tr -c 'a-z0-9' '_'
}

fingerprint_for() {
  local file_line="$1" summary="$2"
  printf '%s:%s' "$file_line" "$(slug "$summary")"
}

cmd="${1:-}"; shift || true
file="${1:-}"; shift || true

case "$cmd" in
  add)
    floc="${1:-}"; summary="${2:-}"; reason="${3:-}"
    [ -n "$file" ] && [ -n "$floc" ] && [ -n "$summary" ] && [ -n "$reason" ] \
      || { echo "Usage: dismiss.sh add <file> <file:line> <summary> <reason>" >&2; exit 2; }
    fp=$(fingerprint_for "$floc" "$summary")
    # Idempotent: if a section with this fingerprint already exists, no-op.
    if [ -f "$file" ] && grep -qF "**Fingerprint:** \`$fp\`" "$file"; then
      echo "code-reviewer: already dismissed: $fp" >&2
      exit 0
    fi
    mkdir -p "$(dirname "$file")"
    : > "${file}.append.$$"
    [ -f "$file" ] && cat "$file" > "${file}.append.$$"
    {
      [ -f "$file" ] && [ -s "$file" ] && echo ""
      printf '## %s — %s\n\n' "$floc" "$summary"
      printf '**Fingerprint:** `%s`\n\n' "$fp"
      printf 'Dismissed: %s\n' "$(date +%Y-%m-%d)"
      printf 'Reason: %s\n' "$reason"
    } >> "${file}.append.$$"
    mv "${file}.append.$$" "$file"
    ;;

  remove)
    floc="${1:-}"; summary_sub="${2:-}"
    [ -n "$file" ] && [ -n "$floc" ] || { echo "Usage: dismiss.sh remove <file> <file:line> [<summary-substring>]" >&2; exit 2; }
    [ -f "$file" ] || { echo "code-reviewer: no DISMISSALS.md found" >&2; exit 0; }
    awk -v fl="$floc" -v sumfilter="$summary_sub" '
      BEGIN { keep=1; buf=""; have_fp=0; matches=0 }
      /^## / {
        # Flush previous section.
        if (buf != "") {
          if (keep) printf "%s", buf
          buf=""; have_fp=0; matches=0
        }
        keep=1
        # Examine heading: does it start with "## <file:line> —"?
        if ($0 ~ "^## "fl" — ") {
          matches=1
        }
      }
      matches && /^\*\*Fingerprint:\*\*/ {
        # Honour summary substring filter if provided
        if (sumfilter != "" && index($0, sumfilter) == 0) {
          # different summary, leave section in place
        } else {
          keep=0
        }
      }
      { buf = buf $0 "\n" }
      END {
        if (buf != "" && keep) printf "%s", buf
      }
    ' "$file" > "${file}.new.$$"
    mv "${file}.new.$$" "$file"
    ;;

  list)
    [ -n "$file" ] || { echo "Usage: dismiss.sh list <file>" >&2; exit 2; }
    [ -f "$file" ] || exit 0
    awk '
      /^\*\*Fingerprint:\*\*[ \t]+`([^`]+)`/ {
        match($0, /`[^`]+`/)
        fp = substr($0, RSTART+1, RLENGTH-2)
        print fp
      }
    ' "$file"
    ;;

  *)
    echo "Usage: dismiss.sh add|remove|list <args>" >&2
    exit 2
    ;;
esac
