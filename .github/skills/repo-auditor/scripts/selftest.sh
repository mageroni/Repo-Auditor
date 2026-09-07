#!/usr/bin/env bash
# selftest.sh - offline check that the deterministic detectors behave as documented.
#
# Runs evaluate.py and aggregate.py against fixture evidence. No network, no gh, no model,
# which is exactly the point: deterministic checks are pure functions of the evidence
# record, so they can be verified without touching the API.
#
# Usage: scripts/selftest.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s (expected %q, got %q)\n' "$1" "$2" "$3"
    fail=1
  fi
}

cat > "$WORK/evidence.ndjson" <<'EOF'
{"repo":"compliant-svc","status":"COLLECTED","head_sha":"a1","default_branch":"main","private":false,"pushed_at":"2026-08-01T00:00:00Z","language":"Go","license_key":"mit","topics":[],"has_semver_tag":true,"tree_truncated":false,"from_cache":false,"paths":[{"p":"LICENSE","s":1068},{"p":"Bancolombia.MD","s":200},{"p":"README.md","s":900},{"p":"CONTRIBUTING.md","s":10},{"p":"SECURITY.md","s":10},{"p":"CODEOWNERS","s":30},{"p":"CHANGELOG.md","s":10},{"p":"Dockerfile","s":300},{"p":"terraform/main.tf","s":100},{"p":".github/workflows/ci.yml","s":800},{"p":".github/dependabot.yml","s":50},{"p":"tests/app_test.go","s":40},{"p":"api/openapi.yaml","s":120},{"p":"go.sum","s":10},{"p":".env.example","s":5},{"p":"docs/runbook.md","s":10},{"p":"docs/slo.md","s":10},{"p":"docs/disaster-recovery.md","s":10},{"p":"docs/incident-response.md","s":10},{"p":".scaffold","s":10},{"p":"environments/dev.tfvars","s":10}]}
{"repo":"gate-fail-svc","status":"COLLECTED","head_sha":"b2","default_branch":"main","private":true,"pushed_at":"2026-08-01T00:00:00Z","language":"Python","license_key":null,"topics":[],"has_semver_tag":false,"tree_truncated":false,"from_cache":false,"paths":[{"p":"README.md","s":10},{"p":"main.py","s":10}]}
{"repo":"empty-license-svc","status":"COLLECTED","head_sha":"c3","default_branch":"main","private":true,"pushed_at":"2026-08-01T00:00:00Z","language":null,"license_key":null,"topics":[],"has_semver_tag":false,"tree_truncated":false,"from_cache":true,"paths":[{"p":"LICENSE","s":0},{"p":"Bancolombia.md","s":5},{"p":"README.md","s":5}]}
{"repo":"archived-svc","status":"SKIPPED","skip_reason":"archived","head_sha":"d4","paths":[],"from_cache":false}
EOF

echo '{"queries":{}}' > "$WORK/heuristics.json"

python3 "$SCRIPT_DIR/evaluate.py" --evidence "$WORK/evidence.ndjson" \
  --checks "$SKILL_DIR/checks.yml" --tier 1 --out "$WORK/verdicts.ndjson" 2>/dev/null

status_of() { jq -r --arg r "$1" 'select(.repo==$r) | .status' "$WORK/verdicts.ndjson"; }
check_of()  { jq -r --arg r "$1" --arg c "$2" 'select(.repo==$r) | .checks[$c].status' "$WORK/verdicts.ndjson"; }
reason_of() { jq -r --arg r "$1" --arg c "$2" 'select(.repo==$r) | .checks[$c].reason // ""' "$WORK/verdicts.ndjson"; }

echo "deterministic detectors"
check "mandatory license found"          PASS "$(check_of compliant-svc 3.1)"
check "mandatory Bancolombia.MD found"   PASS "$(check_of compliant-svc 3.2)"
check "lock file found"                  PASS "$(check_of compliant-svc 2.5)"
check "Dockerfile found"                 PASS "$(check_of compliant-svc 4.4)"
check "IaC found"                        PASS "$(check_of compliant-svc 4.5)"
check "CI workflow found"                PASS "$(check_of compliant-svc 6.1)"
check "dependabot found"                 PASS "$(check_of compliant-svc 6.8)"
check "nested runbook found"             PASS "$(check_of compliant-svc 6.3)"
check "missing mandatory file fails"     FAIL "$(check_of gate-fail-svc 3.2)"
check "empty file warns, not passes"     WARN "$(check_of empty-license-svc 3.1)"

echo "tiering and gates"
check "skipped repo stays SKIPPED"       SKIPPED "$(status_of archived-svc)"
check "gate failure is non-compliant"    non-compliant "$(status_of gate-fail-svc)"
check "early exit after gate failure"    early_exit_gate_failed "$(reason_of gate-fail-svc 4.4)"
check "deep check is never a failure"    NOT-ASSESSED "$(check_of compliant-svc 4.1)"
check "deep check reason is tier 3"      requires_tier_3 "$(reason_of compliant-svc 2.1)"
check "heuristic deferred at tier 1"     NOT-ASSESSED "$(check_of compliant-svc 5.1)"
check "ungranted permission is honest"   NOT-ASSESSABLE "$(check_of compliant-svc 2.10)"

echo "aggregation"
python3 "$SCRIPT_DIR/aggregate.py" "$WORK/verdicts.ndjson" --checks "$SKILL_DIR/checks.yml" \
  --org SelfTest --out-dir "$WORK/out" --max-chars 40000 2>/dev/null
check "considered counts every repo"     4 "$(jq -r '.totals.considered' "$WORK/out/audit-results.json")"
check "audited excludes skipped"         3 "$(jq -r '.totals.audited' "$WORK/out/audit-results.json")"
check "cache hits are reported"          1 "$(jq -r '.totals.cache_hits' "$WORK/out/audit-results.json")"
check "summary respects budget"          ok \
  "$([[ "$(wc -c < "$WORK/out/summary.md")" -le 40000 ]] && echo ok || echo over)"
check "findings are aggregated"          1 \
  "$(grep -c 'Add Bancolombia.MD declaring ownership' "$WORK/out/summary.md")"

python3 - "$WORK/large-paths.json" <<'PY'
import json
import sys

json.dump([{"p": f"src/{i:06d}-{'x' * 100}.txt", "s": i} for i in range(20000)], open(sys.argv[1], "w"))
PY
large_record="$(jq -cn --slurpfile paths "$WORK/large-paths.json" \
  '{path_count: ($paths[0] | length), paths: $paths[0]}')"
check "large paths serialize without argv overflow" 20000 "$(jq -r '.path_count' <<<"$large_record")"

if [[ "$fail" -eq 0 ]]; then
  echo "selftest: all checks passed"
else
  echo "selftest: FAILURES detected" >&2
  exit 1
fi
