# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added core InstrumentMetadata mapping from Deribit metadata values, exported it for venue usage, and added a mapping test that asserts tick_size/amount_step/min_amount/contract_multiplier passthrough plus linear-perp InstrumentKind derivation.
- What value it has (what problem it solves, upgrade provides): Ensures sizing/quantization inputs come directly from `/public/get_instruments` metadata and linear-perp mapping is deterministic, avoiding hardcoded defaults or drift.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Core crate must not depend on infra types; acceptance required metadata passthrough proof without touching `crates/soldier_infra/**`; scope was limited to venue/risk modules.
- Time/token drain it caused: Extra design time to place the mapping at the correct boundary and keep the diff minimal.
- Workaround I used this PR (exploit): Introduced a `soldier_core::venue::InstrumentMetadata::from_deribit` constructor and tested passthrough in-core.
- Next-agent default behavior (subordinate): Prefer adding boundary constructors in `soldier_core::venue` when infra types are out-of-scope.
- Permanent fix proposal (elevate): Add an explicit integration test at the infra→core boundary once ingestion wiring exists.
- Smallest increment: Extend the Deribit ingestion path to produce `InstrumentMetadata` and assert the fields in a unit test.
- Validation (proof it got better): A new test `test_instrument_metadata_uses_get_instruments` passes and captures the passthrough requirement.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire Deribit `/public/get_instruments` ingestion to emit `InstrumentMetadata` into the instrument cache; validate via a focused unit test that compares stored metadata against the raw API payload.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: When acceptance criteria mention raw metadata sources (e.g., `/public/get_instruments`), require a test asserting field passthrough at the boundary (no defaults).
