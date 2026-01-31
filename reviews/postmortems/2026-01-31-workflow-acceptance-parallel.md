# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Faster workflow acceptance allowlist check, restored full preflight coverage with smoke mode validation, and a parallel workflow acceptance runner with safer arg handling + macOS bash compatibility.
- What value it has (what problem it solves, upgrade provides): Cuts preflight time, keeps full-path coverage, and enables parallel acceptance runs without shell/arg pitfalls.
- Governing contract: specs/WORKFLOW_CONTRACT.md (workflow maintenance)

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Workflow acceptance runs were slow; smoke mode lost full preflight coverage; parallel runner was fragile on macOS bash and ambiguous CLI parsing.
- Time/token drain it caused: Long acceptance loops and avoidable reruns.
- Workaround I used this PR (exploit): Optimized allowlist set diff, added smoke-specific test while restoring full test, and hardened the parallel runner CLI + bash compatibility.
- Next-agent default behavior (subordinate): Use --smoke for fast schema+allowlist validation; use the parallel runner with --jobs when running full acceptance locally.
- Permanent fix proposal (elevate): Make workflow acceptance IDs unique (no duplicates) and document supported runner CLI patterns.
- Smallest increment: Rename duplicate test IDs and update any references.
- Validation (proof it got better): Acceptance smoke path covered explicitly; parallel runner runs on macOS bash 3.2; full verify passes.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Rename duplicate workflow acceptance IDs (e.g., split 10c into 10c/10c.1) and update any test expectations; validate by running `./plans/workflow_acceptance.sh --list` and a full `./plans/verify.sh`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  - SHOULD keep workflow_acceptance smoke coverage for any new fast mode flag (Trigger: adds a new fast/smoke mode; Prevents: untested fast path; Enforce: add a smoke-mode acceptance test).
  - SHOULD ensure new workflow scripts are added to `plans/verify.sh:is_workflow_file` (Trigger: new file under plans/ used by harness; Prevents: missing acceptance gates; Enforce: verify.sh allowlist check update).
