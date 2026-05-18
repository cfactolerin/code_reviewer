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
    floc="${1:-}"; sumfilter="${2:-}"
    [ -n "$file" ] && [ -n "$floc" ] || { echo "Usage: dismiss.sh remove <file> <file:line> [<summary-substring>]" >&2; exit 2; }
    [ -f "$file" ] || { echo "code-reviewer: no DISMISSALS.md found" >&2; exit 0; }
    awk -v fl="$floc" -v sumfilter="$sumfilter" '
      function flush() {
        if (buf != "") {
          if (keep) printf "%s", buf
          buf=""; in_section=0; fp=""; section_matches=0
        }
      }
      /^## / {
        flush()
        in_section=1
        keep=1
        section_matches=0
        fp=""
      }
      in_section && /^\*\*Fingerprint:\*\*[ \t]+`[^`]+`/ {
        match($0, /`[^`]+`/)
        fp = substr($0, RSTART+1, RLENGTH-2)
        # fl is a prefix iff fp starts with "<fl>:"
        n = length(fl)
        if (substr(fp, 1, n+1) == fl ":") {
          # If a summary-substring filter is provided, the slug portion must contain it.
          slug_part = substr(fp, n+2)
          if (sumfilter == "" || index(slug_part, sumfilter) > 0) {
            section_matches=1
          }
        }
        if (section_matches) keep=0
      }
      { buf = buf $0 "\n" }
      END { flush() }
    ' "$file" > "${file}.new.$$"
    mv "${file}.new.$$" "$file"
    ;;

  list)
    [ -n "$file" ] || { echo "Usage: dismiss.sh list <file>" >&2; exit 2; }
    [ -f "$file" ] || exit 0
    awk -v sep=" — " '
      function flush() {
        if (fp != "" && in_section) {
          printf "%s — %s — %s\n", fp, (date == "" ? "?" : date), (summary == "" ? "?" : summary)
        }
        fp=""; date=""; summary=""; in_section=0
      }
      /^## / {
        flush()
        in_section=1
        # Extract summary: everything after the first " — " separator.
        i = index($0, sep)
        if (i > 0) summary = substr($0, i+length(sep))
      }
      in_section && /^\*\*Fingerprint:\*\*[ \t]+`[^`]+`/ {
        match($0, /`[^`]+`/)
        fp = substr($0, RSTART+1, RLENGTH-2)
      }
      in_section && /^Dismissed:[ \t]+/ {
        sub(/^Dismissed:[ \t]+/, "")
        date = $0
      }
      END { flush() }
    ' "$file"
    ;;

  *)
    echo "Usage: dismiss.sh add|remove|list <args>" >&2
    exit 2
    ;;
esac
