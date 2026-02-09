# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added WAL durability barrier API with `require_wal_fsync_before_dispatch`, barrier wait-time helper, and dispatch durability tests.
- What value it has (what problem it solves, upgrade provides): Allows dispatch to gate on fsync when configured while keeping enqueue non-blocking and fail-closed on queue backpressure.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Scope limited edits to `crates/soldier_infra/src/lib.rs`, new WAL module, and tests; existing ledger module could not be modified.
- Time/token drain it caused: Required duplicating WAL append + serialization logic instead of extending existing ledger implementation.
- Workaround I used this PR (exploit): Implemented a new WAL module (`crates/soldier_infra/src/wal.rs`) with barrier-aware writer loop.
- Next-agent default behavior (subordinate): If scope restricts ledger changes, implement barrier behavior in `wal.rs` and export via `lib.rs`.
- Permanent fix proposal (elevate): Allow ledger module edits in a future story to consolidate durability barrier logic into a single WAL implementation.
- Smallest increment: Move barrier channel handling into `crates/soldier_infra/src/store/ledger.rs` and delete duplicate serialization helpers.
- Validation (proof it got better): `cargo test -p soldier_infra --test test_dispatch_durability`.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Integrate the new WAL durability barrier with the dispatch path and config loader so `require_wal_fsync_before_dispatch` is wired end-to-end; validate with a dispatch integration test plus `./plans/verify.sh full`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: If scope forbids modifying core modules, explicitly document the duplication workaround in the postmortem and add a follow-up idea in `plans/ideas.md` to consolidate.
