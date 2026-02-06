# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added workflow contract gate caching + acceptance test optimizations (Test 12/12d/0n.1), and added PR template linting (template sections + CI job + lint script).
- What value it has (what problem it solves, upgrade provides): Reduces workflow acceptance wall time and enforces complete PR postmortem sections to prevent missing risk analysis.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Workflow acceptance runs exceeded ~30 minutes; Test 12d ~10m and Test 12 >3m dominated shard wall time; nested acceptance invocations incurred redundant setup.
- Time/token drain it caused: Repeated long acceptance runs slowed iteration and made verification feedback loop the constraint.
- Workaround I used this PR (exploit): Added cached spec/test ID extraction in workflow_contract_gate and reused cache in acceptance tests; forced nested acceptance call in 0n.1 to use archive mode.
- Next-agent default behavior (subordinate): When adding acceptance tests that call workflow_contract_gate or workflow_acceptance.sh, route them through cached/cheap setup modes.
- Permanent fix proposal (elevate): Extend caching to other slow acceptance paths and reduce repeated full gate invocations by consolidating checks.
- Smallest increment: Add cache reuse to remaining slow acceptance tests and measure per-test timings.
- Validation (proof it got better): Test 12d runtime dropped from ~625s to ~282s; Test 12 from ~213s to ~124s; Test 0n.1 from ~203s to ~116s.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Target the next slowest acceptance tests (0k.1, 10b, 10d) with caching/consolidation; validate by comparing per-test PASS durations in acceptance logs and overall wall time.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: When acceptance tests call workflow_acceptance.sh recursively, require WORKFLOW_ACCEPTANCE_SETUP_MODE=archive unless clone/worktree is necessary; require recording per-test timing deltas when optimizing acceptance performance.
