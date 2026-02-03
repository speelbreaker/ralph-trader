# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Stabilized workflow acceptance test 10c by forcing a deterministic diff before committing the non-promo PRD file.
- What value it has (what problem it solves, upgrade provides): Prevents empty-commit failures that caused parallel acceptance workers to exit early.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): workflow_acceptance_parallel reported a worker failure; verify quick failed during pre-push; acceptance log stopped before test 10d.
- Time/token drain it caused: repeated long verify runs during push attempts.
- Workaround I used this PR (exploit): force a newline diff on the PRD file before committing in test 10c.
- Next-agent default behavior (subordinate): when a test relies on git commit, guarantee a deterministic diff (or allow-empty).
- Permanent fix proposal (elevate): add a helper in workflow acceptance to create test-only commit diffs safely.
- Smallest increment: append a newline before committing the PRD file in test 10c.
- Validation (proof it got better): workflow acceptance completes without worker failure in the parallel runner.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a small helper for deterministic test diffs in workflow acceptance; validate by running workflow acceptance (full).

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: When acceptance tests depend on commits, ensure a deterministic diff (or use --allow-empty) to avoid empty-commit failures.
