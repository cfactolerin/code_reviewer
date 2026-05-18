#!/usr/bin/env bash
# Test fixture helpers. Source from each tests/*.test.sh:
#   . "$(dirname "$0")/lib.sh"
# Provides:
#   setup_fixture_repo   — creates /tmp/cr-test-fixtures/$$/<name>/ as a git repo, prints its path
#   teardown_all         — wipes /tmp/cr-test-fixtures/$$/ (call from a trap)
#   assert_eq            — assert string equality, fail loudly
#   assert_contains      — assert substring presence
#   assert_exit          — assert exit code matches

CR_TEST_ROOT="/tmp/cr-test-fixtures/$$"

setup_fixture_repo() {
  local name="${1:-repo}"
  local dir="$CR_TEST_ROOT/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
  echo "initial" > "$dir/README"
  git -C "$dir" add README
  git -C "$dir" commit -qm "initial"
  git -C "$dir" branch -m main
  echo "$dir"
}

teardown_all() {
  rm -rf "$CR_TEST_ROOT"
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: ${msg:-assert_eq}" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *)
      echo "FAIL: ${msg:-assert_contains}" >&2
      echo "  haystack: $haystack" >&2
      echo "  needle:   $needle" >&2
      exit 1
      ;;
  esac
}

assert_exit() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: ${msg:-assert_exit} — expected exit $expected, got $actual" >&2
    exit 1
  fi
}
