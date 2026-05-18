#!/usr/bin/env bash
# tests/hook-pre-push.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

HOOK="$SCRIPTS/hooks/pre-push.sh"

run_hook() {
  # Pipe a minimal PreToolUse JSON to the hook. $1 = the command string.
  local cmd="$1"
  jq -nc --arg c "$cmd" '{toolInput:{command:$c}}' | bash "$HOOK"
}

# Non-push commands → exit 0, no output
out=$(run_hook "ls -la")
assert_eq "$?" "0"
assert_eq "$out" ""

# git push command without config → exit 0 silently (no setup)
unset CR_CONFIG_DIR
out=$(run_hook "git push")
assert_eq "$?" "0"

# Set up a fixture repo + ledger and verify the gate flows.
repo=$(setup_fixture_repo hook-test)
cd "$repo"
git checkout -qb feat
echo hi >> README; git commit -qam "feat commit"

# Create config that points review_output_path at a writable temp dir.
CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
cat > "$CR_CONFIG_DIR/config.json" <<JSON
{
  "review_output_path": "$ROUT",
  "auto_trigger": true,
  "skip_branches": [],
  "keep_last_rounds": 10
}
JSON

# 1) auto_trigger=false → silent allow
jq '. + {auto_trigger:false}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"
out=$(run_hook "git push origin feat")
assert_eq "$?" "0"
jq '. + {auto_trigger:true}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"

# 2) CR_SKIP=1 prefix in command string → silent allow
out=$(run_hook "CR_SKIP=1 git push origin feat")
assert_eq "$?" "0"

# 3) Skip branches matching skip_branches → silent allow
jq '. + {skip_branches:["feat"]}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"
out=$(run_hook "git push origin feat")
assert_eq "$?" "0"
jq '. + {skip_branches:[]}' "$CR_CONFIG_DIR/config.json" > /tmp/c.$$ && mv /tmp/c.$$ "$CR_CONFIG_DIR/config.json"

# 4) No ledger → deny with `no_ledger` reason
out=$(run_hook "git push origin feat" 2>&1) && rc=$? || rc=$?
assert_eq "$rc" "0" "hook returns 0 even on deny; uses permissionDecision payload"
assert_contains "$out" "permissionDecision"
assert_contains "$out" "no_ledger"

# 5) Ledger entry that approves the current HEAD with clean worktree → allow
mkdir -p "$ROUT/$(basename "$repo")/feat"
HEAD_SHA=$(git rev-parse HEAD)
BASE_SHA=$(git rev-parse --verify origin/main 2>/dev/null || git rev-parse main)
cat > "$ROUT/$(basename "$repo")/feat/.review-ledger.json" <<JSON
{
  "branch": "feat", "base_ref": "main", "jira_keys": [], "jira_cached_at": null,
  "reviews": [
    {"timestamp":"20260518-140000","type":"full","head_sha":"$HEAD_SHA","base_ref":"main",
     "base_sha":"$BASE_SHA","commits_reviewed":["$HEAD_SHA"],"previous_head_sha":null,
     "worktree_hash":null,"dismissals_hash":null,"verdict":"APPROVE",
     "findings":{"critical":0,"high":0,"medium":0,"low":0},"open_questions":0,
     "round_dir":"20260518-140000","fallback_reason":null}
  ]
}
JSON
out=$(run_hook "git push origin feat" 2>&1) && rc=$? || rc=$?
assert_eq "$rc" "0"
# allow → no decision payload
case "$out" in *permissionDecision*) echo "FAIL: allow should produce no payload"; exit 1 ;; esac

# 6) Now add a commit beyond what was reviewed → deny with head_changed
echo more >> README; git commit -qam "another"
out=$(run_hook "git push origin feat" 2>&1)
assert_contains "$out" "head_changed"

echo "hook OK"
