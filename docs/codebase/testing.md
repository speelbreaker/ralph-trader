# Codebase Map: Testing

## Test frameworks
- Rust built-in test harness via `cargo test`.

## How to run tests
- `./plans/verify.sh full` (canonical gate).
- `cargo test --workspace` (direct).

## Key test suites
- `crates/soldier_core/tests/test_instrument_kind_mapping.rs`
- `crates/soldier_core/tests/test_instrument_cache_ttl.rs`
- `crates/soldier_core/tests/test_order_size.rs`
- `crates/soldier_core/tests/test_dispatch_map.rs`

## Test data and fixtures
- None currently.

## CI gates
- `.github/workflows/ci.yml` runs `./plans/verify.sh full` with `CI_GATES_SOURCE=verify`.
- CI sets up rustfmt/clippy, Python 3.11, and Node 20 (node deps only if lockfile exists).

## Notes
- `plans/verify.sh` is the single source of truth for gates.
