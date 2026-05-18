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

# --- findings=null produces a clean validation error (not a traceback) ---
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings": null,
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "must be an array"
case "$out" in *"Traceback"*) echo "FAIL: should produce clean error, not traceback"; exit 1 ;; esac
rm -f "$new"

# --- duplicate ID within findings[] fails ---
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"BLOCK","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[
    {"id":"F1","severity":"CRITICAL","category":"Bug","file":"x.py","line":1,
     "end_line":null,"summary":"a","fingerprint":"x.py:1:a",
     "reviewers_agreeing":["claude"],"carried_from":null},
    {"id":"F1","severity":"CRITICAL","category":"Bug","file":"x.py","line":2,
     "end_line":null,"summary":"b","fingerprint":"x.py:2:b",
     "reviewers_agreeing":["claude"],"carried_from":null}
  ],
  "open_questions":[],
  "regression":{"resolved":[],"newly_introduced":["F1"]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "duplicate id"
rm -f "$new"

# --- open_questions missing required sub-field fails ---
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"APPROVE","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[],
  "open_questions":[{"category":"IntentAmbiguity"}],
  "regression":{"resolved":[],"newly_introduced":[]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "missing required key 'id'"
rm -f "$new"

# --- carried_from must point to a real prior reference ---
prior=$(mktemp)
echo '[{"_round":"20260518-130000","id":"F1","fingerprint":"a.py:10:x","severity":"HIGH","_was_dismissed":false}]' > "$prior"
new=$(mktemp)
cat > "$new" <<'JSON'
{
  "round":"X","verdict":"REQUEST_CHANGES","confidence":"HIGH","head_sha":"a","base_sha":"b",
  "findings":[
    {"id":"F1","severity":"HIGH","category":"Bug","file":"a.py","line":10,
     "end_line":null,"summary":"x","fingerprint":"a.py:10:x",
     "reviewers_agreeing":["claude"],"carried_from":"99999999-999999:F99"}
  ],
  "open_questions":[],
  "regression":{"resolved":["20260518-130000:F1"],"newly_introduced":[]},
  "dismissed_active":[],"obsolete_dismissals":[]
}
JSON
out=$(python3 "$SCRIPTS/validate-findings.py" "$new" --prior "$prior" 2>&1) && rc=$? || rc=$?
assert_exit 1 "$rc"
assert_contains "$out" "does not refer to a real prior entry"
rm -f "$prior" "$new"

echo "validate-findings OK"
