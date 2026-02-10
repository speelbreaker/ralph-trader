# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Clarified the dispatch chokepoint doc to name the exact proxy exchange client type (`DispatchStep`) and aligned the chokepoint test messaging to treat `DispatchStep::DispatchAttempt` as the exchange-dispatch marker.
- What value it has (what problem it solves, upgrade provides): Removes ambiguity about the chokepoint symbol used today, so CI and manual evidence stay aligned until a concrete exchange client exists.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): The repo has no concrete exchange client type yet; the doc said "not yet implemented" which violates the roadmap requirement to name a type; the chokepoint test used a dispatch marker but did not label it as the exchange client proxy.
- Time/token drain it caused: Extra review cycles to reconcile acceptance wording with the current code reality.
- Workaround I used this PR (exploit): Treated `DispatchStep::DispatchAttempt` as the exchange-dispatch proxy and documented its type explicitly.
- Next-agent default behavior (subordinate): Use the proxy type in docs/tests until a real client exists; update both when the client is introduced.
- Permanent fix proposal (elevate): Introduce a concrete exchange client type and require the chokepoint test to scan for that type directly.
- Smallest increment: Add a minimal exchange client trait/struct and call it only from `build_order_intent`.
- Validation (proof it got better): `cargo test -p soldier_core --test test_dispatch_chokepoint` passes and fails if the marker appears outside the chokepoint.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Introduce a concrete exchange client type (smallest increment: trait + stub struct) and update the chokepoint test to scan for that type; validate by running `cargo test -p soldier_core --test test_dispatch_chokepoint` and ensuring misuse fails.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Consider a rule that any chokepoint doc must name a concrete symbol used by the test, even if it is a proxy, to avoid doc/test drift.
