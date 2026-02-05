# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Workflow allowlist + change-detection module + parallel stack gate scaffolding.
- What value it has (what problem it solves, upgrade provides): Makes workflow change detection auditable/fail-closed and enables parallel stack execution without log contention.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Preflight blocked on missing postmortem; workflow acceptance checks needed updates across overlays/fixtures; parallel stack scripts initially cleared guard vars.
- Time/token drain it caused: Lost a verify run and required extra passes to align acceptance wiring + guard semantics.
- Workaround I used this PR (exploit): Added postmortem entry early and patched acceptance checks to assert guard preservation.
- Next-agent default behavior (subordinate): Create postmortem entry before running verify; update acceptance tests alongside any workflow/harness change.
- Permanent fix proposal (elevate): Add a lightweight helper in workflow acceptance that validates allowlist + stack guard invariants in one place to reduce drift.
- Smallest increment: Centralize allowlist/guard checks into a single acceptance test and reference it in 0k.* suite.
- Validation (proof it got better): One full verify run passes without manual rework; acceptance logs show new 0k.16/0k.17 tests passing.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Re-enable parallel acceptance cache with isolated per-worker cache dirs; validate via `./plans/workflow_acceptance_parallel.sh --jobs 4` and `./plans/verify.sh full`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1) MUST add/update `plans/workflow_files_allowlist.txt` and `plans/tests/test_workflow_allowlist_coverage.sh` whenever `is_workflow_file` semantics change — prevents silent workflow acceptance skips.
  2) MUST preserve `RUN_LOGGED_*` variables in stack scripts when running via `run_parallel_group` — prevents nondeterministic FAILED_GATE selection.
  3) MUST wire new workflow tests into overlays and `scripts_to_chmod` (or invoke via `bash`) in the same PR — prevents acceptance drift.
