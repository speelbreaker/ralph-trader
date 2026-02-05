# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Ralph harness now uses a single cleanup trap for lock + state-file release, rotates metrics.jsonl at a size cap, and keeps iteration dirs when archive fails. Added a Ralph loop playbook.
- What value it has (what problem it solves, upgrade provides): Prevents stuck locks after interrupt, bounds metrics growth, avoids losing artifacts on failed tar, and documents operational expectations.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): EXIT trap was overwritten during agent execution; metrics.jsonl grows unbounded; archive failure was silent.
- Time/token drain it caused: Manual cleanup for stale locks and large metrics files; ambiguity when archive fails.
- Workaround I used this PR (exploit): Centralized cleanup trap, added metrics rotation cap, added explicit archive-failure warning.
- Next-agent default behavior (subordinate): When adding new traps, always keep a single cleanup path; keep metrics cap explicit and documented.
- Permanent fix proposal (elevate): Add a behavior-level acceptance test that simulates a failed tar and asserts the iter dir is preserved.
- Smallest increment: Add a tiny fixture-run that forces tar failure in workflow_acceptance.sh.
- Validation (proof it got better): workflow acceptance assertions updated; ./plans/verify.sh passes.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a behavioral acceptance test for failed tar archiving (smallest increment: stub tar to fail in a temp worktree and assert iter dir exists; validate via workflow_acceptance.sh).

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule: "Do not replace existing cleanup traps; consolidate cleanup into a single function and re-use it." Validate by grep in workflow_acceptance.sh.
