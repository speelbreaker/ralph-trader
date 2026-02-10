# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added CI tests enforcing the single dispatch chokepoint marker and visibility guard; documented the chokepoint module/function and dispatch hook.
- What value it has (what problem it solves, upgrade provides): Guards against bypass paths for exchange dispatch by pinning the dispatch marker to a single module and documenting the intended chokepoint.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): No concrete exchange client type exists yet, making it ambiguous which symbol should be treated as the exchange dispatch call; visibility expectations (pub vs pub(crate)) are not yet encoded in code.
- Time/token drain it caused: Extra inspection of execution modules and roadmap to choose a safe, minimal enforcement proxy.
- Workaround I used this PR (exploit): Used the dispatch marker `DispatchStep::DispatchAttempt` and the private helper `record_dispatch_step` as the chokepoint proxy until the exchange client is implemented.
- Next-agent default behavior (subordinate): Keep the tests but update the exchange-client symbol and docs once a concrete client type is added.
- Permanent fix proposal (elevate): Introduce a concrete exchange client type and make the dispatch helper visibility explicit (pub(crate)), then update the chokepoint tests to target that type directly.
- Smallest increment: Add the exchange client struct/trait and wire it into `build_order_intent` as the only dispatch site.
- Validation (proof it got better): `test_dispatch_chokepoint_no_direct_exchange_client_usage` passes with a real exchange client symbol and fails when used elsewhere.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a concrete exchange client type in `soldier_infra` and call it only from `build_order_intent`; update the chokepoint tests to scan for that client symbol and require `pub(crate)` visibility on the dispatch helper, validated by `cargo test -p soldier_core --test test_dispatch_chokepoint`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None; current guidance already covers doc + test requirements for chokepoint proofs.
