# Codebase Map: Stack

## Languages
- Rust (edition 2024 in workspace crates).
- Bash (plans harness scripts).
- Python (plans tooling and CI tooling).
- JSON/YAML/Markdown for configuration and docs.

## Frameworks
- None in code yet (Rust std + custom modules).

## Runtime
- Rust standard library only; no async runtime in repo yet.

## Build and Tooling
- Cargo workspace (`Cargo.toml` at repo root).
- `./plans/verify.sh` is the canonical gate; `./plans/ralph.sh` is the harness loop.
- CI sets up rustfmt and clippy (see `.github/workflows/ci.yml`).

## Key Dependencies
- `soldier_infra` depends on `soldier_core` (path dependency).
- No external Rust crates declared yet.

## Data Stores
- None implemented yet.

## Observability
- `eprintln!` structured logs in core modules.
- Atomic counters for simple metrics (instrument cache, unit mismatch).

## Notes
- TBD
