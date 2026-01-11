# Workflow Traceability Report

## Executive summary
- OK: Contract alignment gate is enforced via `plans/contract_check.sh` + `ensure_contract_review` in `plans/ralph.sh` (fail‑closed).
- OK: PRD schema validation (required fields, `human_blocker`, `contract_refs`, `plan_refs`, verify[]) is enforced at preflight.
- OK: WIP=1 and one‑commit‑per‑iteration are enforced (selection + contract check).
- OK: `plans/progress.txt` append‑only + required fields gate is enforced on green iterations.
- OK (partial): Cheat detection blocks common patterns (test deletions, skip markers, assertion removals, CI/verify changes, suppression pragmas).
- MAJOR: `plans/verify.sh` enforces gates not documented in the workflow contract (drift remains).
- MINOR: Some blocked iterations still miss artifacts (`verify_pre.log`, `agent.out`); `RPH_DRY_RUN=1` bypass is undocumented.

## Current codebase worktree (git status --porcelain)
_Snapshot omitted; run `git status --porcelain` to refresh._

## Workflow map (actual code paths)
- **Bootstrap (optional)**: `./plans/bootstrap.sh` seeds `plans/prd.json`, `plans/verify.sh`, `plans/progress.txt`, and updates `.gitignore`.
- **Preflight (optional)**: `./plans/init.sh` checks tools + JSON validity + optional verify; fails if dirty by default.
- **Harness loop**: `./plans/ralph.sh` enforces clean tree, validates PRD schema + required files, selects item, runs verify pre/post, invokes agent, and writes artifacts to `.ralph/iter_*`.
- **PRD mutation**: `./plans/update_task.sh` is the supported setter for `passes`.
- **CI**: `.github/workflows/ci.yml` runs `./plans/verify.sh full` with `CI_GATES_SOURCE=verify`.

## Contract → Code coverage (MUST/SHALL)

| Contract MUST/SHALL | Enforcement location | Pass/Fail signal | Status |
|---|---|---|---|
| Required inputs exist (`CONTRACT.md` and `IMPLEMENTATION_PLAN.md`) | `plans/ralph.sh` preflight with `specs/` fallback | Blocks preflight | OK |
| Every story MUST include `./plans/verify.sh` in its `verify[]` | `plans/ralph.sh` PRD schema gate + per‑story gate | Blocks with `<promise>BLOCKED_MISSING_VERIFY_SH_IN_STORY</promise>` | OK |
| `plans/prd.json` MUST be valid JSON with the canonical shape | `plans/ralph.sh` JSON parse + schema check; `plans/init.sh` JSON parse check | Exit with error if invalid | OK |
| Each PRD item MUST include required fields (id, priority, slice_ref, contract_refs, plan_refs, etc.) | `plans/ralph.sh` PRD schema gate | Blocks preflight | OK |
| If `needs_human_decision=true`, item MUST include `human_blocker` | `plans/ralph.sh` PRD schema gate | Blocks preflight | OK |
| Story Cutter MUST read `CONTRACT.md` first | None | N/A | GAP (process requirement only) |
| Story Cutter MUST populate `contract_refs` for every story | `plans/ralph.sh` schema + `plans/contract_check.sh` refs check | Blocks preflight / contract review | OK |
| Story Cutter MUST block when contract mapping is unclear | None | N/A | GAP (process requirement only) |
| Ralph MUST fail if PRD missing or invalid JSON | `plans/ralph.sh` preflight | Exit with error | OK |
| Ralph MUST fail if git working tree is dirty | `plans/ralph.sh` preflight | Exit 2 with error | OK |
| Ralph MUST fail if required tools (git, jq) missing | `plans/ralph.sh` preflight | Exit with error | OK |
| Ralph MUST stop immediately if selected story has `needs_human_decision=true` | `plans/ralph.sh` needs_human gate | Writes blocked artifacts + `<promise>BLOCKED_NEEDS_HUMAN_DECISION</promise>` and exits | OK |
| Ralph MUST write a blocked artifact snapshot in `.ralph/blocked_*` | `plans/ralph.sh` `write_blocked_artifacts` | `prd_snapshot.json` + `blocked_item.json` written | OK (partial for verify log; see GAP list) |
| Each iteration MUST perform verify_pre and verify_post | `plans/ralph.sh` `run_verify` pre/post | Non‑zero exit stops or self‑heals | GAP (can be bypassed via `RPH_DRY_RUN=1` or early block before pre‑verify) |
| Exactly one commit per iteration | `plans/contract_check.sh` commit count gate | Contract review fails | OK |
| Every iteration MUST write required artifacts (`selected.json`, `prd_before/after.json`, `progress_tail_*`, `head_*`, `diff.patch`, `prompt.txt`, `agent.out`, verify logs, selection.out if used) | `plans/ralph.sh` `save_iter_artifacts`/`save_iter_after` | Files written to `.ralph/iter_*` | GAP (blocked iterations skip `prompt.txt`/`agent.out` and sometimes verify logs) |
| Blocked cases MUST write `prd_snapshot.json`, `blocked_item.json`, `verify_pre.log` (best effort) | `plans/ralph.sh` `write_blocked_artifacts` | Snapshot + blocked item written | GAP (no `verify_pre.log` for invalid selection / missing-verify blocks) |
| After verify_post is green, a contract check MUST occur | `plans/ralph.sh` `ensure_contract_review` + `plans/contract_check.sh` | Blocks on contract review failure | OK |
| CI MUST execute `./plans/verify.sh` | `.github/workflows/ci.yml` + `plans/contract_check.sh` CI gate check | Contract review fails if weakened | OK |
| `plans/progress.txt` MUST be append‑only and include per‑iteration entries | `plans/ralph.sh` progress gate | Blocks with `<promise>BLOCKED_PROGRESS_INVALID</promise>` | OK (enforced on green iterations) |
| No cheating (don’t delete/disable tests or weaken gates) | `plans/ralph.sh` cheat detector + `plans/contract_check.sh` CI/test deletion checks | Blocks with `<promise>BLOCKED_CHEATING_DETECTED</promise>` or contract review failure | PARTIAL (pattern‑based) |
| Workflow changes MUST be made here first, reflected in scripts second, enforced in CI third | None | N/A | GAP (governance only) |

