---
name: code-review
description: Reviews pull requests against linked issues by loading issue context via the GitHub MCP Server and validating implementation against the specification. Use this skill when reviewing pull requests for issue alignment, implementation correctness, type safety, error handling, test coverage, and performance concerns.
---

# Code Review

## Context & Validation

1. Inspect the pull request title, description, linked references, branch name, commits, and review discussion for:
    - A direct link to a GitHub Issue (such as `fixes #<issue-number>`)
    - Issue names or titles mentioned in plain text

2. Use the GitHub MCP Server to load the issue body and all potential comments to identify the specification of the issue you are reviewing. Take that into consideration for the review.
    - Try to identify the main issue and prioritize it, if possible.
    - Other issues may be collateral; only include them if you are absolutely sure they are related to this feature/implementation and not just a follow-up.

## General Review Guidance

When generating suggestions:

1. Prefer incremental, minimal diffs; preserve existing style and naming.
2. Surface security, correctness, and data integrity issues before micro-optimizations.

3. Encourage type safety (no `any` unless justified). Suggest adding/refining model or DTO types when gaps appear.

4. Flag duplicate logic that belongs in a shared utility or repository method.
5. Ensure error handling uses existing custom error types where appropriate (e.g., NotFound, Validation, Conflict) and propagates consistent HTTP status codes via middleware.
6. Encourage tests: request unit tests for new repository logic and component tests (or at least React Testing Library coverage) for critical UI paths.
7. For performance concerns, highlight N+1 query patterns, unnecessary data loading, or large bundle additions.
8. Prefer environment variable driven configuration; avoid hard‑coded paths/secrets.
