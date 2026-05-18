#!/usr/bin/env python3
"""
Validate findings.json against the rules in spec §4.5.

Usage:
  validate-findings.py <findings.json> [--prior <prior_findings.json>] [--dismissals <DISMISSALS.md>]

Exits 0 on success; 1 with one error per line on stderr on failure.
"""
import argparse
import json
import re
import sys
from pathlib import Path

VERDICTS = {"APPROVE", "APPROVE_WITH_COMMENTS", "REQUEST_CHANGES", "BLOCK"}
SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}
CONFIDENCES = {"HIGH", "MEDIUM", "LOW"}
FINDING_CATEGORIES = {
    "Bug", "Security", "Performance", "Regression",
    "TestCoverage", "Style", "IntentMismatch", "Other",
}
OQ_CATEGORIES = {
    "IntentAmbiguity", "MissingContext", "ConflictingSignals", "OutOfScopeConcern",
}
ID_FINDING_RE = re.compile(r"^F[0-9]+$")
ID_DISMISSED_RE = re.compile(r"^D[0-9]+$")
FINGERPRINT_LINE_RE = re.compile(r"^\*\*Fingerprint:\*\*\s+`([^`]+)`\s*$")
REF_RE = re.compile(r"^[0-9]{8}-[0-9]{6}:(F|D)[0-9]+$")


def fail(errors: list[str], msg: str):
    errors.append(msg)


def require_keys(obj, keys, where, errors):
    for k in keys:
        if k not in obj:
            fail(errors, f"{where}: missing required key '{k}'")


def parse_dismissal_fingerprints(path: Path) -> set[str]:
    fps = set()
    if not path or not path.exists():
        return fps
    for line in path.read_text(encoding="utf-8").splitlines():
        m = FINGERPRINT_LINE_RE.match(line)
        if m:
            fps.add(m.group(1))
    return fps


