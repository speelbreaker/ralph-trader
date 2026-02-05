# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Stack gate scripts now emit inner failure excerpts when parallel guard flags suppress outer excerpts; workflow acceptance overlays include test_parallel_smoke.sh.
- What value it has (what problem it solves, upgrade provides): Restores actionable failure context in parallel stacks without reintroducing nondeterministic FAILED_GATE writes, and ensures smoke-test edits are exercised in dirty-tree acceptance runs.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Parallel stack failures lacked useful excerpts; local acceptance didn’t pick up modified test_parallel_smoke.sh.
- Time/token drain it caused: Extra debugging time to locate root failures and verify smoke changes.
- Workaround I used this PR (exploit): Added inner excerpt emission in stack scripts and added smoke test to overlays/scripts_to_chmod.
- Next-agent default behavior (subordinate): Preserve RUN_LOGGED_* guards but emit inner excerpts when those guards suppress outer logs.
- Permanent fix proposal (elevate): Add a shared helper in verify_utils for stack failure excerpts to keep behavior consistent.
- Smallest increment: Keep excerpt emission local to stack scripts.
- Validation (proof it got better): Verify will now surface inner gate log excerpts on parallel failures; acceptance overlays exercise test_parallel_smoke.sh edits.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Centralize stack excerpt emission into verify_utils and add a small acceptance check that asserts excerpt output on simulated failure.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1) MUST keep RUN_LOGGED_* guards for deterministic FAILED_GATE selection in parallel mode.
  2) SHOULD emit inner excerpts when guards suppress outer excerpts.
  3) MUST include smoke-test scripts in overlays/scripts_to_chmod when they are modified.
