# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added order-type preflight guard for market/stop/linked orders across instrument kinds, with a shared preflight entrypoint invoked by build_order_intent and unit tests.
- What value it has (what problem it solves, upgrade provides): Blocks unsupported order types deterministically before any dispatch path and enforces linked-order gating (default off).
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): PRD required build_order_intent wiring but no existing build_order_intent module; no OrderIntent struct existed in execution yet.
- Time/token drain it caused: Extra repo scanning to confirm the chokepoint wasn't implemented and to avoid conflicting with the future S5.5 story.
- Workaround I used this PR (exploit): Implemented a minimal OrderIntent + build_order_intent wrapper in preflight to enforce the single shared entrypoint without expanding scope.
- Next-agent default behavior (subordinate): Keep build_order_intent as a thin wrapper around preflight until S5.5 consolidates the chokepoint and gate ordering.
- Permanent fix proposal (elevate): Land S5.5 to create execution/build_order_intent.rs, move the chokepoint there, and wire all dispatch paths through it with ordered gates.
- Smallest increment: Introduce build_order_intent.rs with a pass-through to preflight and a test that asserts preflight runs before any other gate.
- Validation (proof it got better): S5.5 tests proving gate ordering and no bypass; verify run passes with the new chokepoint test.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Prioritize S5.5 (single chokepoint build_order_intent) to avoid duplicated intent construction; smallest increment is moving the wrapper into build_order_intent.rs and adding a gate-ordering test, validated by running `cargo test -p soldier_core --test test_build_order_intent` and `./plans/verify.sh full`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None; existing scope and contract checks were sufficient for this change.
