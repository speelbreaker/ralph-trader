# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Workflow file allowlist + centralized change-detection module for stack gating.
- What value it has (what problem it solves, upgrade provides): Makes workflow change detection auditable/fail-closed, and consolidates stack gating decisions in one reusable module.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Preflight blocked on missing postmortem; workflow acceptance checks needed updates to point at the new change_detection module; allowlist coverage needed a dedicated test to prevent drift.
- Time/token drain it caused: Lost a verify run and required extra passes to align acceptance wiring + allowlist/test coverage.
- Workaround I used this PR (exploit): Added postmortem entry early and updated acceptance checks to assert allowlist + change_detection coverage.
- Next-agent default behavior (subordinate): Create postmortem entry before running verify; update acceptance tests alongside any workflow/harness change.
- Permanent fix proposal (elevate): Add a small acceptance helper that validates allowlist + change_detection invariants in one place to reduce drift.
- Smallest increment: Centralize allowlist/change_detection checks into a single acceptance test and reference it in the 0k.* suite.
- Validation (proof it got better): One full verify run passes without manual rework; acceptance logs show allowlist + change_detection checks passing.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Implement Phase 1B (parallel stack gate execution) as a follow-up PR; validate with `./plans/verify.sh full` and ensure workflow acceptance remains green.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1) MUST add/update `plans/workflow_files_allowlist.txt` and `plans/tests/test_workflow_allowlist_coverage.sh` whenever `is_workflow_file` semantics change — prevents silent workflow acceptance skips.
  2) MUST update workflow acceptance checks when moving change-detection logic into a new module — prevents stale assertions.
  3) MUST wire new workflow tests into overlays and `scripts_to_chmod` (or invoke via `bash`) in the same PR — prevents acceptance drift.
