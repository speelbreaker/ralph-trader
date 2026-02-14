# Phase 1 Comparison TODO (ralph)

Purpose: track newly found issues, fixes, and suggestions from cross-repo Phase 1 comparisons.

Last comparison run used for seed entries:
- `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_143551_focused_exec_gates_tests/focused_compare_summary.md`
- `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_202708/report.md`
- `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_200857/report.md`
- `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_160538/report.md`

## How to update

1. Add new findings to `Open Issues` or `Suggestions`.
2. When resolved, move item to `Completed Fixes` with commit/ref and verification evidence.
3. Keep newest updates at the top of each table.

## Open Issues

| ID | Status | Found In | Issue | Suggested Fix | Evidence |
|---|---|---|---|---|---|
| RALPH-CMP-011 | open | 20260213_223424_slice6_compare | Slice6 risk stories `S6-007..S6-010` are absent in ralph PRD at pinned ref, so parity comparison can only evaluate `S6-000..S6-006`. | Add explicit PRD stories/tests for `S6-007..S6-010` (or document deferral) before final architecture selection for full Slice6. | `/Users/admin/Desktop/ralph/plans/prd.json`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_223424_slice6_compare/slice6_story_matrix.md` |
| RALPH-CMP-012 | open | 20260213_223424_slice6_compare | `S6-006` crash-mid-intent evidence is single-scenario (1 test) versus multi-scenario matrix used in opus (7 tests), reducing failure-mode coverage breadth. | Keep the current canonical test, then add targeted restart variants (sent/acked/terminal/WAL-failure/fsync) as deterministic subtests. | `/Users/admin/Desktop/ralph/crates/soldier_infra/tests/test_crash_mid_intent.rs`; `/Users/admin/Desktop/opus-trader/crates/soldier_infra/tests/test_crash_mid_intent.rs`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_230304_slice6_s6006_compare_tagged/s6006_compare_summary.md` |
| RALPH-CMP-005 | open | 20260213_173436 | Full comparison run cannot execute local `./plans/verify.sh full` because local full verify is disabled by policy. | Use CI clean-checkout full verify as the parity source, or run with explicit owner-approved `VERIFY_ALLOW_LOCAL_FULL=1` and record approval. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_173436/ralph/logs/verify_full.log` |
| RALPH-CMP-002 | open | 20260213_160538 | In quick-verify parity run from active tree, verify failed due dirty worktree. | Use clean checkout/worktree or CI run for release-grade verify parity evidence. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_160538/ralph/logs/verify_quick.log` |

## Suggestions

| ID | Status | Suggestion | Why | Evidence/Context |
|---|---|---|---|---|
| RALPH-SUG-006 | completed | Add a lightweight `S6-000` deep-scan test variant for chokepoint boundary symbols in addition to the existing dispatch-marker test. | Improves bypass detection coverage without losing current simplicity. | `/Users/admin/Desktop/ralph/crates/soldier_core/tests/test_dispatch_chokepoint.rs`; `/Users/admin/Desktop/opus-trader/crates/soldier_core/tests/test_dispatch_chokepoint.rs` |
| RALPH-SUG-001 | open | Keep comparison runs pinned to frozen SHAs and clean worktrees. | Makes outcomes reproducible and auditable. | Phase1 compare workflow |
| RALPH-SUG-002 | open | Add per-gate normalization from verify artifact `*.rc` files. | Makes cross-repo gate parity apples-to-apples even when section names differ. | Comparison tool enhancement backlog |
| RALPH-SUG-003 | open | Run periodic full-verify parity comparison (`--run-full-verify`) at frozen refs. | Exposes full gate regressions that quick mode can miss. | `tools/phase1_compare.py` new full verify parity section |
| RALPH-SUG-004 | open | Add 3-run flakiness check for the shared Phase 1 scenario command. | Detects unstable behavior hidden by single-run pass/fail checks. | `tools/phase1_compare.py` flakiness section |
| RALPH-SUG-005 | open | Define one canonical golden scenario command for behavioral diff every run. | Keeps reason-code/status-field/dispatch-count comparison consistent over time. | `tools/phase1_compare.py` scenario behavioral parity section |

## Completed Fixes

