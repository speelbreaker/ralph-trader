#!/usr/bin/env bash
set -euo pipefail

# Local convenience for workflow maintenance. CI still runs ./plans/verify.sh (change-aware).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

check_script() {
  local path="$1"
  if [[ -f "$path" ]]; then
    bash -n "$path"
  fi
}

check_script "plans/verify.sh"
check_script "plans/ralph.sh"
check_script "plans/update_task.sh"
check_script "plans/workflow_acceptance.sh"

./plans/workflow_acceptance.sh --mode full

if [[ "${RUN_REPO_VERIFY:-0}" == "1" ]]; then
  ./plans/verify.sh quick
fi
