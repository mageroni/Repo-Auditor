#!/usr/bin/env bash
# collect.sh - Phase A of the Repo Auditor: deterministic evidence collection.
#
# Emits one compact NDJSON evidence record per repository. No LLM involvement.
#
# Cost profile (the reason this script exists):
#   - Repository enumeration: 1 lightweight GraphQL query per 100 repos (~30 queries for a
#     3k-repo org).
#   - Structure: 1 REST call per in-scope repo for the FULL recursive tree. One call returns
#     every path in the repo, replacing the 5-7 directory listings a naive audit would make.
#     Root entries are requested separately only for --shallow or recursive-tree fallback.
#   - Cache hits and skipped repos cost 0 additional calls.
#   => ~1-2 API calls per repo, versus ~7 for the browse-the-repo approach.
#
# Usage:
#   collect.sh --org ORG [options]
#
#   --org ORG              Organization to audit (required).
#   --config FILE          Scope config (default: references/org-policy.yml).
#   --out FILE             NDJSON output path (default: evidence.ndjson).
#   --cache-dir DIR        SHA-keyed evidence cache (default: .repo-auditor-cache).
#   --shard I --of N       Process only shard I of N (1-based). Enables matrix fan-out.
#   --max-repos N          Stop after N in-scope repos (smoke tests only).
#   --no-cache             Ignore the cache and re-collect everything.
#   --shallow              Skip the recursive tree; request root entries only.
#
# Environment:
#   GH_RETRIES             Attempts per GitHub API call before giving up (default: 5).
#                          Transient 5xx responses are retried with exponential backoff.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

ORG=""
CONFIG="$SKILL_DIR/references/org-policy.yml"
OUT="evidence.ndjson"
CACHE_DIR=".repo-auditor-cache"
SHARD=1
OF=1
MAX_REPOS=0
USE_CACHE=1
SHALLOW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)        ORG="$2"; shift 2 ;;
    --config)     CONFIG="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --cache-dir)  CACHE_DIR="$2"; shift 2 ;;
    --shard)      SHARD="$2"; shift 2 ;;
    --of)         OF="$2"; shift 2 ;;
    --max-repos)  MAX_REPOS="$2"; shift 2 ;;
    --no-cache)   USE_CACHE=0; shift ;;
    --shallow)    SHALLOW=1; shift ;;
    -h|--help)    sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "collect.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ORG" ]] || { echo "collect.sh: --org is required" >&2; exit 2; }
