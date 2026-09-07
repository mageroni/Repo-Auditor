#!/usr/bin/env python3
"""aggregate.py - Phase A, part 3: merge shard verdicts into the run artifacts.

Produces:
  audit-results.json  full machine-readable record, one entry per repo (workflow artifact)
  audit-results.csv   same data, flattened for spreadsheets
  summary.md          BOUNDED executive summary intended for the issue body

The summary is capped (default 40,000 characters, well under GitHub's 65,536 issue-body
limit) so a 3,000-repo run cannot silently truncate. Only the per-repo table is trimmed;
the executive summary and the org-level findings are never dropped.

Findings are aggregated org-wide: "Bancolombia.MD missing - 3000/3000 repos" is one action
item, not 3,000 identical checkboxes.

Usage:
  aggregate.py verdicts*.ndjson [--checks checks.yml] [--out-dir .] [--max-chars 40000]
               [--top-repos 25] [--artifact-url URL]
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("aggregate.py: PyYAML is required (pip install pyyaml)")

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}
SEVERITY_HEADING = {
    "critical": "Critical (must fix before deployment)",
    "high": "High (fix within current sprint)",
    "medium": "Medium (fix within 30 days)",
    "low": "Low / Recommended",
}
STATUS_ICON = {
    "compliant": "PASS",
    "partial": "WARN",
    "non-compliant": "FAIL",
    "SKIPPED": "SKIPPED",
}


def load_verdicts(patterns):
    records, seen = [], set()
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    rec = json.loads(line)
                    # Shards are disjoint, but a re-run of one shard must not double-count.
                    if rec["repo"] in seen:
                        continue
                    seen.add(rec["repo"])
                    records.append(rec)
    return records


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("verdicts", nargs="+")
    ap.add_argument("--checks", default=os.path.join(SKILL_DIR, "checks.yml"))
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--max-chars", type=int, default=40000)
    ap.add_argument("--top-repos", type=int, default=25)
    ap.add_argument("--org", default="")
    ap.add_argument("--artifact-url", default="")
    args = ap.parse_args()

    catalogue = yaml.safe_load(open(args.checks))
    checks_by_id = {c["id"]: c for c in catalogue["checks"]}
    os.makedirs(args.out_dir, exist_ok=True)

    records = load_verdicts(args.verdicts)
    if not records:
        sys.exit("aggregate.py: no verdict records found")

    status_counts = Counter(r["status"] for r in records)
    skip_reasons = Counter(r.get("skip_reason", "") for r in records if r["status"] == "SKIPPED")
    cache_hits = sum(1 for r in records if r.get("from_cache"))

    fail_by_check = defaultdict(list)
    assessed_by_check = Counter()
    not_assessed = Counter()
    for rec in records:
        for cid, result in rec.get("checks", {}).items():
            st = result["status"]
            if st in ("PASS", "FAIL", "WARN"):
                assessed_by_check[cid] += 1
            if st == "FAIL":
                fail_by_check[cid].append(rec["repo"])
            elif st in ("NOT-ASSESSED", "NOT-ASSESSABLE"):
                not_assessed[cid] += 1

    audited = [r for r in records if r["status"] != "SKIPPED"]

    # ------------------------------------------------------------- artifacts
    results_path = os.path.join(args.out_dir, "audit-results.json")
    with open(results_path, "w") as fh:
        json.dump({
            "schema_version": 1,
            "org": args.org,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "checks_version": catalogue.get("version"),
            "totals": {
                "considered": len(records),
                "audited": len(audited),
                **{k: status_counts.get(k, 0)
                   for k in ("compliant", "partial", "non-compliant", "SKIPPED")},
                "cache_hits": cache_hits,
            },
            "repos": records,
        }, fh, indent=2)

    csv_path = os.path.join(args.out_dir, "audit-results.csv")
    check_ids = sorted(checks_by_id, key=lambda c: [int(p) for p in c.split(".")])
    with open(csv_path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["repo", "status", "tier", "gate_failed", "head_sha"] + check_ids)
        for rec in records:
            row = [rec["repo"], rec["status"], rec.get("tier", 0),
                   rec.get("gate_failed", ""), rec.get("head_sha", "")]
            row += [rec.get("checks", {}).get(cid, {}).get("status", "") for cid in check_ids]
            writer.writerow(row)

    # --------------------------------------------------------------- summary
    lines = []
    add = lines.append
    add(f"# Organization Compliance Audit{f' - {args.org}' if args.org else ''}")
    add("")
    add(f"**Generated**: {datetime.now(timezone.utc).isoformat(timespec='seconds')}  ")
    add(f"**Check catalogue version**: {catalogue.get('version')}  ")
    add("**Audited by**: Repo Auditor (bulk-org mode)")
    add("")
    add("## Executive summary")
    add("")
    add("| Metric | Count |")
    add("|---|---|")
    add(f"| Repositories considered | {len(records)} |")
    add(f"| Repositories audited | {len(audited)} |")
    add(f"| Compliant | {status_counts.get('compliant', 0)} |")
    add(f"| Partial | {status_counts.get('partial', 0)} |")
    add(f"| Non-compliant | {status_counts.get('non-compliant', 0)} |")
    add(f"| Skipped by rule | {status_counts.get('SKIPPED', 0)} |")
    add(f"| Reused from cache (unchanged since last run) | {cache_hits} |")
    add("")

    if skip_reasons:
        add("Skip reasons: " + ", ".join(f"`{r}` x{n}" for r, n in skip_reasons.most_common()))
        add("")

    # One finding, many repos.
    add("## Top org-wide findings")
    add("")
    add("| Check | Pillar | Severity | Repos failing | Coverage |")
    add("|---|---|---|---|---|")
    ranked = sorted(
        fail_by_check.items(),
        key=lambda kv: (SEVERITY_ORDER.get(checks_by_id[kv[0]]["severity"], 9), -len(kv[1])),
    )
    for cid, repos in ranked[:10]:
        chk = checks_by_id[cid]
        add(f"| {cid} {chk['title']} | {chk['pillar']} | {chk['severity']} | "
            f"{len(repos)}/{len(audited)} | {assessed_by_check[cid]}/{len(audited)} assessed |")
    if not ranked:
        add("| - | - | - | 0 | - |")
    add("")

    add("## Action items (org level)")
    add("")
    for severity in ("critical", "high", "medium", "low"):
        items = [(cid, repos) for cid, repos in ranked
                 if checks_by_id[cid]["severity"] == severity]
        if not items:
            continue
        add(f"**{SEVERITY_HEADING[severity]}**")
        add("")
        for cid, repos in items:
            chk = checks_by_id[cid]
            add(f"- [ ] {chk['remediation']} (check {cid}, {len(repos)}/{len(audited)} repos)")
        add("")

    if not_assessed:
        add("## Coverage gaps")
        add("")
        add("These checks were not decided for some repositories. They are reported as "
            "NOT-ASSESSED / NOT-ASSESSABLE and are **never** counted as failures.")
        add("")
        add("| Check | Repos not assessed | Class | Reason |")
        add("|---|---|---|---|")
        for cid, n in sorted(not_assessed.items(), key=lambda kv: -kv[1])[:15]:
            chk = checks_by_id[cid]
            det = chk.get("detector", {})
            reason = det.get("requires") if det.get("type") == "unavailable" else f"class={chk['class']}"
            add(f"| {cid} {chk['title']} | {n} | {chk['class']} | {reason} |")
        add("")

    if args.artifact_url:
        add(f"Full per-repo results: [audit-results.json]({args.artifact_url})")
        add("")

    fixed_len = len("\n".join(lines))

    # The per-repo table is the only truncatable section. A fixed reserve keeps room for
    # the "further repositories omitted" note, so the table never ends mid-row.
    OMITTED_NOTE_RESERVE = 200
    table = ["## Worst offenders", "",
             "| Repository | Status | Gate | Failing checks |", "|---|---|---|---|"]
    worst = sorted(
        (r for r in audited if r["status"] != "compliant"),
        key=lambda r: (r["status"] != "non-compliant",
                       -sum(1 for c in r["checks"].values() if c["status"] == "FAIL")),
    )
    used = fixed_len + len("\n".join(table)) + OMITTED_NOTE_RESERVE
    shown = 0
    for rec in worst[:args.top_repos]:
        fails = [cid for cid, c in rec["checks"].items() if c["status"] == "FAIL"]
        row = (f"| `{rec['repo']}` | {STATUS_ICON.get(rec['status'], rec['status'])} | "
               f"{'blocked' if rec.get('gate_failed') else 'ok'} | "
               f"{', '.join(fails[:6]) or '-'}{' ...' if len(fails) > 6 else ''} |")
        if used + len(row) + 1 > args.max_chars:
            break
        used += len(row) + 1
        table.append(row)
        shown += 1
    omitted = len(worst) - shown
    if omitted > 0:
        table.append("")
        table.append(f"_{omitted} further non-compliant repositories omitted for length; "
                     f"see `audit-results.json` for the complete list._")

    summary = "\n".join(lines + table) + "\n"
    if len(summary) > args.max_chars:
        # Defensive: the fixed sections alone exceed the budget. Trim on a line boundary
        # so the output stays valid markdown.
        head = summary[:args.max_chars - 120].rsplit("\n", 1)[0]
        summary = head + "\n\n_Truncated at character budget; see `audit-results.json`._\n"

    summary_path = os.path.join(args.out_dir, "summary.md")
    with open(summary_path, "w") as fh:
        fh.write(summary)

    print(f"[aggregate] {len(records)} repos -> {results_path}, {csv_path}, "
          f"{summary_path} ({len(summary)}/{args.max_chars} chars)", file=sys.stderr)


if __name__ == "__main__":
    main()
