# Phase 1 Evidence Pack

**Status:** COMPLETE (local verification)
**Completed:** 2026-02-09
**Head commit:** `0f89186a91250fd5ed019800f1c28bddefe25788`

## Verification Runs
- Full gate: `./plans/verify.sh full`
  - Result: `VERIFY OK (mode=full)`
  - Run ID: `20260209_111228`
  - Artifacts: `artifacts/verify/20260209_111228/`
- Phase 1 gate tests:
  - Log: `evidence/phase1/phase1_gate_tests_20260209_114250.log`
  - Result: all required P1 tests passed

## What was proven
- P1-A: Single dispatch chokepoint is enforced by `test_dispatch_chokepoint_*` and documented in `docs/dispatch_chokepoint.md`.
- P1-B: Deterministic intent bytes/hashes are enforced by `test_intent_determinism_same_inputs_same_hash` with hash artifact `determinism/intent_hashes.txt`.
- P1-C: Rejected intents do not produce persistent side effects, proven by `test_rejected_intent_has_no_side_effects` and documented in `no_side_effects/rejection_cases.md`.
- P1-D: `intent_id`/`run_id` propagation is verified by `test_intent_id_propagates_to_logs_and_metrics` with sample log artifact `traceability/sample_rejection_log.txt`.
- P1-E: Gate ordering constraints are enforced by `test_gate_ordering_constraints` and documented in `docs/intent_gate_invariants.md`.
- P1-F: Missing config fails closed with enumerated reasons via `test_missing_config_fails_closed` and matrix artifact `config_fail_closed/missing_keys_matrix.json`.
- P1-G: Crash-mid-intent replay safety is enforced by `test_crash_mid_intent_no_duplicate_dispatch`; supplemental manual drill is documented in `crash_mid_intent/drill.md`.

## What failed
- No Phase 1 gate failures in the local completion run.
- Hosted CI run `21842775668` failed overall due `pr-template-lint`; the `verify` job itself passed.

## What remains risky
- Overall CI remains red until `pr-template-lint` is resolved; Phase 1 gate evidence is still present via local run artifacts plus hosted verify job output.

---

## Checklist Status

| Item | AUTO Gate | MANUAL Artifact | Status |
|------|-----------|-----------------|--------|
| P1-A | `test_dispatch_chokepoint_*` | `docs/dispatch_chokepoint.md` | ✅ |
| P1-B | `test_intent_determinism_*` | `determinism/intent_hashes.txt` | ✅ |
| P1-C | `test_rejected_intent_*` | `no_side_effects/rejection_cases.md` | ✅ |
| P1-D | `test_intent_id_propagates_*` | `traceability/sample_rejection_log.txt` | ✅ |
| P1-E | `test_gate_ordering_*` | `docs/intent_gate_invariants.md` | ✅ |
| P1-F | `test_missing_config_*` | `config_fail_closed/missing_keys_matrix.json` | ✅ |
| P1-G | `test_crash_mid_intent_*` | `crash_mid_intent/drill.md` (supplemental) | ✅ |

## Owner Sign-Off

1. Can any code path dispatch without the chokepoint? **NO**
   - Evidence: `docs/dispatch_chokepoint.md`, `crates/soldier_core/tests/test_dispatch_chokepoint.rs`
2. Identical frozen inputs → identical intent bytes? **YES**
   - Evidence: `crates/soldier_core/tests/test_intent_determinism.rs`, `evidence/phase1/determinism/intent_hashes.txt`
3. Can rejected intent leave persistent state? **NO**
   - Evidence: `crates/soldier_core/tests/test_rejection_side_effects.rs`, `evidence/phase1/no_side_effects/rejection_cases.md`
4. All logs traceable by intent_id? **YES**
   - Evidence: `crates/soldier_core/tests/test_intent_id_propagation.rs`, `evidence/phase1/traceability/sample_rejection_log.txt`
5. Missing config → fail-closed with enumerated reason? **YES**
   - Evidence: `crates/soldier_core/tests/test_missing_config.rs`, `evidence/phase1/config_fail_closed/missing_keys_matrix.json`

**Phase 1 DONE:** YES
