---
emoji: 🛡️
description: Organization-wide compliance audit using Repo Auditor
on:
  schedule: weekly on monday
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  pull-requests: read
  copilot-requests: write
engine: copilot
# Single source of credentials for the whole workflow. gh-aw mints a short-lived
# installation token from the Repo Auditor GitHub App for activation, the GitHub MCP
# server and safe-outputs, so no personal access token secrets are required.
# `repositories` is deliberately left unset here: these operations only ever touch
# this repository, so the fallback token stays scoped to it.
github-app:
  client-id: ${{ vars.REPO_AUDITOR_APP_CLIENT_ID }}
  private-key: ${{ secrets.REPO_AUDITOR_APP_PRIVATE_KEY }}
tools:
  bash:
    true
  github:
    toolsets: [repos, issues, pull_requests]
skills:
  - .github/skills/repo-auditor
# Phase A runs here, before the agent starts: deterministic collection and evaluation
# with no model involvement. The agent only ever sees the aggregated summary, which is
# what keeps the run affordable at organization scale.
steps:
  - name: Mint org-wide App token for evidence collection
    id: audit-app-token
    uses: actions/create-github-app-token@v3.2.0
    with:
      client-id: ${{ vars.REPO_AUDITOR_APP_CLIENT_ID }}
      private-key: ${{ secrets.REPO_AUDITOR_APP_PRIVATE_KEY }}
      # Setting `owner` while omitting `repositories` scopes the token to every
      # repository the App is installed on in the organization, which is exactly
      # the audit surface. This is what replaces the org-wide PAT.
      owner: ${{ github.repository_owner }}
  - name: Restore audit evidence cache
    uses: actions/cache/restore@v6.1.0
    with:
      path: .repo-auditor-cache
      key: repo-auditor-evidence-${{ github.run_id }}
      restore-keys: |
        repo-auditor-evidence-
  - name: Audit - collect evidence and evaluate
    env:
      # Short-lived (1 hour) App installation token. Never a PAT: it expires on its
      # own, its permissions are the App's, and it is auditable as the App identity.
      GH_TOKEN: ${{ steps.audit-app-token.outputs.token }}
      ORG: ${{ github.repository_owner }}
      AUDIT_TIER: "2"
      RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
    run: |
      set -euo pipefail
      SKILL=.github/skills/repo-auditor
      mkdir -p audit-out

      # Org-wide data is fetched once per run, never once per repository.
      "$SKILL/scripts/fetch-scaffolds.sh"

      # Batched GraphQL enumeration + one recursive tree call per in-scope repo.
      # For a very large org, run this as a matrix over --shard I --of N; the bucketing
      # is deterministic, so each shard keeps a stable, warm cache.
      "$SKILL/scripts/collect.sh" --org "$ORG" \
        --out audit-out/evidence.ndjson \
        --cache-dir .repo-auditor-cache

      # One code search per heuristic check for the whole org.
      "$SKILL/scripts/heuristics.sh" --org "$ORG" --out audit-out/heuristics.json

      # Deterministic verdicts: no model, so results are reproducible and diffable.
      python3 "$SKILL/scripts/evaluate.py" \
        --evidence audit-out/evidence.ndjson \
        --tier "$AUDIT_TIER" \
        --heuristics audit-out/heuristics.json \
        --out audit-out/verdicts.ndjson

      # Artifacts plus a length-bounded executive summary.
      python3 "$SKILL/scripts/aggregate.py" audit-out/verdicts.ndjson \
        --org "$ORG" --out-dir audit-out \
        --artifact-url "$RUN_URL"

      echo "### Audit collection complete" >> "$GITHUB_STEP_SUMMARY"
      head -c 2000 audit-out/summary.md >> "$GITHUB_STEP_SUMMARY"
post-steps:
  - name: Upload audit results
    if: always()
    uses: actions/upload-artifact@v7.0.1
    with:
      name: audit-results
      path: audit-out/
      retention-days: 90
  - name: Save audit evidence cache
    if: always()
    uses: actions/cache/save@v6.1.0
    with:
      path: .repo-auditor-cache
      key: repo-auditor-evidence-${{ github.run_id }}
safe-outputs:
  create-issue:
    title-prefix: "Repo-auditor - "
    labels: [repo-auditor, compliance]
    close-older-issues: true
---

# DemoOrg Repository Compliance Audit

## Task

Phase A of the **Repo Auditor** skill has already run in a workflow step before you started.
Its output is in the `audit-out/` directory of the workspace:

| File | Contents |
|---|---|
| `audit-out/summary.md` | Bounded executive summary, ready to publish |
| `audit-out/audit-results.json` | Full per-repository record (also uploaded as an artifact) |
| `audit-out/audit-results.csv` | The same data, flattened |

Your job is Phase B only: interpret those results and publish them.

1. Read `.github/skills/repo-auditor/SKILL.md` so you apply its result vocabulary correctly.
2. Read `audit-out/summary.md`.
3. Query `audit-out/audit-results.json` with `jq` for any specific figure you want to quote.
   Read it selectively — do not print the whole file into your context.
4. Sanity-check the summary before publishing:
   - every cited check id and count matches the underlying data;
   - no `NOT-ASSESSED` or `NOT-ASSESSABLE` check is described as a failure;
   - the repository totals add up (considered = audited + skipped).
5. Create exactly one issue. Its body is the contents of `audit-out/summary.md`, preceded by
   a short paragraph of interpretation: which single remediation would move the most
   repositories, and anything notable about coverage gaps.

### Rules

- **Do not inspect repositories individually.** Phase A already collected the evidence at
  roughly one API call per repository; re-walking repositories with per-repo tool calls is
  the failure mode this design exists to prevent.
- **Do not restate per-repository detail.** Report findings aggregated by check with counts
  (`Bancolombia.MD missing - N/M repos`). The per-repo record lives in the artifact.
- **Do not change scope.** Repositories skipped by rule are listed with their reason; if you
  think an exclusion rule is wrong, say so as a recommendation rather than acting on it.
- If `audit-out/` is missing or empty, the collection step failed. Report that, including the
  step's error output, and call `noop`. Do not attempt to audit the organization by hand.

## Safe Outputs

- Use `create_issue` exactly once to publish the executive summary.
- If no repositories are in scope, call `noop` with a short reason.
