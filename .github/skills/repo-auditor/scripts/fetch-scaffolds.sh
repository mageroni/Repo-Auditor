#!/usr/bin/env bash
# fetch-scaffolds.sh - refresh the approved scaffold list ONCE per run.
#
# The scaffold list is org-wide, not repo-specific. Fetching it per repository turned
# into 3,000 identical requests at org scale, so it is fetched once here and every
# repository is matched against this cached file.
#
# Uses `gh api` (the workflow grants bash + the github toolset; web/fetch is NOT granted).
#
# Usage: fetch-scaffolds.sh [--repo OWNER/REPO] [--out references/approved-scaffolds.json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

REPO="octodemo/Magero-ApprovedScaffolds"
OUT="$SKILL_DIR/references/approved-scaffolds.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "fetch-scaffolds.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! listing="$(gh api "repos/$REPO/contents/scaffolds" 2>/dev/null)"; then
  echo "[scaffolds] WARN: could not read $REPO/scaffolds; keeping existing cache" >&2
  [[ -f "$OUT" ]] || printf '{"source":"%s","fetched_at":null,"scaffolds":[]}\n' "$REPO" > "$OUT"
  exit 0
fi

jq --arg src "$REPO" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '{source:$src, fetched_at:$at, scaffolds: [.[] | select(.type=="dir") | .name]}' \
   <<<"$listing" > "$OUT"

echo "[scaffolds] cached $(jq '.scaffolds | length' "$OUT") approved scaffold(s) in $OUT" >&2
