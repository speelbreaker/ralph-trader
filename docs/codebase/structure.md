# Codebase Map: Structure

## Repository layout
- `crates/` - Rust workspace crates.
  - `crates/soldier_core/` - core domain (execution, risk, venue).
  - `crates/soldier_infra/` - exchange adapters (Deribit public types).
- `plans/` - agent harness (PRD, verify, ralph, progress, ideas, pause).
- `docs/` - schemas and codebase maps.
- `specs/`, `prompts/`, `reviews/`, `scripts/` - supporting materials.
- `.github/workflows/ci.yml` - CI gate definition.
- `.ralph/` - harness runtime state and logs (generated).
- `.context/` - Conductor local context (gitignored).

## Key entry points
- `plans/verify.sh` (canonical verify gate).
- `plans/ralph.sh` (agent harness loop).
- `crates/soldier_core/src/lib.rs` (core crate root).

## Important files
- `CONTRACT.md` and `IMPLEMENTATION_PLAN.md` (requirements and phases).
- `plans/prd.json` (story backlog).
- `plans/progress.txt`, `plans/ideas.md`, `plans/pause.md` (handoff/notes).

## Generated artifacts
- `Cargo.lock`.
- `plans/logs/*` and `.ralph/*` (harness runtime).
- `.context/*` (local).

## Notes
- TBD
