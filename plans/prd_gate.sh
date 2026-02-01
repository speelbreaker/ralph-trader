#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

trap 'rc=$?; [[ $rc -ne 0 ]] && echo "See plans/prd_gate_help.md" >&2' EXIT

PRD_FILE="${1:-${PRD_FILE:-plans/prd.json}}"
PRD_REF_CHECK_ENABLED="${PRD_REF_CHECK_ENABLED:-1}"
PRD_GATE_ALLOW_REF_SKIP="${PRD_GATE_ALLOW_REF_SKIP:-0}"

if [[ -z "$PRD_FILE" || ! -f "$PRD_FILE" ]]; then
  echo "ERROR: missing PRD file: $PRD_FILE" >&2
  exit 2
fi

if [[ "$PRD_REF_CHECK_ENABLED" == "0" ]]; then
  if [[ -n "${CI:-}" ]]; then
    echo "ERROR: PRD_REF_CHECK_ENABLED=0 is not allowed in CI" >&2
    exit 2
  fi
  if [[ "$PRD_GATE_ALLOW_REF_SKIP" != "1" ]]; then
    echo "ERROR: PRD ref check skip requires PRD_GATE_ALLOW_REF_SKIP=1" >&2
    exit 2
  fi
  echo "WARN: PRD ref check skipped: PRD_REF_CHECK_ENABLED=0" >&2
fi

if [[ ! -x "./plans/prd_schema_check.sh" ]]; then
  echo "ERROR: missing gate script: ./plans/prd_schema_check.sh" >&2
  exit 2
fi
if [[ ! -x "./plans/prd_lint.sh" ]]; then
  echo "ERROR: missing gate script: ./plans/prd_lint.sh" >&2
  exit 2
fi
if [[ "$PRD_REF_CHECK_ENABLED" != "0" && ! -x "./plans/prd_ref_check.sh" ]]; then
  echo "ERROR: missing gate script: ./plans/prd_ref_check.sh" >&2
  exit 2
fi

./plans/prd_schema_check.sh "$PRD_FILE"

if [[ -n "${PRD_LINT_JSON:-}" ]]; then
  ./plans/prd_lint.sh --json "$PRD_LINT_JSON" "$PRD_FILE"
else
  ./plans/prd_lint.sh "$PRD_FILE"
fi

if [[ "$PRD_REF_CHECK_ENABLED" != "0" ]]; then
  ./plans/prd_ref_check.sh "$PRD_FILE"
fi

echo "PRD gate OK"
