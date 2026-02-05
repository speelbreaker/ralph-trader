#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ROOT:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

source "$ROOT/plans/lib/verify_utils.sh"

RUN_LOGGED_SUPPRESS_EXCERPT="${RUN_LOGGED_SUPPRESS_EXCERPT:-}"
RUN_LOGGED_SKIP_FAILED_GATE="${RUN_LOGGED_SKIP_FAILED_GATE:-}"
RUN_LOGGED_SUPPRESS_TIMEOUT_FAIL="${RUN_LOGGED_SUPPRESS_TIMEOUT_FAIL:-}"

need cargo

log "2a) Rust format"
run_logged "rust_fmt" "$RUST_FMT_TIMEOUT" cargo fmt --all -- --check

if [[ "${MODE:-}" == "full" ]]; then
  log "2b) Rust clippy"
  run_logged "rust_clippy" "$RUST_CLIPPY_TIMEOUT" cargo clippy --workspace --all-targets --all-features -- -D warnings
else
  warn "Skipping clippy in quick mode"
fi

log "2c) Rust tests"
if [[ "${MODE:-}" == "full" ]]; then
  run_logged "rust_tests_full" "$RUST_TEST_TIMEOUT" cargo test --workspace --all-features --locked
else
  run_logged "rust_tests_quick" "$RUST_TEST_TIMEOUT" cargo test --workspace --lib --locked
fi

echo "✓ rust gates passed"
