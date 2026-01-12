# REVIEW

## Summary
- State machine (current): preflight -> active slice detection -> selection (harness/agent) -> verify_pre -> agent run -> scope/cheat gates -> verify_post -> contract review -> pass flip + progress gate -> completion/blocked artifact.
- Baseline failure modes observed: no concurrency lock (state/progress races), PRD schema drift (inline check diverged from canonical checker), and missing verify_pre logs for some early blocks (invalid selection / missing verify in story).
- This patch hardens determinism and operator feedback without weakening gates: adds a fail-closed lock, centralizes schema validation via `plans/prd_schema_check.sh`, and guarantees best-effort verify_pre logs for early blocked cases.

## Findings
### Critical
- None observed.

### Major
- Concurrency hazard: no run-level lock; concurrent runs could corrupt `.ralph/state.json` and progress gating. Fixed by `RPH_LOCK_DIR` lock + fail-closed block. Evidence: `plans/ralph.sh` lock acquisition + new acceptance test.
- PRD schema drift: ralph.sh duplicated schema logic and missed stricter checks (rules booleans, id format). Fixed by calling canonical `plans/prd_schema_check.sh` in preflight. Evidence: `plans/ralph.sh` preflight change + prd checker script.
- Blocked artifacts missing verify_pre logs for early failures (invalid selection / missing verify in story). Fixed by best-effort verify_pre on block paths. Evidence: `plans/ralph.sh` + new acceptance test.

### Minor
- Gate-bypass toggles exist (`RPH_ALLOW_VERIFY_SH_EDIT`, `RPH_ALLOW_HARNESS_EDIT`, `RPH_ALLOW_UNSAFE_STORY_VERIFY`). They are explicit but can weaken safety if set in CI; recommend guarding them in CI env policy.
- Blocked artifacts still do not include iter_dir or selection context beyond `blocked_item.json`; debugging relies on `plans/logs/ralph.*.log`. Consider adding iter_dir pointer in blocked metadata later.
- Instrument cache TTL tests used exact counter deltas on global atomics; parallel tests can skew them. Assertions now require monotonic increase to avoid flakes.

## Contract mapping table
| Decision / Gate | Contract clause | Evidence |
|---|---|---|
| `./plans/verify.sh` is canonical gate | CONTRACT.md Section 0.Y Verification Harness | `plans/verify.sh`, `plans/ralph.sh` verify_pre/verify_post |
| PRD schema validation (fields, verify in story) | Workflow Contract Section 3 | `plans/prd_schema_check.sh`, `plans/ralph.sh` preflight |
| Clean worktree required at start | Workflow Contract Section 5.1 | `plans/ralph.sh` dirty worktree check |
| Active slice gating | Workflow Contract Section 5.2 | `plans/ralph.sh` ACTIVE_SLICE computation + selection |
| One story per iteration (WIP=1) | Workflow Contract Section 2 (Non-negotiables) | Single `NEXT_ID` selection + agent prompt |
| `needs_human_decision` hard stop | Workflow Contract Section 5.4 | `plans/ralph.sh` block on needs_human_decision |
| verify_pre/verify_post required | Workflow Contract Section 5.5 | `plans/ralph.sh` run_verify pre/post |
| Pass flips only after verify_post + contract review | Workflow Contract Section 2.2 + Section 7 | `plans/ralph.sh` update_task guarded by verify_post + contract_review |
| Contract review artifact required | Workflow Contract Section 7 | `plans/contract_check.sh`, `plans/ralph.sh` ensure_contract_review |
| progress.txt append-only | Workflow Contract Section 9 | `plans/ralph.sh` progress_gate |
| Blocked artifacts required | Workflow Contract Section 2 + Section 6 | `plans/ralph.sh` write_blocked_* |
| Anti-spin limit | Workflow Contract Section 5.8 | `plans/ralph.sh` MAX_ITERS gate |

## Recommended patch list (ordered)
1) Add a fail-closed run lock (`RPH_LOCK_DIR`) with lock metadata and deterministic block reason when held.
2) Centralize PRD schema validation through `plans/prd_schema_check.sh` to eliminate drift and enforce canonical rules.
3) Emit best-effort `verify_pre.log` for early blocked cases (invalid selection, missing verify in story, needs_human decision).
4) Expand `plans/workflow_acceptance.sh` with lock and invalid-selection verify_pre assertions.

## Evidence (commands + expected outputs)
- RUN: `./plans/workflow_acceptance.sh` -> `Workflow acceptance tests passed`.
- RUN: `./plans/init.sh` -> `[init] OK`.
- RUN: `CI_GATES_SOURCE=verify ./plans/verify.sh` -> `VERIFY_SH_SHA=...` and `VERIFY OK (mode=quick)` (warning about dirty tree is expected while uncommitted).

If verify fails due to missing toolchain or CI gate source, install Rust + ensure `CI_GATES_SOURCE=verify` (or add `.github/workflows`) and rerun.
