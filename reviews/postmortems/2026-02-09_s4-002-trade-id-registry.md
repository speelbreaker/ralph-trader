# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added a durable trade-id registry with atomic insert-if-absent semantics and duplicate counter; added persistence, restart, and concurrency tests.
- What value it has (what problem it solves, upgrade provides): Prevents duplicate trade processing across WS/REST/restarts and provides observability for duplicate events.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Needed a durable append-before-apply guarantee without touching out-of-scope execution paths; concurrency requirements implied atomic insert with a minimal interface.
- Time/token drain it caused: Extra design time to pick a file-backed registry with a single mutex while staying within scope and testability constraints.
- Workaround I used this PR (exploit): Implemented a file-backed registry with a locked check+append and flush, plus focused tests for restart and concurrency.
- Next-agent default behavior (subordinate): Prefer a minimal persistent registry module with explicit append-before-apply semantics and deterministic tests before wiring into execution paths.
- Permanent fix proposal (elevate): Add a small shared durability helper (append+flush + parse helpers) used by both ledger and trade-id registry to reduce duplication and drift.
- Smallest increment: Extract escape/parse helpers into a store::codec module used by ledger and registry.
- Validation (proof it got better): Fewer duplicated helper implementations; rustfmt/grep shows single codec source; unit tests continue to pass.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire the registry into the WS trade handler so trade_id is recorded before TLSM/position updates; validate with an integration test that simulates duplicate WS trades across restart and confirms no double-apply.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require trade-id registry tests to assert both persistence across restart and concurrency dedupe; disallow append-only registries without explicit append-before-apply documentation in module docs.
