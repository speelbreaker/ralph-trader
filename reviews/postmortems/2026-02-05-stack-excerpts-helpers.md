# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Centralized stack excerpt helpers in verify_utils and fixed run_logged_or_exit to preserve failing exit codes.
- What value it has (what problem it solves, upgrade provides): Ensures parallel stack failures surface actionable excerpts and do not mask failures.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Parallel stack failures could exit 0 due to `! run_logged` inversion; helper duplication made fixes drift-prone.
- Time/token drain it caused: Extra debug cycles to recover missing failure context.
- Workaround I used this PR (exploit): Centralized helpers and made run_logged_or_exit capture real exit codes.
- Next-agent default behavior (subordinate): Keep helper logic in verify_utils and avoid `! run_logged` when exit codes matter.
- Permanent fix proposal (elevate): Add a small acceptance test that asserts non-zero exit propagation on simulated failure.
- Smallest increment: Centralize helpers without changing gating behavior.
- Validation (proof it got better): CI verify pending.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add acceptance coverage for stack excerpt emission and non-zero propagation.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1) MUST avoid `! run_logged` in helpers that propagate exit codes.
  2) MUST keep stack excerpt helpers centralized in verify_utils.
  3) SHOULD add acceptance coverage when changing stack helper behavior.
