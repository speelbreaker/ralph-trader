#!/usr/bin/env bash
#
# Golden tests for prd_audit_merge.py
#
# Test cases:
#   TC1: Basic merge (2 slices, all PASS, inputs match)
#   TC2: Mixed statuses (PASS/FAIL/BLOCKED) + must_fix_count math
#   TC3: Global findings merge (must_fix, risk, improvements)
#   TC4: Empty global_findings
#   TC5: Slice ordering validation
#   TC6: Inputs mismatch -> merge fails (fail-closed)
#
set -euo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
merge_script="$repo_root/plans/prd_audit_merge.py"
check_script="$repo_root/plans/prd_audit_check.sh"

if [[ ! -f "$merge_script" ]]; then
  echo "FAIL: prd_audit_merge.py not found at $merge_script" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

hash_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

# Create common fixture PRD
prd="$tmp_dir/prd.json"
cat > "$prd" <<'JSON'
{
  "project": "TestProject",
  "items": [
    { "id": "S0-001", "slice": 0 },
    { "id": "S0-002", "slice": 0 },
    { "id": "S1-001", "slice": 1 },
    { "id": "S1-002", "slice": 1 }
  ]
}
JSON
prd_sha="$(hash_file "$prd")"

# Common inputs object
common_inputs='{"prd": "plans/prd.json", "contract": "CONTRACT.md"}'

# Helper to create a valid audit item
make_item() {
  local id="$1"
  local slice="$2"
  local status="$3"
  local reasons="${4:-[]}"
  local patches="${5:-[]}"
  local notes="${6:-[\"checked\"]}"

  cat <<JSON
{
  "id": "$id",
  "slice": $slice,
  "status": "$status",
  "reasons": $reasons,
  "schema_check": { "missing_fields": [], "notes": $notes },
  "contract_check": {
    "refs_present": true,
    "refs_specific": true,
    "contract_refs_resolved": true,
    "acceptance_enforces_invariant": true,
    "contradiction": false,
    "notes": []
  },
  "verify_check": {
    "has_verify_sh": true,
    "has_targeted_checks": true,
    "evidence_concrete": true,
    "notes": []
  },
  "scope_check": { "too_broad": false, "est_size_too_large": false, "notes": [] },
  "dependency_check": { "invalid": false, "forward_dep": false, "cycle": false, "notes": [] },
  "patch_suggestions": $patches
}
JSON
}

echo "=== TC1: Basic merge (2 slices, all PASS) ==="

tc1_dir="$tmp_dir/tc1"
mkdir -p "$tc1_dir"

# Slice 0 audit
cat > "$tc1_dir/audit_slice_0.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S0-001" 0 "PASS"),
    $(make_item "S0-002" 0 "PASS")
  ]
}
JSON

# Slice 1 audit
cat > "$tc1_dir/audit_slice_1.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S1-001" 1 "PASS"),
    $(make_item "S1-002" 1 "PASS")
  ]
}
JSON

merged="$tc1_dir/merged.json"
PRD_FILE="$prd" AUDIT_OUTPUT_DIR="$tc1_dir" MERGED_AUDIT_FILE="$merged" \
  python3 "$merge_script" 2>/dev/null

# Validate
if ! AUDIT_PROMISE_REQUIRED=0 PRD_FILE="$prd" AUDIT_FILE="$merged" "$check_script" >/dev/null 2>&1; then
  echo "FAIL: TC1 merged output failed validation" >&2
  exit 1
fi

# Check summary
items_total=$(jq '.summary.items_total' "$merged")
items_pass=$(jq '.summary.items_pass' "$merged")
if [[ "$items_total" != "4" ]] || [[ "$items_pass" != "4" ]]; then
  echo "FAIL: TC1 summary incorrect: total=$items_total, pass=$items_pass" >&2
  exit 1
fi

echo "TC1: ok"

echo "=== TC2: Mixed statuses + must_fix_count ==="

tc2_dir="$tmp_dir/tc2"
mkdir -p "$tc2_dir"

# Slice 0: 1 PASS, 1 FAIL
cat > "$tc2_dir/audit_slice_0.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 1, "items_fail": 1, "items_blocked": 0, "must_fix_count": 1 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S0-001" 0 "PASS"),
    $(make_item "S0-002" 0 "FAIL" '["missing contract ref"]' '["add contract ref"]')
  ]
}
JSON

