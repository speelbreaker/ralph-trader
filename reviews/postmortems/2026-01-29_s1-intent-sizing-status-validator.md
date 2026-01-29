# PR Postmortem (Agent-Filled)

Governing contract: workflow (specs/WORKFLOW_CONTRACT.md)

## 0) What shipped
- Feature/behavior: Enforced sizing invariants (contracts/amount tolerance + errors), intent classification helpers, expiry guard cancel allowance, Deribit instrument metadata mapping, and a status validator fix for registry parsing.
- What value it has (what problem it solves, upgrade provides): Prevents silent sizing errors, ensures fail-closed intent classification, and unblocks status fixture validation by aligning validator parsing with the manifest schema.

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): verify failed with a Python TypeError in tools/validate_status.py when parsing reason registries; /status fixtures could not be validated.
- Time/token drain it caused: repeated verify runs and manual inspection of manifest vs validator expectations.
- Workaround I used this PR (exploit): implemented registry normalization in validate_status.py to accept dict-based registry entries and prevent crashes.
- Next-agent default behavior (subordinate): if status validation fails, check manifest shape vs validator assumptions and normalize codes defensively.
- Permanent fix proposal (elevate): add a unit test for validate_status against the current manifest schema to prevent regressions.
- Smallest increment: add a fixture-level test that loads specs/status/status_reason_registries_manifest.json and validates code extraction.
- Validation (proof it got better): `CONTRACT_COVERAGE_STRICT=0 ./plans/verify.sh` now passes the status fixture validation step.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a dedicated validator test to lock manifest parsing. Smallest increment: a python test that exercises normalize_code_list against ModeReasonCode and OpenPermissionReasonCode. Validate by running the test and ensuring verify step 0d stays green.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Consider adding a rule to keep tooling validators resilient to schema evolution (manifest shape changes must have a test). No additional AGENTS.md rule required beyond that.
