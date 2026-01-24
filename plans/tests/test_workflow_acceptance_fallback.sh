#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -x "$ROOT/plans/workflow_acceptance.sh" ]]; then
  echo "FAIL: missing workflow_acceptance.sh" >&2
  exit 1
fi

set +e
output=$(VERIFY_ALLOW_DIRTY=1 WORKFLOW_ACCEPTANCE_MODE=clone WORKFLOW_ACCEPTANCE_SETUP_ONLY=1 \
  "$ROOT/plans/workflow_acceptance.sh" 2>&1)
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected clone setup to succeed (rc=$rc)" >&2
  echo "$output" >&2
  exit 1
fi

if ! echo "$output" | grep -Fq "workflow acceptance mode: clone"; then
  echo "FAIL: expected clone mode output" >&2
  echo "$output" >&2
  exit 1
fi

echo "test_workflow_acceptance_fallback.sh: ok"
