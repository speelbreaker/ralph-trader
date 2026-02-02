# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Fail-closed allowlist validation, stricter --only-set parsing, and acceptance coverage for the new failure modes; review checklist and plan-review skill updates.
- What value it has (what problem it solves, upgrade provides): Prevents silent pass on empty/invalid allowlists and catches typoed --only-set input, reducing false-green verification.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Allowlist validation could mask tool/file errors; empty allowlists weren’t explicitly blocked; acceptance coverage didn’t exercise the new failure paths.
- Time/token drain it caused: Re-review cycles and uncertainty about whether preflight checks were truly fail-closed.
- Workaround I used this PR (exploit): Extracted validation into a shared function and added direct acceptance tests that assert non-zero exit codes and error messages.
- Next-agent default behavior (subordinate): When tightening workflow validators, reuse the same validation path in acceptance tests.
- Permanent fix proposal (elevate): Add an AGENTS.md rule requiring shared validation helpers for workflow checks plus acceptance tests that call the real path.
- Smallest increment: Introduce a helper function and a single focused test before adding more checks.
- Validation (proof it got better): workflow acceptance suite passed locally (including new 0k.11/0k.12 tests).

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Best follow-up PR is to document allowlist validation expectations in the relevant workflow docs and add a brief troubleshooting note. Smallest increment: add a short section to `plans/story_verify_allowlist_check.sh` help or docs and validate via `./plans/workflow_acceptance.sh --only 0k`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  - MUST: When adding a new workflow validation rule, add acceptance coverage that exercises the exact validation path (no re-implemented logic).
  - SHOULD: Any new fail-closed check must assert non-zero exit and a specific error message in acceptance tests.
  - SHOULD: If a plan references validator behavior, open the validator script and note the source-of-truth fields.
