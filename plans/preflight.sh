#!/usr/bin/env bash
# =============================================================================
# plans/preflight.sh
# -----------------------------------------------------------------------------
# Purpose:
#   Lightweight preflight checks that run before verify.sh. Catches common
#   issues early (postmortem, schema, shell syntax) without the full verify cost.
#
# Usage:
#   ./plans/preflight.sh               # Run all checks (warn on minor issues)
#   ./plans/preflight.sh --strict      # Fail on warnings (e.g., missing BASE_REF)
#   ./plans/preflight.sh --census      # Emit verify census (non-mutating)
#   ./plans/preflight.sh --census-json # Emit verify census JSON (non-mutating)
#
# Exit codes:
#   0 = all checks passed
#   1 = validation failed
#   2 = setup error (missing tools/files)
#
# Runtime target: <30 seconds
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- Parse arguments ---
STRICT_MODE=0
CENSUS_MODE=""
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT_MODE=1 ;;
    --census)
      if [[ -n "$CENSUS_MODE" ]]; then
        echo "Unknown argument: $arg" >&2
        exit 2
      fi
      CENSUS_MODE="human"
      ;;
    --census-json)
      if [[ -n "$CENSUS_MODE" ]]; then
        echo "Unknown argument: $arg" >&2
        exit 2
      fi
      CENSUS_MODE="json"
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -n "$CENSUS_MODE" ]]; then
  if [[ "$CENSUS_MODE" == "json" ]]; then
    exec ./plans/verify.sh --census-json
  else
    exec ./plans/verify.sh --census
  fi
fi

# --- Counters ---
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SETUP_FAIL_COUNT=0

# --- Output helpers ---
pass() {
  echo "[PASS] $*"
  ((PASS_COUNT++)) || true
}

fail() {
  echo "[FAIL] $*" >&2
  ((FAIL_COUNT++)) || true
}

setup_fail() {
  echo "[FAIL] $*" >&2
  ((FAIL_COUNT++)) || true
  ((SETUP_FAIL_COUNT++)) || true
}

warn() {
  echo "[WARN] $*" >&2
  ((WARN_COUNT++)) || true
}

# =============================================================================
# Tier 1: Instant checks (<5s)
# =============================================================================

# 1. Git repository check
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "Git repository"
else
  setup_fail "Not a git repository: $ROOT"
fi

# 2. Required tools: git, jq, bash
check_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    pass "Tool: $tool"
  else
    setup_fail "Missing required tool: $tool"
  fi
}

check_tool git
check_tool jq
check_tool bash

# 3. Required files
check_file() {
  local path="$1"
  local desc="${2:-$path}"
  if [[ -f "$path" ]]; then
    pass "File: $desc"
  else
    setup_fail "Missing required file: $path"
  fi
}

check_file "plans/prd.json" "PRD file"

# Honor CONTRACT_FILE override (consistent with verify.sh/ralph.sh)
CONTRACT_FILE="${CONTRACT_FILE:-specs/CONTRACT.md}"
check_file "$CONTRACT_FILE" "Contract spec"

# =============================================================================
# Tier 2: Fast checks (<30s)
# =============================================================================

# 4. Shell syntax: bash -n plans/*.sh
SHELL_SYNTAX_OK=1
SHELL_ERRORS=()
if compgen -G "plans/*.sh" >/dev/null; then
  for f in plans/*.sh; do
    if ! bash -n "$f" 2>/dev/null; then
      SHELL_SYNTAX_OK=0
      SHELL_ERRORS+=("$f")
    fi
  done
fi

if [[ "$SHELL_SYNTAX_OK" == "1" ]]; then
  pass "Shell syntax (plans/*.sh)"
else
  fail "Shell syntax errors in: ${SHELL_ERRORS[*]}"
fi

# 5. PRD schema: plans/prd_schema_check.sh
PRD_SCHEMA_CHECK="plans/prd_schema_check.sh"
if [[ -x "$PRD_SCHEMA_CHECK" ]]; then
  if "$PRD_SCHEMA_CHECK" "plans/prd.json" >/dev/null 2>&1; then
    pass "PRD schema validation"
  else
    fail "PRD schema validation failed (run $PRD_SCHEMA_CHECK for details)"
  fi
elif [[ -f "$PRD_SCHEMA_CHECK" ]]; then
  echo "[FAIL] PRD schema check not executable: $PRD_SCHEMA_CHECK (setup error)" >&2
  exit 2
else
  echo "[FAIL] Missing PRD schema check: $PRD_SCHEMA_CHECK (setup error)" >&2
  exit 2
fi

# 6. Postmortem check: plans/postmortem_check.sh
POSTMORTEM_CHECK="plans/postmortem_check.sh"
POSTMORTEM_GATE="${POSTMORTEM_GATE:-1}"

# Honor POSTMORTEM_GATE=0 for local runs (consistent with verify.sh)
if [[ "$POSTMORTEM_GATE" == "0" && -z "${CI:-}" ]]; then
  warn "POSTMORTEM_GATE=0 (postmortem check skipped locally)"
elif [[ -x "$POSTMORTEM_CHECK" ]]; then
  # Check if BASE_REF is resolvable
  BASE_REF="${BASE_REF:-origin/main}"
  if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    if [[ "$STRICT_MODE" == "1" ]]; then
      fail "Cannot verify BASE_REF=$BASE_REF (required in --strict mode)"
    else
      warn "Cannot verify BASE_REF=$BASE_REF (postmortem check skipped)"
    fi
  else
    # Run the postmortem check
    if BASE_REF="$BASE_REF" "$POSTMORTEM_CHECK" >/dev/null 2>&1; then
      pass "Postmortem check"
    else
      fail "Postmortem check failed (run $POSTMORTEM_CHECK for details)"
    fi
  fi
elif [[ -f "$POSTMORTEM_CHECK" ]]; then
  echo "[FAIL] Postmortem check not executable: $POSTMORTEM_CHECK (setup error)" >&2
  exit 2
else
  echo "[FAIL] Missing postmortem check: $POSTMORTEM_CHECK (setup error)" >&2
  exit 2
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "preflight: $PASS_COUNT passed, $FAIL_COUNT failed, $WARN_COUNT warnings"

# Determine exit code
if [[ "$SETUP_FAIL_COUNT" -gt 0 ]]; then
  exit 2
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

if [[ "$STRICT_MODE" == "1" && "$WARN_COUNT" -gt 0 ]]; then
  echo "Exiting with failure due to --strict mode" >&2
  exit 1
fi

exit 0
