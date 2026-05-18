#!/usr/bin/env bash
# tests/ledger.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

dir=$(mktemp -d "$CR_TEST_ROOT/ledger-XXXX")
mkdir -p "$dir"
LEDGER="$dir/.review-ledger.json"

# --- append (creates file when missing) ---
bash "$SCRIPTS/ledger.sh" append "$LEDGER" '{
  "timestamp": "20260518-140000",
  "type": "full",
  "head_sha": "abc123",
  "base_ref": "origin/main",
  "base_sha": "f00ba8",
  "commits_reviewed": ["abc123"],
  "previous_head_sha": null,
  "worktree_hash": null,
  "dismissals_hash": null,
  "verdict": "APPROVE",
  "findings": {"critical":0,"high":0,"medium":0,"low":0},
  "open_questions": 0,
  "round_dir": "20260518-140000",
  "fallback_reason": null
}'

n=$(jq '.reviews | length' "$LEDGER")
assert_eq "$n" "1" "first append should create reviews=[1]"
v=$(jq -r '.reviews[0].verdict' "$LEDGER")
assert_eq "$v" "APPROVE" "verdict preserved"

# --- append (extends existing file, preserves top-level metadata) ---
bash "$SCRIPTS/ledger.sh" append "$LEDGER" '{
  "timestamp": "20260518-153000",
  "type": "delta",
  "head_sha": "def456",
  "base_ref": "origin/main",
  "base_sha": "f00ba8",
  "commits_reviewed": ["def456"],
  "previous_head_sha": "abc123",
  "worktree_hash": "7f3e",
  "dismissals_hash": null,
  "verdict": "REQUEST_CHANGES",
  "findings": {"critical":0,"high":2,"medium":1,"low":0},
  "open_questions": 1,
  "round_dir": "20260518-153000",
  "fallback_reason": null
}'

n=$(jq '.reviews | length' "$LEDGER")
assert_eq "$n" "2" "second append should bring length to 2"

# --- list (prints the entries as a table or JSON-per-line) ---
out=$(bash "$SCRIPTS/ledger.sh" list "$LEDGER")
assert_contains "$out" "20260518-140000"
assert_contains "$out" "20260518-153000"
assert_contains "$out" "REQUEST_CHANGES"

# --- render-md (regenerates a human-readable summary) ---
MD="$dir/REVIEW_LEDGER.md"
bash "$SCRIPTS/ledger.sh" render-md "$LEDGER" "$MD"
[ -f "$MD" ] || { echo "FAIL: render-md should write the .md path"; exit 1; }
assert_contains "$(cat "$MD")" "20260518-140000"
assert_contains "$(cat "$MD")" "APPROVE"

# --- append rejects malformed entry without overwriting the ledger ---
backup=$(cat "$LEDGER")
out=$(bash "$SCRIPTS/ledger.sh" append "$LEDGER" 'not-json' 2>&1) && rc=$? || rc=$?
assert_exit "1" "$rc" "append should fail on malformed entry"
assert_eq "$(cat "$LEDGER")" "$backup" "ledger should be unchanged after failed append"

# --- lock acquire + release ---
LOCK="$dir/.review-ledger.lock"
bash "$SCRIPTS/ledger.sh" acquire-lock "$LOCK"
[ -f "$LOCK" ] || { echo "FAIL: lock file should exist after acquire"; exit 1; }

# second acquire should fail (file fresh, stale-override condition not met)
out=$(bash "$SCRIPTS/ledger.sh" acquire-lock "$LOCK" 2>&1) && rc=$? || rc=$?
assert_exit "1" "$rc" "second acquire should fail"
assert_contains "$out" "in progress" "deny message"

# release + re-acquire works
bash "$SCRIPTS/ledger.sh" release-lock "$LOCK"
[ -f "$LOCK" ] && { echo "FAIL: lock should be gone after release"; exit 1; }
bash "$SCRIPTS/ledger.sh" acquire-lock "$LOCK"
bash "$SCRIPTS/ledger.sh" release-lock "$LOCK"

echo "ledger OK"
