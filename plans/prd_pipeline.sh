#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${PRD_FILE:-plans/prd.json}"
MAX_REPAIR_PASSES="${MAX_REPAIR_PASSES:-5}"
MAX_AUDIT_PASSES="${MAX_AUDIT_PASSES:-2}"
PRD_LINT_JSON="${PRD_LINT_JSON:-.context/prd_lint.json}"

PRD_CUTTER_CMD="${PRD_CUTTER_CMD:-}"
PRD_AUDITOR_CMD="${PRD_AUDITOR_CMD:-}"
PRD_PATCHER_CMD="${PRD_PATCHER_CMD:-}"

run_cmd() {
  local label="$1"
  local cmd="$2"
  if [[ -z "$cmd" ]]; then
    echo "ERROR: $label command not set. Export ${label}_CMD." >&2
    exit 2
  fi
  echo "==> $label" >&2
  # shellcheck disable=SC2086
  eval $cmd
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

# Stage A: Story Cutter + lint/repair loop
pass=0
for ((i=1; i<=MAX_REPAIR_PASSES; i++)); do
  echo "==> Stage A (repair pass $i/$MAX_REPAIR_PASSES)" >&2
  # Cutter is expected to read PRD_LINT_JSON and fix PRD when present.
  run_cmd PRD_CUTTER "$PRD_CUTTER_CMD"
  ./plans/prd_schema_check.sh "$PRD_FILE"
  if ./plans/prd_lint.sh --json "$PRD_LINT_JSON" "$PRD_FILE"; then
    pass=1
    break
  fi
  echo "Lint errors detected. Continuing repair loop..." >&2
  sleep 0.2
done

if [[ "$pass" != "1" ]]; then
  echo "ERROR: PRD lint still failing after $MAX_REPAIR_PASSES passes. Cutter should mark needs_human_decision for unresolved items." >&2
  exit 5
fi

# Stage B: Auditor
if [[ -n "$PRD_AUDITOR_CMD" ]]; then
  echo "==> Stage B (Auditor)" >&2
  run_cmd PRD_AUDITOR "$PRD_AUDITOR_CMD"
else
  echo "WARN: PRD_AUDITOR_CMD not set; skipping auditor." >&2
fi

# Optional Stage B.1: Patcher (controlled)
if [[ -n "$PRD_PATCHER_CMD" ]]; then
  echo "==> Stage B.1 (Patcher)" >&2
  run_cmd PRD_PATCHER "$PRD_PATCHER_CMD"
fi

# Stage C: Gate
./plans/prd_schema_check.sh "$PRD_FILE"
./plans/prd_lint.sh --json "$PRD_LINT_JSON" "$PRD_FILE"

echo "PRD pipeline complete"
