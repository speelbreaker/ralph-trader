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

ensure_python

# Ruff: required in CI (best ROI for agent-heavy workflows)
if command -v ruff >/dev/null 2>&1; then
  log "3a) Python ruff lint"
  run_logged "python_ruff_check" "$RUFF_TIMEOUT" ruff check .

  log "3b) Python ruff format"
  run_logged "python_ruff_format" "$RUFF_TIMEOUT" ruff format --check .
else
  if is_ci; then
    fail "ruff not found in CI (install it or adjust verify.sh)"
  else
    warn "ruff not found (install: pip install ruff) — skipping lint/format"
  fi
fi

# Pytest: required in CI if present in toolchain
if command -v pytest >/dev/null 2>&1; then
  log "3c) Python tests"
  if [[ "${MODE:-}" == "quick" ]]; then
    PYTEST_QUICK_EXPR="${PYTEST_QUICK_EXPR:-not integration and not slow}"
    if ! run_logged "python_pytest_quick" "$PYTEST_TIMEOUT" pytest -q -m "$PYTEST_QUICK_EXPR"; then
      warn "pytest quick selection failed; retrying full pytest -q"
      run_logged "python_pytest_full" "$PYTEST_TIMEOUT" pytest -q
    fi
  else
    run_logged "python_pytest_full" "$PYTEST_TIMEOUT" pytest -q
  fi
else
  if is_ci; then
    fail "pytest not found in CI (install it or adjust verify.sh)"
  else
    warn "pytest not found — skipping python tests"
  fi
fi

# MyPy optional: can be made strict with REQUIRE_MYPY=1
REQUIRE_MYPY="${REQUIRE_MYPY:-0}"
if command -v mypy >/dev/null 2>&1; then
  log "3d) Python mypy"
  if [[ "$REQUIRE_MYPY" == "1" ]]; then
    run_logged "python_mypy" "$MYPY_TIMEOUT" mypy .
  else
    run_logged "python_mypy" "$MYPY_TIMEOUT" mypy . --ignore-missing-imports || warn "mypy reported issues"
  fi
else
  if [[ "$REQUIRE_MYPY" == "1" ]]; then
    fail "REQUIRE_MYPY=1 but mypy is not installed"
  fi
fi

echo "✓ python gates passed"
