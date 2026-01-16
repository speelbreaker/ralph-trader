# Agent Guide (High-Signal)

Read this first. It is the shortest, enforceable workflow summary.

## Non-negotiables
- Contract alignment is mandatory; if conflict, STOP and output `<promise>BLOCKED_CONTRACT_CONFLICT</promise>` with the violated section.
- Verification is mandatory; never weaken gates or tests.
- Contract kernel use is derived-only; it never overrides CONTRACT.md and must be validated before use.

## Start here (every session)
- Read `docs/contract_kernel.json` (if present and validated), `IMPLEMENTATION_PLAN.md`, `specs/WORKFLOW_CONTRACT.md`.
- If the kernel is missing, stale, invalid, or any rule is ambiguous/conflicting, read full `CONTRACT.md` before proceeding.
- If acting as Story Cutter or Contract Arbiter, read full `CONTRACT.md` first.
- If using the kernel, run `python3 scripts/check_contract_kernel.py` and stop on failure.
- If running the Ralph loop, read `plans/prd.json` and `plans/progress.txt`.
- Read `docs/skills/workflow.md`.
- If running the Ralph loop, run `./plans/init.sh` (if present) then `./plans/verify.sh <mode>`.

## Ralph loop only (PRD iterations)
- WIP=1: exactly one PRD item and one commit per iteration.
- Work only the selected PRD item.
- Fail closed on PRD ambiguity; set needs_human_decision=true and stop.

## Repo Path Guardrails (Non-Negotiable)

### Canonical workflow files (use THESE paths)
- Workflow contract: `specs/WORKFLOW_CONTRACT.md`
- Ralph orchestrator: `plans/ralph.sh`
- Verification gate (canonical): `plans/verify.sh`
- Acceptance harness: `plans/workflow_acceptance.sh`
- Initializer: `plans/init.sh`
- PRD backlog: `plans/prd.json`
- Contract review tooling: `plans/contract_check.sh`, `plans/contract_review_validate.sh`

### State + logs (expected runtime artifacts)
- Ralph state directory: `.ralph/`
- Canonical state file: `.ralph/state.json`
- Run logs directory: `plans/logs/`

### Critical ambiguity guard
There is also a `./verify.sh` at repo root. **DO NOT edit or reference it** unless explicitly instructed.
All workflow gating must target **`plans/verify.sh`**.

### Contract vs workflow contract
- `CONTRACT.md` = trading engine contract (runtime behavior/safety gates)
- `specs/WORKFLOW_CONTRACT.md` = coding workflow contract (Ralph loop + harness rules)
Do not mix them. If a workflow rule is being enforced, it must cite `specs/WORKFLOW_CONTRACT.md`.

### Changes must be self-proving
Any change to workflow/harness files (see allowlist in `plans/verify.sh:is_workflow_file`) must include:
- updated/added assertions in `plans/workflow_acceptance.sh` (or a dedicated gate script invoked by it)
- and a run that passes `./plans/verify.sh`
- Do not edit `plans/workflow_acceptance.sh` without running `./plans/verify.sh full`.
- Keep WF-* IDs synchronized across `specs/WORKFLOW_CONTRACT.md` and `plans/workflow_contract_map.json`.

### Fail-closed default
If a required script/artifact is missing or invalid, the workflow must produce a deterministic BLOCKED outcome (not a silent pass).

## Handoff hygiene (when relevant)
- Update `docs/codebase/*` with verified facts if you touched new areas.
- Append deferred ideas to `plans/ideas.md`.
- If pausing mid-story, fill `plans/pause.md`.
- Append to `plans/progress.txt`; include Assumptions/Open questions when applicable.
- Update `docs/skills/workflow.md` only when a new repeated pattern is discovered (manual judgment).

## Repo map
- `crates/` - Rust execution + risk (`soldier_core/`, `soldier_infra/`).
- `plans/` - harness (PRD, progress, verify, ralph).
- `docs/codebase/` - codebase maps.

## Sentinel outputs
- When blocked: `<promise>BLOCKED_CI_COMMANDS</promise>`
- When done: `<promise>COMPLETE</promise>`

## Don'ts
- Never use skip-permissions.
- Never delete/disable tests or weaken fail-closed gates.
