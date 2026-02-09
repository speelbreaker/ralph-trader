# P1-G Crash-Mid-Intent Drill (Supplemental)

This drill is supplemental evidence for P1-G. The AUTO gate
`test_crash_mid_intent_no_duplicate_dispatch` exists and passes.

## Trigger
- Simulate process termination after WAL record is persisted and flushed, but before dispatch.
- Test implementation: `crates/soldier_infra/tests/test_crash_mid_intent.rs`.

## Restart Steps
1. Open WAL ledger and write one pending intent with `record_before_dispatch(...)`.
2. Flush and drop the process context (simulated crash before send).
3. Re-open ledger and replay.
4. Dispatch exactly once from replay pending set.
5. Persist replay outcome with `ReplayOutcome::Sent`.
6. Re-open ledger again and replay to confirm no pending duplicates.

## Proof
- Command:
  - `cargo test -p soldier_infra --test test_crash_mid_intent`
- Result:
  - `test test_crash_mid_intent_no_duplicate_dispatch ... ok`
  - `test result: ok. 1 passed; 0 failed`
- Consolidated log:
  - `evidence/phase1/phase1_gate_tests_20260209_114250.log`

## Assertions Demonstrated
- No duplicate dispatch after restart (`dispatch_count == 1`).
- No ghost pending state on second restart (`pending.is_empty()`).
- Record is durably advanced (`latest.sent_ts == Some(200)`).
