# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added a WAL replay test proving crash mid-intent (RecordedBeforeDispatch, no send) results in exactly one dispatch after restart and none on the second restart.
- What value it has (what problem it solves, upgrade provides): Confirms no duplicate dispatch occurs across restarts when an intent is recorded but unsent at crash time.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Scope required a new test file only; no existing files could be touched; evidence needed to be captured via the test itself.
- Time/token drain it caused: Extra care to model restart/replay using existing ledger APIs without touching implementation code.
- Workaround I used this PR (exploit): Built the proof entirely in an integration test that simulates crash + two restarts via ledger replay.
- Next-agent default behavior (subordinate): Prefer a minimal integration test when scope limits prevent core changes.
- Permanent fix proposal (elevate): Add a small shared test helper for crash/restart WAL scenarios to reduce duplication.
- Smallest increment: Create a helper in `crates/soldier_infra/tests/` used by crash/replay tests.
- Validation (proof it got better): New helper reduces lines per test and keeps restart semantics consistent.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a common `wal_crash_restart` test helper in infra tests; validate by refactoring one existing test (e.g., replay no-resend) to use it and ensuring `cargo test -p soldier_infra --tests` stays green.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None.
