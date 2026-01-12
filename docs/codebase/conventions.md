# Codebase Map: Conventions

## Naming
- Rust modules use `snake_case`; types/enums use `PascalCase`.
- Tests use `test_*.rs` naming in `crates/*/tests/`.

## Style and formatting
- `cargo fmt` expected; CI installs rustfmt and clippy.

## Error handling
- Domain-specific enums + `Result` for rejects (e.g., `DispatchReject`).
- Risk state uses `RiskState::Degraded` for fail-closed behavior in core paths.

## Logging and metrics
- `eprintln!` structured logs in core modules.
- Atomic counters for basic metrics (cache hits/stales, unit mismatch rejects).

## Configuration
- No centralized configuration module yet.

## Notes
- TBD
