# Workflow Traceability Report

## Executive summary
- CRITICAL: The contract-mandated post‑verify contract alignment gate is not implemented (no `plans/contract_check.sh` or LLM arbiter hook in `plans/ralph.sh`).
- MAJOR: The PRD schema requirements (required fields, `human_blocker`, and `contract_refs`) are not validated; `plans/prd.json` currently violates the contract schema.
- MAJOR: Multiple non‑negotiables rely on agent compliance only (WIP=1, one commit per iteration, progress log content), with no enforcement in code.
- MAJOR: `plans/verify.sh` enforces several gates (endpoint test gate, lockfiles, CI source check, toolchain gates) that are not documented in the workflow contract.
- MINOR: Some required artifacts for blocked iterations (e.g., `verify_pre.log`, `agent.out`) are not always produced, despite the contract claiming they are mandatory.

## Current codebase worktree (git status --porcelain)
```
 M .DS_Store
 M README.md
 M agent.md
?? plans/README.md
?? plans/bootstrap.sh
?? specs/
?? workflow_traceability_report.md
```

## Workflow map (actual code paths)
- **Bootstrap (optional)**: `./plans/bootstrap.sh` seeds `plans/prd.json`, `plans/verify.sh`, `plans/progress.txt`, and updates `.gitignore`.
- **Preflight (optional)**: `./plans/init.sh` checks tools + JSON validity + optional verify; fails if dirty by default.
- **Harness loop**: `./plans/ralph.sh` enforces clean tree, selects item, runs verify pre/post, invokes agent, and writes artifacts to `.ralph/iter_*`.
- **PRD mutation**: `./plans/update_task.sh` is the supported setter for `passes`.
- **CI**: `.github/workflows/ci.yml` runs `./plans/verify.sh full` with `CI_GATES_SOURCE=verify`.

## Contract → Code coverage (MUST/SHALL)

