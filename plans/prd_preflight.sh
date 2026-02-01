#!/usr/bin/env bash
set -euo pipefail

# Unified PRD preflight gate
# Runs: prd_gate.sh + story_verify_allowlist_check.sh
# --strict: enforce allowlist check presence and PRD lint strict heuristics (fail-closed if scripts missing)
# --smoke:  fast mode (schema + allowlist only, skip deep lint/ref checks)

ARG_PRD_FILE=""
STRICT=0
SMOKE=0

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --smoke) SMOKE=1 ;;
    --help|-h)
      echo "Usage: $0 [--strict] [--smoke] [prd.json]"
      echo ""
      echo "Unified PRD preflight gate. Runs:"
      echo "  1. prd_gate.sh (schema + lint + ref check)"
      echo "  2. story_verify_allowlist_check.sh (allowlist validation)"
      echo "  3. story_verify_allowlist_lint.sh (optional hygiene, warn only)"
      echo ""
      echo "Options:"
      echo "  --strict    Fail closed if allowlist scripts missing; enable PRD lint strict heuristics"
      echo "  --smoke     Fast mode: schema + allowlist only (skip PRD lint + ref checks)"
      exit 0
      ;;
    -*)
      echo "[preflight] ERROR: Unknown option: $arg" >&2
      exit 2
      ;;
    *) ARG_PRD_FILE="$arg" ;;
  esac
done

PRD_FILE="${ARG_PRD_FILE:-${PRD_FILE:-plans/prd.json}}"

if [[ ! -f "$PRD_FILE" ]]; then
  echo "[preflight] ERROR: PRD file not found: $PRD_FILE" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Gate 1: PRD schema (+ lint + ref check in full mode)
if [[ $SMOKE -eq 1 ]]; then
  echo "[preflight] Running PRD gate (smoke mode)..." >&2
  # Smoke mode: schema check only (fast)
  if [[ ! -x "$SCRIPT_DIR/prd_schema_check.sh" ]]; then
    echo "[preflight] ERROR: prd_schema_check.sh not found or not executable" >&2
    exit 2
  fi
  "$SCRIPT_DIR/prd_schema_check.sh" "$PRD_FILE"
else
  echo "[preflight] Running PRD gate..." >&2
  if [[ ! -x "$SCRIPT_DIR/prd_gate.sh" ]]; then
    echo "[preflight] ERROR: prd_gate.sh not found or not executable" >&2
    exit 2
  fi
  if [[ $STRICT -eq 1 ]]; then
    PRD_LINT_STRICT_HEURISTICS=1 "$SCRIPT_DIR/prd_gate.sh" "$PRD_FILE"
  else
    "$SCRIPT_DIR/prd_gate.sh" "$PRD_FILE"
  fi
fi

# Gate 2: Allowlist check
echo "[preflight] Running allowlist check..." >&2
if [[ -x "$SCRIPT_DIR/story_verify_allowlist_check.sh" ]]; then
  "$SCRIPT_DIR/story_verify_allowlist_check.sh" "$PRD_FILE"
else
  echo "[preflight] WARN: story_verify_allowlist_check.sh not found, skipping" >&2
  if [[ $STRICT -eq 1 ]]; then
    echo "[preflight] ERROR: --strict requires allowlist check script" >&2
    exit 2
  fi
fi

# Gate 3: Allowlist lint (optional hygiene, warn only)
if [[ $SMOKE -eq 0 ]]; then
  if [[ -x "$SCRIPT_DIR/story_verify_allowlist_lint.sh" ]]; then
    echo "[preflight] Running allowlist lint..." >&2
    "$SCRIPT_DIR/story_verify_allowlist_lint.sh" || true  # Warn only, don't block
  fi
fi

echo "[preflight] PASS: All gates passed" >&2
exit 0
