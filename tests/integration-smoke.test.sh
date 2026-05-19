#!/usr/bin/env bash
# tests/integration-smoke.test.sh
#
# End-to-end smoke: fixture repo, /code-reviewer:start full → ledger + findings.json,
# then /code-reviewer:start delta with no new commits → nothing-new short-circuit,
# then /code-reviewer:start delta after a new commit → second ledger entry.
#
# Stubs out the actual agent dispatch by short-circuiting the prompt run and
# writing a hand-crafted findings.json + FINAL_REVIEW_RESULTS.md that pass
# validation. The point is to exercise the orchestration glue, not the agents.

set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo smoke-int)
cd "$repo"
git checkout -qb feat
echo a >> README; git commit -qam "c1"

CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\",\"agents\":[\"claude\"],\"keep_last_rounds\":5}" > "$CR_CONFIG_DIR/config.json"

# 1) context.sh full run → produces a round dir.
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR=$(echo "$out" | tail -1)
[ -d "$ROUND_DIR" ] || { echo "FAIL: round dir not created"; exit 1; }

# 2) Inject a hand-crafted findings.json + FINAL_REVIEW_RESULTS.md as if the agents produced them.
mkdir -p "$ROUND_DIR/results"
HEAD_SHA=$(git rev-parse HEAD)
BASE_SHA=$(git rev-parse main)
cat > "$ROUND_DIR/findings.json" <<JSON
{
  "round":"$(basename $ROUND_DIR)","verdict":"APPROVE","confidence":"HIGH",
  "head_sha":"$HEAD_SHA","base_sha":"$BASE_SHA",
  "findings":[],"open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
JSON
cp "$ROUND_DIR/findings.json" "$ROUND_DIR/FINAL_REVIEW_RESULTS.md"   # placeholder body

# 3) Validate it.
python3 "$SCRIPTS/validate-findings.py" "$ROUND_DIR/findings.json" >/dev/null
assert_exit 0 "$?"

# 4) Append the ledger entry manually (simulating Phase 6.5 success).
REPO_SLUG=$(basename "$repo")
BRANCH_DIR="$ROUT/$REPO_SLUG/feat"
bash "$SCRIPTS/ledger.sh" append "$BRANCH_DIR/.review-ledger.json" "$(jq -n \
  --arg ts "$(basename $ROUND_DIR)" --arg head "$HEAD_SHA" --arg base "$BASE_SHA" \
  '{branch:"feat",base_ref:"main",jira_keys:[],jira_cached_at:null,
    timestamp:$ts,type:"full",head_sha:$head,base_ref:"main",base_sha:$base,
    commits_reviewed:[$head],previous_head_sha:null,worktree_hash:null,
    dismissals_hash:null,verdict:"APPROVE",
    findings:{critical:0,high:0,medium:0,low:0},open_questions:0,
    round_dir:$ts,fallback_reason:null}')"

# 5) Delta with no changes → nothing-new short-circuit.
out=$(bash "$SCRIPTS/context.sh" 2>&1) && rc=$? || rc=$?
assert_contains "$out" "Nothing new"

# 6) New commit → Delta runs.
echo b >> README; git commit -qam "c2"
out=$(bash "$SCRIPTS/context.sh" 2>&1)
ROUND_DIR2=$(echo "$out" | tail -1)
[ -d "$ROUND_DIR2" ] || { echo "FAIL: second round dir not created"; exit 1; }
[ -f "$ROUND_DIR2/prior_findings.json" ] || { echo "FAIL: prior_findings.json must exist on Delta"; exit 1; }

# 7) Hook denies because no ledger entry for the new HEAD.
HOOK="$SCRIPTS/hooks/pre-push.sh"
out=$(jq -nc --arg c "git push origin feat" '{toolInput:{command:$c}}' | bash "$HOOK")
assert_contains "$out" "head_changed"

echo "integration-smoke OK"
