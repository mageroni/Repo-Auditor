# Repo Auditor

Audits repositories against six pillars: approved scaffolds, internal engineering
standards, mandatory files, architecture guidelines, security requirements, and
operational practices.

This skill is designed to run over **thousands of repositories**. It achieves that by
separating deterministic data collection from model judgement: scripts decide everything
that can be decided from a file listing or an API field, and the model only reasons about
what is genuinely ambiguous.

## Files in this skill

| File | Purpose |
|---|---|
| `checks.yml` | The check catalogue. Every check, its class, tier, severity and detector. **Edit rules here, not in prose.** |
| `references/org-policy.yml` | Declared audit scope, tiering thresholds and output budgets. |
| `references/approved-scaffolds.json` | Approved scaffold list, refreshed once per run. |
| `scripts/collect.sh` | Phase A: enumerate repos and gather evidence (NDJSON). |
| `scripts/heuristics.sh` | Tier 2: resolve search-backed checks with org-wide code search. |
| `scripts/evaluate.py` | Phase A: evidence + `checks.yml` → deterministic verdicts. |
| `scripts/aggregate.py` | Merge shards → `audit-results.json`, `.csv` and a bounded `summary.md`. |
| `scripts/fetch-scaffolds.sh` | Refresh the scaffold cache once per run. |
| `scripts/selftest.sh` | Offline verification of the deterministic detectors against fixtures. |

---

## Execution modes

The caller selects the mode. If it is not stated, infer it from the target: one repository
means `single-repo`, an organisation means `bulk-org`.

### `single-repo`

Interactive audit of one repository. Ask the user for the target `owner/repo` if it was not
provided. Inspect the repository directly, run all six pillars including `deep` checks, and
return the full report inline. Per-repo API budget is not constrained.

### `bulk-org`

Scheduled audit of an entire organisation. **Never browse repositories one at a time in
this mode.** Instead:

```bash
SKILL=.github/skills/repo-auditor

# once per run - not once per repository
"$SKILL/scripts/fetch-scaffolds.sh"

# Phase A: deterministic collection (no model involvement)
"$SKILL/scripts/collect.sh" --org "$ORG" --shard "$SHARD" --of "$SHARDS" \
  --out "evidence-$SHARD.ndjson" --cache-dir "$CACHE_DIR"

# Tier 2: one code search per check for the whole org
"$SKILL/scripts/heuristics.sh" --org "$ORG" --out heuristics.json

# Phase A part 2: deterministic verdicts
python3 "$SKILL/scripts/evaluate.py" --evidence "evidence-$SHARD.ndjson" \
  --tier 2 --heuristics heuristics.json --out "verdicts-$SHARD.ndjson"

# after all shards complete
python3 "$SKILL/scripts/aggregate.py" 'verdicts-*.ndjson' --org "$ORG" \
  --out-dir audit-out --artifact-url "$ARTIFACT_URL"
```

**Phase B — model judgement.** The model reads `audit-out/summary.md` and, when needed,
`audit-out/audit-results.json`. It never reads repository contents in bulk mode. Its job is
to interpret aggregated results, sanity-check the top findings, and write the issue body.

If the scripts cannot run, report the failure. Do not silently fall back to browsing
repositories with individual API calls — that is the failure mode this skill exists to prevent.

---

## Scope

Scope is **declared** in `references/org-policy.yml`, never decided by the model at runtime.

- The caller supplies the organisation, optional topic filter, repo-name glob exclusions,
  `include_archived` and `include_forks`.
- **Every repository that is not excluded by a rule must appear in the report**, even if
  only as `SKIPPED` with a reason. An auditor needs to know that all 3,000 repositories
  were considered, not "about 3,000".
- The model must not add, remove or reinterpret exclusions. If a repository looks like it
  should be out of scope (a tooling or meta repository, for example), report it normally and
  raise it as a recommendation to add an exclusion rule. Do not drop it.

---

## Tiering

Evaluated before any check runs.

| Tier | Applies to | Work performed |
|---|---|---|
| **Skip** | archived, empty, forked, no default branch, stale beyond `stale_after_months`, or excluded by rule | none; recorded as `SKIPPED` with a reason |
| **Tier 1** | every in-scope repository | `deterministic` checks only |
| **Tier 2** | repositories passing tier 1, or a sample | `+ heuristic` checks, resolved by org-wide search |
| **Tier 3** | opt-in or sampled; typically repos already failing a gate | `+ deep` checks requiring source reading |