| Contract MUST/SHALL | Enforcement location | Pass/Fail signal | Status |
|---|---|---|---|
| Every story MUST include `./plans/verify.sh` in its `verify[]` | `plans/ralph.sh` gate when `RPH_REQUIRE_STORY_VERIFY=1` | Blocks with `<promise>BLOCKED_MISSING_VERIFY_SH_IN_STORY</promise>` | GAP (enforcement optional via env; no schema validation) |
| `plans/prd.json` MUST be valid JSON with the canonical shape | `plans/ralph.sh` JSON parse check; `plans/init.sh` JSON parse check | Exit with error if JSON invalid | GAP (no schema/field validation) |
| Each PRD item MUST include required fields (id, priority, slice_ref, contract_refs, plan_refs, etc.) | None | N/A | GAP (no validation; current PRD missing `contract_refs`, `plan_refs`, etc.) |
| `verify[]` MUST include `./plans/verify.sh` | `plans/ralph.sh` conditional gate | Blocked sentinel | GAP (optional; not validated on PRD load) |
| If `needs_human_decision=true`, item MUST include `human_blocker` | None | N/A | GAP (no validation; current PRD has `needs_human_decision=true` without `human_blocker`) |
| Story Cutter MUST read `CONTRACT.md` first | None | N/A | GAP (process requirement only) |
| Story Cutter MUST populate `contract_refs` for every story | None | N/A | GAP (process requirement only; missing in current PRD) |
| Story Cutter MUST block when contract mapping is unclear | None | N/A | GAP (process requirement only) |
| Ralph MUST fail if PRD missing or invalid JSON | `plans/ralph.sh` preflight | Exit with error | OK |
| Ralph MUST fail if git working tree is dirty | `plans/ralph.sh` preflight | Exit 2 with error | OK |
| Ralph MUST fail if required tools (git, jq) missing | `plans/ralph.sh` preflight | Exit with error | OK |
| Ralph MUST stop immediately if selected story has `needs_human_decision=true` | `plans/ralph.sh` needs_human gate | Writes blocked artifacts + `<promise>BLOCKED_NEEDS_HUMAN_DECISION</promise>` and exits | OK |
| Ralph MUST write a blocked artifact snapshot in `.ralph/blocked_*` | `plans/ralph.sh` `write_blocked_artifacts` | `prd_snapshot.json` + `blocked_item.json` written | OK (partial for verify log; see GAP list) |
| Each iteration MUST perform verify_pre and verify_post | `plans/ralph.sh` `run_verify` pre/post | Non‑zero exit stops or self‑heals | GAP (can be bypassed via `RPH_DRY_RUN=1` or early block before pre‑verify) |
| If `RPH_REQUIRE_STORY_VERIFY=1`, Ralph MUST block any story missing `./plans/verify.sh` in `verify[]` | `plans/ralph.sh` gate | Blocked sentinel | OK |
| Every iteration MUST write required artifacts (`selected.json`, `prd_before/after.json`, `progress_tail_*`, `head_*`, `diff.patch`, `prompt.txt`, `agent.out`, verify logs, selection.out if used) | `plans/ralph.sh` `save_iter_artifacts`/`save_iter_after` | Files written to `.ralph/iter_*` | GAP (blocked iterations skip `prompt.txt`/`agent.out` and sometimes verify logs) |
| Blocked cases MUST write `prd_snapshot.json`, `blocked_item.json`, `verify_pre.log` (best effort) | `plans/ralph.sh` `write_blocked_artifacts` | Snapshot + blocked item written | GAP (no `verify_pre.log` for invalid selection / missing-verify blocks) |
| After verify_post is green, a contract check MUST occur | None | N/A | **GAP (CRITICAL)** |
| CI MUST execute `./plans/verify.sh` | `.github/workflows/ci.yml` | Job fails on non‑zero exit | OK |
| `plans/progress.txt` MUST be append‑only and include per‑iteration entries | None | N/A | GAP (no enforcement) |
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
- **Entry conditions**: git and jq installed; `plans/prd.json` exists and is valid JSON; working tree clean; progress file exists; state file initialized. `./plans/verify.sh` must be executable before verify runs.
- **Selection rules**: `ACTIVE_SLICE = min(slice)` among items with `passes=false`. Harness mode selects highest priority item in active slice. Agent mode requires exact `<selected_id>ITEM_ID</selected_id>`; invalid selection blocks.
- **Pre‑verify**: Always runs `./plans/verify.sh $RPH_VERIFY_MODE` before agent work unless blocked/dry‑run; failure stops or self‑heals if `RPH_SELF_HEAL=1`.
- **Post‑verify**: Always runs after agent execution; failure stops (or self‑heals + continues if enabled). Circuit breaker/no‑progress can block after repeated failures/no changes.
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
1) Add a post‑verify contract alignment gate in `plans/ralph.sh` (call `./plans/contract_check.sh` and/or require `.ralph/iter_*/contract_review.json`).
2) Enforce PRD schema validation (required fields, `contract_refs`, `plan_refs`, `human_blocker`, acceptance ≥3, steps ≥5) in `plans/ralph.sh` preflight or a dedicated `plans/prd_schema_check.sh`.
3) Enforce WIP=1 and one‑commit‑per‑iteration (validate only one story changed, and commit count between `HEAD_BEFORE` and `HEAD_AFTER` is 1).
4) Enforce “passes=true only after green verify” by recording verify results and checking PRD pass flips against them (or by making `plans/update_task.sh` require a green sentinel file).
5) Add blocked‑case artifact completeness (write `verify_pre.log` best‑effort for all block reasons and always write `agent.out`/`prompt.txt` stubs for traceability).

## Single Source of Truth recommendation
- **Recommendation**: Keep **CI calling `./plans/verify.sh`** as the single source of truth (current state). This is already implemented in `.github/workflows/ci.yml` with `CI_GATES_SOURCE=verify` and `./plans/verify.sh full`.
