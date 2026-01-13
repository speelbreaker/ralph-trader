#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

file="${1:-}"
if [[ -z "$file" ]]; then
  echo "ERROR: missing contract review JSON path" >&2
  echo "Usage: $0 path/to/contract_review.json" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

if [[ ! -f "$file" ]]; then
  echo "ERROR: contract review JSON not found: $file" >&2
  exit 1
fi

if ! jq -e . "$file" >/dev/null 2>&1; then
  echo "ERROR: invalid JSON in $file" >&2
  exit 1
fi

schema_file="${CONTRACT_REVIEW_SCHEMA:-docs/schemas/contract_review.schema.json}"
if [[ ! -f "$schema_file" ]]; then
  echo "ERROR: contract review schema not found: $schema_file" >&2
  exit 1
fi

if ! jq -e . "$schema_file" >/dev/null 2>&1; then
  echo "ERROR: invalid JSON schema: $schema_file" >&2
  exit 1
fi

schema_get() {
  local jq_path="$1"
  local label="$2"
  local out
  out="$(jq -c "$jq_path" "$schema_file" 2>/dev/null || true)"
  if [[ -z "$out" || "$out" == "null" ]]; then
    echo "ERROR: schema missing $label ($jq_path)" >&2
    exit 1
  fi
  echo "$out"
}

root_required="$(schema_get '.required' 'root.required')"
root_props="$(schema_get '.properties | keys' 'root.properties')"

decision_enum="$(schema_get '.properties.decision.enum' 'decision.enum')"
confidence_enum="$(schema_get '.properties.confidence.enum' 'confidence.enum')"

scope_required="$(schema_get '.properties.scope_check.required' 'scope_check.required')"
scope_props="$(schema_get '.properties.scope_check.properties | keys' 'scope_check.properties')"

verify_required="$(schema_get '.properties.verify_check.required' 'verify_check.required')"
verify_props="$(schema_get '.properties.verify_check.properties | keys' 'verify_check.properties')"

pass_required="$(schema_get '.properties.pass_flip_check.required' 'pass_flip_check.required')"
pass_props="$(schema_get '.properties.pass_flip_check.properties | keys' 'pass_flip_check.properties')"
pass_decision_enum="$(schema_get '.properties.pass_flip_check.properties.decision_on_pass_flip.enum' 'pass_flip_check.decision_on_pass_flip.enum')"

violations_required="$(schema_get '.properties.violations.items.required' 'violations.items.required')"
violations_props="$(schema_get '.properties.violations.items.properties | keys' 'violations.items.properties')"
violations_severity_enum="$(schema_get '.properties.violations.items.properties.severity.enum' 'violations.items.properties.severity.enum')"
violations_action_enum="$(schema_get '.properties.violations.items.properties.recommended_action.enum' 'violations.items.properties.recommended_action.enum')"