# Slice 1: 1 PASS, 1 BLOCKED
cat > "$tc2_dir/audit_slice_1.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 1, "items_fail": 0, "items_blocked": 1, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S1-001" 1 "PASS"),
    $(make_item "S1-002" 1 "BLOCKED" '["depends on S0-002"]' '["fix S0-002 first"]')
  ]
}
JSON

merged="$tc2_dir/merged.json"
PRD_FILE="$prd" AUDIT_OUTPUT_DIR="$tc2_dir" MERGED_AUDIT_FILE="$merged" \
  python3 "$merge_script" 2>/dev/null

if ! AUDIT_PROMISE_REQUIRED=0 PRD_FILE="$prd" AUDIT_FILE="$merged" "$check_script" >/dev/null 2>&1; then
  echo "FAIL: TC2 merged output failed validation" >&2
  exit 1
fi

# Verify counts
items_fail=$(jq '.summary.items_fail' "$merged")
items_blocked=$(jq '.summary.items_blocked' "$merged")
must_fix_count=$(jq '.summary.must_fix_count' "$merged")

if [[ "$items_fail" != "1" ]] || [[ "$items_blocked" != "1" ]]; then
  echo "FAIL: TC2 status counts incorrect: fail=$items_fail, blocked=$items_blocked" >&2
  exit 1
fi

# must_fix_count = FAIL items (1) + global must_fix (0) = 1
if [[ "$must_fix_count" != "1" ]]; then
  echo "FAIL: TC2 must_fix_count incorrect: $must_fix_count (expected 1)" >&2
  exit 1
fi

echo "TC2: ok"

echo "=== TC3: Global findings merge ==="

tc3_dir="$tmp_dir/tc3"
mkdir -p "$tc3_dir"

# Slice 0 with global findings
cat > "$tc3_dir/audit_slice_0.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 1 },
  "global_findings": {
    "must_fix": ["Contract section 2.1 missing coverage"],
    "risk": ["Slice 0 has tight coupling"],
    "improvements": ["Consider splitting large stories"]
  },
  "items": [
    $(make_item "S0-001" 0 "PASS"),
    $(make_item "S0-002" 0 "PASS")
  ]
}
JSON

# Slice 1 with different global findings
cat > "$tc3_dir/audit_slice_1.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": {
    "must_fix": [],
    "risk": ["Dependencies could cause cascade"],
    "improvements": ["Add integration tests"]
  },
  "items": [
    $(make_item "S1-001" 1 "PASS"),
    $(make_item "S1-002" 1 "PASS")
  ]
}
JSON

merged="$tc3_dir/merged.json"
PRD_FILE="$prd" AUDIT_OUTPUT_DIR="$tc3_dir" MERGED_AUDIT_FILE="$merged" \
  python3 "$merge_script" 2>/dev/null

if ! AUDIT_PROMISE_REQUIRED=0 PRD_FILE="$prd" AUDIT_FILE="$merged" "$check_script" >/dev/null 2>&1; then
  echo "FAIL: TC3 merged output failed validation" >&2
  exit 1
fi

# Check global findings were concatenated
must_fix_len=$(jq '.global_findings.must_fix | length' "$merged")
risk_len=$(jq '.global_findings.risk | length' "$merged")
improvements_len=$(jq '.global_findings.improvements | length' "$merged")

if [[ "$must_fix_len" != "1" ]] || [[ "$risk_len" != "2" ]] || [[ "$improvements_len" != "2" ]]; then
  echo "FAIL: TC3 global findings not merged correctly" >&2
  echo "  must_fix=$must_fix_len (expected 1), risk=$risk_len (expected 2), improvements=$improvements_len (expected 2)" >&2
  exit 1
fi

# must_fix_count = FAIL items (0) + global must_fix (1) = 1
must_fix_count=$(jq '.summary.must_fix_count' "$merged")
if [[ "$must_fix_count" != "1" ]]; then
  echo "FAIL: TC3 must_fix_count incorrect: $must_fix_count (expected 1)" >&2
  exit 1
fi

echo "TC3: ok"

echo "=== TC4: Empty global_findings ==="

