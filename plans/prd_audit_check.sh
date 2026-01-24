#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${PRD_FILE:-plans/prd.json}"
AUDIT_FILE="${AUDIT_FILE:-plans/prd_audit.json}"
AUDIT_STDOUT="${AUDIT_STDOUT:-.context/prd_auditor_stdout.log}"
AUDIT_PROMISE="${AUDIT_PROMISE:-<promise>AUDIT_COMPLETE</promise>}"
AUDIT_PROMISE_REQUIRED="${AUDIT_PROMISE_REQUIRED:-1}"
AUDIT_META_FILE="${AUDIT_META_FILE:-.context/prd_audit_meta.json}"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

if ! command -v jq >/dev/null 2>&1; then
  fail "jq required"
fi

if [[ -z "$AUDIT_FILE" || ! -f "$AUDIT_FILE" ]]; then
  fail "missing audit file: $AUDIT_FILE"
fi
if ! jq -e . "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "audit file is not valid JSON: $AUDIT_FILE"
fi

if [[ -f "$AUDIT_META_FILE" ]]; then
  audit_scope="$(jq -r '.audit_scope // empty' "$AUDIT_META_FILE" 2>/dev/null || true)"
  prd_slice_file="$(jq -r '.prd_slice_file // empty' "$AUDIT_META_FILE" 2>/dev/null || true)"
  if [[ "$audit_scope" == "slice" && -n "$prd_slice_file" && "$PRD_FILE" == "plans/prd.json" ]]; then
    PRD_FILE="$prd_slice_file"
  fi
fi

if [[ -z "$PRD_FILE" || ! -f "$PRD_FILE" ]]; then
  fail "missing PRD file: $PRD_FILE"
fi

if [[ "$AUDIT_PROMISE_REQUIRED" == "1" ]]; then
  if [[ -z "$AUDIT_STDOUT" || ! -f "$AUDIT_STDOUT" ]]; then
    fail "missing auditor stdout log: $AUDIT_STDOUT"
  fi
  if ! grep -Fq "$AUDIT_PROMISE" "$AUDIT_STDOUT"; then
    fail "auditor stdout missing promise: $AUDIT_PROMISE"
  fi
fi

hash_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

prd_sha="$(hash_file "$PRD_FILE")"
audit_sha="$(jq -r '.prd_sha256 // empty' "$AUDIT_FILE")"
if [[ -z "$audit_sha" || "$audit_sha" != "$prd_sha" ]]; then
  fail "prd_sha256 mismatch in audit file (expected $prd_sha, got $audit_sha)"
fi

prd_ids="$(jq -r '.items[]?.id // empty' "$PRD_FILE" | sort -u)"
audit_ids="$(jq -r '.items[]?.id // empty' "$AUDIT_FILE" | sort -u)"
if [[ -z "$prd_ids" ]]; then
  fail "PRD contains no item ids"
fi
if [[ "$prd_ids" != "$audit_ids" ]]; then
  echo "ERROR: audit items must match PRD item ids" >&2
  echo "PRD ids:" >&2
  echo "$prd_ids" >&2
  echo "Audit ids:" >&2
  echo "$audit_ids" >&2
  exit 2
fi

if ! jq -e '
  (.items | type == "array") and
  (.summary | type == "object") and
  (.global_findings | type == "object")
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "audit file missing required top-level keys (items/summary/global_findings)"
fi

if ! jq -e '
  all(.items[];
    (.status | type=="string") and
    (.status as $status | ["PASS","FAIL","BLOCKED"] | index($status) != null)
  )
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "audit items contain invalid status (allowed: PASS|FAIL|BLOCKED)"
fi

if ! jq -e '
  all(.items[]; (.reasons | type=="array") and (.patch_suggestions | type=="array"))
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "audit items must include reasons[] and patch_suggestions[] arrays"
fi

if ! jq -e '
  all(.items[];
    if (.status == "FAIL" or .status == "BLOCKED") then
      ((.reasons | map(select(type=="string" and length>0)) | length) > 0)
      and ((.patch_suggestions | map(select(type=="string" and length>0)) | length) > 0)
    else true end
  )
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "FAIL/BLOCKED items require non-empty reasons[] and patch_suggestions[]"
fi

if ! jq -e '
  def notes_count:
    ((.schema_check.notes // []) + (.contract_check.notes // []) + (.verify_check.notes // []) + (.scope_check.notes // []) + (.dependency_check.notes // []))
    | map(select(type=="string" and length>0))
    | length;
  all(.items[];
    if (.status == "PASS") then
      (notes_count > 0)
    else true end
  )
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "PASS items must include at least one non-empty note"
fi

if ! jq -e '
  (.global_findings.must_fix | type=="array") and
  (.global_findings.risk | type=="array") and
  (.global_findings.improvements | type=="array")
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "global_findings must include must_fix, risk, improvements arrays"
fi

if ! jq -e '
  (.summary.items_total | tonumber? != null) and
  (.summary.items_pass | tonumber? != null) and
  (.summary.items_fail | tonumber? != null) and
  (.summary.items_blocked | tonumber? != null) and
  (.summary.must_fix_count | tonumber? != null)
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "summary counts must be numeric"
fi

if ! jq -e '
  ( .items | length ) as $total
  | ( [ .items[] | select(.status=="PASS") ] | length ) as $pass
  | ( [ .items[] | select(.status=="FAIL") ] | length ) as $fail
  | ( [ .items[] | select(.status=="BLOCKED") ] | length ) as $blocked
  | ( .global_findings.must_fix | length ) as $must_fix
  | ( .summary.items_total == $total )
    and ( .summary.items_pass == $pass )
    and ( .summary.items_fail == $fail )
    and ( .summary.items_blocked == $blocked )
    and ( .summary.must_fix_count == ($fail + $must_fix) )
' "$AUDIT_FILE" >/dev/null 2>&1; then
  fail "summary counts must match item statuses and global must_fix"
fi

echo "PRD audit check OK"
