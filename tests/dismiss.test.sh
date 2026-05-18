#!/usr/bin/env bash
# tests/dismiss.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

dir=$(mktemp -d "$CR_TEST_ROOT/dismiss-XXXX")
DISM="$dir/DISMISSALS.md"

# --- add creates file + writes section with **Fingerprint:** line ---
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/auth.rs:42" "missing null check" "middleware handles null"
[ -f "$DISM" ] || { echo "FAIL: dismiss add should create the file"; exit 1; }
assert_contains "$(cat "$DISM")" "## src/auth.rs:42 — missing null check"
assert_contains "$(cat "$DISM")" "**Fingerprint:** \`src/auth.rs:42:missing_null_check\`"
assert_contains "$(cat "$DISM")" "Reason: middleware handles null"

# --- add is idempotent: same file:line + summary → no duplicate ---
before=$(wc -l < "$DISM")
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/auth.rs:42" "missing null check" "different reason"
after=$(wc -l < "$DISM")
assert_eq "$before" "$after" "idempotent add should not change line count"

# --- list outputs one line per dismissal ---
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "src/auth.rs:42:missing_null_check"

# --- add a second dismissal, then list shows both ---
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/db.rs:120" "N+1" "bounded dataset"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "src/auth.rs:42:missing_null_check"
assert_contains "$out" "src/db.rs:120:n_plus_1"

# --- remove by file:line ---
bash "$SCRIPTS/dismiss.sh" remove "$DISM" "src/auth.rs:42"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
case "$out" in *"src/auth.rs:42:missing_null_check"*) echo "FAIL: should be removed"; exit 1 ;; esac
assert_contains "$out" "src/db.rs:120:n_plus_1"

# --- remove non-existent is a no-op ---
bash "$SCRIPTS/dismiss.sh" remove "$DISM" "no/such:99"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "src/db.rs:120:n_plus_1"

# --- C1 regression: removing src/auth.rs:42 must not also remove src/authXrs:42 ---
# Set up two near-look-alike entries.
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/auth.rs:42" "alpha" "x"
bash "$SCRIPTS/dismiss.sh" add "$DISM" "src/authXrs:42" "alpha2" "y"
bash "$SCRIPTS/dismiss.sh" remove "$DISM" "src/auth.rs:42"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
case "$out" in *"src/auth.rs:42:alpha"*) echo "FAIL: src/auth.rs:42 entry should be removed"; exit 1 ;; esac
assert_contains "$out" "src/authXrs:42:alpha2" "src/authXrs:42 (look-alike) must be retained"

# --- I1 regression: range heading remove-by-start-line works (matches by fingerprint) ---
# Manually craft a range-heading entry (no helper supports range adds yet — the section
# format is what the arbiter/user might write).
{
  echo ""
  echo "## src/db.rs:118-130 — Unsynchronised access"
  echo ""
  echo "**Fingerprint:** \`src/db.rs:118:unsynchronised_access\`"
  echo ""
  echo "Dismissed: 2026-05-18"
  echo "Reason: cache only mutated at startup"
} >> "$DISM"
bash "$SCRIPTS/dismiss.sh" remove "$DISM" "src/db.rs:118"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
case "$out" in *"src/db.rs:118:unsynchronised_access"*) echo "FAIL: range-heading entry should be removed"; exit 1 ;; esac

# --- I2 regression: list emits <fp> — <date> — <summary> ---
# Use the existing src/db.rs:120 entry from earlier in the test.
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "src/db.rs:120:n_plus_1 — " "list should include date separator"
assert_contains "$out" " — N+1" "list should include the original summary"

# --- slug rules: spaces, capitals, punctuation normalised ---
bash "$SCRIPTS/dismiss.sh" add "$DISM" "foo.py:10" "Mixed CASE & punct!" "x"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "foo.py:10:mixed_case___punct_"

echo "dismiss OK"