tc4_dir="$tmp_dir/tc4"
mkdir -p "$tc4_dir"

cat > "$tc4_dir/audit_slice_0.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S0-001" 0 "PASS"),
    $(make_item "S0-002" 0 "PASS")
  ]
}
JSON

cat > "$tc4_dir/audit_slice_1.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S1-001" 1 "PASS"),
    $(make_item "S1-002" 1 "PASS")
  ]
}
JSON

merged="$tc4_dir/merged.json"
PRD_FILE="$prd" AUDIT_OUTPUT_DIR="$tc4_dir" MERGED_AUDIT_FILE="$merged" \
  python3 "$merge_script" 2>/dev/null

if ! AUDIT_PROMISE_REQUIRED=0 PRD_FILE="$prd" AUDIT_FILE="$merged" "$check_script" >/dev/null 2>&1; then
  echo "FAIL: TC4 merged output failed validation" >&2
  exit 1
fi

echo "TC4: ok"

echo "=== TC5: Slice ordering validation ==="

tc5_dir="$tmp_dir/tc5"
mkdir -p "$tc5_dir"

# Items out of order within slices
cat > "$tc5_dir/audit_slice_0.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S0-002" 0 "PASS"),
    $(make_item "S0-001" 0 "PASS")
  ]
}
JSON

cat > "$tc5_dir/audit_slice_1.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": $common_inputs,
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S1-002" 1 "PASS"),
    $(make_item "S1-001" 1 "PASS")
  ]
}
JSON

merged="$tc5_dir/merged.json"
PRD_FILE="$prd" AUDIT_OUTPUT_DIR="$tc5_dir" MERGED_AUDIT_FILE="$merged" \
  python3 "$merge_script" 2>/dev/null

# Items should be sorted by (slice, id) in output
first_id=$(jq -r '.items[0].id' "$merged")
second_id=$(jq -r '.items[1].id' "$merged")
third_id=$(jq -r '.items[2].id' "$merged")
fourth_id=$(jq -r '.items[3].id' "$merged")

if [[ "$first_id" != "S0-001" ]] || [[ "$second_id" != "S0-002" ]] || \
   [[ "$third_id" != "S1-001" ]] || [[ "$fourth_id" != "S1-002" ]]; then
  echo "FAIL: TC5 items not sorted correctly" >&2
  echo "  Got: $first_id, $second_id, $third_id, $fourth_id" >&2
  echo "  Expected: S0-001, S0-002, S1-001, S1-002" >&2
  exit 1
fi

echo "TC5: ok"

echo "=== TC6: Inputs mismatch fails ==="

tc6_dir="$tmp_dir/tc6"
mkdir -p "$tc6_dir"

# Different inputs between slices
cat > "$tc6_dir/audit_slice_0.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": {"prd": "plans/prd.json", "contract": "CONTRACT.md"},
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S0-001" 0 "PASS"),
    $(make_item "S0-002" 0 "PASS")
  ]
}
JSON

cat > "$tc6_dir/audit_slice_1.json" <<JSON
{
  "project": "TestProject",
  "prd_sha256": "$prd_sha",
  "inputs": {"prd": "plans/prd.json", "contract": "OTHER_CONTRACT.md"},
  "summary": { "items_total": 2, "items_pass": 2, "items_fail": 0, "items_blocked": 0, "must_fix_count": 0 },
  "global_findings": { "must_fix": [], "risk": [], "improvements": [] },
  "items": [
    $(make_item "S1-001" 1 "PASS"),
    $(make_item "S1-002" 1 "PASS")
  ]
}
JSON

merged="$tc6_dir/merged.json"
set +e
output=$(PRD_FILE="$prd" AUDIT_OUTPUT_DIR="$tc6_dir" MERGED_AUDIT_FILE="$merged" \
  python3 "$merge_script" 2>&1)
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: TC6 expected merge to fail on inputs mismatch" >&2
  exit 1
fi

if ! echo "$output" | grep -q "inputs mismatch"; then
  echo "FAIL: TC6 error message should mention inputs mismatch" >&2
  echo "$output" >&2
  exit 1
fi

echo "TC6: ok"

echo ""
echo "test_prd_audit_merge.sh: all tests passed"
