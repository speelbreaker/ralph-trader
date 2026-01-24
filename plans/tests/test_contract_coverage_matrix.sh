#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo_root/plans/contract_coverage_matrix.py"

if [[ ! -x "$script" ]]; then
  echo "FAIL: contract_coverage_matrix.py not executable at $script" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

kernel="$tmp_dir/contract_kernel.json"
prd="$tmp_dir/prd.json"
out="$tmp_dir/coverage.md"
stderr="$tmp_dir/stderr.log"

cat > "$kernel" <<'JSON'
{
  "anchors": [
    { "id": "Anchor-999", "title": "Kernel Anchor" }
  ],
  "validation_rules": [
    { "id": "VR-999", "title": "Kernel Rule" }
  ]
}
JSON

cat > "$prd" <<'JSON'
{
  "items": [
    {
      "id": "S1-000",
      "contract_refs": []
    }
  ]
}
JSON

set +e
CONTRACT_KERNEL="$kernel" \
  CONTRACT_ANCHORS="$tmp_dir/missing_anchors.md" \
  VALIDATION_RULES="$tmp_dir/missing_rules.md" \
  CONTRACT_COVERAGE_OUT="$out" \
  CONTRACT_COVERAGE_STRICT=1 \
  PRD_FILE="$prd" \
  python3 "$script" 2> "$stderr"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected contract_coverage_matrix.py to fail under strict missing coverage" >&2
  exit 1
fi
if ! grep -Fq "Anchor-999" "$stderr"; then
  echo "FAIL: missing Anchor-999 in contract coverage error output" >&2
  cat "$stderr" >&2
  exit 1
fi
if ! grep -Fq "VR-999" "$stderr"; then
  echo "FAIL: missing VR-999 in contract coverage error output" >&2
  cat "$stderr" >&2
  exit 1
fi

echo "test_contract_coverage_matrix.sh: ok"
