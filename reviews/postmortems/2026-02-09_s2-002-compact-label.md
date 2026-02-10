# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Implemented compact `s4` label encode/decode with strict <=64 char enforcement; overlength labels reject with `LabelTooLong` and `RiskState::Degraded` (no truncation).
- What value it has (what problem it solves, upgrade provides): Enforces Deribit label length hard limit and prevents unsafe truncation that could break idempotency/collision safety.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Needed a `LabelTooLong` reason code but `RejectReason` lives in `dispatch_map.rs`, which is out-of-scope for S2-002; could not add a shared enum variant without violating scope.
- Time/token drain it caused: Required redesign to keep label-specific reject reason within allowed files.
- Workaround I used this PR (exploit): Added `LabelRejectReason::LabelTooLong` scoped to label encoding and asserted it in tests.
- Next-agent default behavior (subordinate): If a new reason code would require touching a shared enum outside scope, pause and request a scope update before editing shared files.
- Permanent fix proposal (elevate): Extend the shared `RejectReason` enum with `LabelTooLong` and update PRD scope to include the shared enum location for label-related changes.
- Smallest increment: Add `LabelTooLong` to the shared enum with a minimal test proving mapping, after scope update.
- Validation (proof it got better): Compile + targeted tests show the shared reason is used across modules; no duplicate reason types.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire label encoding into the actual order-intent build/dispatch path to enforce the rejection before dispatch and surface `RiskState::Degraded` in status. Smallest increment: call `encode_compact_label` at intent creation and propagate the rejection; validate via a new dispatch test that verifies no dispatch and `RiskState::Degraded` on overlength labels.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule: "If a PRD story requires a new reason code, ensure the shared enum file is in scope or request a scope update before coding".