errors="$(
  jq -r \
    --argjson root_required "$root_required" \
    --argjson root_props "$root_props" \
    --argjson decision_enum "$decision_enum" \
    --argjson confidence_enum "$confidence_enum" \
    --argjson scope_required "$scope_required" \
    --argjson scope_props "$scope_props" \
    --argjson verify_required "$verify_required" \
    --argjson verify_props "$verify_props" \
    --argjson pass_required "$pass_required" \
    --argjson pass_props "$pass_props" \
    --argjson pass_decision_enum "$pass_decision_enum" \
    --argjson violations_required "$violations_required" \
    --argjson violations_props "$violations_props" \
    --argjson violations_severity_enum "$violations_severity_enum" \
    --argjson violations_action_enum "$violations_action_enum" \
    '
    def check(cond; msg): if cond then empty else msg end;
    def in_enum(val; options): val as $v | (options | index($v)) != null;
    def has_all(obj; reqs): (obj) as $o | reqs | all(. as $k | $o | has($k));
    def keys_ok(obj; allowed): (obj) as $o | (($o|keys) - allowed | length) == 0;
    [
      check(type=="object"; "root must be an object"),
      check(has_all(.; $root_required); "root missing required keys"),
      check(keys_ok(.; $root_props); "root has unknown keys"),
      check((.selected_story_id|type=="string" and length>0); "selected_story_id missing or empty"),
      check((.decision|type=="string") and (in_enum(.decision; $decision_enum)); "decision must match schema enum"),
      check((.confidence|type=="string") and (in_enum(.confidence; $confidence_enum)); "confidence must match schema enum"),
      check((.contract_refs_checked|type=="array"); "contract_refs_checked must be array"),
      check((.contract_refs_checked|all(.[]?; type=="string" and length>0)); "contract_refs_checked items must be non-empty strings"),

      check((.scope_check|type=="object"); "scope_check must be object"),
      check(has_all(.scope_check; $scope_required); "scope_check missing required keys"),
      check(keys_ok(.scope_check; $scope_props); "scope_check has unknown keys"),
      check((.scope_check.changed_files|type=="array"); "scope_check.changed_files must be array"),
      check((.scope_check.out_of_scope_files|type=="array"); "scope_check.out_of_scope_files must be array"),
      check((.scope_check.notes|type=="array"); "scope_check.notes must be array"),

      check((.verify_check|type=="object"); "verify_check must be object"),
      check(has_all(.verify_check; $verify_required); "verify_check missing required keys"),
      check(keys_ok(.verify_check; $verify_props); "verify_check has unknown keys"),
      check((.verify_check.verify_post_present|type=="boolean"); "verify_check.verify_post_present must be boolean"),
      check((.verify_check.verify_post_green|type=="boolean"); "verify_check.verify_post_green must be boolean"),
      check((.verify_check.notes|type=="array"); "verify_check.notes must be array"),

      check((.pass_flip_check|type=="object"); "pass_flip_check must be object"),
      check(has_all(.pass_flip_check; $pass_required); "pass_flip_check missing required keys"),
      check(keys_ok(.pass_flip_check; $pass_props); "pass_flip_check has unknown keys"),
      check((.pass_flip_check.requested_mark_pass_id|type=="string" and length>0); "pass_flip_check.requested_mark_pass_id missing or empty"),
      check((.pass_flip_check.prd_passes_before|type=="boolean"); "pass_flip_check.prd_passes_before must be boolean"),
      check((.pass_flip_check.prd_passes_after|type=="boolean"); "pass_flip_check.prd_passes_after must be boolean"),
      check((.pass_flip_check.evidence_required|type=="array"); "pass_flip_check.evidence_required must be array"),
      check((.pass_flip_check.evidence_found|type=="array"); "pass_flip_check.evidence_found must be array"),
      check((.pass_flip_check.evidence_missing|type=="array"); "pass_flip_check.evidence_missing must be array"),
      check((.pass_flip_check.decision_on_pass_flip|type=="string") and (in_enum(.pass_flip_check.decision_on_pass_flip; $pass_decision_enum)); "pass_flip_check.decision_on_pass_flip must match schema enum"),

      check((.violations|type=="array"); "violations must be array"),
      check((.violations|all(.[]?; type=="object")); "violations entries must be objects"),
      check((.violations|all(.[]?; has_all(.; $violations_required))); "violations entries missing required keys"),
      check((.violations|all(.[]?; keys_ok(.; $violations_props))); "violations entries have unknown keys"),
      check((.violations|all(.[]?; (.severity|type=="string") and (in_enum(.severity; $violations_severity_enum)))); "violations.severity must match schema enum"),
      check((.violations|all(.[]?; (.contract_ref|type=="string" and length>0))); "violations.contract_ref must be non-empty string"),
      check((.violations|all(.[]?; (.description|type=="string" and length>0))); "violations.description must be non-empty string"),
      check((.violations|all(.[]?; (.evidence_in_diff|type=="string" and length>0))); "violations.evidence_in_diff must be non-empty string"),
      check((.violations|all(.[]?; (.changed_files|type=="array"))); "violations.changed_files must be array"),
      check((.violations|all(.[]?; (.recommended_action|type=="string") and (in_enum(.recommended_action; $violations_action_enum)))); "violations.recommended_action must match schema enum"),

      check((.required_followups|type=="array"); "required_followups must be array"),
      check((.required_followups|all(.[]?; type=="string" and length>0)); "required_followups items must be non-empty strings"),
      check((.rationale|type=="array"); "rationale must be array"),
      check((.rationale|all(.[]?; type=="string" and length>0)); "rationale items must be non-empty strings")
    ] | .[]?
    ' "$file"
)"

if [[ -n "$errors" ]]; then
  echo "ERROR: contract review schema invalid: $file" >&2
  printf '%s\n' "$errors" | sed 's/^/- /' >&2
  exit 1
fi

exit 0