def expected_verdict(findings):
    if any(f.get("severity") == "CRITICAL" for f in findings):
        return "BLOCK"
    if any(f.get("severity") == "HIGH" for f in findings):
        return "REQUEST_CHANGES"
    if findings:
        return "APPROVE_WITH_COMMENTS"
    return "APPROVE"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("findings")
    ap.add_argument("--prior", default=None, help="path to prior_findings.json (Delta only)")
    ap.add_argument("--dismissals", default=None, help="path to DISMISSALS.md")
    args = ap.parse_args()

    errors: list[str] = []

    # Rule 1: parseable JSON
    try:
        data = json.loads(Path(args.findings).read_text(encoding="utf-8"))
    except Exception as e:
        print(f"rule 1 (parseable JSON): {e}", file=sys.stderr)
        return 1

    # Rule 2: required top-level fields
    top_required = ["round", "verdict", "confidence", "head_sha", "base_sha",
                    "findings", "open_questions", "regression",
                    "dismissed_active", "obsolete_dismissals"]
    require_keys(data, top_required, "top-level", errors)

    def ensure_list(name, value, errs):
        if isinstance(value, list):
            return value
        fail(errs, f"top-level: {name!r} must be an array (got {type(value).__name__})")
        return []

    findings        = ensure_list("findings",            data.get("findings"),            errors)
    dismissed       = ensure_list("dismissed_active",    data.get("dismissed_active"),    errors)
    obsolete        = ensure_list("obsolete_dismissals", data.get("obsolete_dismissals"), errors)
    open_questions  = ensure_list("open_questions",      data.get("open_questions"),      errors)

    regression = data.get("regression", {})
    if not isinstance(regression, dict):
        regression = {}
        fail(errors, "top-level: 'regression' must be an object")

    # Per-finding required fields + types
    for i, f in enumerate(findings):
        where = f"findings[{i}]"
        require_keys(f, ["id", "severity", "category", "file", "line", "end_line",
                         "summary", "fingerprint", "reviewers_agreeing",
                         "carried_from"], where, errors)
        if "line" in f and not (isinstance(f["line"], int) and f["line"] >= 1):
            fail(errors, f"{where}: 'line' must be a positive integer (got {f.get('line')!r})")
        if "id" in f and not ID_FINDING_RE.match(str(f.get("id", ""))):
            fail(errors, f"{where}: 'id' must match ^F[0-9]+$ (got {f.get('id')!r})")

    for i, d in enumerate(dismissed):
        where = f"dismissed_active[{i}]"
        require_keys(d, ["id", "ref", "fingerprint", "severity", "category",
                         "file", "line", "end_line", "summary"], where, errors)
        if "id" in d and not ID_DISMISSED_RE.match(str(d.get("id", ""))):
            fail(errors, f"{where}: 'id' must match ^D[0-9]+$ (got {d.get('id')!r})")

    # Rule 3 (continued): IDs unique within their array
    seen_ids: set = set()
    for i, f in enumerate(findings):
        fid = f.get("id")
        if isinstance(fid, str):
            if fid in seen_ids:
                fail(errors, f"findings[{i}]: duplicate id {fid!r}")
            seen_ids.add(fid)

    seen_ids = set()
    for i, d in enumerate(dismissed):
        did = d.get("id")
        if isinstance(did, str):
            if did in seen_ids:
                fail(errors, f"dismissed_active[{i}]: duplicate id {did!r}")
            seen_ids.add(did)

    # Rule 3: enums
    if data.get("verdict") not in VERDICTS:
        fail(errors, f"verdict: invalid value {data.get('verdict')!r}; must be one of {sorted(VERDICTS)}")
    if data.get("confidence") not in CONFIDENCES:
        fail(errors, f"confidence: invalid value {data.get('confidence')!r}")
    for i, f in enumerate(findings):
        if f.get("severity") not in SEVERITIES:
            fail(errors, f"findings[{i}].severity: invalid value {f.get('severity')!r}")
        if f.get("category") not in FINDING_CATEGORIES:
            fail(errors, f"findings[{i}].category: invalid value {f.get('category')!r}")
    for i, d in enumerate(dismissed):
        if d.get("severity") not in SEVERITIES:
            fail(errors, f"dismissed_active[{i}].severity: invalid value {d.get('severity')!r}")
        if d.get("category") not in FINDING_CATEGORIES:
            fail(errors, f"dismissed_active[{i}].category: invalid value {d.get('category')!r}")
    for i, q in enumerate(open_questions):
        where = f"open_questions[{i}]"
        require_keys(q, ["id", "category", "file", "line", "summary"], where, errors)
        if "line" in q and not (isinstance(q["line"], int) and q["line"] >= 1):
            fail(errors, f"{where}: 'line' must be a positive integer")
        if q.get("category") not in OQ_CATEGORIES:
            fail(errors, f"{where}.category: invalid value {q.get('category')!r}")

    # Rule 4: verdict vs severity rubric (findings only)
    expected = expected_verdict(findings)
    if data.get("verdict") in VERDICTS and data["verdict"] != expected:
        fail(errors, f"rubric mismatch: findings imply verdict {expected!r}, got {data['verdict']!r}")

    # Dismissals on disk
    dism_fps = parse_dismissal_fingerprints(Path(args.dismissals) if args.dismissals else None)

    # Rule 6: dismissal coherence (findings must not match an active dismissal;
    # dismissed_active fingerprints must be in DISMISSALS).
    for i, f in enumerate(findings):
        fp = f.get("fingerprint")
        if fp and fp in dism_fps:
            fail(errors, f"findings[{i}]: fingerprint {fp!r} matches an active dismissal — should have been suppressed")
    if args.dismissals:
        for i, d in enumerate(dismissed):
            fp = d.get("fingerprint")
            if fp and fp not in dism_fps:
                fail(errors, f"dismissed_active[{i}]: fingerprint {fp!r} does not match any active dismissal in DISMISSALS.md")
        for i, o in enumerate(obsolete):
            fp = (o or {}).get("fingerprint")
            if fp and fp not in dism_fps:
                fail(errors, f"obsolete_dismissals[{i}]: fingerprint {fp!r} does not match any active dismissal in DISMISSALS.md")

    # Rule 7: fingerprint plausibility + 8: within-round uniqueness
    seen = {}
    for i, f in enumerate(findings):
        fp = f.get("fingerprint")
        if fp:
            if fp in seen:
                fail(errors, f"fingerprint {fp!r} duplicated (findings[{i}] and {seen[fp]})")
            seen[fp] = f"findings[{i}]"
            parts = fp.split(":", 2)
            if len(parts) != 3:
                fail(errors, f"findings[{i}]: fingerprint {fp!r} does not match <file>:<line>:<slug>")
            elif parts[0] != f.get("file") or str(f.get("line")) != parts[1]:
                fail(errors, f"findings[{i}]: fingerprint {fp!r} not consistent with file={f.get('file')!r} line={f.get('line')!r}")
    for i, d in enumerate(dismissed):
        fp = d.get("fingerprint")
        if fp and fp in seen:
            fail(errors, f"fingerprint {fp!r} duplicated (dismissed_active[{i}] and {seen[fp]})")
        if fp:
            seen[fp] = f"dismissed_active[{i}]"

    # Rule 9: DISMISSALS.md coverage (both modes) — every dism fp must be in
    # dismissed_active ∪ obsolete_dismissals.
    if args.dismissals:
        active_fps = {d.get("fingerprint") for d in dismissed if d.get("fingerprint")}
        obsolete_fps = {(o or {}).get("fingerprint") for o in obsolete if (o or {}).get("fingerprint")}
        for fp in dism_fps:
            if fp not in active_fps and fp not in obsolete_fps:
                fail(errors, f"coverage: DISMISSALS.md entry {fp!r} not classified (neither dismissed_active nor obsolete_dismissals)")

    # Rule 5: carry-forward accounting (Delta only — when --prior is given)
    if args.prior:
        try:
            prior = json.loads(Path(args.prior).read_text(encoding="utf-8"))
        except Exception as e:
            print(f"could not read --prior {args.prior}: {e}", file=sys.stderr)
            return 1
        if not isinstance(prior, list):
            print("--prior must be a JSON array of objects", file=sys.stderr)
            return 1
        carried_refs = {f.get("carried_from") for f in findings if f.get("carried_from")}
        dismissed_refs = {d.get("ref") for d in dismissed if d.get("ref")}
        resolved_refs = set((regression.get("resolved") or []))
        accounted = carried_refs | dismissed_refs | resolved_refs

        # Build a set of valid prior refs for the inverse direction check.
        valid_prior_refs: set = set()
        for p in prior:
            if "id" in p and "_round" in p:
                valid_prior_refs.add(f"{p['_round']}:{p['id']}")
            elif "ref_self" in p:
                valid_prior_refs.add(p["ref_self"])

        # Every carried_from / ref / regression.resolved must refer to a real prior entry.
        for i, f in enumerate(findings):
            cf = f.get("carried_from")
            if cf is not None:
                if not REF_RE.match(str(cf)):
                    fail(errors, f"findings[{i}]: carried_from {cf!r} does not match <YYYYMMDD-HHMMSS>:F|D<n>")
                elif cf not in valid_prior_refs:
                    fail(errors, f"findings[{i}]: carried_from {cf!r} does not refer to a real prior entry")
        for i, d in enumerate(dismissed):
            r = d.get("ref")
            if r is not None:
                if not REF_RE.match(str(r)):
                    fail(errors, f"dismissed_active[{i}]: ref {r!r} does not match <YYYYMMDD-HHMMSS>:F|D<n>")
                elif r not in valid_prior_refs:
                    fail(errors, f"dismissed_active[{i}]: ref {r!r} does not refer to a real prior entry")
        for r in (regression.get("resolved") or []):
            if not REF_RE.match(str(r)):
                fail(errors, f"regression.resolved: {r!r} does not match <YYYYMMDD-HHMMSS>:F|D<n>")
            elif r not in valid_prior_refs:
                fail(errors, f"regression.resolved: {r!r} does not refer to a real prior entry")

        for p in prior:
            ref = None
            # Each prior entry must carry a stable ref. We synthesise from id+round here.
            # Convention used in the spec: <round>:<id>. Round comes from prior round dir's findings.json.
            if "id" in p and "_round" in p:
                ref = f"{p['_round']}:{p['id']}"
            elif "ref_self" in p:
                ref = p["ref_self"]
            else:
                # Skip — caller annotated incorrectly
                continue
            if ref not in accounted:
                fail(errors, f"carry-forward: prior entry {ref!r} not in findings.carried_from, dismissed_active.ref, or regression.resolved")

    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
