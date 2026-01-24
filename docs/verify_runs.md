# Verify Runs

## 2026-01-23 - verify.sh clean (reconciliation matrix AUTO)

Commit/PR: 07430a3 (dirty)

Commands:
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- OK: time/freshness spec checks passed.
- OK: RECONCILIATION_MATRIX checks passed.
- OK: CRASH_MATRIX.md looks mechanically consistent.
- OK: crash/replay/idempotency spec checks passed.
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/20260123_07430a3/

## 2026-01-22 - verify.sh clean (crash replay/idempotency closure)

Commit/PR: 07430a3 (dirty)

Commands:
- python3 scripts/check_contract_crossrefs.py --contract specs/CONTRACT.md --strict --check-at --include-bare-section-refs
- python3 scripts/check_arch_flows.py --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --strict
- python3 scripts/check_state_machines.py --dir specs/state_machines --strict --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --invariants specs/invariants/GLOBAL_INVARIANTS.md
- python3 scripts/check_global_invariants.py --file specs/invariants/GLOBAL_INVARIANTS.md --contract specs/CONTRACT.md
- python3 scripts/check_vq_evidence.py --file specs/flows/VQ_EVIDENCE.md --allow-missing
- python3 scripts/check_time_freshness.py --contract specs/CONTRACT.md --spec specs/flows/TIME_FRESHNESS.yaml --strict
- python3 scripts/check_crash_matrix.py --contract specs/CONTRACT.md --matrix specs/flows/CRASH_MATRIX.md
- python3 scripts/check_crash_replay_idempotency.py --contract specs/CONTRACT.md --spec specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml --strict
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- OK: time/freshness spec checks passed.
- OK: CRASH_MATRIX.md looks mechanically consistent.
- OK: crash/replay/idempotency spec checks passed.
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/20260122_07430a3/

## 2026-01-22 - verify.sh clean (crash matrix gate)

Commit/PR: 07430a3 (dirty)

Commands:
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- OK: time/freshness spec checks passed.
- OK: CRASH_MATRIX.md looks mechanically consistent.
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/spec_lint/20260122_155043_verify_crash_matrix.md

## 2026-01-22 - verify.sh clean (TF-005 + runtime AT gate)

Commit/PR: 07430a3 (dirty)

Commands:
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- OK: time/freshness spec checks passed.
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/spec_lint/20260122_143423_verify.md

## 2026-01-22 - specs restructure (state machines split)

Commit/PR: 07430a3 (dirty)

Commands:
- python3 scripts/check_state_machines.py --dir specs/state_machines --strict --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --invariants specs/invariants/GLOBAL_INVARIANTS.md
- python3 scripts/check_global_invariants.py --file specs/invariants/GLOBAL_INVARIANTS.md --contract specs/CONTRACT.md
- python3 scripts/check_time_freshness.py --contract specs/CONTRACT.md --spec specs/flows/TIME_FRESHNESS.yaml --strict
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/spec_lint/20260122_131901_spec_structure.md

## 2026-01-22 - time freshness strict (status *_ts_ms coverage)

Commit/PR: 07430a3 (dirty)

Commands:
- python3 scripts/check_time_freshness.py --contract specs/CONTRACT.md --spec specs/flows/TIME_FRESHNESS.yaml --strict
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/spec_lint/20260122_122911_time_freshness.md

## 2026-01-21 - verify.sh clean (entry_conditions/on_fail update)

Commit/PR: 07430a3 (dirty)

Commands:
- python3 scripts/check_state_machines.py --dir specs/state_machines --strict --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --invariants specs/invariants/GLOBAL_INVARIANTS.md
- python3 scripts/check_global_invariants.py --file specs/invariants/GLOBAL_INVARIANTS.md --contract specs/CONTRACT.md
- python3 scripts/check_vq_evidence.py --file specs/flows/VQ_EVIDENCE.md --allow-missing
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/spec_lint/20260121_194827_invariants_state_machines.md

## 2026-01-21 - verify.sh clean

Commit/PR: uncommitted

Commands:
- python3 scripts/check_state_machines.py --dir specs/state_machines --strict
- python3 scripts/check_global_invariants.py --file specs/invariants/GLOBAL_INVARIANTS.md
- python3 scripts/check_vq_evidence.py --file specs/flows/VQ_EVIDENCE.md --allow-missing
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- OK: state_machines passed structural checks.
- OK: GLOBAL_INVARIANTS is reference-closed (each GI has >=1 Contract ref and >=1 AT).
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

## 2026-01-21 - verify.sh clean (invariants/state machines gate)

Commit/PR: 07430a3

Commands:
- python3 scripts/check_state_machines.py --dir specs/state_machines --strict --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --invariants specs/invariants/GLOBAL_INVARIANTS.md
- python3 scripts/check_global_invariants.py --file specs/invariants/GLOBAL_INVARIANTS.md --contract specs/CONTRACT.md
- python3 scripts/check_vq_evidence.py --file specs/flows/VQ_EVIDENCE.md --allow-missing
- ./plans/verify.sh

Result:
- PASS: no cross-reference issues found.
- OK: ARCH_FLOW_INDEX checks passed.
- STATE MACHINES OK
- INVARIANTS OK
- OK: VQ_EVIDENCE is reference-closed (each record has >=1 Contract ref and >=1 AT).
- INFO: No Cargo.toml at repo root; skipping cargo test --workspace.
- VERIFY SUMMARY: PASS (cargo skipped)

Artifact:
- artifacts/verify/spec_lint/20260121_191900_invariants_state_machines.md
