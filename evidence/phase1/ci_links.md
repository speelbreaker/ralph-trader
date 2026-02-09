# Phase 1 CI Links

Links to CI runs for each AUTO gate.

## Run Context
- Date: `2026-02-09`
- Branch: `run/slice1-reimplement`
- Head: `0f89186a91250fd5ed019800f1c28bddefe25788`
- Full verify command: `./plans/verify.sh full`
- Full verify result: `VERIFY OK (mode=full)`
- Full verify run ID: `20260209_111228`
- Full verify artifacts: `artifacts/verify/20260209_111228/`
- Gate test bundle: `evidence/phase1/phase1_gate_tests_20260209_114250.log`

## CI Lookup Result
- Command: `gh run list -R speelbreaker/ralph-trader --branch run/slice1-reimplement --limit 20 --json databaseId,workflowName,displayTitle,headSha,status,conclusion,url,createdAt,updatedAt`
- Result: `[]` (no hosted runs available for this local-only branch snapshot)

| Gate | Test Name | CI Run Link | Build ID | Status |
|------|-----------|-------------|----------|--------|
| P1-A | `test_dispatch_chokepoint_no_direct_exchange_client_usage` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
| P1-A | `test_dispatch_visibility_is_restricted` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
| P1-B | `test_intent_determinism_same_inputs_same_hash` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
| P1-C | `test_rejected_intent_has_no_side_effects` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
| P1-D | `test_intent_id_propagates_to_logs_and_metrics` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
| P1-E | `test_gate_ordering_constraints` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
| P1-F | `test_missing_config_fails_closed` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
| P1-G | `test_crash_mid_intent_no_duplicate_dispatch` | N/A (local-only branch) | `local:phase1_gate_tests_20260209_114250` | ✅ PASS |
