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

errors="$(
  jq -r '
    def check(cond; msg): if cond then empty else msg end;
    def in_enum(val; options): val as $v | (options | index($v)) != null;
    [
      check(type=="object"; "root must be an object"),
      check((.selected_story_id|type=="string" and length>0); "selected_story_id missing or empty"),
      check((.decision|type=="string") and (in_enum(.decision; ["PASS","FAIL","BLOCKED"])); "decision must be PASS|FAIL|BLOCKED"),
      check((.confidence|type=="string") and (in_enum(.confidence; ["high","med","low"])); "confidence must be high|med|low"),
      check((.contract_refs_checked|type=="array"); "contract_refs_checked must be array"),
      check((.contract_refs_checked|all(.[]?; type=="string" and length>0)); "contract_refs_checked items must be non-empty strings"),
      check((.scope_check|type=="object"); "scope_check must be object"),
      check((.scope_check.changed_files|type=="array"); "scope_check.changed_files must be array"),
      check((.scope_check.out_of_scope_files|type=="array"); "scope_check.out_of_scope_files must be array"),
      check((.scope_check.notes|type=="array"); "scope_check.notes must be array"),
      check((.verify_check|type=="object"); "verify_check must be object"),
      check((.verify_check.verify_post_present|type=="boolean"); "verify_check.verify_post_present must be boolean"),
      check((.verify_check.verify_post_green|type=="boolean"); "verify_check.verify_post_green must be boolean"),
      check((.verify_check.notes|type=="array"); "verify_check.notes must be array"),
      check((.pass_flip_check|type=="object"); "pass_flip_check must be object"),
      check((.pass_flip_check.requested_mark_pass_id|type=="string" and length>0); "pass_flip_check.requested_mark_pass_id missing or empty"),
      check((.pass_flip_check.prd_passes_before|type=="boolean"); "pass_flip_check.prd_passes_before must be boolean"),
      check((.pass_flip_check.prd_passes_after|type=="boolean"); "pass_flip_check.prd_passes_after must be boolean"),
      check((.pass_flip_check.evidence_required|type=="array"); "pass_flip_check.evidence_required must be array"),
      check((.pass_flip_check.evidence_found|type=="array"); "pass_flip_check.evidence_found must be array"),
      check((.pass_flip_check.evidence_missing|type=="array"); "pass_flip_check.evidence_missing must be array"),
      check((.pass_flip_check.decision_on_pass_flip|type=="string") and (in_enum(.pass_flip_check.decision_on_pass_flip; ["ALLOW","DENY","BLOCKED"])); "pass_flip_check.decision_on_pass_flip must be ALLOW|DENY|BLOCKED"),
      check((.violations|type=="array"); "violations must be array"),
      check((.violations|all(.[]?; type=="object" and
        (.severity|type=="string") and (in_enum(.severity; ["CRITICAL","MAJOR","MINOR"])) and
        (.contract_ref|type=="string" and length>0) and
        (.description|type=="string" and length>0) and
        (.evidence_in_diff|type=="string" and length>0) and
        (.changed_files|type=="array") and
        (.recommended_action|type=="string") and (in_enum(.recommended_action; ["REVERT","PATCH_CONTRACT","PATCH_CODE","NEEDS_HUMAN"]))
      )); "violations entries invalid"),
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
