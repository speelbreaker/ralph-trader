# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: intent_hash now hashes quantized integer steps (qty_steps, price_ticks) rather than float bits; idempotency tests updated for step-based determinism and timestamp exclusion.
- What value it has (what problem it solves, upgrade provides): removes float-bit drift from the idempotency key and enforces contract-aligned hashing inputs.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): hashing relied on f64 bits; acceptance required step-based inputs; scope avoided quantize/label edits.
- Time/token drain it caused: needed extra test adjustments to prove step-only hashing without touching quantize code.
- Workaround I used this PR (exploit): switched hash input to QuantizedSteps and asserted step equality in tests.
- Next-agent default behavior (subordinate): use QuantizedSteps for any new intent hash call sites.
- Permanent fix proposal (elevate): add a build_order_intent-level test that hashes via QuantizedSteps end-to-end.
- Smallest increment: add a single integration test that wires quantize_steps -> intent_hash.
- Validation (proof it got better): idempotency unit tests now cover step-only hashing and pass.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add an end-to-end build_order_intent test that feeds quantize_steps into intent_hash; validate by asserting hashes match across equivalent quantized inputs.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None; current workflow rules were sufficient.
