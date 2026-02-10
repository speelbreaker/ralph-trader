# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Fee model cache staleness evaluation (soft buffer, hard-stale degrade), fee model cache polling helpers, Deribit account summary parsing, and fee cache tests.
- What value it has (what problem it solves, upgrade provides): Enforces fee staleness fail-closed behavior and conservative fees while proving fee tier updates propagate within one polling cycle.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Fee staleness logic needed to be in core while account summary parsing lives in infra; metrics are global and can cross-test bleed.
- Time/token drain it caused: Extra design/iteration to keep dependency direction correct and tests isolated.
- Workaround I used this PR (exploit): Added a core-local FeeModelSnapshot and used a per-test mutex to serialize metric updates.
- Next-agent default behavior (subordinate): Keep fee model staleness logic in core and feed it snapshot inputs; avoid core -> infra dependencies.
- Permanent fix proposal (elevate): Introduce a shared domain-types crate for exchange DTOs consumed by both crates.
- Smallest increment: Create a minimal shared crate that defines FeeModelSnapshot and re-export it.
- Validation (proof it got better): Remove duplicate snapshot structs and ensure tests still pass with a single shared type.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Implement NetEdge to consume FeeModelCache effective rates and add a test proving buffered fees flip a pass to a reject in the soft-stale window. Smallest increment: wire `effective_fee_rate` into NetEdge with a new `test_net_edge_gate_fee_stale_buffer` unit test.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule that core must not depend on infra types; use snapshots or shared crate types. Add a rule to serialize tests that rely on global metric state.
