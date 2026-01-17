# Agent Guide (High-Signal)

Read this first. It is the shortest, enforceable workflow summary.

## Non-negotiables
- Contract alignment is mandatory; if conflict, STOP and output `<promise>BLOCKED_CONTRACT_CONFLICT</promise>` with the violated section.
- Verification is mandatory; never weaken gates or tests.
- No postmortem, no merge: every PR must include a filled postmortem entry under `reviews/postmortems/`.
- MUST declare the governing contract (workflow vs bot) in the PR postmortem; enforced by postmortem check.

## Start here (every session)
- Read `CONTRACT.md`, `IMPLEMENTATION_PLAN.md`, `specs/WORKFLOW_CONTRACT.md`.
- If running the Ralph loop, read `plans/prd.json` and `plans/progress.txt`.
- Read `docs/skills/workflow.md`.
- Read `WORKFLOW_FRICTION.md` and the relevant files under `SKILLS/`.
- Use `reviews/REVIEW_CHECKLIST.md` when reviewing PRs.
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
If root `./verify.sh` exists, it must remain a thin wrapper that delegates to `plans/verify.sh`.

### Contract vs workflow contract
- `CONTRACT.md` = trading engine contract (runtime behavior/safety gates)
- `specs/WORKFLOW_CONTRACT.md` = coding workflow contract (Ralph loop + harness rules)
Do not mix them. If a workflow rule is being enforced, it must cite `specs/WORKFLOW_CONTRACT.md`.

### Changes must be self-proving
Any change to workflow/harness files (see allowlist in `plans/verify.sh:is_workflow_file`) must include:
- updated/added assertions in `plans/workflow_acceptance.sh` (or a dedicated gate script invoked by it)
- and a run that passes `./plans/verify.sh`
- Do not edit `plans/workflow_acceptance.sh` without running `./plans/verify.sh full`.
- MUST update workflow acceptance coverage when changing `plans/verify.sh` mode defaults.
- Keep WF-* IDs synchronized across `specs/WORKFLOW_CONTRACT.md` and `plans/workflow_contract_map.json`.
- Workflow acceptance always runs in CI; locally it may skip when no workflow-critical files changed (WORKFLOW_ACCEPTANCE_POLICY=auto). Force with WORKFLOW_ACCEPTANCE_POLICY=always.

### Fail-closed default
If a required script/artifact is missing or invalid, the workflow must produce a deterministic BLOCKED outcome (not a silent pass).

## Handoff hygiene (when relevant)
- Update `docs/codebase/*` with verified facts if you touched new areas.
- Append deferred ideas to `plans/ideas.md`.
- If pausing mid-story, fill `plans/pause.md`.
- Append to `plans/progress.txt`; include Assumptions/Open questions when applicable.
- Update `docs/skills/workflow.md` only when a new repeated pattern is discovered (manual judgment).
- Add a PR postmortem entry using `reviews/postmortems/PR_POSTMORTEM_TEMPLATE.md`.
- If a recurring issue is flagged, update `WORKFLOW_FRICTION.md` with the elevation action.

## Repo map
- `crates/` - Rust execution + risk (`soldier_core/`, `soldier_infra/`).
- `plans/` - harness (PRD, progress, verify, ralph).
- `docs/codebase/` - codebase maps.
- `SKILLS/` - one file per workflow skill (audit, patch-only edits, diff-first review).
- `reviews/postmortems/` - PR postmortem entries (agent-filled).

## Sentinel outputs
- When blocked: `<promise>BLOCKED_CI_COMMANDS</promise>`
- When done: `<promise>COMPLETE</promise>`

## Don'ts
- Never use skip-permissions.
- Never delete/disable tests or weaken fail-closed gates.
