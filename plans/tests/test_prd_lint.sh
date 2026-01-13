#!/usr/bin/env bash

set -e

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
lint_script="$repo_root/plans/prd_lint.sh"

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cd "$tmp_dir"
git init -q

mkdir -p plans
touch touch.txt

echo '#!/usr/bin/env bash' > plans/verify.sh
chmod +x plans/verify.sh

cat <<'JSON' > plans/prd.json
{
  "items": [
    {
      "id": "S1-001",
      "slice": 1,
      "passes": true,
      "needs_human_decision": false,
      "description": "Missing verify gate",
      "scope": { "touch": ["touch.txt"] },
      "acceptance": ["Baseline acceptance"],
      "verify": ["echo ok"]
    },
    {
      "id": "S1-002",
      "slice": 1,
      "passes": true,
      "needs_human_decision": false,
      "description": "Contract mismatch",
      "scope": { "touch": ["touch.txt"] },
      "acceptance": ["Baseline acceptance"],
      "verify": ["./plans/verify.sh"],
      "contract_refs": ["Must reject; RiskState::Degraded on failure"]
    }
  ]
}
JSON

set +e
output=$("$lint_script" "plans/prd.json" 2>&1)
status=$?
set -e

if [[ $status -ne 2 ]]; then
  echo "Expected exit code 2, got $status"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "MISSING_VERIFY_SH"; then
  echo "Expected output to contain MISSING_VERIFY_SH"
  echo "$output"
  exit 1
fi

if ! echo "$output" | grep -q "CONTRACT_ACCEPTANCE_MISMATCH"; then
  echo "Expected output to contain CONTRACT_ACCEPTANCE_MISMATCH"
  echo "$output"
  exit 1
fi

# Test 2: scope.create allows new files when scope.touch is empty
mkdir -p new_dir
cat <<'JSON' > plans/prd_create_ok.json
{
  "items": [
    {
      "id": "S1-003",
      "slice": 1,
      "passes": false,
      "needs_human_decision": false,
      "description": "Create a new file",
      "scope": { "touch": [], "avoid": [], "create": ["new_dir/new_file.txt"] },
      "acceptance": ["a"],
      "verify": ["./plans/verify.sh"]
    }
  ]
}
JSON

set +e
output=$("$lint_script" "plans/prd_create_ok.json" 2>&1)
status=$?
set -e
if [[ $status -ne 0 ]]; then
  echo "Expected scope.create ok status 0, got $status"
  echo "$output"
  exit 1
fi

# Test 3: scope.create parent missing fails
cat <<'JSON' > plans/prd_create_missing_parent.json
{
  "items": [
    {
      "id": "S1-004",
      "slice": 1,
      "passes": false,
      "needs_human_decision": false,
      "description": "Missing parent",
      "scope": { "touch": [], "avoid": [], "create": ["missing_dir/new_file.txt"] },
      "acceptance": ["a"],
      "verify": ["./plans/verify.sh"]
    }
  ]
}
JSON

set +e
output=$("$lint_script" "plans/prd_create_missing_parent.json" 2>&1)
status=$?
set -e
if [[ $status -ne 2 ]]; then
  echo "Expected CREATE_PARENT_MISSING exit code 2, got $status"
  echo "$output"
  exit 1
fi
if ! echo "$output" | grep -q "CREATE_PARENT_MISSING"; then
  echo "Expected output to contain CREATE_PARENT_MISSING"
  echo "$output"
  exit 1
fi

# Test 4: scope.create existing path fails
touch new_dir/existing.txt
cat <<'JSON' > plans/prd_create_exists.json
{
  "items": [
    {
      "id": "S1-005",
      "slice": 1,
      "passes": false,
      "needs_human_decision": false,
      "description": "Existing path",
      "scope": { "touch": [], "avoid": [], "create": ["new_dir/existing.txt"] },
      "acceptance": ["a"],
      "verify": ["./plans/verify.sh"]
    }
  ]
}
JSON

set +e
output=$("$lint_script" "plans/prd_create_exists.json" 2>&1)
status=$?
set -e
if [[ $status -ne 2 ]]; then
  echo "Expected CREATE_PATH_EXISTS exit code 2, got $status"
  echo "$output"
  exit 1
fi
if ! echo "$output" | grep -q "CREATE_PATH_EXISTS"; then
  echo "Expected output to contain CREATE_PATH_EXISTS"
  echo "$output"
  exit 1
fi

# Test 5: strict heuristics gate
cat <<'JSON' > plans/prd_strict_heuristics.json
{
  "items": [
    {
      "id": "S1-006",
      "slice": 1,
      "passes": false,
      "needs_human_decision": false,
      "description": "Strict heuristics",
      "scope": { "touch": ["touch.txt"], "avoid": [] },
      "acceptance": ["baseline"],
      "verify": ["./plans/verify.sh"],
      "contract_refs": ["Must reject on failure"]
    }
  ]
}
JSON

set +e
output=$(PRD_LINT_STRICT_HEURISTICS=1 "$lint_script" "plans/prd_strict_heuristics.json" 2>&1)
status=$?
set -e
if [[ $status -ne 2 ]]; then
  echo "Expected strict heuristics exit code 2, got $status"
  echo "$output"
  exit 1
fi
if ! echo "$output" | grep -q "CONTRACT_ACCEPTANCE_MISMATCH"; then
  echo "Expected strict heuristics to flag CONTRACT_ACCEPTANCE_MISMATCH"
  echo "$output"
  exit 1
fi

set +e
output=$(PRD_LINT_STRICT_HEURISTICS=0 "$lint_script" "plans/prd_strict_heuristics.json" 2>&1)
status=$?
set -e
if [[ $status -ne 0 ]]; then
  echo "Expected non-strict heuristics exit code 0, got $status"
  echo "$output"
  exit 1
fi

echo "test_prd_lint.sh: ok"
