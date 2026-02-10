# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added dispatch-map coverage to reject non-canonical amount fields for the instrument kind (e.g., option with qty_usd, perp with qty_coin).
- What value it has (what problem it solves, upgrade provides): Locks in the "exactly one canonical amount" rule so invalid sizing inputs are fail-closed before dispatch mapping.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Story scope limited to dispatch_map/test files; contract-aligned checks needed to be expressed via tests without touching broader reject enums.
- Time/token drain it caused: Careful selection of test-only changes to avoid out-of-scope edits.
- Workaround I used this PR (exploit): Added a focused negative test that exercises the existing rejection path for wrong canonical fields.
- Next-agent default behavior (subordinate): Prefer adding targeted tests within scope to encode contract rules when broader refactors are out of scope.
- Permanent fix proposal (elevate): Add a dedicated story to align reject reasons with ContractsAmountMismatch across dispatch and order_size tests.
- Smallest increment: Update DispatchRejectReason + test_order_size.rs expectations in one scoped change.
- Validation (proof it got better): cargo test -p soldier_core --test test_dispatch_map; ./plans/verify.sh full.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Best follow-up is to align mismatch reject reason with ContractsAmountMismatch and update test_order_size.rs; validate via `cargo test -p soldier_core --test test_order_size` and `./plans/verify.sh full`. Upgrade: wire map_order_size_to_deribit_amount into the production dispatch path with an integration test.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require a quick scope check before changing shared enums or reject reasons to avoid out-of-scope churn.