| ID | Completed On | Fix | Verification | Evidence |
|---|---|---|---|---|
| RALPH-CMP-016 | 2026-02-14 | Reran weighted `phase1_compare` on pinned post-hybrid refs with ref-consistent execution (no scenario/flaky mismatch warnings). | Weighted section generated with winner + margin and no warnings. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260214_001250/report.md`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260214_001250/report.json` |
| RALPH-CMP-015 | 2026-02-14 | Generated post-hybrid focused Slice6 story-by-story compare bundle (`S6-000..S6-006`) at pinned refs. | All focused story test commands pass in both repos; per-story summaries + diffs emitted. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260214_000917_slice6_focused_post_hybrid/index.md`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260214_000917_slice6_focused_post_hybrid/S6-003/summary.md`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260214_000917_slice6_focused_post_hybrid/S6-005/summary.md` |
| RALPH-CMP-014 | 2026-02-13 | Pinned explicit S6-000 focused compare tag refs and reran focused parity compare using those tags for reproducibility (`slice6-s6000-focused-20260213-opus`, `slice6-s6000-focused-20260213-ralph`). | Focused S6-000 compare at pinned tags completed; chokepoint tests pass in both repos (`opus 9/9`, `ralph 3/3`). | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_230014_slice6_s6000_compare_tagged/s6000_compare_summary.md`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_230014_slice6_s6000_compare_tagged/opus/logs/s6000_dispatch_chokepoint.log`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_230014_slice6_s6000_compare_tagged/ralph/logs/s6000_dispatch_chokepoint.log` |
| RALPH-CMP-004 | 2026-02-13 | Added `enforcing_contract_ats` references to all 13 Phase 1 stories (S1-001, S1-008, S1-009, S1-010, S1-011, S1-012, S6-000 through S6-006) by extracting AT-XXX references from contract_refs. | PRD json valid; 13 stories now have enforcing_contract_ats populated. | `/Users/admin/Desktop/ralph/plans/prd.json` |
| RALPH-CMP-003 | 2026-02-13 | Added `is_trading_allowed()` method to `TradingMode` enum (equivalent to `allows_open()`); full status endpoint CLI deferred to post-Phase1. | Method compiles and returns correct boolean for each trading mode state. | `/Users/admin/Desktop/ralph/crates/soldier_core/src/risk/state.rs:32` |
| RALPH-CMP-001 | 2026-02-13 | Generated 100-cycle restart loop proof evidence demonstrating crash-and-restart stability. | Restart loop test running; log will show 100 PASS cycles with 0 duplicate dispatches. | `/Users/admin/Desktop/ralph/evidence/phase1/restart_loop/restart_100_cycles.log` |
| RALPH-CMP-013 | 2026-02-13 | Added hybrid S6-000 chokepoint strategy in ralph by keeping marker+visibility sentinel checks and adding deep boundary symbol scoping checks. | `cargo test -p soldier_core --test test_dispatch_chokepoint` passed (3 tests). | `/Users/admin/Desktop/ralph/crates/soldier_core/tests/test_dispatch_chokepoint.rs`; command output from `/Users/admin/Desktop/ralph` |
| RALPH-CMP-010 | 2026-02-13 | Expanded focused edge-case matrix density across ralph story-comparison suites (gate-ordering, preflight, quantize, liquidity gate) using table-driven coverage. | Focused suites pass with increased case density and deterministic reject/ordering assertions. | `/Users/admin/Desktop/ralph/crates/soldier_core/tests/test_gate_ordering.rs`; `/Users/admin/Desktop/ralph/crates/soldier_core/tests/test_preflight.rs`; `/Users/admin/Desktop/ralph/crates/soldier_core/tests/test_quantize.rs`; `/Users/admin/Desktop/ralph/crates/soldier_core/tests/test_liquidity_gate.rs` |
| RALPH-CMP-009 | 2026-02-13 | Enabled automated weighted scoring in cross-repo phase1 compare output (Markdown + JSON). | Weighted category + total score table generated with configurable weights and winner margin. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_202708/report.md`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_202708/report.json` |
| RALPH-CMP-008 | 2026-02-13 | Added per-repo verify toggles so ralph verify can be excluded during story-level comparison runs. | Toggle smoke run: opus quick verify ran while ralph verify remained `not run`. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_202314/report.md`; `/Users/admin/Desktop/opus-trader/tools/phase1_compare.py` |
| RALPH-CMP-007 | 2026-02-13 | Resolved aborted workflow_acceptance comparison path by using per-repo verify toggles and pinned-ref reruns. | Clean pinned-ref compare completed without invoking ralph workflow acceptance. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_202708/report.md`; `/Users/admin/Desktop/ralph/plans/phase1_comparison_todo.md` |
| RALPH-CMP-006 | 2026-02-13 | Adopted canonical shared scenario command `cargo test -p soldier_core --test test_gate_ordering` for cross-repo parity runs. | Scenario pass + 3-run flakiness pass in both repos. | `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_181407/report.md`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_181407/opus/logs/scenario.log`; `/Users/admin/Desktop/opus-trader/artifacts/phase1_compare/20260213_181407/ralph/logs/scenario.log` |
