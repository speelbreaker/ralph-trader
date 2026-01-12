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

echo "$output" | grep -q "MISSING_VERIFY_SH"
echo "$output" | grep -q "CONTRACT_ACCEPTANCE_MISMATCH"

echo "test_prd_lint.sh: ok"
