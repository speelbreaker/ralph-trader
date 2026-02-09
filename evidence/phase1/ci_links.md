# Phase 1 CI Links

Links to CI runs for each AUTO gate.

## Run Context
- Date: `2026-02-09`
- Branch: `phase1-evidence-ci`
- Head: `a82bffb5d82c1cdf0be50694946630b6b2305950`
- Hosted CI run: `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668`
- Hosted CI build ID: `21842775668`
- Hosted verify job: `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485`
- Hosted verify job result: `success`
- Workflow result note: overall run `failure` due `pr-template-lint`; verify job is green.
- Local gate test bundle: `evidence/phase1/phase1_gate_tests_20260209_114250.log`

## CI Lookup Result
- Command: `gh run view 21842775668 -R speelbreaker/ralph-trader --json databaseId,displayTitle,headSha,status,conclusion,url,event,jobs`
- Result: run found for PR #113; `verify` job succeeded; workflow failed on unrelated `pr-template-lint`.

| Gate | Test Name | CI Run Link | Build ID | Status |
|------|-----------|-------------|----------|--------|
| P1-A | `test_dispatch_chokepoint_no_direct_exchange_client_usage` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
| P1-A | `test_dispatch_visibility_is_restricted` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
| P1-B | `test_intent_determinism_same_inputs_same_hash` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
| P1-C | `test_rejected_intent_has_no_side_effects` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
| P1-D | `test_intent_id_propagates_to_logs_and_metrics` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
| P1-E | `test_gate_ordering_constraints` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
| P1-F | `test_missing_config_fails_closed` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
| P1-G | `test_crash_mid_intent_no_duplicate_dispatch` | `https://github.com/speelbreaker/ralph-trader/actions/runs/21842775668/job/63031158485` | `21842775668` | ✅ PASS (verify job) |