command -v gh >/dev/null || { echo "collect.sh: gh is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "collect.sh: jq is required" >&2; exit 2; }

log() { printf '[collect] %s\n' "$*" >&2; }

# GitHub occasionally answers with a transient 5xx (HTTP 502/503) or a network
# blip. Enumeration is a hard dependency of the whole run, so a single blip must
# not abort the audit: retry with exponential backoff before giving up.
GH_RETRIES="${GH_RETRIES:-5}"
gh_retry() {
  local attempt=1 delay=2 rc=0 err out
  err="$(mktemp)"
  out="$(mktemp)"
  while :; do
    rc=0
    # Stdout from each attempt is captured separately so a failed attempt's
    # partial/garbage output is never concatenated with a later successful
    # attempt's output (which previously produced invalid JSON on retry).
    "$@" >"$out" 2>"$err" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      cat "$out"
      rm -f "$err" "$out"
      return 0
    fi
    if [[ "$attempt" -ge "$GH_RETRIES" ]]; then
      cat "$err" >&2
      log "ERROR: '$1 $2' failed after $attempt attempt(s)"
      rm -f "$err" "$out"
      return "$rc"
    fi
    log "WARN: API call failed (attempt $attempt/$GH_RETRIES), retrying in ${delay}s: $(tr '\n' ' ' < "$err" | cut -c1-200)"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# ---------------------------------------------------------------- scope config
# Scope is declared, never inferred. A repo is audited unless a rule excludes it,
# and every excluded repo is still emitted with an explicit reason.
read_cfg() {
  local key="$1" default="$2"
  if [[ ! -f "$CONFIG" ]]; then printf '%s' "$default"; return; fi
  python3 - "$CONFIG" "$key" "$default" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
val = cfg.get("scope", {}).get(sys.argv[2], sys.argv[3])
if isinstance(val, list):
    print("\n".join(str(v) for v in val))
elif isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
PY
}

INCLUDE_ARCHIVED="$(read_cfg include_archived false)"
INCLUDE_FORKS="$(read_cfg include_forks false)"
STALE_MONTHS="$(read_cfg stale_after_months 24)"
EXCLUDE_GLOBS="$(read_cfg exclude_repos '')"
REQUIRE_TOPIC="$(read_cfg require_topic '')"

log "org=$ORG shard=$SHARD/$OF include_archived=$INCLUDE_ARCHIVED include_forks=$INCLUDE_FORKS stale_after_months=$STALE_MONTHS"

mkdir -p "$CACHE_DIR"
: > "$OUT"

# ---------------------------------------------------------- 1. enumerate (GraphQL)
# One lightweight query per 100 repos. Returns the tiering fields and the head SHA used
# as the cache key; file entries are collected separately only when needed.
# shellcheck disable=SC2016  # $org/$cursor are GraphQL variables, not shell expansions
ENUM_QUERY='
query($org: String!, $cursor: String) {
  organization(login: $org) {
    repositories(first: 100, after: $cursor, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        isArchived
        isFork
        isEmpty
        isPrivate
        pushedAt
        primaryLanguage { name }
        licenseInfo { key }
        repositoryTopics(first: 20) { nodes { topic { name } } }
        defaultBranchRef { name target { ... on Commit { oid } } }
        refs(refPrefix: "refs/tags/", first: 5, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
          nodes { name }
        }
      }
    }
  }
}'

REPOS_JSON="$(mktemp)"
trap 'rm -f "$REPOS_JSON"' EXIT

cursor=""
pages=0
: > "$REPOS_JSON"
while :; do
  if [[ -z "$cursor" ]]; then
    page="$(gh_retry gh api graphql -f query="$ENUM_QUERY" -F org="$ORG")"
  else
    page="$(gh_retry gh api graphql -f query="$ENUM_QUERY" -F org="$ORG" -F cursor="$cursor")"
  fi
  jq -c '.data.organization.repositories.nodes[]' <<<"$page" >> "$REPOS_JSON"
  pages=$((pages + 1))
  if [[ "$(jq -r '.data.organization.repositories.pageInfo.hasNextPage' <<<"$page")" != "true" ]]; then
    break
  fi
  cursor="$(jq -r '.data.organization.repositories.pageInfo.endCursor' <<<"$page")"
done

total="$(wc -l < "$REPOS_JSON" | tr -d ' ')"
log "enumerated $total repositories in $pages GraphQL query(ies)"

# ---------------------------------------------------------------- 2. scope + tier
STALE_CUTOFF="$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30*int('${STALE_MONTHS}'))).isoformat())
")"

index=0
in_scope=0
skipped=0
cached=0
tree_calls=0
root_calls=0

fetch_root_paths() {
  local repo="$1" branch="$2" root_tree
  root_tree="$(gh_retry gh api "repos/$ORG/$repo/git/trees/$branch")" || return $?
  jq -c '[.tree[]? | select(.type=="blob") | {p:.path, s:(.size // 0)}]' <<<"$root_tree"
}

while IFS= read -r node; do
  name="$(jq -r '.name' <<<"$node")"

  # Deterministic sharding by repo name: stable across runs, so a shard always
  # covers the same repos and its cache stays warm.
  if [[ "$OF" -gt 1 ]]; then
    bucket="$(( ( $(printf '%s' "$name" | cksum | cut -d' ' -f1) % OF ) + 1 ))"
    if [[ "$bucket" -ne "$SHARD" ]]; then continue; fi
  fi
  index=$((index + 1))

  decision="audit"; reason=""
  archived="$(jq -r '.isArchived' <<<"$node")"
  fork="$(jq -r '.isFork' <<<"$node")"
  empty="$(jq -r '.isEmpty' <<<"$node")"
  pushed="$(jq -r '.pushedAt // ""' <<<"$node")"
  head_sha="$(jq -r '.defaultBranchRef.target.oid // ""' <<<"$node")"
  topics="$(jq -c '[.repositoryTopics.nodes[].topic.name]' <<<"$node")"

  if [[ "$empty" == "true" ]]; then
    decision="skip"; reason="empty"
  elif [[ "$archived" == "true" && "$INCLUDE_ARCHIVED" != "true" ]]; then
    decision="skip"; reason="archived"
  elif [[ "$fork" == "true" && "$INCLUDE_FORKS" != "true" ]]; then
    decision="skip"; reason="fork"
  elif [[ -z "$head_sha" ]]; then
    decision="skip"; reason="no_default_branch"
  elif [[ -n "$pushed" && "$pushed" < "$STALE_CUTOFF" ]]; then
    decision="skip"; reason="stale_gt_${STALE_MONTHS}mo"
  fi

  if [[ "$decision" == "audit" && -n "$EXCLUDE_GLOBS" ]]; then
    while IFS= read -r g; do
      [[ -n "$g" ]] || continue
      # shellcheck disable=SC2053
      if [[ "$name" == $g ]]; then decision="skip"; reason="excluded_by_rule:$g"; break; fi
    done <<<"$EXCLUDE_GLOBS"
  fi

  if [[ "$decision" == "audit" && -n "$REQUIRE_TOPIC" ]]; then
    if ! jq -e --arg t "$REQUIRE_TOPIC" 'index($t)' <<<"$topics" >/dev/null; then
      decision="skip"; reason="missing_required_topic:$REQUIRE_TOPIC"
    fi
  fi

  # Every repo appears in the output, even when skipped. Auditors need to know that
  # all N repos were considered, not "about N".
  if [[ "$decision" == "skip" ]]; then
    skipped=$((skipped + 1))
    jq -cn --arg r "$name" --arg s "$reason" --arg sha "$head_sha" \
      '{repo:$r, status:"SKIPPED", skip_reason:$s, head_sha:$sha, paths:[], from_cache:false}' >> "$OUT"
    continue
  fi

  # ---------------------------------------------------- 3. cache by repo + head SHA
  cache_file="$CACHE_DIR/${name}.${head_sha}.json"
  if [[ "$USE_CACHE" -eq 1 && -f "$cache_file" ]]; then
    cached=$((cached + 1))
    in_scope=$((in_scope + 1))
    jq -c '.from_cache = true' "$cache_file" >> "$OUT"
    if [[ "$MAX_REPOS" -gt 0 && "$in_scope" -ge "$MAX_REPOS" ]]; then break; fi
    continue
  fi

  # ------------------------------------------- 4. one recursive tree call per repo
  branch="$(jq -r '.defaultBranchRef.name' <<<"$node")"
  if [[ "$SHALLOW" -eq 1 ]]; then
    if paths="$(fetch_root_paths "$name" "$branch")"; then
      root_calls=$((root_calls + 1))
    else
      log "WARN $name: root tree fetch failed; recording empty shallow paths"
      paths="[]"
    fi
    truncated=true
  else
    if tree="$(gh_retry gh api "repos/$ORG/$name/git/trees/$branch?recursive=1")"; then
      tree_calls=$((tree_calls + 1))
      paths="$(jq -c '[.tree[]? | select(.type=="blob") | {p:.path, s:(.size // 0)}]' <<<"$tree")"
      truncated="$(jq -r '.truncated // false' <<<"$tree")"
    else
      log "WARN $name: tree fetch failed; falling back to root entries"
      if paths="$(fetch_root_paths "$name" "$branch")"; then
        root_calls=$((root_calls + 1))
      else
        log "WARN $name: root tree fetch failed after recursive-tree failure; recording empty paths"
        paths="[]"
      fi
      truncated=true
    fi
  fi

  paths_file="$(mktemp)"
  printf '%s\n' "$paths" > "$paths_file"
  record="$(jq -cn \
    --arg repo "$name" \
    --arg sha "$head_sha" \
    --argjson node "$node" \
    --slurpfile paths "$paths_file" \
    --argjson truncated "$truncated" \
    '{
       repo: $repo,
       status: "COLLECTED",
       head_sha: $sha,
       default_branch: ($node.defaultBranchRef.name // ""),
       private: $node.isPrivate,
       pushed_at: $node.pushedAt,
       language: ($node.primaryLanguage.name // null),
       license_key: ($node.licenseInfo.key // null),
       topics: [$node.repositoryTopics.nodes[].topic.name],
       has_semver_tag: ([$node.refs.nodes[].name | select(test("^v?[0-9]+[.][0-9]+[.][0-9]+$"))] | length > 0),
       path_count: ($paths[0] | length),
       tree_truncated: $truncated,
       paths: $paths[0],
       from_cache: false
     }')"
  rm -f "$paths_file"

  printf '%s\n' "$record" > "$cache_file"
  printf '%s\n' "$record" >> "$OUT"
  in_scope=$((in_scope + 1))
  if [[ "$MAX_REPOS" -gt 0 && "$in_scope" -ge "$MAX_REPOS" ]]; then break; fi
done < "$REPOS_JSON"

log "shard $SHARD/$OF: considered=$index in_scope=$in_scope skipped=$skipped cache_hits=$cached tree_calls=$tree_calls root_calls=$root_calls"
log "api calls this shard: $pages graphql + $((tree_calls + root_calls)) rest = $((pages + tree_calls + root_calls))"
log "evidence written to $OUT"
