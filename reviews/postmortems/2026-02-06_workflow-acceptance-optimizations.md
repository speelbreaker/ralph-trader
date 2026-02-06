# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added workflow contract gate caching + acceptance test optimizations (Tests 12/12d/0n/0n.1/0k.1/10b/10d/5d), plus PR template linting (template sections + CI job + lint script + exit-code preservation), review checklist expansions, a day/night verification policy (local full verify guard + daily CI schedule + quick day wrappers + pre-push full-verify guard), and checkpoint fingerprint manifest lint + lock/policy acceptance coverage.
- What value it has (what problem it solves, upgrade provides): Reduces workflow acceptance wall time, cuts redundant preflight in acceptance tests, improves nested acceptance reliability, and enforces complete PR postmortem/risk sections with correct CI failure behavior.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Workflow acceptance runs exceeded ~30 minutes; Test 12d ~10m and Test 12 >3m dominated shard wall time; nested acceptance invocations incurred redundant setup.
- Time/token drain it caused: Repeated long acceptance runs slowed iteration and made verification feedback loop the constraint.
- Workaround I used this PR (exploit): Added cached spec/test ID extraction in workflow_contract_gate and reused cache in acceptance tests; forced nested acceptance call in 0n.1 to use archive mode; stubbed PRD preflight in acceptance tests not exercising PRD preflight itself.
- Next-agent default behavior (subordinate): When adding acceptance tests that call workflow_contract_gate or workflow_acceptance.sh, route them through cached/cheap setup modes; stub PRD preflight when not under test.
- Permanent fix proposal (elevate): Extend caching to other slow acceptance paths and reduce repeated full gate invocations by consolidating checks; isolate PRD ref checks in a dedicated acceptance test so other fixtures can skip them safely.
- Smallest increment: Add cache reuse + preflight stubs to remaining slow acceptance tests and measure per-test timings.
- Validation (proof it got better): 12d ~625s → ~282s; 12 ~213s → ~124s; 0n.1 ~203s → ~116s; 0k.1 ~297s → ~103s; 10b ~190s → ~161s; 10d ~184s → ~134s; 5d ~198s → ~112s.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Target remaining slow acceptance tests (e.g., 0k.2/2/3/5d cluster) with preflight stubs or focused fixtures; validate by comparing per-test PASS durations and overall workflow_acceptance wall time.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: When acceptance tests call workflow_acceptance.sh recursively, require WORKFLOW_ACCEPTANCE_SETUP_MODE=archive unless clone/worktree is necessary; require recording per-test timing deltas when optimizing acceptance performance.
