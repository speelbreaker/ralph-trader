# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Deterministic qty/price quantization using integer step/tick rounding, metadata validation, and missing-metadata rejection; added quantization tests.
- What value it has (what problem it solves, upgrade provides): Prevents float rounding drift on exact-step values, enforces safer rounding direction, and fail-closed behavior when metadata is invalid.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Float floor on exact-step inputs (e.g., 1.2/0.1) can under-quantize; contract requires safe rounding; tests lacked boundary coverage.
- Time/token drain it caused: Minor rework to add integer-step helpers and boundary tests.
- Workaround I used this PR (exploit): Quantize via integer step/tick counts with near-integer tolerance; add exact-step test.
- Next-agent default behavior (subordinate): Use integer step/tick helpers and include exact-on-step test cases for quantization changes.
- Permanent fix proposal (elevate): Add a shared quantization utility (or decimal-based helper) reused by dispatch/idempotency paths.
- Smallest increment: Add a reusable helper in execution/quantize for step/tick calculation and reuse across call sites.
- Validation (proof it got better): `cargo test -p soldier_core --test test_quantize` includes exact-step assertions.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire quantize_from_metadata/quantize_steps into the dispatch path (S2.1/S2.2 integration) so downstream hashing uses integer steps. Smallest increment: add a call site in the dispatcher with a focused unit test asserting hash stability; validate with `cargo test -p soldier_core --test test_quantize` and idempotency tests.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None. Existing rules plus boundary tests in `test_quantize` are sufficient for this area.