Skipping archived, empty, forked and dormant repositories typically removes 30–50% of a
large organisation before any audit work begins.

### Early exit

A repository can only PASS overall when the mandatory-file pillar (Check 3) fully passes.
Therefore **evaluate Check 3 first**, and stop evaluating a repository once a gating check
fails. Run #13 found `Bancolombia.MD` missing in 100% of repositories; every check performed
on those repositories after that point was wasted work.

Checks skipped by early exit are reported `NOT-ASSESSED` with reason `early_exit_gate_failed`
— they are **not** reported as failures.

---

## Check classification

Every check in `checks.yml` carries a `class`:

**`deterministic`** — decidable from a file listing or an API field (mandatory files, lock
files, `Dockerfile`, IaC extensions, workflow files, `dependabot.yml`, semver tags).
These are decided by `evaluate.py` and **must never consume model tokens**.

**`heuristic`** — decidable from a targeted org-scoped code search (plaintext `http://`,
hardcoded credentials, wildcard CORS, circuit breakers, health endpoints). One
`search/code` query with `org:<ORG>` covers every repository at once: ~12 queries replace
3,000 per-repository inspections.

**`deep`** — genuinely requires reading source (single responsibility, hexagonal
architecture, input validation, audit logging). **Skipped by default in bulk mode**, reported
as `NOT-ASSESSED`, and run only for a sampled subset or for repositories escalated to tier 3.

> **A `deep` check must never be reported as ❌ FAIL from absence of evidence in bulk mode.**
> That rule is what produced the misleading "non-compliant" verdicts in run #13.

---

## Result vocabulary

| Status | Meaning |
|---|---|
| ✅ `PASS` | Requirement met, with a cited artifact. |
| ⚠️ `WARN` | Partially met, or a negative-polarity search hit that needs review in context. |
| ❌ `FAIL` | Requirement demonstrably not met — the artifact was looked for and is absent. |
| ℹ️ `NOT-ASSESSED` | Not evaluated at this tier, skipped by early exit, or not applicable. |
| ℹ️ `NOT-ASSESSABLE` | The data needed is not reachable with the granted permissions. |

Rules:

- **Every `PASS` and `FAIL` must cite a concrete artifact** — a file path, an API field, or a
  search hit. A check with no citation is `NOT-ASSESSED`, never `FAIL`.
- Distinguish *absent* from *uninspectable*. A file that was searched for and is missing is
  `FAIL`. A check that could not be run is `NOT-ASSESSED` / `NOT-ASSESSABLE`.
- A file that exists but is empty or template-only is `WARN`, not `PASS`.
- Conditional checks (`applies_when` in `checks.yml`) are `NOT-ASSESSED` when they do not
  apply. Image scanning is not a failure for a repository that builds no image.

---

## Tool contract

- **`gh` from bash is the primary interface** in bulk mode. MCP tool results are echoed into
  the model's context, so a per-repo MCP call costs both an API round trip and tokens;
  `gh api` from a script costs only the round trip.
- The `github` MCP tool is for `single-repo` mode and for the small number of targeted
  lookups Phase B may need.
- **`web/fetch` is not granted to this workflow.** The approved scaffold list is fetched with
  `gh api` by `scripts/fetch-scaffolds.sh`, **once per run**, into
  `references/approved-scaffolds.json`. Re-fetching it per repository is forbidden.
- Checks 2.10 (branch protection) and 5.7 (secret scanning) require repository administration
  data that the current permissions do not grant. They are declared `unavailable` in
  `checks.yml` and always report `NOT-ASSESSABLE`. They stopped producing false ❌ FAILs.
  To enable them, grant the App `administration: read` and change their detector type.

### Credentials

**One credential for the whole workflow: a GitHub App.** No personal access tokens.

| Value | Kind | Used for |
|---|---|---|
| `vars.REPO_AUDITOR_APP_CLIENT_ID` | org variable | minting installation tokens |
| `secrets.REPO_AUDITOR_APP_PRIVATE_KEY` | org secret | minting installation tokens |

Two tokens are minted per run, each scoped to what it actually needs:

- **Org-wide, for Phase A.** `actions/create-github-app-token` with `owner` set and
  `repositories` omitted, giving read access to every repository the App is installed on.
  This is what `collect.sh` and `heuristics.sh` use, and it is the only token that needs
  org-wide reach.
