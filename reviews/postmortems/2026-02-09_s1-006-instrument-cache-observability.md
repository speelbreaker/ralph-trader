# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added TTL observability hooks for instrument cache (structured TTL breach log, cache hit/stale/age metrics, refresh error counter).
- What value it has (what problem it solves, upgrade provides): Makes cache freshness and refresh failures visible for ops and tests.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Needed structured log coverage and new metric hooks without adding dependencies or leaving scope.
- Time/token drain it caused: Minor extra time to wire a test-visible log hook and counter.
- Workaround I used this PR (exploit): Stored the last TTL breach in-memory for tests while still emitting an `eprintln!` structured log.
- Next-agent default behavior (subordinate): Use the same in-memory capture pattern for core structured logs.
- Permanent fix proposal (elevate): Add a small shared observability helper for structured log capture in tests.
- Smallest increment: Introduce a minimal `observability` module with a test log sink.
- Validation (proof it got better): TTL tests now assert the breach event and metric increments.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire metadata refresh paths to call `record_instrument_cache_refresh_error` on failures; validate by simulating a refresh error in a unit test.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None; existing scope and verification rules covered this change.
