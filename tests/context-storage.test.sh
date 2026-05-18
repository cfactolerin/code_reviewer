#!/usr/bin/env bash
# tests/context-storage.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
trap teardown_all EXIT

repo=$(setup_fixture_repo storage)
cd "$repo"
git checkout -qb feat
echo x >> README; git commit -qam "feat"

# Default review_output_path → /tmp/code-reviewer/<repo-slug>/<branch>/<ts>
unset CR_CONFIG_DIR
out=$(bash "$SCRIPTS/context.sh" 2>&1 | tail -1)
case "$out" in
  /tmp/code-reviewer/*/feat/*) : ;;
  *) echo "FAIL: default path should be /tmp/code-reviewer/<repo>/feat/<ts>; got $out"; exit 1 ;;
esac

# Custom review_output_path
CR_CONFIG_DIR=$(mktemp -d "$CR_TEST_ROOT/conf-XXXX"); export CR_CONFIG_DIR
ROUT=$(mktemp -d "$CR_TEST_ROOT/rout-XXXX")
echo "{\"review_output_path\":\"$ROUT\"}" > "$CR_CONFIG_DIR/config.json"
out=$(bash "$SCRIPTS/context.sh" 2>&1 | tail -1)
case "$out" in
  "$ROUT"/*/feat/*) : ;;
  *) echo "FAIL: custom path should be $ROUT/<repo>/feat/<ts>; got $out"; exit 1 ;;
esac

# skip_branches: feat is in the list → refuses to run
echo "{\"review_output_path\":\"$ROUT\",\"skip_branches\":[\"feat\"]}" > "$CR_CONFIG_DIR/config.json"
out=$(bash "$SCRIPTS/context.sh" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc" "feat in skip_branches should refuse"
assert_contains "$out" "skip_branches"

# On main with empty skip_branches → should run, not refuse
git checkout -q main
echo y >> README; git commit -qam "on main"
echo "{\"review_output_path\":\"$ROUT\",\"skip_branches\":[]}" > "$CR_CONFIG_DIR/config.json"
out=$(bash "$SCRIPTS/context.sh" 2>&1 | tail -1)
case "$out" in
  "$ROUT"/*/main/*) : ;;
  *) echo "FAIL: main should now be reviewable; got $out"; exit 1 ;;
esac

echo "context-storage OK"
