#!/usr/bin/env bash
# tests/context-delta-full.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo modes)
cd "$repo"
git checkout -qb feat
echo a >> README; git commit -qam "c1"

CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\"}" > "$CR_CONFIG_DIR/config.json"

REPO_SLUG=$(basename "$repo")
BRANCH_DIR="$ROUT/$REPO_SLUG/feat"

# 1) No ledger → context.sh runs as Full (no `--delta` flag possible).
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR=$(echo "$out" | tail -1)
[ -d "$ROUND_DIR/context" ] || { echo "FAIL: round dir missing"; exit 1; }
# Mode must be FULL since no ledger
grep -q "Mode.*full" "$ROUND_DIR/context/context-manifest.md" \
  || { echo "FAIL: first run should be FULL"; exit 1; }

# Simulate a successful review by creating a ledger entry.
mkdir -p "$BRANCH_DIR"
HEAD_SHA=$(git rev-parse HEAD)
BASE_SHA=$(git rev-parse main 2>/dev/null)
cat > "$BRANCH_DIR/.review-ledger.json" <<JSON
{
  "branch":"feat","base_ref":"main","jira_keys":[],"jira_cached_at":null,
  "reviews":[
    {"timestamp":"$(basename $ROUND_DIR)","type":"full","head_sha":"$HEAD_SHA",
     "base_ref":"main","base_sha":"$BASE_SHA","commits_reviewed":["$HEAD_SHA"],
     "previous_head_sha":null,"worktree_hash":null,"dismissals_hash":null,
     "verdict":"APPROVE","findings":{"critical":0,"high":0,"medium":0,"low":0},
     "open_questions":0,"round_dir":"$(basename $ROUND_DIR)","fallback_reason":null}
  ]
}
JSON
# Also populate the prior round dir with a tiny findings.json so Delta can read it.
cat > "$ROUND_DIR/findings.json" <<'JSON'
{"round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
 "findings":[],"open_questions":[],"regression":{"resolved":[],"newly_introduced":[]},
 "dismissed_active":[],"obsolete_dismissals":[]}
JSON

# 2) Second run with a new commit → defaults to DELTA, writes prior_findings.json
echo b >> README; git commit -qam "c2"
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR2=$(echo "$out" | tail -1)
grep -q "Mode.*delta" "$ROUND_DIR2/context/context-manifest.md" \
  || { echo "FAIL: should default to DELTA when ledger exists"; exit 1; }
[ -f "$ROUND_DIR2/prior_findings.json" ] \
  || { echo "FAIL: prior_findings.json must be written"; exit 1; }
jq -e 'type == "array"' "$ROUND_DIR2/prior_findings.json" \
  || { echo "FAIL: prior_findings.json must be an array"; exit 1; }

# 3) --full forces FULL even when ledger exists
out=$(bash "$SCRIPTS/context.sh" --full 2>&1)
ROUND_DIR3=$(echo "$out" | tail -1)
grep -q "Mode.*full" "$ROUND_DIR3/context/context-manifest.md" || \
  { echo "FAIL: --full should override"; exit 1; }
[ ! -f "$ROUND_DIR3/prior_findings.json" ] || \
  { echo "FAIL: Full mode should not write prior_findings.json"; exit 1; }

# 4) --delta with no ledger errors clearly
rm -rf "$BRANCH_DIR/.review-ledger.json"
out=$(bash "$SCRIPTS/context.sh" --delta 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "no prior review"

# 5) Nothing-new short-circuit on Delta
# Re-seed the ledger to point at the new HEAD.
HEAD_SHA=$(git rev-parse HEAD)
cat > "$BRANCH_DIR/.review-ledger.json" <<JSON
{
  "branch":"feat","base_ref":"main","jira_keys":[],"jira_cached_at":null,
  "reviews":[
    {"timestamp":"$(basename $ROUND_DIR2)","type":"delta","head_sha":"$HEAD_SHA",
     "base_ref":"main","base_sha":"$BASE_SHA","commits_reviewed":["$HEAD_SHA"],
     "previous_head_sha":null,"worktree_hash":null,"dismissals_hash":null,
     "verdict":"APPROVE","findings":{"critical":0,"high":0,"medium":0,"low":0},
     "open_questions":0,"round_dir":"$(basename $ROUND_DIR2)","fallback_reason":null}
  ]
}
JSON
cat > "$ROUND_DIR2/findings.json" <<'JSON'
{"round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
 "findings":[],"open_questions":[],"regression":{"resolved":[],"newly_introduced":[]},
 "dismissed_active":[],"obsolete_dismissals":[]}
JSON
out=$(bash "$SCRIPTS/context.sh" 2>&1) && rc=$? || rc=$?
# Nothing-new exits with a known message; could be exit 0 or a special code.
assert_contains "$out" "Nothing new"

echo "context-delta-full OK"
