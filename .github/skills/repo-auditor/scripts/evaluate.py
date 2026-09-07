#!/usr/bin/env python3
"""evaluate.py - Phase A, part 2: turn evidence records into deterministic verdicts.

Reads the NDJSON produced by collect.sh plus checks.yml, and decides every check whose
class is `deterministic`. No LLM involvement, so results are reproducible: identical
evidence always yields an identical verdict, which is what makes the SHA-keyed cache
sound and makes week-over-week runs diffable.

Checks that cannot be decided here are emitted with an explicit status:
  NOT-ASSESSED   - class is `heuristic` (needs tier 2) or `deep` (needs tier 3)
  NOT-ASSESSABLE - the required API/permission is not granted (detector type `unavailable`)

Neither is ever reported as FAIL. Absence of evidence is not evidence of failure.

Usage:
  evaluate.py --evidence evidence.ndjson [--checks checks.yml] [--out verdicts.ndjson]
              [--tier 1] [--heuristics heuristics.json] [--no-early-exit]
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("evaluate.py: PyYAML is required (pip install pyyaml)")

PASS = "PASS"
FAIL = "FAIL"
WARN = "WARN"
NOT_ASSESSED = "NOT-ASSESSED"
NOT_ASSESSABLE = "NOT-ASSESSABLE"

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def match_paths(paths, globs):
    """Return the paths matching any glob, case-insensitively.

    A bare name (`LICENSE`) matches at the repository root only. A `**/` prefix also
    matches at the root, so `**/runbook*.md` finds both `runbook.md` and `docs/runbook.md`.
    """
    hits = []
    lowered = [(p["p"], p["p"].lower(), p.get("s", 0)) for p in paths]
    for g in globs:
        patterns = [g.lower()]
        if patterns[0].startswith("**/"):
            patterns.append(patterns[0][3:])
        for original, low, size in lowered:
            if any(fnmatch.fnmatch(low, pat) for pat in patterns):
                hits.append((original, size))
    # stable de-duplication
    seen, out = set(), []
    for original, size in hits:
        if original not in seen:
            seen.add(original)
            out.append((original, size))
    return out


def eval_detector(det, record):
    """Return (status, evidence_refs). Only handles detectors decidable from evidence."""
    dtype = det.get("type")
    paths = record.get("paths", [])

    if dtype == "paths_any":
        hits = match_paths(paths, det.get("globs", []))
        min_size = det.get("min_size_bytes")
        if min_size is not None:
            sized = [h for h in hits if h[1] >= min_size]
            if hits and not sized:
                # File exists but is empty: partially met, not a clean failure.
                return WARN, [h[0] for h in hits[:3]]
            hits = sized
        return (PASS, [h[0] for h in hits[:3]]) if hits else (FAIL, [])

    if dtype == "paths_all":
        refs = []
        for g in det.get("globs", []):
            hits = match_paths(paths, [g])
            if not hits:
                return FAIL, refs
            refs.append(hits[0][0])
        return PASS, refs[:3]

    if dtype == "paths_none":
        hits = match_paths(paths, det.get("globs", []))
        return (FAIL, [h[0] for h in hits[:3]]) if hits else (PASS, [])

    if dtype == "field":
        value = record
        for part in det["field"].split("."):
            value = value.get(part) if isinstance(value, dict) else None
        op = det.get("op", "is_true")
        if value is None:
            return NOT_ASSESSED, []
        if op == "is_true":
            return (PASS, [f"{det['field']}={value}"]) if value else (FAIL, [f"{det['field']}={value}"])
        if op == "is_false":
            return (PASS, []) if not value else (FAIL, [f"{det['field']}={value}"])
        if op == "not_null":
            return PASS, [f"{det['field']}={value}"]
        return NOT_ASSESSED, []

    if dtype == "any_of":
        refs = []
        for sub in det.get("detectors", []):
            status, sub_refs = eval_detector(sub, record)
            refs.extend(sub_refs)
            if status == PASS:
                return PASS, refs[:3]
        return FAIL, refs[:3]

    if dtype == "unavailable":
        fallback = det.get("fallback_detector")
        if fallback:
            status, refs = eval_detector(fallback, record)
            # A fallback is a proxy, not proof. It can supply supporting evidence but it
            # can never decide the check, so the status stays NOT-ASSESSABLE either way.
            return NOT_ASSESSABLE, refs if status == PASS else []
        return NOT_ASSESSABLE, []

    # search / content_any / manual are resolved in later tiers, not here.
    return NOT_ASSESSED, []


def eval_search(check, record, heuristics):
    """Resolve a `search` detector from the org-wide search results (tier 2)."""
    entry = (heuristics or {}).get("queries", {}).get(check["id"])
    if not entry or entry.get("repos") is None:
        return NOT_ASSESSED, []
    hit = record["repo"] in entry["repos"]
    polarity = entry.get("polarity", "positive")
    ref = [f"code-search hit: {entry['query'][:60]}"]
    if hit:
        # Negative polarity: a hit is a possible problem, never an automatic FAIL. The
        # match still has to be reviewed in context - docs and fixtures are not violations.
        return (PASS, ref) if polarity == "positive" else (WARN, ref)
    if entry.get("capped"):
        # The query hit GitHub's 1,000-result ceiling, so "no hit" may only mean the repo
        # fell outside the returned window. Absence of evidence is not evidence of failure.
        return NOT_ASSESSED, []
    return (FAIL, []) if polarity == "positive" else (PASS, [])


def derive_scaffold(record, approved):
    """Resolve check 1.2 against the once-per-run scaffold cache.

    Returns None when no scaffold is declared, so the check reports NOT-ASSESSED
    rather than FAIL: an undeclared scaffold is check 1.1's finding, not 1.2's.
    """
    if not approved:
        return None
    names = {n.lower() for n in approved}
    for topic in record.get("topics", []):
        if topic.lower() in names:
            return {"declared": topic, "approved": True}
    for entry in record.get("paths", []):
        head = entry["p"].split("/")[0].lower()
        if head in names:
            return {"declared": head, "approved": True}
    return None


def evaluate_repo(record, checks, tier, early_exit=True, heuristics=None):
    results = {}
    gate_failed = False

    # Gate pillar first. A repo can only PASS overall when the mandatory-file checks
    # pass, so evaluating them first lets everything else be skipped for repos that
    # already cannot pass. Run #13 spent its whole budget auditing repos that were
    # all missing Bancolombia.MD.
    ordered = sorted(checks, key=lambda c: (c["pillar"] != "mandatory_files", c["id"]))

    for check in ordered:
        cid = check["id"]
        det = check.get("detector", {})
        cls = check.get("class")

        if gate_failed and early_exit and check["pillar"] != "mandatory_files":
            results[cid] = {"status": NOT_ASSESSED, "reason": "early_exit_gate_failed", "refs": []}
            continue

        if cls == "deep":
            # Never FAIL a deep check from absence of evidence in bulk mode.
            results[cid] = {"status": NOT_ASSESSED, "reason": "requires_tier_3", "refs": []}
            continue

        if cls == "heuristic" and tier < 2:
            results[cid] = {"status": NOT_ASSESSED, "reason": "requires_tier_2", "refs": []}
            continue

        # A conditional check is only meaningful for repos it applies to (e.g. image
        # scanning on repos that build an image). Not applicable is not a failure.
        applies_when = det.get("applies_when")
        if applies_when and applies_when in results and results[applies_when]["status"] != PASS:
            results[cid] = {"status": NOT_ASSESSED, "reason": f"not_applicable ({applies_when})",
                            "refs": []}
            continue

        if det.get("type") == "search":
            status, refs = eval_search(check, record, heuristics)
            results[cid] = {"status": status, "refs": refs}
            if check.get("gate") and status == FAIL:
                gate_failed = True
            continue

        if det.get("type") == "content_any":
            # Needs file bodies; resolved by the tier-2 content pass, not from the tree.
            results[cid] = {"status": NOT_ASSESSED, "reason": "pending_content_scan", "refs": []}
            continue

        status, refs = eval_detector(det, record)
        results[cid] = {"status": status, "refs": refs}

        if check.get("gate") and status == FAIL:
            gate_failed = True

    return results, gate_failed


def overall(results, checks_by_id, gate_failed):
    if gate_failed:
        return "non-compliant"
    fails = [cid for cid, r in results.items() if r["status"] == FAIL]
    warns = [cid for cid, r in results.items() if r["status"] == WARN]
    if any(checks_by_id[cid]["severity"] in ("critical", "high") for cid in fails):
        return "non-compliant"
    if fails or warns:
        return "partial"
    return "compliant"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--evidence", default="evidence.ndjson")
    ap.add_argument("--checks", default=os.path.join(SKILL_DIR, "checks.yml"))
    ap.add_argument("--out", default="verdicts.ndjson")
    ap.add_argument("--tier", type=int, default=1)
    ap.add_argument("--heuristics", default="",
                    help="heuristics.json from scripts/heuristics.sh (required for tier >= 2)")
    ap.add_argument("--scaffolds",
                    default=os.path.join(SKILL_DIR, "references", "approved-scaffolds.json"))
    ap.add_argument("--no-early-exit", action="store_true")
    args = ap.parse_args()

    catalogue = yaml.safe_load(open(args.checks))
    checks = catalogue["checks"]
    checks_by_id = {c["id"]: c for c in checks}

    heuristics = None
    if args.heuristics:
        with open(args.heuristics) as fh:
            heuristics = json.load(fh)
    elif args.tier >= 2:
        print("[evaluate] WARNING: tier >= 2 requested without --heuristics; "
              "search-backed checks will stay NOT-ASSESSED", file=sys.stderr)

    approved_scaffolds = []
    if os.path.exists(args.scaffolds):
        with open(args.scaffolds) as fh:
            approved_scaffolds = json.load(fh).get("scaffolds", [])

    counts = {"compliant": 0, "partial": 0, "non-compliant": 0, "skipped": 0}
    with open(args.evidence) as src, open(args.out, "w") as dst:
        for line in src:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if record.get("status") == "SKIPPED":
                counts["skipped"] += 1
                dst.write(json.dumps({
                    "repo": record["repo"],
                    "status": "SKIPPED",
                    "skip_reason": record.get("skip_reason", ""),
                    "tier": 0,
                    "checks": {},
                }) + "\n")
                continue

            scaffold = derive_scaffold(record, approved_scaffolds)
            if scaffold:
                record["scaffold"] = scaffold

            results, gate_failed = evaluate_repo(
                record, checks, args.tier,
                early_exit=not args.no_early_exit,
                heuristics=heuristics,
            )
            status = overall(results, checks_by_id, gate_failed)
            counts[status] += 1
            dst.write(json.dumps({
                "repo": record["repo"],
                "status": status,
                "tier": args.tier,
                "head_sha": record.get("head_sha", ""),
                "from_cache": record.get("from_cache", False),
                "gate_failed": gate_failed,
                "tree_truncated": record.get("tree_truncated", False),
                "checks": results,
            }) + "\n")

    print(
        "[evaluate] {compliant} compliant / {partial} partial / "
        "{non-compliant} non-compliant / {skipped} skipped -> {out}".format(out=args.out, **counts),
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