## DRIFT list (enforcement behavior → missing contract text)
- **MAJOR**: `plans/verify.sh` enforces CI gate source selection (`CI_GATES_SOURCE`), and emits `<promise>BLOCKED_CI_COMMANDS</promise>` if not set to `github`/`verify` — not documented in the contract.
- **MAJOR**: Endpoint‑level test gate based on diff vs `BASE_REF` is enforced in `plans/verify.sh` but not documented.
- **MAJOR**: Lockfile enforcement (Cargo.lock and JS lockfile rules) is enforced in `plans/verify.sh` but not documented.
- **MAJOR**: Python/Rust/Node gates (ruff, pytest, mypy, rustfmt/clippy/test, node lint/typecheck/test) are enforced by `plans/verify.sh` without contract text describing them.
- **MAJOR**: CI runs `./plans/verify.sh full` with `CI_GATES_SOURCE=verify` (mode and env are not described in the contract).
- **MINOR**: `plans/ralph.sh` adds rate limiting (`RPH_RATE_LIMIT_*`), circuit breaker (`RPH_CIRCUIT_BREAKER_ENABLED`), and “no progress” blocking; not documented.
- **MINOR**: `plans/ralph.sh` uses `.ralph/state.json`, `.ralph/rate_limit.json`, and progress rotation; not documented.
- **MINOR**: `RPH_DRY_RUN=1` bypasses verify and agent execution; not documented.

## Truth table for the loop (actual `plans/ralph.sh`)
- **Entry conditions**: git and jq installed; `CONTRACT.md` and `IMPLEMENTATION_PLAN.md` exist (with `specs/` fallback); `plans/prd.json` exists and passes schema validation; working tree clean; progress file exists; state file initialized. `./plans/verify.sh` must be executable before verify runs.
- **Selection rules**: `ACTIVE_SLICE = min(slice)` among items with `passes=false`. Harness mode selects highest priority item in active slice. Agent mode requires exact `<selected_id>ITEM_ID</selected_id>`; invalid selection blocks.
- **Pre‑verify**: Always runs `./plans/verify.sh $RPH_VERIFY_MODE` before agent work unless blocked/dry‑run; failure stops or self‑heals if `RPH_SELF_HEAL=1`.
- **Post‑agent / pre‑verify**: Cheat detection runs on the iteration diff (pattern‑based) and blocks or warns based on `RPH_CHEAT_DETECTION`.
- **Post‑verify**: Always runs after agent execution; failure stops (or self‑heals + continues if enabled). Progress append‑only gate is enforced on green iterations. Contract review gate runs on green iterations and blocks on failure.
- **Blocked behavior**: Blocks on invalid selection, `needs_human_decision`, missing `./plans/verify.sh` in story (if required), circuit breaker, or no‑progress. Writes `.ralph/blocked_*` artifacts and emits sentinel promises.
- **Completion**: Stops if agent outputs `<promise>COMPLETE</promise>` or all PRD items have `passes=true`, or if max iterations reached.
- **Artifact writing**: `.ralph/iter_*` contains `selected.json`, `prd_before/after.json`, progress tails, head refs, `diff.patch`, `prompt.txt`, `agent.out`, verify logs (when run), and `selection.out` (agent mode). Blocked cases write `prd_snapshot.json` + `blocked_item.json` in `.ralph/blocked_*`.

## Top 5 contract text edits (to match current enforcement)
1) Document `plans/verify.sh` gating behavior (CI gate source selection, lockfile rules, endpoint diff gate, Rust/Python/Node gates, and optional promotion/E2E/smoke gates).
2) Document Ralph’s circuit breaker, no‑progress blocking, and rate‑limit behavior (`RPH_RATE_LIMIT_*`, `RPH_CIRCUIT_BREAKER_ENABLED`).
3) Clarify that `RPH_DRY_RUN` bypasses verification and agent execution (if you intend to keep it).
4) Specify that `./plans/verify.sh` is invoked with a mode (quick/full/promotion) and how CI chooses it.
5) Clarify which iteration artifacts are guaranteed in blocked/early‑exit cases vs normal iterations.

## Top 5 code/CI changes (to enforce the contract)
1) Close blocked‑iteration artifact gaps (always emit `verify_pre.log` best‑effort and stub `prompt.txt`/`agent.out` on early blocks).
2) Decide whether to keep `RPH_DRY_RUN`; if kept, document and hard‑gate its use.
3) Expand cheat detection beyond pattern matching (AST‑aware assertion removal, per‑framework skip detection).
4) Enforce progress gating even on failed iterations (if strict per‑iteration logging is required).
5) Add a focused acceptance test for the workflow gates (smoke test for PRD schema + contract review + progress gate).

## Single Source of Truth recommendation
- **Recommendation**: Keep **CI calling `./plans/verify.sh`** as the single source of truth (current state). This is already implemented in `.github/workflows/ci.yml` with `CI_GATES_SOURCE=verify` and `./plans/verify.sh full`.
