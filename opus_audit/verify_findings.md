# Verify Harness Audit: Findings

> Generated: 2026-02-07 | Measured run: `VERIFY_MODE=full` on macOS, 4-core parallel

## 1. Top Time Sinks (measured wall-clock, sorted descending)

| Rank | Gate | Measured | Notes |
|------|------|----------|-------|
| 1 | `workflow_acceptance` (full) | **1807s (30 min) — hit timeout** (119 tests, 4 workers, longest test 319s) | Dominates total verify.sh time (>97% of wall-clock). Tests the harness itself, not the product. |
| 2 | `preflight` | 27s | Mostly `bash -n plans/*.sh` shell syntax validation (~25s of the 27s). |
| 3 | `parallel_smoke` | 7s | Tests verify.sh's own parallel infrastructure. |
| 4 | `status_fixture_*` (6 fixtures) | 3-6s each, ~6s wall-clock (parallel) | Reasonable; parallel execution keeps this fast. |
| 5 | `spec_validators_group` (9 validators) | 2-3s each, ~3s wall-clock (parallel) | Highly efficient; 9 CRITICAL checks in ~3s. |
| 6 | `postmortem_check` | 4s | Trivial cost. |
| 7 | `vendor_docs_lint_rust` | 4s | Trivial cost. |

**Stack gates (Rust/Python/Node)**: All change-skipped in this run. When active:
- `rust_clippy` + `rust_tests_full`: typically 2-15 min combined (the second-biggest time sink after workflow_acceptance)
- `python_pytest_full` + `python_mypy`: typically 30s-2.5 min combined
- `node_test` + `node_typecheck` + `node_lint`: typically 30s-3 min combined

**Total non-workflow-acceptance time (measured)**: ~45s
**Total with workflow_acceptance (measured)**: 1807s (30 min, hit timeout limit). >97% of wall-clock from workflow_acceptance alone.

## 2. High Cost / Low Signal Candidates

| Gate | Cost | Signal | Verdict |
|------|------|--------|---------|
| `workflow_acceptance` (full) | ~10-15 min | Tests harness itself, not product. Useful for harness development only. | **Remove from standard verify.** Run separately when workflow scripts change. |
| `parallel_smoke` | 7s | Tests `run_parallel_group()` internal behavior. Meta-check. | **Remove from standard verify.** Only needed when parallel infra changes. |
| `postmortem_check` | 4s | Process enforcement (PR postmortem exists). No correctness signal. | **Demote to optional.** Process gate, disable locally with POSTMORTEM_GATE=0. |
| `python_ruff_format` | <5s (when active) | Cosmetic formatting. No runtime impact. | **Low priority.** Keep in full, exclude from quick. |
| `integration_smoke` | 30s-5min (when enabled) | Disabled by default. Tests docker-compose health. | Already opt-in. **No change needed.** |
| `e2e` | 1-10min (when enabled) | Disabled by default. Tests UI E2E. | Already opt-in. **No change needed.** |
| `endpoint_gate` | <1s | Heuristic regex pairing (endpoint changes vs test changes). False positives possible. | **Low cost, keep.** Could be improved with project-specific patterns. |

## 3. Redundancy and Overlap

### postmortem_check vs preflight pf-7
- `preflight` (pf-7) checks postmortem entry in `--strict` mode
- `postmortem_check` is a standalone gate doing the same check
- **Overlap**: When preflight runs with `--strict` (CI), pf-7 duplicates postmortem_check
- **Impact**: Low (4s total). Both are process gates, not correctness.
- **Recommendation**: Remove standalone `postmortem_check` gate; rely on preflight pf-7 in strict mode.

### python_pytest_quick fallback to python_pytest_full
- In quick mode, `python_pytest_quick` runs first (`-m "not integration and not slow"`)
- On failure, it falls back to `python_pytest_full` (`pytest -q`)
- **Not true redundancy**: quick mode is a subset. Fallback is a safety net.
- **Issue**: Fallback means quick mode can unexpectedly become slow on failure.
- **Recommendation**: Keep as-is. The fallback catches test infrastructure issues where markers are wrong.

### rust_tests_quick vs rust_tests_full
- `rust_tests_quick`: `cargo test --workspace --lib --locked` (quick mode only)
- `rust_tests_full`: `cargo test --workspace --all-features --locked` (full mode only)
- **Not redundant**: Different modes, different scope (lib-only vs all targets + all features).
- **Recommendation**: Keep as-is. Correct mode separation.

## 4. Workflow/Ralph-Specific Gates (not relevant for product forks)

These gates test the verify.sh/ralph harness itself, not the trading system:

| Gate | Purpose | Fork Relevance |
|------|---------|----------------|
| `workflow_acceptance` | Tests 119 scenarios of the ralph/verify harness | None. Remove entirely in fork. |
| `parallel_smoke` | Tests `run_parallel_group()` bash function | None. Remove in fork. |
| `postmortem_check` | Enforces Ralph PR postmortem process | None. Remove in fork. |
| `endpoint_gate` | Pairs endpoint changes with test changes | Potentially useful but currently generic/heuristic. |
| `preflight` pf-7 | Checks postmortem for BASE_REF | Remove pf-7 sub-check in fork. Keep rest of preflight. |

## 5. Structural Observations

### Spec validators are the best-designed gate group
- 9 CRITICAL validators run in parallel (2-3s each, ~3s wall-clock total)
- All share the same skip logic via `decide_skip_gate "spec_validators_group"`
- Individual `.time` and `.status` artifacts per validator
- Pattern should be replicated for other parallel groups

### Status fixtures are well-structured
- 6 fixtures validated in parallel, each with individual timing
- Using exact schema (not minimum schema) is the right choice
- Manifest-based reason registry validation prevents drift

### preflight is heavier than expected
- 27s is dominated by `bash -n plans/*.sh` (shell syntax check on all plan scripts)
- As the number of `.sh` files grows, this will get slower
- Consider caching: only re-check files changed since last successful preflight

### Change detection is fail-open (correct)
- When change detection is unavailable, all gates run (safe default)
- This means CI with shallow clones runs everything (correct for CI)
- Local with good git history gets change-gated skip (correct for speed)

### workflow_acceptance dominates verify time
- 119 tests, even with 4-worker parallelism, measured at 1807s (30 min) — hit the 30m timeout
- This is >97% of total verify.sh wall-clock time
- The tests are themselves running verify.sh in temporary repos (test-within-test)
- Longest individual tests: 0n.1 (319s), 0k.1 (288s), 0n (283s), 2g (261s), 2h (258s)
