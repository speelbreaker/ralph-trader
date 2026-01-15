#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${PRD_FILE:-plans/prd.json}"
MAX_REPAIR_PASSES="${MAX_REPAIR_PASSES:-5}"
MAX_AUDIT_PASSES="${MAX_AUDIT_PASSES:-2}"
PRD_LINT_JSON="${PRD_LINT_JSON:-.context/prd_lint.json}"
PRD_PIPELINE_BLOCKED_JSON="${PRD_PIPELINE_BLOCKED_JSON:-.context/prd_pipeline_blocked.json}"

PRD_CUTTER_CMD="${PRD_CUTTER_CMD:-}"
PRD_CUTTER_ARGS="${PRD_CUTTER_ARGS:-}"
PRD_AUTOFIX_CMD="${PRD_AUTOFIX_CMD:-}"
PRD_AUTOFIX_ARGS="${PRD_AUTOFIX_ARGS:-}"
PRD_AUDITOR_CMD="${PRD_AUDITOR_CMD:-}"
PRD_AUDITOR_ARGS="${PRD_AUDITOR_ARGS:-}"
PRD_PATCHER_CMD="${PRD_PATCHER_CMD:-}"
PRD_PATCHER_ARGS="${PRD_PATCHER_ARGS:-}"
PRD_AUDITOR_ENABLED="${PRD_AUDITOR_ENABLED:-1}"
PRD_AUDIT_SCOPE="${PRD_AUDIT_SCOPE:-}"
PRD_AUDIT_SLICE="${PRD_AUDIT_SLICE:-}"

slice_arg="${1:-}"
slice_num=""
if [[ -n "$slice_arg" ]]; then
  if [[ "$slice_arg" =~ ^slice([0-9]+)$ ]]; then
    slice_num="${BASH_REMATCH[1]}"
  elif [[ "$slice_arg" =~ ^[0-9]+$ ]]; then
    slice_num="$slice_arg"
  fi
fi

AUDIT_SCOPE="${PRD_AUDIT_SCOPE:-}"
AUDIT_SLICE="${PRD_AUDIT_SLICE:-}"
if [[ -z "$AUDIT_SCOPE" ]]; then
  if [[ -n "$slice_num" ]]; then
    AUDIT_SCOPE="slice"
  else
    AUDIT_SCOPE="full"
  fi
fi
if [[ "$AUDIT_SCOPE" == "slice" && -z "$AUDIT_SLICE" ]]; then
  if [[ -n "$slice_num" ]]; then
    AUDIT_SLICE="$slice_num"
  else
    echo "ERROR: AUDIT_SCOPE=slice requires PRD_AUDIT_SLICE or slice argument (e.g., slice3)" >&2
    exit 2
  fi
fi

sha256_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

write_blocked() {
  local reason="$1"
  local detail="$2"
  local prd_hash
  prd_hash="$(sha256_file "$PRD_FILE")"
  mkdir -p "$(dirname "$PRD_PIPELINE_BLOCKED_JSON")"
  jq -n \
    --arg reason "$reason" \
    --arg detail "$detail" \
    --arg prd_file "$PRD_FILE" \
    --arg prd_hash "$prd_hash" \
    --arg lint_json "$PRD_LINT_JSON" \
    --arg schema_check "./plans/prd_schema_check.sh" \
    --argjson max_repair_passes "$MAX_REPAIR_PASSES" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{reason:$reason, detail:$detail, prd_file:$prd_file, prd_hash:$prd_hash, lint_json:$lint_json, schema_check:$schema_check, max_repair_passes:$max_repair_passes, timestamp:$timestamp}' \
    > "$PRD_PIPELINE_BLOCKED_JSON"
}

