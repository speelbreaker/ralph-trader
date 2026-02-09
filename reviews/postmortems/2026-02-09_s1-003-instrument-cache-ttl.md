# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added deterministic cache-read time injection for InstrumentCache and updated TTL tests to use fixed instants.
- What value it has (what problem it solves, upgrade provides): Removes time-flake risk and proves TTL comparisons against instrument_cache_ttl_s deterministically.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): TTL tests relied on Instant::now() and broad time ranges; deterministic acceptance criteria were only indirectly proven.
- Time/token drain it caused: Risk of reruns if timing variance ever tightened the assertions.
- Workaround I used this PR (exploit): Added get_with_instant() to inject a fixed "now" for cache reads and used it in tests.
- Next-agent default behavior (subordinate): Prefer deterministic time injection for cache/TTL tests.
- Permanent fix proposal (elevate): Add a tiny time-provider helper trait for other time-based guards to standardize deterministic tests.
- Smallest increment: Introduce a single helper in venue/cache or test utilities with a fixed Instant.
- Validation (proof it got better): test_instrument_cache_ttl now asserts exact age (30.0s) without timing slack.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire InstrumentCache freshness into the actual dispatch eligibility path once that surface exists; smallest increment is a helper that converts CacheRead.risk_state into the dispatch gate input, validated by an integration test that blocks OPEN when cache is stale and permits CLOSE/HEDGE/CANCEL.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule to avoid Instant::now in tests when asserting time thresholds; require deterministic time injection or fixed instants.
