#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_script="$repo_root/plans/prd_audit_check.sh"

if [[ ! -x "$check_script" ]]; then
  echo "FAIL: prd_audit_check.sh not executable at $check_script" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

prd="$tmp_dir/prd.json"
stdout_log="$tmp_dir/auditor_stdout.log"

cat > "$prd" <<'JSON'
{
  "items": [
    {
      "id": "S1-001"
    }
  ]
}
JSON

hash_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

prd_sha="$(hash_file "$prd")"
printf '%s\n' "<promise>AUDIT_COMPLETE</promise>" > "$stdout_log"

audit_empty_notes="$tmp_dir/audit_empty_notes.json"
cat > "$audit_empty_notes" <<JSON
{
  "project": "Fixture",
  "prd_sha256": "$prd_sha",
  "inputs": {},
  "summary": {
    "items_total": 1,
    "items_pass": 1,
    "items_fail": 0,
    "items_blocked": 0,
    "must_fix_count": 0
  },
  "global_findings": {
    "must_fix": [],
    "risk": [],
    "improvements": []
  },
  "items": [
    {
      "id": "S1-001",
      "slice": 1,
      "status": "PASS",
      "reasons": [],
      "schema_check": { "missing_fields": [], "notes": [] },
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
      "patch_suggestions": []
    }
  ]
}
JSON

set +e
output=$(PRD_FILE="$prd" AUDIT_FILE="$audit_empty_notes" AUDIT_STDOUT="$stdout_log" "$check_script" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected empty notes to be rejected" >&2
  exit 1
fi
if ! echo "$output" | grep -Fq "PASS items must include at least one non-empty note"; then
  echo "FAIL: missing empty-notes error" >&2
  echo "$output" >&2
  exit 1
fi

audit_with_notes="$tmp_dir/audit_with_notes.json"
cat > "$audit_with_notes" <<JSON
{
  "project": "Fixture",
  "prd_sha256": "$prd_sha",
  "inputs": {},
  "summary": {
    "items_total": 1,
    "items_pass": 1,
    "items_fail": 0,
    "items_blocked": 0,
    "must_fix_count": 0
  },
  "global_findings": {
    "must_fix": [],
    "risk": [],
    "improvements": []
  },
  "items": [
    {
      "id": "S1-001",
      "slice": 1,
      "status": "PASS",
      "reasons": [],
      "schema_check": { "missing_fields": [], "notes": ["checked schema"] },
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
      "patch_suggestions": []
    }
  ]
}
JSON

PRD_FILE="$prd" AUDIT_FILE="$audit_with_notes" AUDIT_STDOUT="$stdout_log" "$check_script" >/dev/null 2>&1

audit_missing_reasons="$tmp_dir/audit_missing_reasons.json"
cat > "$audit_missing_reasons" <<JSON
{
  "project": "Fixture",
  "prd_sha256": "$prd_sha",
  "inputs": {},
  "summary": {
    "items_total": 1,
    "items_pass": 0,
    "items_fail": 1,
    "items_blocked": 0,
    "must_fix_count": 1
  },
  "global_findings": {
    "must_fix": [],
    "risk": [],
    "improvements": []
  },
  "items": [
    {
      "id": "S1-001",
      "slice": 1,
      "status": "FAIL",
      "reasons": [],
      "schema_check": { "missing_fields": [], "notes": ["checked schema"] },
      "contract_check": {
        "refs_present": true,
        "refs_specific": true,
        "contract_refs_resolved": true,
        "acceptance_enforces_invariant": false,
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
      "patch_suggestions": []
    }
  ]
}
JSON

set +e
output=$(PRD_FILE="$prd" AUDIT_FILE="$audit_missing_reasons" AUDIT_STDOUT="$stdout_log" "$check_script" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected missing reasons to be rejected" >&2
  exit 1
fi
if ! echo "$output" | grep -Fq "FAIL/BLOCKED items require non-empty reasons"; then
  echo "FAIL: missing FAIL/BLOCKED reasons error" >&2
  echo "$output" >&2
  exit 1
fi

slice_prd="$tmp_dir/prd_slice.json"
slice_meta="$tmp_dir/prd_audit_meta.json"
slice_audit="$tmp_dir/audit_slice.json"

cat > "$slice_prd" <<'JSON'
{
  "items": [
    {
      "id": "S1-123"
    }
  ]
}
JSON

slice_sha="$(hash_file "$slice_prd")"

cat > "$slice_meta" <<JSON
{
  "audit_scope": "slice",
  "prd_slice_file": "$slice_prd"
}
JSON

cat > "$slice_audit" <<JSON
{
  "project": "Fixture",
  "prd_sha256": "$slice_sha",
  "inputs": {},
  "summary": {
    "items_total": 1,
    "items_pass": 1,
    "items_fail": 0,
    "items_blocked": 0,
    "must_fix_count": 0
  },
  "global_findings": {
    "must_fix": [],
    "risk": [],
    "improvements": []
  },
  "items": [
    {
      "id": "S1-123",
      "slice": 1,
      "status": "PASS",
      "reasons": [],
      "schema_check": { "missing_fields": [], "notes": ["checked schema"] },
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
      "patch_suggestions": []
    }
  ]
}
JSON

AUDIT_META_FILE="$slice_meta" AUDIT_FILE="$slice_audit" AUDIT_STDOUT="$stdout_log" "$check_script" >/dev/null 2>&1

echo "test_prd_audit_check.sh: ok"
