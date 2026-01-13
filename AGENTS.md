# Agent Guide (High-Signal)

Read this first. It is the shortest, enforceable workflow summary.

## Non-negotiables
- Contract alignment is mandatory; if conflict, STOP and output `<promise>BLOCKED_CONTRACT_CONFLICT</promise>` with the violated section.
- Verification is mandatory; never weaken gates or tests.
- WIP=1: exactly one PRD item and one commit per iteration.
- Fail closed on ambiguity; set needs_human_decision=true and stop.

## Start here (every session)
- Read `CONTRACT.md`, `IMPLEMENTATION_PLAN.md`, `specs/WORKFLOW_CONTRACT.md`.
- Read `plans/prd.json` and `plans/progress.txt`.
- Read `docs/skills/workflow.md`.
- Run `./plans/init.sh` (if present) then `./plans/verify.sh <mode>`.
- Work only the selected PRD item.

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
