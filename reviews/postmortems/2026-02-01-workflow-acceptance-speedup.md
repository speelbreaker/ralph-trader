# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Add `--only-set` selector to workflow acceptance; switch preflight acceptance test to smoke mode; clarify preflight smoke messaging.
- What value it has (what problem it solves, upgrade provides): Enables targeted, parallelized acceptance runs and reduces preflight test cost in workflow acceptance.
- Governing contract: specs/WORKFLOW_CONTRACT.md (workflow maintenance)

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): workflow acceptance runs were slow; preflight test ran full PRD gate; parallel runner needed multi-id selection.
- Time/token drain it caused: repeated acceptance runs with long runtimes.
- Workaround I used this PR (exploit): added `--only-set` selection and switched test 27 to smoke mode.
- Next-agent default behavior (subordinate): use `--only-set` for focused workflow acceptance reruns.
- Permanent fix proposal (elevate): add documented workflow acceptance speed targets and a dedicated fast path in CI for smoke runs.
- Smallest increment: add a short doc note in workflow acceptance usage plus a CI timing report.
- Validation (proof it got better): workflow acceptance can now shard and target subsets via `--only-set`.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a short usage doc for `--only-set` and the parallel runner; validate by running `./plans/workflow_acceptance.sh --only-set "0e,0f" --list` and a parallel run with `./plans/workflow_acceptance_parallel.sh --jobs 2`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  - SHOULD add a postmortem entry early for workflow PRs to avoid push failures at the end.
