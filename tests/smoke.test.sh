#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
trap teardown_all EXIT

repo=$(setup_fixture_repo smoke)
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
assert_eq "$branch" "main" "fixture should start on main"
echo "smoke OK"