- **This repository only, for Phase B.** The workflow's top-level `github-app:` config is the
  fallback gh-aw uses for activation, the GitHub MCP server and safe-outputs. It defaults to
  the current repository, which is correct: the agent reads `audit-out/` and files one issue
  here.

Rules:

- Do **not** add `GH_AW_GITHUB_TOKEN`, `GH_AW_GITHUB_MCP_SERVER_TOKEN` or `GH_TOKEN` secrets.
  gh-aw only falls back to those when no App is configured, and a long-lived org-wide PAT is
  both broader than this workflow needs and invisible in the audit log as a distinct identity.
- The App needs, at minimum: repository **Contents: Read** and **Metadata: Read** across the
  org (for enumeration, trees and code search), plus **Issues: Write** on this repository
  (for the report). Add **Administration: Read** only if you enable checks 2.10 / 5.7.
- Install the App **org-wide** ("All repositories"), otherwise the audit silently reports on a
  subset and the "3,000 repositories considered" guarantee in *Scope* is false.
- Installation tokens expire after one hour. A run that exceeds that must shard (see
  *Sharding*) rather than hold a token open.

### Budget

In `bulk-org` mode:

- **No more than 2 API calls per repository.** The design is 1 GraphQL enumeration query per
  100 repositories plus 1 recursive-tree call per in-scope repository.
- Never issue a per-repository call for org-wide data (scaffold list, code search results).
- If a repository appears to need more than 2 calls, record `NOT-ASSESSED` and escalate it to
  tier 3 rather than spending the calls inline.

---

## Prohibited behaviours

- Do **not** decide you "have enough information" and stop early. What to evaluate is
  determined by the tiering rules, not by the model.
- Do **not** exclude repositories from the report on your own judgement.
- Do **not** infer a `FAIL` from a check you did not actually run.
- Do **not** modify audited repositories. This skill is read-only.

---

## Determinism

Identical evidence must produce an identical verdict. `evaluate.py` contains no
model-dependent logic, so:

- Cached and freshly-collected results are directly comparable.
- Week-over-week runs are diffable, and a changed verdict means the repository changed.
- Evidence is cached per `repo + default-branch head SHA`. If the SHA is unchanged since the
  last audit, the cached record is reused. After the first full run, a weekly audit only
  re-collects repositories that actually changed — usually a small fraction of the org.

## Sharding

`collect.sh` accepts `--shard I --of N` and buckets repositories deterministically by name,
so a shard always covers the same repositories and keeps its cache warm. Run the shards as a
workflow matrix (≈30 shards × 100 repos), each uploading a partial `verdicts-*.ndjson`, then
aggregate once at the end. A failed shard can be retried alone without redoing the run.

---

## Output

### Primary artifact

`audit-results.json` (and `audit-results.csv`) — one record per repository with a fixed
schema: `repo`, `status`, `tier`, `gate_failed`, `head_sha`, and a per-check result code with
evidence references. Upload it as a workflow artifact. This is the auditable record and the
basis for week-over-week diffs.

### Issue body

The issue contains the **executive summary only**, generated by `aggregate.py` and capped at
`issue_body_max_chars` (default 40,000, against GitHub's 65,536 hard limit):

1. Totals by status, including repositories considered, skipped and reused from cache.
2. Top 10 failing checks org-wide, ranked by severity then by number of affected repositories.
3. Org-level action items, grouped by severity.
4. Coverage gaps — which checks were `NOT-ASSESSED` / `NOT-ASSESSABLE`, and why.
5. A bounded "worst offenders" table, plus a link to the artifact.

**Only the worst-offenders table may be truncated.** The executive summary, the org-wide
findings and the coverage gaps are never dropped.

### Aggregate findings, do not repeat them

Report one finding per check, with a count:

> `Bancolombia.MD` missing — 3,000/3,000 repositories

Never emit 3,000 identical checkboxes. Per-repository detail belongs in the artifact, or —
when `output.per_repo_issues` is enabled — in an issue opened on the offending repository
rather than in the central report.

---

## Adding or changing a check

Edit `checks.yml` only. Set `id` (never reuse one), `pillar`, `class`, `tier`, `severity`,
`gate`, a `detector`, and the `remediation` text that becomes the action item. Deterministic
detectors are pure functions of the evidence record, so they can be unit-tested against
fixture evidence without touching the network. Run `scripts/selftest.sh` after any change to
`checks.yml` or the evaluator; it needs no token, no network and no model.
