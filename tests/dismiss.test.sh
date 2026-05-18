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

# --- slug rules: spaces, capitals, punctuation normalised ---
bash "$SCRIPTS/dismiss.sh" add "$DISM" "foo.py:10" "Mixed CASE & punct!" "x"
out=$(bash "$SCRIPTS/dismiss.sh" list "$DISM")
assert_contains "$out" "foo.py:10:mixed_case___punct_"

echo "dismiss OK"
