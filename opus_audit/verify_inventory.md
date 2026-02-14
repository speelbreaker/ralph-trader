# Verify Harness Gate Inventory

> Generated: 2026-02-07 | Source: `plans/verify.sh` (2289 lines)
> Timings: measured from `VERIFY_MODE=full ./plans/verify.sh` on this repo (macOS, 4-core parallel)

## Execution Order

| # | gate_id | invoked_from | command | conditions | mode | measured_time | function_bucket | importance | rationale |
|---|---------|-------------|---------|-----------|------|---------------|----------------|------------|-----------|
| 1 | `preflight` | verify.sh:1893-1895 | `./plans/preflight.sh [--strict]` | Always. `--strict` in CI or VERIFY_PREFLIGHT_STRICT=1 | quick+full | 27s | workflow/process | HIGH | Catches missing files/tools before expensive gates |
| 2 | `parallel_smoke` | verify.sh:1905 | `./plans/test_parallel_smoke.sh` | Always. Requires `-x plans/test_parallel_smoke.sh` | quick+full | 7s | workflow/process | LOW | Tests verify.sh's own parallel primitives; meta-gate, not product quality |
| 3 | `contract_coverage` | verify.sh:1920 | `$PYTHON_BIN plans/contract_coverage_matrix.py` | `should_run_contract_coverage()` + `decide_skip_gate`. Change-gated: plans/prd.json, docs/contract_anchors.md, docs/validation_rules.md, plans/contract_coverage_matrix.py. Full mode always. | full (quick if changes) | skipped (no changes) | contract | HIGH | Maps PRD stories to contract sections; catches untracked contract drift |
| 4 | `contract_crossrefs` | spec_validators_group.sh:10 via verify.sh:1970 | `$PYTHON_BIN scripts/check_contract_crossrefs.py --contract $CONTRACT_FILE --strict --check-at --include-bare-section-refs` | `decide_skip_gate "spec_validators_group"`. Parallel group (up to 4 jobs). | quick+full | 3s | specs | CRITICAL | Validates section and AT-### cross-refs in CONTRACT.md; broken refs = spec integrity failure |
| 5 | `arch_flows` | spec_validators_group.sh:11 via verify.sh:1970 | `$PYTHON_BIN scripts/check_arch_flows.py --contract $CONTRACT_FILE --flows $ARCH_FLOWS_FILE --strict` | Same as #4 | quick+full | 3s | specs | CRITICAL | Validates architecture flow refs (AT/section) resolve in contract; catches orphaned flows |
| 6 | `state_machines` | spec_validators_group.sh:12 via verify.sh:1970 | `$PYTHON_BIN scripts/check_state_machines.py --dir specs/state_machines --strict --contract $CONTRACT_FILE --flows $ARCH_FLOWS_FILE --invariants $GLOBAL_INVARIANTS_FILE` | Same as #4 | quick+full | 3s | specs | CRITICAL | Validates TradingMode/RiskState/OpenPermissionLatch state machines; reachability, transition coverage, contract enum alignment |
| 7 | `global_invariants` | spec_validators_group.sh:13 via verify.sh:1970 | `$PYTHON_BIN scripts/check_global_invariants.py --file $GLOBAL_INVARIANTS_FILE --contract $CONTRACT_FILE` | Same as #4 | quick+full | 2s | specs | CRITICAL | Validates GI-### blocks have enforcement points, forbidden states, AT coverage |
| 8 | `time_freshness` | spec_validators_group.sh:14 via verify.sh:1970 | `$PYTHON_BIN scripts/check_time_freshness.py --contract $CONTRACT_FILE --spec specs/flows/TIME_FRESHNESS.yaml --strict` | Same as #4 | quick+full | 3s | specs | CRITICAL | Validates time/freshness requirements; stale data = wrong trading decisions |
| 9 | `crash_matrix` | spec_validators_group.sh:15 via verify.sh:1970 | `$PYTHON_BIN scripts/check_crash_matrix.py --contract $CONTRACT_FILE --matrix specs/flows/CRASH_MATRIX.md` | Same as #4 | quick+full | 2s | specs | CRITICAL | Validates crash recovery matrix; AT proof refs; crash recovery correctness |
| 10 | `crash_replay_idempotency` | spec_validators_group.sh:16 via verify.sh:1970 | `$PYTHON_BIN scripts/check_crash_replay_idempotency.py --contract $CONTRACT_FILE --spec specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml --strict` | Same as #4 | quick+full | 2s | specs | CRITICAL | Validates replay idempotency spec; prevents duplicate order execution on crash recovery |
| 11 | `reconciliation_matrix` | spec_validators_group.sh:17 via verify.sh:1970 | `$PYTHON_BIN scripts/check_reconciliation_matrix.py --matrix specs/flows/RECONCILIATION_MATRIX.md --contract $CONTRACT_FILE --strict` | Same as #4 | quick+full | 2s | specs | CRITICAL | Validates reconciliation matrix; reason codes, AT resolution; reconciliation safety |
| 12 | `csp_trace` | spec_validators_group.sh:18 via verify.sh:1970 | `$PYTHON_BIN scripts/check_csp_trace.py --contract $CONTRACT_FILE --trace specs/TRACE.yaml` | Same as #4 | quick+full | 2s | specs | HIGH | CSP clause-to-implementation traceability; catches unmapped contract clauses |
| 13 | `status_fixture_market_data_stale` | verify.sh:2007-2019 | `$PYTHON_BIN tools/validate_status.py --file $f --schema $STATUS_EXACT_SCHEMA --manifest $STATUS_MANIFEST --strict [--quiet]` | Only if `tests/fixtures/status/` dir exists. Parallel (up to 4 jobs). | quick+full | 6s | status/observability | HIGH | Validates /status endpoint fixture against exact JSON schema + reason registry |
| 14 | `status_fixture_partial_fill_containment` | verify.sh:2007-2019 | (same as #13) | (same as #13) | quick+full | 6s | status/observability | HIGH | (same as #13) |
| 15 | `status_fixture_restart_reconcile` | verify.sh:2007-2019 | (same as #13) | (same as #13) | quick+full | 5s | status/observability | HIGH | (same as #13) |
| 16 | `status_fixture_session_termination` | verify.sh:2007-2019 | (same as #13) | (same as #13) | quick+full | 4s | status/observability | HIGH | (same as #13) |
| 17 | `status_fixture_unknown_token_force_kill` | verify.sh:2007-2019 | (same as #13) | (same as #13) | quick+full | 3s | status/observability | HIGH | (same as #13) |
| 18 | `status_fixture_wal_backpressure` | verify.sh:2007-2019 | (same as #13) | (same as #13) | quick+full | 3s | status/observability | HIGH | (same as #13) |
| 19 | `endpoint_gate` | verify.sh:2035-2071 (inline logic, no run_logged) | Regex match on CHANGED_FILES against ENDPOINT_PATTERNS vs TEST_PATTERNS | `ENDPOINT_GATE!=0` (disabled locally with =0). Change-detection required. | quick+full | <1s (inline) | workflow/process | MEDIUM | Proxy: endpoint code changes must be paired with test changes |
| 20 | `postmortem_check` | verify.sh:2082 | `$ROOT/plans/postmortem_check.sh` | `POSTMORTEM_GATE!=0` (disabled locally with =0). Requires `-x plans/postmortem_check.sh`. | quick+full | 4s | workflow/process | LOW | Enforces PR postmortem entry exists; process gate, not correctness |
| 21 | `vendor_docs_lint_rust` | verify.sh:2095 | `$PYTHON_BIN tools/vendor_docs_lint_rust.py` | Only if `Cargo.toml` + `specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml` exist | quick+full | 4s | specs | MEDIUM | Validates vendored Rust documentation; correctness aid, not safety-critical |
| 22 | `rust_fmt` | rust_gates.sh:36 via verify.sh:2104 | `cargo fmt --all -- --check` | `Cargo.toml` exists + `should_run_rust_gates()` | quick+full | N/A (change-skipped) | formatting | MEDIUM | Rust formatting check |
| 23 | `rust_clippy` | rust_gates.sh:40 via verify.sh:2104 | `cargo clippy --workspace --all-targets --all-features -- -D warnings` | Full mode only. `Cargo.toml` + `should_run_rust_gates()` | full only | N/A (change-skipped) | static analysis | HIGH | Catches correctness issues (warnings-as-errors) in Rust |
| 24 | `rust_tests_full` | rust_gates.sh:47 via verify.sh:2104 | `cargo test --workspace --all-features --locked` | Full mode only. `Cargo.toml` + `should_run_rust_gates()` | full only | N/A (change-skipped) | unit tests | CRITICAL | Full Rust test suite with all features; catches regressions |
| 25 | `rust_tests_quick` | rust_gates.sh:49 via verify.sh:2104 | `cargo test --workspace --lib --locked` | Quick mode only. `Cargo.toml` + `should_run_rust_gates()` | quick only | N/A (change-skipped) | unit tests | HIGH | Library-only Rust tests; fast feedback loop |
| 26 | `python_ruff_check` | python_gates.sh:38 via verify.sh:2104 | `ruff check .` | `ruff` available. `pyproject.toml`/`requirements.txt` + `should_run_python_gates()`. CI: required | quick+full | N/A (change-skipped) | static analysis | MEDIUM | Python lint (ruff) |
| 27 | `python_ruff_format` | python_gates.sh:41 via verify.sh:2104 | `ruff format --check .` | Same as #26 | quick+full | N/A (change-skipped) | formatting | LOW | Python format check |
| 28 | `python_pytest_quick` | python_gates.sh:55 via verify.sh:2104 | `pytest -q -m "not integration and not slow"` | Quick mode. `pytest` available. Fallback to full on failure. | quick only | N/A (change-skipped) | unit tests | HIGH | Fast Python tests excluding integration/slow |
| 29 | `python_pytest_full` | python_gates.sh:58,61 via verify.sh:2104 | `pytest -q` | Full mode or quick fallback. `pytest` available. | full (+ quick fallback) | N/A (change-skipped) | unit tests | HIGH | Complete Python test suite |
| 30 | `python_mypy` | python_gates.sh:76,78 via verify.sh:2104 | `mypy . [--ignore-missing-imports]` | `mypy` available. Strict if REQUIRE_MYPY=1 | quick+full | N/A (change-skipped) | static analysis | MEDIUM | Python type checking |
| 31 | `node_lint` | node_gates.sh:42-53 via verify.sh:2104 | `{pnpm\|npm\|yarn} run lint` | `package.json` + lockfile + `should_run_node_gates()` | quick+full | N/A (toolchain absent) | static analysis | MEDIUM | Node/TS linting |
| 32 | `node_typecheck` | node_gates.sh:43-56 via verify.sh:2104 | `{pnpm\|npm\|yarn} run typecheck` | Same as #31 | quick+full | N/A (toolchain absent) | static analysis | HIGH | TypeScript type checking; catches type errors |
| 33 | `node_test` | node_gates.sh:44-59 via verify.sh:2104 | `{pnpm\|npm\|yarn} run test` | Same as #31 | quick+full | N/A (toolchain absent) | unit tests | HIGH | Node/TS unit tests |
| 34 | `vq_evidence` | verify.sh:2123-2125 (no run_logged) | `$PYTHON_BIN scripts/check_vq_evidence.py` | Only if script exists. Optional strictness via REQUIRE_VQ_EVIDENCE=1 | quick+full | <1s (inline) | specs | MEDIUM | Validates venue facts evidence (VQ-### records have contract+AT refs) |
| 35 | `f1_cert` | verify.sh:2141-2156 (inline) | `$PYTHON_BIN python/tools/f1_certify.py --window=24h --out=artifacts/F1_CERT.json` + `jq` validation | Only if VERIFY_MODE=promotion or REQUIRE_F1_CERT=1 | promotion only | N/A (not promotion) | contract | CRITICAL | Release-grade financial cert; wrong cert = production trading risk |
| 36 | `integration_smoke` | verify.sh:2167-2196 (inline) | `docker compose up -d --build` + `curl` health checks | Full mode + INTEGRATION_SMOKE=1 + docker available | full (opt-in) | N/A (opt-in disabled) | integration/e2e | LOW | Docker-compose smoke; disabled by default; rarely used |
| 37 | `e2e` | verify.sh:2204-2244 (inline) | Playwright/Cypress/custom E2E_CMD | E2E=1 (opt-in) | quick+full (opt-in) | N/A (opt-in disabled) | integration/e2e | LOW | UI end-to-end; disabled by default |
| 38 | `workflow_acceptance` | verify.sh:2254-2258 | `./plans/workflow_acceptance[_parallel].sh --mode smoke\|full [--jobs N]` | `should_run_workflow_acceptance()`. CI: always. Local: change-gated. ~119 tests. | quick+full (gated) | see note [1] | workflow/process | NOT-IMPORTANT | Tests verify.sh/ralph harness itself; meta-gate for workflow, not product |

**[1] workflow_acceptance**: 119 tests run across 4 parallel workers. Individual test times ranged from 1s to 319s. **Measured: 1807s (30 min) — hit the 30m timeout limit.** The gate dominates total verify.sh wall-clock time in full mode. It consumed >97% of total wall-clock.

## Preflight Sub-Checks (within preflight.sh, 196 lines)

| sub_id | check | line | validates | measured |
|--------|-------|------|-----------|----------|
| pf-1 | git repo | 68-72 | Working dir is git repo | <1s |
| pf-2 | tools: git, jq, bash | 84-86 | Required tools installed | <1s |
| pf-3 | plans/prd.json exists | 99 | PRD file present | <1s |
| pf-4 | CONTRACT.md exists | 103 | Contract spec present | <1s |
| pf-5 | shell syntax | 112-125 | `bash -n plans/*.sh` -- all shell scripts parse | ~25s (dominates preflight) |
| pf-6 | PRD schema | 128-141 | prd.json matches schema (via prd_schema_check.sh) | <1s |
| pf-7 | postmortem | 144-173 | Postmortem entry for BASE_REF | <1s |

## Change Detection Functions (change_detection.sh)

| function | file patterns | default when unavailable |
|----------|-------------|--------------------------|
| `should_run_rust_gates()` | *.rs, Cargo.toml, Cargo.lock, rust-toolchain*, rustfmt.toml, clippy.toml, .cargo/* | Always run (fail-open) |
| `should_run_python_gates()` | *.py, *.pyi, pyproject.toml, requirements*.txt, setup.*, tox.ini, mypy.ini, pytest.ini, poetry.lock, uv.lock, ruff.toml, Pipfile*, .python-version | Always run |
| `should_run_node_gates()` | *.ts, *.tsx, *.js, *.jsx, *.mjs, *.cjs, package.json, *-lock.*, tsconfig.*, eslint.*, .prettierrc*, jest/vitest/babel/vite/next/webpack/rollup.config.* | Always run |
| `should_run_contract_coverage()` | plans/prd.json, docs/contract_anchors.md, docs/validation_rules.md, plans/contract_coverage_matrix.py | Always run |
| `should_run_workflow_acceptance()` | workflow_files_allowlist.txt entries | Always run in CI. Local: run if changes |

## Classification Summary

### By Importance

| Bucket | Count | Gates |
|--------|-------|-------|
| CRITICAL | 10 | contract_crossrefs, arch_flows, state_machines, global_invariants, time_freshness, crash_matrix, crash_replay_idempotency, reconciliation_matrix, rust_tests_full, f1_cert |
| HIGH | 15 (10 logical) | preflight, contract_coverage, csp_trace, status_fixture_* (6 fixtures), rust_clippy, rust_tests_quick, python_pytest_quick, python_pytest_full, node_typecheck, node_test |
| MEDIUM | 7 | endpoint_gate, vendor_docs_lint_rust, rust_fmt, python_ruff_check, python_mypy, node_lint, vq_evidence |
| LOW | 5 | parallel_smoke, postmortem_check, integration_smoke, e2e, python_ruff_format |
| NOT-IMPORTANT | 1 | workflow_acceptance |

### By Function

| Bucket | Count | Gates |
|--------|-------|-------|
| contract | 2 | contract_coverage, f1_cert |
| specs | 10 | contract_crossrefs, arch_flows, state_machines, global_invariants, time_freshness, crash_matrix, crash_replay_idempotency, reconciliation_matrix, csp_trace, vq_evidence |
| status/observability | 6 | status_fixture_* (6 fixtures as group) |
| unit tests | 5 | rust_tests_full, rust_tests_quick, python_pytest_quick, python_pytest_full, node_test |
| static analysis | 5 | rust_clippy, python_ruff_check, python_mypy, node_lint, node_typecheck |
| formatting | 2 | rust_fmt, python_ruff_format |
| integration/e2e | 2 | integration_smoke, e2e |
| workflow/process | 4 | preflight, parallel_smoke, endpoint_gate, postmortem_check |
| misc | 2 | vendor_docs_lint_rust, workflow_acceptance |
