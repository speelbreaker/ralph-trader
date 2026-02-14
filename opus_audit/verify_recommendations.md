# Verify Harness Audit: Recommendations

> Generated: 2026-02-07 | Based on measured timings from `VERIFY_MODE=full` run

## Proposed Quick Gate Set

**Target**: <2 min local, <5 min CI (excluding stack gate variance)

| # | Gate | Measured | Justification |
|---|------|----------|---------------|
| 1 | `preflight` | 27s | Catches missing tools/files before expensive work. Consider caching shell syntax check. |
| 2 | `spec_validators_group` (all 9) | ~3s (parallel) | CRITICAL: contract/spec integrity. 9 checks in 3s is exceptional value. |
| 3 | `status_fixture_*` (6) | ~6s (parallel) | HIGH: /status schema validation. Fast parallel execution. |
| 4 | `rust_fmt` | ~1-5s | Formatting gate; fast. Only when Rust changes detected. |
| 5 | `rust_tests_quick` | ~30s-5min | HIGH: fast Rust lib tests. Only when Rust changes detected. |
| 6 | `python_ruff_check` | ~2-5s | MEDIUM: fast Python lint. Only when Python changes detected. |
| 7 | `python_pytest_quick` | ~5-30s | HIGH: fast Python tests. Only when Python changes detected. |
| 8 | `node_lint` | ~5-30s | MEDIUM: fast linting. Only when Node changes detected. |
| 9 | `node_typecheck` | ~5-30s | HIGH: catches type errors. Only when Node changes detected. |
| 10 | `node_test` | ~10s-2min | HIGH: unit tests. Only when Node changes detected. |
| 11 | `vq_evidence` | <1s | MEDIUM: venue facts spec integrity. Negligible cost. |
| 12 | `endpoint_gate` | <1s | MEDIUM: endpoint/test pairing. Negligible cost. |

**Quick Set Total (measured, non-stack)**: ~36s
**Quick Set Total (estimated, with Rust stack active)**: ~1-6 min
**Quick Set Total (estimated, with all stacks active)**: ~2-8 min

### Excluded from Quick

| Gate | Reason |
|------|--------|
| `contract_coverage` | Change-gated; runs if files changed anyway. Not needed in every quick run. |
| `rust_clippy` | Slow (1-5min). Full-only. |
| `rust_tests_full` | Slow (1-10min). Full-only. |
| `python_pytest_full` | Covered by quick. Full-only. |
| `python_mypy` | Medium cost (5-30s), moderate signal. Deferred to full. |
| `python_ruff_format` | Cosmetic. Deferred to full. |
| `workflow_acceptance` | NOT-IMPORTANT: harness meta-test. Run separately. |
| `parallel_smoke` | LOW: harness meta-test. Run separately. |
| `postmortem_check` | LOW: process enforcement. Redundant with preflight pf-7 in strict mode. |
| `vendor_docs_lint_rust` | MEDIUM: documentation accuracy. Deferred to full. |
| `f1_cert` | Promotion only. Separate pipeline. |
| `integration_smoke` | Opt-in. Separate pipeline. |
| `e2e` | Opt-in. Separate pipeline. |

---

## Proposed Full Gate Set

**Target**: <15 min CI

All Quick gates plus:

| # | Gate | Est. Time | Justification |
|---|------|-----------|---------------|
| 13 | `contract_coverage` | 1-10s | HIGH: maps PRD to contract; ensures no coverage drift. |
| 14 | `rust_clippy` | 1-5min | HIGH: catches correctness issues beyond tests. |
| 15 | `rust_tests_full` | 1-10min | CRITICAL: full test coverage with all features. |
| 16 | `python_pytest_full` | 10s-2min | HIGH: complete Python test suite. |
| 17 | `python_mypy` | 5-30s | MEDIUM: type checking catches bugs. |
| 18 | `python_ruff_format` | <5s | LOW: formatting consistency. |
| 19 | `vendor_docs_lint_rust` | 4s (measured) | MEDIUM: documentation accuracy. |

**Full Set Total (estimated, with all stacks)**: ~5-20 min (mostly Rust clippy + tests)

### Excluded from Full (always)

| Gate | Reason |
|------|--------|
| `workflow_acceptance` | NOT-IMPORTANT: harness meta-test. Run in dedicated workflow acceptance pipeline. |
| `parallel_smoke` | LOW: harness meta-test. Run in workflow acceptance pipeline. |
| `postmortem_check` | LOW: process enforcement. Subsumed by preflight pf-7 in strict mode. |
| `f1_cert` | Promotion only: belongs in separate promotion pipeline. |
| `integration_smoke` | Opt-in: belongs in separate integration pipeline. |
| `e2e` | Opt-in: belongs in separate E2E pipeline. |

---

## Implementation Actions

### Immediate (no risk)

1. **Move `workflow_acceptance` to a separate pipeline trigger**
   - Remove from `verify.sh` main flow
   - Create `verify_workflow.sh` or a CI job that runs only when `workflow_files_allowlist.txt` entries change
   - Saves ~10-15 min on every full verify run

2. **Remove `parallel_smoke` from main verify**
   - Only run when `verify.sh` or `run_parallel_group` internals change
   - Bundle with workflow_acceptance pipeline

3. **Remove standalone `postmortem_check`**
   - Already covered by `preflight` pf-7 in `--strict` mode (CI)
   - Saves 4s and removes redundancy

### Short-term (low risk)

4. **Cache preflight shell syntax check**
   - `bash -n plans/*.sh` takes ~25s and reruns every time
   - Cache based on SHA of each `.sh` file; only recheck changed files
   - Could reduce preflight from 27s to ~2s on unchanged runs

5. **Add `--quick` / `--full` CLI flag to verify.sh** (if not already present)
   - Make the Quick/Full gate sets explicit and selectable
   - Default to `--quick` locally, `--full` in CI

### Medium-term (moderate risk)

6. **Parallelize stack gates**
   - Currently `run_stack_gates` runs Rust, Python, Node sequentially
   - These are independent; running in parallel could save significant time
   - Risk: resource contention on CI runners with limited cores

7. **Split preflight into fast/slow**
   - Fast: file existence, tool checks (pf-1 through pf-4, pf-6) — <2s
   - Slow: shell syntax (pf-5), postmortem (pf-7) — ~25s
   - Run fast preflight always; slow preflight only in full mode or on `.sh` changes

---

## Pipeline Architecture (target state)

```
Local developer:
  verify.sh --quick    (~1-2 min, spec validators + quick stack gates)

CI / pre-merge:
  verify.sh --full     (~5-20 min, all gates except workflow/promotion)

Workflow CI (only on harness changes):
  verify_workflow.sh   (~10-15 min, workflow_acceptance + parallel_smoke)

Promotion pipeline:
  verify.sh --full + f1_cert + integration_smoke

E2E pipeline (nightly / on-demand):
  verify.sh + E2E=1 + INTEGRATION_SMOKE=1
```
