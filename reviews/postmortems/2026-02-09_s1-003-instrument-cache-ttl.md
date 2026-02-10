# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added deterministic InstrumentCache TTL boundary test to keep stale vs fresh behavior precise at the TTL edge.
- What value it has (what problem it solves, upgrade provides): Prevents regressions that could treat exactly-ttl metadata as stale, keeping OPEN gating and RiskState transitions deterministic.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): TTL tests only covered fresh vs stale; no explicit boundary proof; risk of off-by-one drift in cache age comparison.
- Time/token drain it caused: Small but recurring review uncertainty about TTL edge semantics.
- Workaround I used this PR (exploit): Added a boundary test at age == ttl that asserts Healthy and no stale counter increment.
- Next-agent default behavior (subordinate): Add a boundary test whenever staleness or freshness gates use `>` comparisons.
- Permanent fix proposal (elevate): Add a test template rule in AGENTS.md for staleness guards to include boundary coverage.
- Smallest increment: Add a single test to the guard’s existing test file.
- Validation (proof it got better): `cargo test -p soldier_core --test test_instrument_cache_ttl` passes with boundary coverage.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a dedicated test for `instrument_cache_ttl_s = 3600` default in this file, validate by running `cargo test -p soldier_core --test test_instrument_cache_ttl`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule: any staleness guard must include a boundary test at exactly TTL to prevent off-by-one regressions.