run_cmd() {
  local label="$1"
  local cmd="$2"
  local args="$3"
  local cmd_arr=()
  if [[ -z "$cmd" ]]; then
    echo "ERROR: $label command not set. Export ${label}_CMD." >&2
    exit 2
  fi
  if [[ "$cmd" == *" "* ]]; then
    echo "ERROR: $label command must be a single executable path (no spaces). Use ${label}_ARGS for arguments." >&2
    exit 2
  fi
  if [[ "$cmd" == /* || "$cmd" == ./* || "$cmd" == ../* ]]; then
    if [[ ! -x "$cmd" ]]; then
      echo "ERROR: $label command not executable: $cmd" >&2
      exit 2
    fi
  else
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: $label command not found in PATH: $cmd" >&2
      exit 2
    fi
  fi
  cmd_arr+=("$cmd")
  if [[ -n "$args" ]]; then
    read -r -a arg_arr <<<"$args"
    if (( ${#arg_arr[@]} > 0 )); then
      cmd_arr+=("${arg_arr[@]}")
    fi
  fi
  echo "==> $label" >&2
  "${cmd_arr[@]}"
}

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

if [[ -z "$PRD_AUDITOR_CMD" && "$PRD_AUDITOR_ENABLED" == "1" && -x "./plans/run_prd_auditor.sh" ]]; then
  PRD_AUDITOR_CMD="./plans/run_prd_auditor.sh"
fi
if [[ -z "$PRD_AUTOFIX_CMD" && -x "./plans/prd_autofix.sh" ]]; then
  PRD_AUTOFIX_CMD="./plans/prd_autofix.sh"
fi

# Stage A: Story Cutter + lint/repair loop
pass=0
for ((i=1; i<=MAX_REPAIR_PASSES; i++)); do
  echo "==> Stage A (repair pass $i/$MAX_REPAIR_PASSES)" >&2
  if ! ./plans/prd_schema_check.sh "$PRD_FILE"; then
    write_blocked "SCHEMA_FAIL" "PRD schema check failed before repair pass $i."
    echo "<promise>BLOCKED_PRD_PIPELINE</promise>" >&2
    echo "ERROR: PRD schema check failed before repair pass $i." >&2
    exit 4
  fi

  if ./plans/prd_lint.sh --json "$PRD_LINT_JSON" "$PRD_FILE"; then
    pass=1
    break
  fi

  if [[ -n "$PRD_AUTOFIX_CMD" ]]; then
    run_cmd PRD_AUTOFIX "$PRD_AUTOFIX_CMD" "$PRD_AUTOFIX_ARGS"
    if ! ./plans/prd_schema_check.sh "$PRD_FILE"; then
      write_blocked "SCHEMA_FAIL" "PRD schema check failed after autofix on pass $i."
      echo "<promise>BLOCKED_PRD_PIPELINE</promise>" >&2
      echo "ERROR: PRD schema check failed after autofix on pass $i." >&2
      exit 4
    fi
    if ./plans/prd_lint.sh --json "$PRD_LINT_JSON" "$PRD_FILE"; then
      pass=1
      break
    fi
  fi

  if [[ -z "$PRD_CUTTER_CMD" ]]; then
    write_blocked "LINT_FAIL" "PRD lint failing and PRD_CUTTER_CMD not set after pass $i."
    echo "<promise>BLOCKED_PRD_PIPELINE</promise>" >&2
    echo "ERROR: PRD lint failing and PRD_CUTTER_CMD not set after pass $i." >&2
    exit 5
  fi

  # Cutter is expected to read PRD_LINT_JSON and fix PRD when present.
  pre_hash="$(sha256_file "$PRD_FILE")"
  run_cmd PRD_CUTTER "$PRD_CUTTER_CMD" "$PRD_CUTTER_ARGS"
  post_hash="$(sha256_file "$PRD_FILE")"
  if [[ -n "$pre_hash" && "$pre_hash" == "$post_hash" ]]; then
    write_blocked "NO_PROGRESS" "PRD_CUTTER produced no changes on pass $i; see lint at $PRD_LINT_JSON."
    echo "<promise>BLOCKED_PRD_PIPELINE</promise>" >&2
    echo "ERROR: PRD_CUTTER produced no changes on pass $i; see lint at $PRD_LINT_JSON." >&2
    exit 6
  fi
  if ! ./plans/prd_schema_check.sh "$PRD_FILE"; then
    write_blocked "SCHEMA_FAIL" "PRD schema check failed after cutter on pass $i."
    echo "<promise>BLOCKED_PRD_PIPELINE</promise>" >&2
    echo "ERROR: PRD schema check failed after cutter on pass $i." >&2
    exit 4
  fi
  if ./plans/prd_lint.sh --json "$PRD_LINT_JSON" "$PRD_FILE"; then
    pass=1
    break
  fi

  echo "Lint errors detected. Continuing repair loop..." >&2
  sleep 0.2
done

if [[ "$pass" != "1" ]]; then
  write_blocked "LINT_FAIL" "PRD lint still failing after $MAX_REPAIR_PASSES passes. Cutter should mark needs_human_decision for unresolved items."
  echo "<promise>BLOCKED_PRD_PIPELINE</promise>" >&2
  echo "ERROR: PRD lint still failing after $MAX_REPAIR_PASSES passes. Cutter should mark needs_human_decision for unresolved items." >&2
  exit 5
fi

if [[ -x "./plans/prd_ref_check.sh" ]]; then
  ./plans/prd_ref_check.sh "$PRD_FILE"
else
  echo "WARN: ./plans/prd_ref_check.sh not found or not executable; skipping reference check." >&2
fi

export AUDIT_SCOPE
export AUDIT_SLICE

# Stage B: Auditor
if [[ -n "$PRD_AUDITOR_CMD" ]]; then
  echo "==> Stage B (Auditor)" >&2
  run_cmd PRD_AUDITOR "$PRD_AUDITOR_CMD" "$PRD_AUDITOR_ARGS"
else
  echo "WARN: PRD_AUDITOR_CMD not set; skipping auditor." >&2
fi

# Optional Stage B.1: Patcher (controlled)
if [[ -n "$PRD_PATCHER_CMD" ]]; then
  echo "==> Stage B.1 (Patcher)" >&2
  run_cmd PRD_PATCHER "$PRD_PATCHER_CMD" "$PRD_PATCHER_ARGS"
fi

# Stage C: Gate
./plans/prd_schema_check.sh "$PRD_FILE"
./plans/prd_lint.sh --json "$PRD_LINT_JSON" "$PRD_FILE"

echo "PRD pipeline complete"
