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
if [[ -z "${NODE_PM:-}" ]]; then
  warn "No recognized lockfile; skipping node gates"
  exit 0
fi

need "$NODE_PM"

log "4) Node/TS gates"
case "$NODE_PM" in
  pnpm)
    run_logged "node_lint" "$NODE_LINT_TIMEOUT" pnpm -s run lint --if-present
    run_logged "node_typecheck" "$NODE_TYPECHECK_TIMEOUT" pnpm -s run typecheck --if-present
    run_logged "node_test" "$NODE_TEST_TIMEOUT" pnpm -s run test --if-present
    ;;
  npm)
    run_logged "node_lint" "$NODE_LINT_TIMEOUT" npm run -s lint --if-present
    run_logged "node_typecheck" "$NODE_TYPECHECK_TIMEOUT" npm run -s typecheck --if-present
    run_logged "node_test" "$NODE_TEST_TIMEOUT" npm run -s test --if-present
    ;;
  yarn)
    if node_script_exists lint; then
      run_logged "node_lint" "$NODE_LINT_TIMEOUT" yarn -s run lint
    fi
    if node_script_exists typecheck; then
      run_logged "node_typecheck" "$NODE_TYPECHECK_TIMEOUT" yarn -s run typecheck
    fi
    if node_script_exists test; then
      run_logged "node_test" "$NODE_TEST_TIMEOUT" yarn -s run test
    fi
    ;;
  *)
    fail "No node package manager selected (missing lockfile)"
    ;;
esac

echo "✓ node gates passed ($NODE_PM)"
