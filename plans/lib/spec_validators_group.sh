#!/usr/bin/env bash

if [[ -n "${__SPEC_VALIDATORS_GROUP_SOURCED:-}" ]]; then
  return 0
fi
__SPEC_VALIDATORS_GROUP_SOURCED=1

spec_validators_group_specs_raw() {
  cat <<EOF
contract_crossrefs|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_contract_crossrefs.py --contract ${CONTRACT_FILE:?} --strict --check-at --include-bare-section-refs
arch_flows|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_arch_flows.py --contract ${CONTRACT_FILE:?} --flows ${ARCH_FLOWS_FILE:?} --strict
state_machines|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_state_machines.py --dir specs/state_machines --strict --contract ${CONTRACT_FILE:?} --flows ${ARCH_FLOWS_FILE:?} --invariants ${GLOBAL_INVARIANTS_FILE:?}
global_invariants|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_global_invariants.py --file ${GLOBAL_INVARIANTS_FILE:?} --contract ${CONTRACT_FILE:?}
time_freshness|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_time_freshness.py --contract ${CONTRACT_FILE:?} --spec specs/flows/TIME_FRESHNESS.yaml --strict
crash_matrix|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_crash_matrix.py --contract ${CONTRACT_FILE:?} --matrix specs/flows/CRASH_MATRIX.md
crash_replay_idempotency|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_crash_replay_idempotency.py --contract ${CONTRACT_FILE:?} --spec specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml --strict
reconciliation_matrix|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_reconciliation_matrix.py --matrix specs/flows/RECONCILIATION_MATRIX.md --contract ${CONTRACT_FILE:?} --strict
csp_trace|${SPEC_LINT_TIMEOUT:?}|${PYTHON_BIN:?} scripts/check_csp_trace.py --contract ${CONTRACT_FILE:?} --trace specs/TRACE.yaml
EOF
}

spec_validators_group_build_specs() {
  SPEC_VALIDATOR_SPECS=()
  SPEC_VALIDATOR_NAMES=()

  local min_expected="${MIN_SPEC_VALIDATORS:-7}"
  if [[ ! "$min_expected" =~ ^[0-9]+$ ]]; then
    echo "FAIL: MIN_SPEC_VALIDATORS must be numeric" >&2
    return 1
  fi

  local line name timeout cmd
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    IFS='|' read -r name timeout cmd <<<"$line"
    if [[ -z "${name:-}" || -z "${timeout:-}" || -z "${cmd:-}" ]]; then
      echo "FAIL: malformed spec validator line (expected name|timeout|command): $line" >&2
      return 1
    fi
    if [[ ! "$timeout" =~ ^[0-9]+[smhd]$ ]]; then
      echo "FAIL: malformed validator timeout '$timeout' for '$name' (expected <int><unit>)" >&2
      return 1
    fi
    if printf '%s\n' "${SPEC_VALIDATOR_NAMES[@]:-}" | grep -Fx -q "$name"; then
      echo "FAIL: duplicate spec validator name '$name'" >&2
      return 1
    fi

    SPEC_VALIDATOR_SPECS+=("$name|$timeout|$cmd")
    SPEC_VALIDATOR_NAMES+=("$name")
  done < <(spec_validators_group_specs_raw)

  local count="${#SPEC_VALIDATOR_SPECS[@]}"
  if (( count < min_expected )); then
    echo "FAIL: validator list suspiciously short ($count < MIN_SPEC_VALIDATORS=$min_expected)" >&2
    return 1
  fi
  return 0
}
