#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

warn() { :; }
is_ci() { return 1; }
is_workflow_file() {
  [[ "$1" == "plans/verify.sh" ]]
}

source "$ROOT/plans/lib/change_detection.sh"

WORKFLOW_ACCEPTANCE_POLICY=auto
MODE=quick
CHANGE_DETECTION_OK=1

CHANGED_FILES="Cargo.toml"
should_run_rust_gates || fail "expected rust gates"
should_run_python_gates && fail "unexpected python gates"
should_run_node_gates && fail "unexpected node gates"

CHANGED_FILES="plans/verify.sh"
workflow_files_changed || fail "expected workflow files changed"
should_run_workflow_acceptance || fail "expected workflow acceptance"
[[ "$(workflow_acceptance_mode)" == "full" ]] || fail "expected workflow acceptance full mode"

CHANGED_FILES=$'Cargo.toml\npyproject.toml\npackage.json'
should_run_rust_gates || fail "expected rust gates"
should_run_python_gates || fail "expected python gates"
should_run_node_gates || fail "expected node gates"

CHANGE_DETECTION_OK=0
CHANGED_FILES=""
should_run_rust_gates || fail "expected rust gates when change detection missing"
should_run_python_gates || fail "expected python gates when change detection missing"
should_run_node_gates || fail "expected node gates when change detection missing"
should_run_workflow_acceptance || fail "expected workflow acceptance when change detection missing"
[[ "$(workflow_acceptance_mode)" == "full" ]] || fail "expected workflow acceptance full mode when change detection missing"
