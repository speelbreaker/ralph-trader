# Proposal: CI Lint for Required PR Template Sections

Date: 2026-02-06
Status: Draft (deferred)
Owner: TBD
Scope: Workflow maintenance (`.github/workflows`, `tools/ci`, docs)

## Problem

We now require richer PR content (including the Architectural Risk Lens), but CI does not enforce that PR descriptions actually contain required sections or non-empty responses.

Current gap:
- `.github/pull_request_template.md` is guidance only.
- Review quality can regress silently when authors remove or leave placeholders in required sections.

## Goal

Fail CI when a PR body is missing required template sections or leaves required fields empty.

## Non-goals

- Linting prose quality or correctness of technical claims.
- Replacing reviewer judgment.
- Parsing every possible Markdown style variation.

## Proposed Design

### 1) Add a dedicated PR body lint script

New script (proposed): `tools/ci/lint_pr_template_sections.py`

Inputs:
- `--body-file <path>` OR `--body <string>`
- `--mode warn|strict` (default `strict`)

Core checks:
- Required section headers exist in PR body:
  - `## 0) What shipped`
  - `## 1) Constraint (ONE)`
  - `## 2) Given what I built...`
  - `## 3) Given what I built and the pain I hit...`
  - `## 4) Architectural Risk Lens (required)`
- Required response lines are not empty or placeholder-only (examples: `TBD`, `TODO`, `n/a`).
- Architectural Risk Lens coverage:
  - each of the 5 numbered items is present
  - each item has either:
    - at least one concrete filled field, or
    - explicit `none` with rationale text (not just `none`)

Policy details (strictness + placeholders):
- Field is considered empty if value is blank after trimming or under a minimum content threshold (`< 12` non-whitespace chars).
- Placeholder-only values are invalid in strict mode:
  - exact (case-insensitive): `tbd`, `todo`, `wip`, `na`, `n/a`, `pending`, `later`
  - prefixed placeholders: `tbd: ...`, `todo: ...`, `wip: ...`
- `none` handling:
  - allowed only as `none: <rationale>` (or `none - <rationale>`) with rationale length `>= 12` non-whitespace chars
  - bare `none`, `none.` or `none -` is invalid
- Section-specific rule:
  - Architectural Risk Lens items may use `none:<rationale>` when genuinely not applicable
  - mandatory core sections (`0`, `1`, `2`, `3`) may not use `none` as full-section response

Output:
- Deterministic, line-oriented failures:
  - `MISSING_SECTION: <header>`
  - `EMPTY_REQUIRED_FIELD: <field>`
  - `ARCH_RISK_INCOMPLETE: <item>`

Exit codes:
- `0` pass
- `1` lint failures
- `2` invalid invocation/input

### 2) Wire a CI job for PR events

Workflow update (proposed): `.github/workflows/ci.yml`

New job:
- `pr-template-lint`
- Trigger: `pull_request`
- Permissions: `contents: read`, `pull-requests: read`
- Steps:
  - run Python script with `github.event.pull_request.body`
  - emit annotations for each failure

Enforcement policy:
- Draft PR (`pull_request.draft == true`): `warn` mode by default
  - reports annotations
  - does not fail job unless `PR_TEMPLATE_LINT_DRAFT_MODE=strict`
- Ready-for-review PR (`pull_request.draft == false`): `strict` mode always
  - lint failures fail the job
- Transition event (`ready_for_review`): re-run in strict mode and block merge if failing

Guardrails:
- If PR body is empty, emit `MISSING_SECTION` for all required headers.
- If body exists but required fields are placeholders-only, emit `EMPTY_REQUIRED_FIELD`/`PLACEHOLDER_FIELD`.
- Linter output must be stable and machine-parsable so CI annotations stay deterministic.

### 3) Add tests for the linter

Proposed tests:
- Unit fixtures under `tools/ci/tests/fixtures/pr_template_lint/`
- Cases:
  - valid complete body
  - missing required header
  - placeholder-only content
  - architectural section with `none` but no rationale
  - architectural section with valid `none + rationale`

## Rollout Plan

Phase 1 (soft-launch, 1 week):
- Draft PRs: warn mode.
- Ready PRs: strict mode.
- Collect false positives and tune placeholder normalization.

Phase 2 (harden):
- Keep draft default as warn (developer ergonomics).
- Enforce strict on all non-draft PRs as required check for merge.
- Optional repo-level toggle to make drafts strict later if signal quality is good.

## Risks and Mitigations

- Risk: false positives due to minor formatting differences.
  - Mitigation: normalize whitespace and allow small header variants.
- Risk: contributors bypass template by editing PR body structure heavily.
  - Mitigation: check semantic anchors, not exact full text blocks.
- Risk: maintenance burden as template evolves.
  - Mitigation: keep required headers in one constant list in the script.

## Acceptance Criteria

- CI fails when required sections are missing.
- CI fails when required fields are empty/placeholders.
- CI enforces Architectural Risk Lens presence and completeness policy.
- Error messages are actionable and stable.
- Local script execution reproduces CI result.

## Estimate

- Effort: Medium
- Expected payoff: Higher review consistency and lower quality drift in PR narratives.
