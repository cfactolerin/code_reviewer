#!/usr/bin/env bash
# tests/validate-findings.test.sh
set -u
. "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
FIX="$(cd "$(dirname "$0")/fixtures/findings" && pwd)"
trap teardown_all EXIT

# Valid minimal findings.json → exit 0
python3 "$SCRIPTS/validate-findings.py" "$FIX/valid-minimal.json" >/dev/null
assert_exit 0 "$?" "valid-minimal should validate"

# Missing required field → exit non-zero, error mentions the field
out=$(python3 "$SCRIPTS/validate-findings.py" "$FIX/invalid-missing-field.json" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "missing"

# Bad verdict enum value → exit non-zero, error mentions verdict
out=$(python3 "$SCRIPTS/validate-findings.py" "$FIX/invalid-bad-verdict.json" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "verdict"

# Verdict/severity rubric mismatch (verdict APPROVE with CRITICAL finding)
out=$(python3 "$SCRIPTS/validate-findings.py" "$FIX/invalid-rubric-mismatch.json" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "rubric"

# Carry-forward accounting (Delta) — provide a prior_findings.json
prior=$(mktemp); echo '[{"_round":"20260518-130000","id":"F1","fingerprint":"a.py:10:x","severity":"HIGH","_was_dismissed":false}]' > "$prior"
new=$(mktemp)
# Build a findings.json that DROPS the prior finding (no carried_from, no resolved, no dismissed)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],
  "obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" --prior "$prior" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "carry-forward"
rm -f "$prior" "$new"

# Dismissal coherence — finding fingerprint matches an active dismissal → fail
dism=$(mktemp)
cat > "$dism" <<'MD'
## src/auth.rs:42 — Token check

**Fingerprint:** `src/auth.rs:42:token_check`

Reason: x
MD
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"REQUEST_CHANGES","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[
    {"id":"F1","severity":"HIGH","category":"Bug","file":"src/auth.rs","line":42,
     "end_line":null,"summary":"Token check","fingerprint":"src/auth.rs:42:token_check",
     "reviewers_agreeing":["claude"],"carried_from":null}
  ],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":["F1"]},
  "dismissed_active":[],
  "obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" --dismissals "$dism" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "dismissal"
rm -f "$dism" "$new"

# DISMISSALS.md coverage rule — fingerprint in DISMISSALS but neither in
# dismissed_active nor obsolete_dismissals → fail.
dism=$(mktemp)
cat > "$dism" <<'MD'
## src/x.py:5 — issue

**Fingerprint:** `src/x.py:5:issue`

Reason: y
MD
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],
  "obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" --dismissals "$dism" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "coverage"
rm -f "$dism" "$new"

echo "validate-findings OK"
