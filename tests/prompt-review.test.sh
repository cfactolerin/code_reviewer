#!/usr/bin/env bash
# tests/prompt-review.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

# Build a minimal round dir layout the prompt builder expects.
dir=$(mktemp -d "$CR_TEST_ROOT/pr-XXXX")
mkdir -p "$dir/context" "$dir/results" "$dir/repro"
echo "# manifest" > "$dir/context/context-manifest.md"
echo "commits" > "$dir/context/commits.md"
echo "diff"    > "$dir/context/diff.patch"
echo "files"   > "$dir/context/files-status.txt"
echo "[]"      > "$dir/context/linters.json"
echo ""        > "$dir/context/test-instructions.md"
echo "# jira"  > "$dir/context/jira.md"
echo "## src/x.py:1 — issue\n\n**Fingerprint:** \`src/x.py:1:issue\`\n\nReason: x" > "$dir/context/dismissals.md"

bash "$SCRIPTS/prompt.sh" review "$dir"
prompt="$dir/results/review-prompt.md"
[ -f "$prompt" ] || { echo "FAIL: prompt file missing"; exit 1; }

# Must instruct reviewers about Open Questions
assert_contains "$(cat $prompt)" "Open Questions"
# Must instruct about dismissals
assert_contains "$(cat $prompt)" "Previously Dismissed Findings"
# Must include the dismissals.md content
assert_contains "$(cat $prompt)" "src/x.py:1:issue"
# Must instruct about linter exclusion from verdict
assert_contains "$(cat $prompt)" "Linter output is never the basis"
# Must mention findings.json emission requirement
assert_contains "$(cat $prompt)" "findings.json"

echo "prompt-review OK"
