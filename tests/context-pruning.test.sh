#!/usr/bin/env bash
# tests/context-pruning.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo prune)
cd "$repo"
git checkout -qb feat
echo a >> README; git commit -qam "c1"

CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\",\"keep_last_rounds\":2}" > "$CR_CONFIG_DIR/config.json"

REPO_SLUG=$(basename "$repo")
BRANCH_DIR="$ROUT/$REPO_SLUG/feat"

# Simulate three completed runs by manually creating timestamp dirs + a ledger.
mkdir -p "$BRANCH_DIR/20260101-100000" "$BRANCH_DIR/20260101-110000" "$BRANCH_DIR/20260101-120000"
HEAD_SHA=$(git rev-parse HEAD)
cat > "$BRANCH_DIR/.review-ledger.json" <<JSON
{
  "branch":"feat","base_ref":"main","jira_keys":[],"jira_cached_at":null,
  "reviews":[
    {"timestamp":"20260101-100000","type":"full","head_sha":"x","base_ref":"main","base_sha":"x",
     "commits_reviewed":["x"],"previous_head_sha":null,"worktree_hash":null,
     "dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260101-100000","fallback_reason":null},
    {"timestamp":"20260101-110000","type":"delta","head_sha":"y","base_ref":"main","base_sha":"x",
     "commits_reviewed":["y"],"previous_head_sha":"x","worktree_hash":null,
     "dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260101-110000","fallback_reason":null},
    {"timestamp":"20260101-120000","type":"delta","head_sha":"$HEAD_SHA","base_ref":"main","base_sha":"x",
     "commits_reviewed":["$HEAD_SHA"],"previous_head_sha":"y","worktree_hash":null,
     "dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260101-120000","fallback_reason":null}
  ]
}
JSON
# Each prior round dir needs a findings.json for Delta carry-forward
for d in 20260101-100000 20260101-110000 20260101-120000; do
  cat > "$BRANCH_DIR/$d/findings.json" <<'JSON'
{"round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
 "findings":[],"open_questions":[],"regression":{"resolved":[],"newly_introduced":[]},
 "dismissed_active":[],"obsolete_dismissals":[]}
JSON
done

# Add a new commit so Delta will actually run
echo b >> README; git commit -qam "c2"

# Run context.sh — pruning should run as last step, keep_last_rounds=2, so it
# should preserve only the 2 most recent timestamp dirs at the END of the run
# (current + previous; older dirs removed).
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR=$(echo "$out" | tail -1)
TS=$(basename "$ROUND_DIR")

# Survivors should be: the new TS, AND the immediately-prior round (20260101-120000),
# AND at most keep_last_rounds-2 older. With keep_last_rounds=2, expect just those two.
[ -d "$BRANCH_DIR/$TS" ]                || { echo "FAIL: new round missing"; exit 1; }
[ -d "$BRANCH_DIR/20260101-120000" ]    || { echo "FAIL: prev round must be preserved (carry-forward source)"; exit 1; }
[ ! -d "$BRANCH_DIR/20260101-100000" ]  || { echo "FAIL: 20260101-100000 should have been pruned"; exit 1; }
[ ! -d "$BRANCH_DIR/20260101-110000" ]  || { echo "FAIL: 20260101-110000 should have been pruned"; exit 1; }

# --no-prune skips pruning
mkdir -p "$BRANCH_DIR/20260101-100000"   # restore older round
out=$(bash "$SCRIPTS/context.sh" --no-prune 2>&1)
[ -d "$BRANCH_DIR/20260101-100000" ] || { echo "FAIL: --no-prune should preserve old rounds"; exit 1; }

echo "context-pruning OK"
