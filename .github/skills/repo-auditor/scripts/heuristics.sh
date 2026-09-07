#!/usr/bin/env bash
# heuristics.sh - Tier 2: resolve `heuristic` checks with ORG-SCOPED code search.
#
# One search per check for the whole organisation, not one inspection per repository.
# For a 3,000-repo org this is ~12 API calls instead of ~36,000.
#
# Reads the `search` detectors from checks.yml, runs each query once with `org:<ORG>`,
# and joins the hits back to repositories by name. Repos with no hit are recorded as
# a clean negative for that check - which is meaningful for `polarity: positive`
# checks and is the desired state for `polarity: negative` checks.
#
# Usage:
#   heuristics.sh --org ORG [--checks checks.yml] [--out heuristics.json] [--limit 1000]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

ORG=""
CHECKS="$SKILL_DIR/checks.yml"
OUT="heuristics.json"
LIMIT=1000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)    ORG="$2"; shift 2 ;;
    --checks) CHECKS="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --limit)  LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "heuristics.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ORG" ]] || { echo "heuristics.sh: --org is required" >&2; exit 2; }

log() { printf '[heuristics] %s\n' "$*" >&2; }

mapfile -t SPECS < <(python3 - "$CHECKS" <<'PY'
import sys, yaml
cat = yaml.safe_load(open(sys.argv[1]))
for c in cat["checks"]:
    d = c.get("detector", {})
    if d.get("type") == "search":
        print("\t".join([c["id"], d.get("polarity", "positive"), d["query"]]))
PY
)

log "${#SPECS[@]} search-backed checks to resolve"

# One search covers every repository in the organisation, so cost is per check,
# not per repo. GitHub's code search API returns at most 1,000 results per query;
# beyond that the result set is CAPPED. A hit is still reliable, but the absence of a
# hit no longer proves anything, so capped queries are flagged and evaluate.py
# downgrades their negatives to NOT-ASSESSED instead of emitting false failures.
MAX_PAGES=$(( LIMIT / 100 ))
[[ "$MAX_PAGES" -gt 10 ]] && MAX_PAGES=10
[[ "$MAX_PAGES" -lt 1 ]] && MAX_PAGES=1

echo '{"queries":{}}' > "$OUT"
calls=0
for spec in "${SPECS[@]}"; do
  cid="${spec%%$'\t'*}"; rest="${spec#*$'\t'}"
  polarity="${rest%%$'\t'*}"; query="${rest#*$'\t'}"

  repos="[]"
  total=0
  capped=false
  failed=false
  for ((page = 1; page <= MAX_PAGES; page++)); do
    if ! resp="$(gh api -X GET search/code -f q="$query org:$ORG" \
                   -F per_page=100 -F page="$page" 2>/dev/null)"; then
      # Page 1 failing means no usable result; a later page failing means we keep
      # what we have and treat the result set as capped.
      if [[ "$page" -eq 1 ]]; then failed=true; else capped=true; fi
      break
    fi
    calls=$((calls + 1))
    total="$(jq -r '.total_count // 0' <<<"$resp")"
    repos="$(jq -c --argjson acc "$repos" '($acc + [.items[]?.repository.name]) | unique' <<<"$resp")"
    [[ "$(jq -r '.items | length' <<<"$resp")" -lt 100 ]] && break
    [[ "$page" -eq "$MAX_PAGES" ]] && capped=true
  done

  if [[ "$failed" == true ]]; then
    log "WARN $cid: search failed (rate limit or unsupported query); recording NOT-ASSESSED"
    repos="null"
  fi
  [[ "$total" -gt $(( MAX_PAGES * 100 )) ]] && capped=true

  tmp="$(mktemp)"
  jq --arg cid "$cid" --arg pol "$polarity" --arg q "$query" \
     --argjson repos "$repos" --argjson capped "$capped" --argjson total "$total" \
     '.queries[$cid] = {polarity:$pol, query:$q, repos:$repos, capped:$capped, total_hits:$total}' \
     "$OUT" > "$tmp"
  mv "$tmp" "$OUT"
  log "$cid: ${total} hit(s), $(jq -r --arg c "$cid" '.queries[$c].repos | if . == null then "n/a" else length end' "$OUT") repo(s)$([[ "$capped" == true ]] && echo ' [CAPPED]')"
done

log "resolved with $calls search API call(s) total (not per repo); written to $OUT"
