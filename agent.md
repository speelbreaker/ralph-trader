# Agent Guide (High-Signal)

## Non-negotiable: Contract Alignment
- Any change you make to the code must be 100% aligned with CONTRACT.md.
- Every code change MUST be 100% aligned with CONTRACT.md.
- If any instruction, story, or implementation detail conflicts with CONTRACT.md:
  - STOP immediately
  - output: <promise>BLOCKED_CONTRACT_CONFLICT</promise>
  - explain the conflict and what contract section it violates
- NEVER “fix” a conflict by weakening gates, staleness rules, evidence requirements, or tests.
- If uncertain which contract section applies, treat it as needs_human_decision and stop.

## Modes
- Plan Mode is mandatory for non-trivial changes.
- Plan mode first; execution second.
- Only after the plan is approved, execute with auto-accept edits.
- If the plan cannot be verified, stop.

## Command Permissions (Allow/Ask/Deny)
- Never use skip-permissions.
- Keep allow/ask/deny lists in `.claude/settings.json` and commit it.
- Explicitly deny foot-guns (examples): `rm -rf`, destructive `docker system prune -a --volumes`, `docker volume prune`, rewriting or deleting `artifacts/`.

## CI Alignment
- CI must run `./plans/verify.sh full` as the canonical gate.
- If CI and `verify.sh` diverge, `verify.sh` is wrong until fixed.

## Repo map (where things live)
- `crates/` — Rust execution + risk (run `ls crates` and keep this list accurate)
  - `soldier_core/`
  - `soldier_infra/`
- `plans/` — agent harness (PRD, progress, verify)

## Sentinel outputs
- When blocked: `<promise>BLOCKED_CI_COMMANDS</promise>`
- When done: `<promise>COMPLETE</promise>`
