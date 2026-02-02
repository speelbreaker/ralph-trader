# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: workflow acceptance test 10c now writes its non-promo PRD to a temp path under .ralph.
- What value it has (what problem it solves, upgrade provides): avoids no-op commits against tracked fixtures and makes acceptance reruns deterministic.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): full workflow_acceptance run stopped at test 10c; git commit failed because tracked fixture content was unchanged; speedup timing comparison was blocked.
- Time/token drain it caused: ~28 minutes per failed run before the stop.
- Workaround I used this PR (exploit): moved the test PRD to a temp .ralph path so the commit always has a change.
- Next-agent default behavior (subordinate): use temp/ephemeral paths for acceptance fixtures to avoid tracked no-op commits.
- Permanent fix proposal (elevate): add a harness guideline or guard that forbids writing acceptance fixtures to tracked paths unless the test asserts content changes.
- Smallest increment: change test 10c PRD path to `.ralph/valid_prd_10c_non_promo.json`.
- Validation (proof it got better): workflow_acceptance should complete end-to-end; CI verify run is green for this branch.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: run full workflow_acceptance in CI and capture before/after timing for the speedup branch; smallest increment is a CI log note summarizing top 3 slowest tests.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: require acceptance tests to write temporary fixtures under `.ralph/` (or another temp dir) rather than tracked paths; require any acceptance test that commits to ensure a staged diff exists before `git commit`.
