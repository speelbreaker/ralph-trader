# Postmortem

Governing contract: Workflow (specs/WORKFLOW_CONTRACT.md)

0) What shipped
Feature/behavior:
- Added unique suffixes to preflight blocked artifacts to avoid timestamp collisions.
- Made workflow acceptance test 5c deterministic by stubbing date and requiring two distinct blocked dirs.
What value it has (what problem it solves, upgrade provides):
- Prevents blocked artifact name collisions in fast CI runs and keeps acceptance deterministic.

1) Constraint (ONE)
How it manifested (2-3 concrete symptoms):
- Workflow acceptance test 5c failed in CI with "expected blocked artifact".
- Blocked artifact names collided when multiple blocks occurred in the same second.
- Local runs were slower, masking the collision.
Time/token drain it caused:
- CI reruns needed to diagnose flaky acceptance failures.
Workaround I used this PR (exploit):
- Added PID+RANDOM suffix and made the test force same-timestamp collisions.
Next-agent default behavior (subordinate):
- Use unique blocked dir naming and keep acceptance tests deterministic under fast CI.
Permanent fix proposal (elevate):
- Ensure all blocked artifact writers use unique suffixes (pid/random or mktemp).
Smallest increment:
- Add uniqueness suffix to write_blocked_basic and assert two blocks with fixed date.
Validation (proof it got better):
- ./plans/verify.sh full passes; test 5c now requires two blocked dirs.

2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
Response:
- Consider standardizing blocked artifact creation through one helper (mktemp-based) and validate via workflow acceptance.

3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
Response:
- When blocked artifact naming changes, add or update a deterministic acceptance test and run ./plans/verify.sh full.

Evidence (optional but recommended)
- Command:
  - ./plans/verify.sh full
  - Key output: Workflow acceptance tests passed
  - Artifact/log path: artifacts/verify/<run_id>
