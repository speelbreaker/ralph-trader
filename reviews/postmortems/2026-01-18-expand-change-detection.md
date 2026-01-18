# Postmortem

Governing contract: Workflow (specs/WORKFLOW_CONTRACT.md)

0) What shipped
Feature/behavior:
- Expanded python/node change-detection patterns in plans/verify.sh (pyi, poetry/uv, ruff, eslint/prettier, jest/vitest, node version files).
- Added workflow acceptance assertions to prove the new patterns exist.
What value it has (what problem it solves, upgrade provides):
- Ensures python/node gates trigger when config/tooling files change, not just source files.

1) Constraint (ONE)
How it manifested (2-3 concrete symptoms):
- Config-only changes (e.g., ruff/eslint or node version files) did not trigger gates.
- Gate behavior depended on code file changes rather than tooling changes.
- Hard to prove pattern coverage via acceptance tests.
Time/token drain it caused:
- Risk of missing relevant gate runs; follow-up reruns needed to catch issues.
Workaround I used this PR (exploit):
- Manually expanded change-detection patterns and added acceptance checks.
Next-agent default behavior (subordinate):
- Extend patterns only via the existing helpers and add acceptance assertions when workflow files change.
Permanent fix proposal (elevate):
- Maintain a documented, centralized list of config patterns and keep acceptance checks aligned.
Smallest increment:
- Add new patterns + acceptance assertions (as done here).
Validation (proof it got better):
- ./plans/verify.sh full passes and workflow acceptance asserts presence of new patterns.

2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
Response:
- Add any repo-specific config patterns (if needed) to the change-detection helpers and add matching acceptance checks; validate with ./plans/verify.sh full.

3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
Response:
- When modifying workflow change-detection helpers, also add/adjust workflow acceptance assertions and run ./plans/verify.sh full.

Evidence (optional but recommended)
- Command:
  - ./plans/verify.sh full
  - Key output: Workflow acceptance tests passed
  - Artifact/log path: artifacts/verify/20260118_163031
