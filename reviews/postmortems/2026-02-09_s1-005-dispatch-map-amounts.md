# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Align dispatch mapping to canonical OrderSize amounts, add intent-classification reduce_only helper, and expand dispatch-map tests (canonical amount selection + reject both canonical fields).
- What value it has (what problem it solves, upgrade provides): Ensures Deribit outbound sizing uses the correct canonical units and reduce_only is derived solely from intent classification, with regression coverage for invalid dual-canonical input.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Narrow PRD scope limited changes to dispatch_map/test files; mismatch reason changes would require out-of-scope test updates.
- Time/token drain it caused: Extra care to avoid touching out-of-scope files or running formatting that would spill over.
- Workaround I used this PR (exploit): Kept API changes additive (new helper + enum) and focused tests within allowed paths.
- Next-agent default behavior (subordinate): Confirm scope and existing test expectations before changing shared enums or reject reasons.
- Permanent fix proposal (elevate): Add a dedicated story to align reject reasons with ContractsAmountMismatch and update related tests in scope.
- Smallest increment: Update dispatch_map reject reason plus test_order_size.rs expectations in one scoped change.
- Validation (proof it got better): cargo test -p soldier_core --test test_dispatch_map; ./plans/verify.sh full.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Best follow-up is to align mismatch reject reason with ContractsAmountMismatch and update test_order_size.rs; validate via `cargo test -p soldier_core --test test_order_size` and `./plans/verify.sh full`. Upgrades: wire mapping into the production dispatch path; add an integration test asserting reduce_only is set for close/hedge intents.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule to avoid running cargo fmt when scope excludes unrelated files; require a quick scope check before changing shared reject enums.
