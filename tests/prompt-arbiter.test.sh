#!/usr/bin/env bash
# tests/prompt-arbiter.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

dir=$(mktemp -d "$CR_TEST_ROOT/arb-XXXX")
mkdir -p "$dir/context" "$dir/results"
echo "# manifest" > "$dir/context/context-manifest.md"
# Two reviewer reviews
echo "claude review body"  > "$dir/results/claude-review.md"
echo "gemini review body"  > "$dir/results/gemini-review.md"

# Without prior_findings → arbiter prompt must mention dismissed_active+obsolete_dismissals
bash "$SCRIPTS/prompt.sh" arbiter "$dir"
prompt="$dir/results/arbiter-prompt.md"
[ -f "$prompt" ] || { echo "FAIL: arbiter prompt missing"; exit 1; }
assert_contains "$(cat $prompt)" "dismissed_active"
assert_contains "$(cat $prompt)" "obsolete_dismissals"
assert_contains "$(cat $prompt)" "findings.json"
assert_contains "$(cat $prompt)" "verdict rubric"

# With prior_findings.json → arbiter prompt must include the carry-forward instructions
echo '[{"id":"F1","_round":"20260518-140000","fingerprint":"x.py:1:bad","severity":"HIGH"}]' > "$dir/prior_findings.json"
bash "$SCRIPTS/prompt.sh" arbiter "$dir"
prompt="$dir/results/arbiter-prompt.md"
assert_contains "$(cat $prompt)" "prior_findings.json"
assert_contains "$(cat $prompt)" "carried_from"
assert_contains "$(cat $prompt)" "regression.resolved"

echo "prompt-arbiter OK"
