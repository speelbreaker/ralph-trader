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

emit_inner_excerpt() {
  local name="$1"
  if [[ -n "${RUN_LOGGED_SUPPRESS_EXCERPT:-}" ]]; then
    emit_fail_excerpt "$name" "${VERIFY_ARTIFACTS_DIR}/${name}.log"
  fi
}

run_logged_or_exit() {
  local name="$1"
  local timeout="$2"
  shift 2
  if ! run_logged "$name" "$timeout" "$@"; then
    local rc=$?
    emit_inner_excerpt "$name"
    exit "$rc"
  fi
}

need cargo

log "2a) Rust format"
run_logged_or_exit "rust_fmt" "$RUST_FMT_TIMEOUT" cargo fmt --all -- --check

if [[ "${MODE:-}" == "full" ]]; then
  log "2b) Rust clippy"
  run_logged_or_exit "rust_clippy" "$RUST_CLIPPY_TIMEOUT" cargo clippy --workspace --all-targets --all-features -- -D warnings
else
  warn "Skipping clippy in quick mode"
fi

log "2c) Rust tests"
if [[ "${MODE:-}" == "full" ]]; then
  run_logged_or_exit "rust_tests_full" "$RUST_TEST_TIMEOUT" cargo test --workspace --all-features --locked
else
  run_logged_or_exit "rust_tests_quick" "$RUST_TEST_TIMEOUT" cargo test --workspace --lib --locked
fi

echo "✓ rust gates passed"
