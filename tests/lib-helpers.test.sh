#!/usr/bin/env bash
# tests/lib-helpers.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
. "$SCRIPTS/lib.sh"
trap teardown_all EXIT

# --- cr_repo_slug ---
assert_eq "$(cr_repo_slug /tmp/foo-bar)"          "foo-bar"          "basic slug"
assert_eq "$(cr_repo_slug /tmp/My.Project!)"      "My_Project_"      "sanitise non-alnum"
assert_eq "$(cr_repo_slug /a/b/c/code_reviewer)"  "code_reviewer"    "underscore preserved"

# --- cr_review_output_path ---
unset CR_CONFIG_DIR
mkdir -p /tmp/cr-conf-$$ ; export CR_CONFIG_DIR=/tmp/cr-conf-$$
assert_eq "$(cr_review_output_path /tmp/repo)"    "/tmp/code-reviewer" "default when no config"
echo '{"review_output_path":"/tmp/custom"}' > "$CR_CONFIG_DIR/config.json"
assert_eq "$(cr_review_output_path /tmp/repo)"    "/tmp/custom"        "explicit absolute path"
echo '{"review_output_path":"~/reviews"}' > "$CR_CONFIG_DIR/config.json"
assert_eq "$(cr_review_output_path /tmp/repo)"    "$HOME/reviews"      "~ expansion"
echo '{"review_output_path":"tmp/code-reviews"}' > "$CR_CONFIG_DIR/config.json"
assert_eq "$(cr_review_output_path /tmp/repo)"    "/tmp/repo/tmp/code-reviews" "relative resolves against repo root"
rm -rf "$CR_CONFIG_DIR"; unset CR_CONFIG_DIR

# --- cr_worktree_hash ---
repo=$(setup_fixture_repo wt)
cd "$repo"

# clean tree → null
assert_eq "$(cr_worktree_hash)" "" "clean tree → empty"

# modified tracked file → non-empty
echo "modification" >> README
h1=$(cr_worktree_hash)
[ -n "$h1" ] || { echo "FAIL: dirty tree should produce hash"; exit 1; }

# different modification → different hash
echo "extra"        >> README
h2=$(cr_worktree_hash)
[ "$h1" != "$h2" ] || { echo "FAIL: different dirty states should differ"; exit 1; }

# revert → null again
git checkout -- README
assert_eq "$(cr_worktree_hash)" "" "reverted tree → empty"

# untracked file → non-empty
echo "new" > new.txt
h3=$(cr_worktree_hash)
[ -n "$h3" ] || { echo "FAIL: untracked file should produce hash"; exit 1; }

# changing untracked content → different hash
echo "newer" > new.txt
h4=$(cr_worktree_hash)
[ "$h3" != "$h4" ] || { echo "FAIL: untracked content change should change hash"; exit 1; }

# .gitignore'd file should not affect hash
echo "*.log" > .gitignore
git add .gitignore && git commit -qm "ignore logs"
rm new.txt
assert_eq "$(cr_worktree_hash)" "" "fully clean again"
echo "logfile" > debug.log
assert_eq "$(cr_worktree_hash)" "" "ignored file does not affect hash"
cd /

# --- cr_dismissals_hash ---
mkdir -p /tmp/cr-dh-$$
assert_eq "$(cr_dismissals_hash /tmp/cr-dh-$$/DISMISSALS.md)" "" "missing file → empty"
echo "content" > /tmp/cr-dh-$$/DISMISSALS.md
dh1=$(cr_dismissals_hash /tmp/cr-dh-$$/DISMISSALS.md)
[ -n "$dh1" ] || { echo "FAIL: present file should hash"; exit 1; }
echo "more"   >> /tmp/cr-dh-$$/DISMISSALS.md
dh2=$(cr_dismissals_hash /tmp/cr-dh-$$/DISMISSALS.md)
[ "$dh1" != "$dh2" ] || { echo "FAIL: changed contents → different hash"; exit 1; }
rm -rf /tmp/cr-dh-$$

echo "lib-helpers OK"
