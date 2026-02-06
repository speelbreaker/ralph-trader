#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
gate_script="$repo_root/plans/prd_gate.sh"

if [[ ! -x "$gate_script" ]]; then
  echo "FAIL: prd_gate.sh not executable at $gate_script" >&2
  exit 1
fi

run_case() {
  local fixture="$1"
  local expected_rc="$2"
  local expected_pattern="$3"
  local ref_check="${4:-on}"
  local prd="$repo_root/plans/fixtures/prd/$fixture"
  if [[ ! -f "$prd" ]]; then
    echo "FAIL: missing fixture $prd" >&2
    exit 1
  fi
  set +e
  if [[ "$ref_check" == "skip" ]]; then
    output="$(CI= PRD_REF_CHECK_ENABLED=0 PRD_GATE_ALLOW_REF_SKIP=1 "$gate_script" "$prd" 2>&1)"
  else
    output="$("$gate_script" "$prd" 2>&1)"
  fi
  rc=$?
  set -e
  if [[ "$rc" -ne "$expected_rc" ]]; then
    echo "FAIL: $fixture expected rc $expected_rc, got $rc" >&2
    echo "$output" >&2
    exit 1
  fi
  if ! echo "$output" | grep -Fq "$expected_pattern"; then
    echo "FAIL: $fixture missing expected output: $expected_pattern" >&2
    echo "$output" >&2
    exit 1
  fi
}

run_case "missing_plan_refs.json" 5 "plan_refs must be non-empty array" skip
run_case "acceptance_too_short.json" 5 "acceptance must have >=3 items" skip
run_case "empty_evidence.json" 5 "evidence must have >=1 items" skip
run_case "missing_targeted_verify.json" 5 "verify must include at least one targeted check" skip
run_case "missing_contract_must_evidence.json" 2 "MISSING_CONTRACT_MUST_EVIDENCE" skip
run_case "missing_observability_metrics.json" 2 "MISSING_OBSERVABILITY_METRICS" skip
run_case "reason_code_missing_values.json" 2 "REASON_CODES_EMPTY" skip
run_case "missing_failure_mode.json" 2 "MISSING_FAILURE_MODE" skip
run_case "placeholder_todo.json" 5 "placeholder tokens TODO/TBD/FIXME/??? require needs_human_decision=true" skip
run_case "workflow_touches_crates_touch.json" 2 "WORKFLOW_TOUCHES_CRATES" skip
run_case "workflow_touches_crates_create.json" 2 "WORKFLOW_TOUCHES_CRATES" skip
run_case "execution_touches_plans.json" 2 "EXECUTION_TOUCHES_PLANS" skip
run_case "unresolved_contract_ref.json" 1 "unresolved contract_ref"

echo "test_prd_gate.sh: ok"
