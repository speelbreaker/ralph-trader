#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${1:-plans/prd.json}"
PRD_SCHEMA_MIN_ACCEPTANCE="${PRD_SCHEMA_MIN_ACCEPTANCE:-3}"
PRD_SCHEMA_MIN_STEPS="${PRD_SCHEMA_MIN_STEPS:-5}"
PRD_SCHEMA_DRAFT_MODE="${PRD_SCHEMA_DRAFT_MODE:-0}"

FLOOR_ACCEPTANCE=3
FLOOR_STEPS=5

if ! [[ "$PRD_SCHEMA_MIN_ACCEPTANCE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PRD_SCHEMA_MIN_ACCEPTANCE must be an integer" >&2
  exit 2
fi
if ! [[ "$PRD_SCHEMA_MIN_STEPS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PRD_SCHEMA_MIN_STEPS must be an integer" >&2
  exit 2
fi

if (( PRD_SCHEMA_MIN_ACCEPTANCE < FLOOR_ACCEPTANCE || PRD_SCHEMA_MIN_STEPS < FLOOR_STEPS )); then
  if [[ "$PRD_SCHEMA_DRAFT_MODE" == "1" ]]; then
    echo "WARN: PRD_SCHEMA_DRAFT_MODE=1 allows thresholds below contract floors (acceptance>=${PRD_SCHEMA_MIN_ACCEPTANCE}, steps>=${PRD_SCHEMA_MIN_STEPS}). Drafting mode is blocked from execution." >&2
  else
    echo "ERROR: PRD_SCHEMA_MIN_ACCEPTANCE/MIN_STEPS below contract floors (${FLOOR_ACCEPTANCE}/${FLOOR_STEPS}). Set PRD_SCHEMA_DRAFT_MODE=1 to allow draft-only checks." >&2
    exit 2
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for PRD schema validation" >&2
  exit 2
fi

if [[ ! -f "$PRD_FILE" ]]; then
  echo "ERROR: missing PRD file: $PRD_FILE" >&2
  exit 3
fi

if ! jq . "$PRD_FILE" >/dev/null 2>&1; then
  echo "ERROR: PRD is not valid JSON: $PRD_FILE" >&2
  exit 4
fi

errors="$(
  jq -r --argjson min_acceptance "$PRD_SCHEMA_MIN_ACCEPTANCE" --argjson min_steps "$PRD_SCHEMA_MIN_STEPS" '
    def err($id; $msg): "\($id): \($msg)";
    def missing_fields($obj; $fields):
      [$fields[] as $f | select($obj | has($f) | not) | $f];

    def text_blob($it):
      ([($it.description // "")] + ($it.acceptance // []) + ($it.steps // []) + ($it.verify // []))
      | map(tostring)
      | join(" ");

    def has_placeholders($it):
      (text_blob($it)
        | test("(^|[^A-Za-z0-9_])(TODO|TBD|FIXME)([^A-Za-z0-9_]|$)|\\?\\?\\?"; "i"));

    def check_dependencies($it; $ids; $by_id):
      ($it.id // "<no id>") as $id
      | (
          if ($it.dependencies|type)!="array" then [err($id; "dependencies must be array")]
          elif ([ $it.dependencies[] | select(type!="string") ] | length) > 0 then [err($id; "dependencies must be array of strings")]
          else [] end
        )
      + (
          if ($it.dependencies|type)=="array" then
            ([$it.dependencies[] | select(. == $it.id)] | length > 0) as $self
            | if $self then [err($id; "dependency cannot include self")] else [] end
          else [] end
        )
      + (
          if ($it.dependencies|type)=="array" then
            ($it.dependencies
              | map(select(($ids | index(.)) == null))
              | map(err($id; "dependency id not found: " + .)))
          else [] end
        )
      + (
          if ($it.dependencies|type)=="array" then
            ($it.dependencies
              | map(select(($ids | index(.)) != null))
              | map(select((($by_id[.] // {}) | .slice // -1) > ($it.slice // -1)))
              | map(. as $dep | err($id; "dependency slice higher than item: \($dep) (dep_slice=\((($by_id[$dep] // {}) | .slice // -1)), item_slice=\($it.slice // -1))")))
          else [] end
        );

    def check_top:
      (if (has("project") and has("source") and has("rules") and has("items") and (.items|type=="array")) then [] else ["<top>: missing project/source/rules/items or items not array"] end)
      + (if (.source|has("implementation_plan_path")) then [] else ["<top>: missing source.implementation_plan_path"] end)
      + (if (.source|has("contract_path")) then [] else ["<top>: missing source.contract_path"] end)
      + (if ((.rules|has("one_story_per_iteration")) and (.rules.one_story_per_iteration==true)) then [] else ["<top>: rules.one_story_per_iteration must be true"] end)
      + (if ((.rules|has("one_commit_per_story")) and (.rules.one_commit_per_story==true)) then [] else ["<top>: rules.one_commit_per_story must be true"] end)
      + (if ((.rules|has("no_prd_rewrite")) and (.rules.no_prd_rewrite==true)) then [] else ["<top>: rules.no_prd_rewrite must be true"] end)
      + (if ((.rules|has("passes_only_flips_after_verify_green")) and (.rules.passes_only_flips_after_verify_green==true)) then [] else ["<top>: rules.passes_only_flips_after_verify_green must be true"] end);

    def check_item($it; $ids; $by_id):
      ($it.id // "<no id>") as $id
      | (missing_fields($it; [
          "id","priority","phase","slice","slice_ref","story_ref","category","description",
          "contract_refs","plan_refs","scope","acceptance","steps","verify","evidence",
          "contract_must_evidence","enforcing_contract_ats","reason_codes","enforcement_point",
          "failure_mode","observability","implementation_tests",
          "dependencies","est_size","risk","needs_human_decision","passes"
        ])
        | map(err($id; "missing field " + .)))
      + (
        if ($it.scope? and ($it.scope|type)=="object") then
          (missing_fields($it.scope; ["touch","avoid"]) | map(err($id; "missing scope." + .)))
        else
          [err($id; "missing scope")]
        end
      )
      + (
        if ($it.id? and ($it.slice?)) then
          if ($it.id|test("^S[0-9]+-[0-9]{3}$")) then
            ($it.id|capture("^S(?<slice>[0-9]+)-").slice|tonumber) as $slice_from_id
            | if ($slice_from_id != $it.slice) then
                [err($id; "id slice mismatch (id implies S\($slice_from_id), slice=\($it.slice))")]
              else [] end
          else [err($id; "id format must be S{slice}-{NNN}")] end
        else [] end
      )
      + (
        if ($it.acceptance|type)!="array" then [err($id; "acceptance must be array")]
        elif ($it.acceptance|length < $min_acceptance) then [err($id; "acceptance must have >=\($min_acceptance) items")]
        else [] end
      )
      + (
        if ($it.steps|type)!="array" then [err($id; "steps must be array")]
        elif ($it.steps|length < $min_steps) then [err($id; "steps must have >=\($min_steps) items")]
        else [] end
      )
      + (
        if ($it.verify|type)!="array" then [err($id; "verify must be array")]
        elif ($it.verify | index("./plans/verify.sh") == null) then [err($id; "verify[] missing ./plans/verify.sh")]
        else [] end
      )
      + (
        if ($it.verify|type)=="array" then
          ([ $it.verify[] | select(. != "./plans/verify.sh") ] | length) as $extra
          | if ($extra < 1) then
              if ($it.needs_human_decision == true) then [] else [err($id; "verify must include at least one targeted check (non-./plans/verify.sh) or needs_human_decision=true")] end
            else [] end
        else [] end
      )
      + (
        if ($it.evidence|type)!="array" then [err($id; "evidence must be array")]
        elif ([ $it.evidence[] | select(type!="string") ] | length) > 0 then [err($id; "evidence must be array of strings")]
        elif ($it.evidence|length < 1) then [err($id; "evidence must have >=1 items")]
        else [] end
      )
      + (
        if ($it.contract_must_evidence|type)!="array" then [err($id; "contract_must_evidence must be array")]
        elif ([ $it.contract_must_evidence[] | select(type!="object") ] | length) > 0 then [err($id; "contract_must_evidence must contain objects")]
        elif ([ $it.contract_must_evidence[] | select((.quote|type)!="string" or (.location|type)!="string" or (.anchor|type)!="string") ] | length) > 0 then [err($id; "contract_must_evidence entries must include quote/location/anchor strings")]
        elif ([ $it.contract_must_evidence[] | select((.quote|length)==0 or (.location|length)==0 or (.anchor|length)==0) ] | length) > 0 then [err($id; "contract_must_evidence entries must be non-empty strings")]
        else [] end
      )
      + (
        if ($it.enforcing_contract_ats|type)!="array" then [err($id; "enforcing_contract_ats must be array")]
        elif ([ $it.enforcing_contract_ats[] | select(type!="string") ] | length) > 0 then [err($id; "enforcing_contract_ats must be array of strings")]
        elif ([ $it.enforcing_contract_ats[] | select(length==0) ] | length) > 0 then [err($id; "enforcing_contract_ats entries must be non-empty strings")]
        elif ([ $it.enforcing_contract_ats[] | select(test("^AT-[0-9]+$")|not) ] | length) > 0 then [err($id; "enforcing_contract_ats entries must match AT-###")]
        else [] end
      )
      + (
        if ($it.reason_codes|type)!="object" then [err($id; "reason_codes must be object")]
        elif ($it.reason_codes.type|type)!="string" then [err($id; "reason_codes.type must be string")]
        elif (($it.reason_codes.type|length>0) and ($it.reason_codes.type|test("^(ModeReasonCode|OpenPermissionReasonCode|RejectReason)$")|not)) then [err($id; "reason_codes.type must be ModeReasonCode|OpenPermissionReasonCode|RejectReason when set")]
        elif ($it.reason_codes.values|type)!="array" then [err($id; "reason_codes.values must be array")]
        elif ([ $it.reason_codes.values[] | select(type!="string") ] | length) > 0 then [err($id; "reason_codes.values must be array of strings")]
        else [] end
      )
      + (
        if ($it.enforcement_point|type)!="string" then [err($id; "enforcement_point must be string")]
        elif (($it.enforcement_point|length>0) and ($it.enforcement_point|test("^(PolicyGuard|EvidenceGuard|DispatcherChokepoint|WAL|AtomicGroupExecutor|StatusEndpoint)$")|not)) then [err($id; "enforcement_point must be a known enforcement point when set")]
        else [] end
      )
      + (
        if ($it.failure_mode|type)!="array" then [err($id; "failure_mode must be array")]
        elif ([ $it.failure_mode[] | select(type!="string") ] | length) > 0 then [err($id; "failure_mode must be array of strings")]
        elif ([ $it.failure_mode[] | select(length==0) ] | length) > 0 then [err($id; "failure_mode entries must be non-empty strings")]
        elif ([ $it.failure_mode[] | select(test("^(stall|hang|backpressure|missing|stale|parse_error)$")|not) ] | length) > 0 then [err($id; "failure_mode entries must be stall|hang|backpressure|missing|stale|parse_error")]
        else [] end
      )
      + (
        if ($it.observability|type)!="object" then [err($id; "observability must be object")]
        else
          (missing_fields($it.observability; ["metrics","status_fields","status_contract_ats"])
            | map(err($id; "missing observability." + .)))
        end
      )
      + (
        if ($it.observability.metrics|type)!="array" then [err($id; "observability.metrics must be array")]
        elif ([ $it.observability.metrics[] | select(type!="object") ] | length) > 0 then [err($id; "observability.metrics must contain objects")]
        elif ([ $it.observability.metrics[] | select((.name|type)!="string" or (.type|type)!="string" or (.unit|type)!="string" or (.labels|type)!="array") ] | length) > 0 then [err($id; "observability.metrics entries must include name/type/unit/labels")]
        elif ([ $it.observability.metrics[] | select((.type|test("^(counter|gauge|histogram)$")|not)) ] | length) > 0 then [err($id; "observability.metrics.type must be counter|gauge|histogram")]
        elif ([ $it.observability.metrics[] | select((.unit|test("^(count|ms|pct|s)$")|not)) ] | length) > 0 then [err($id; "observability.metrics.unit must be count|ms|pct|s")]
        elif ([ $it.observability.metrics[] | select((.labels|type)!="array") ] | length) > 0 then [err($id; "observability.metrics.labels must be array")]
        elif ([ $it.observability.metrics[] | select((.labels|map(select(type!="string"))|length)>0) ] | length) > 0 then [err($id; "observability.metrics.labels must be strings")]
        else [] end
      )
      + (
        if ($it.observability.status_fields|type)!="array" then [err($id; "observability.status_fields must be array")]
        elif ([ $it.observability.status_fields[] | select(type!="string") ] | length) > 0 then [err($id; "observability.status_fields must be array of strings")]
        else [] end
      )
      + (
        if ($it.observability.status_contract_ats|type)!="array" then [err($id; "observability.status_contract_ats must be array")]
        elif ([ $it.observability.status_contract_ats[] | select(type!="string") ] | length) > 0 then [err($id; "observability.status_contract_ats must be array of strings")]
        elif ([ $it.observability.status_contract_ats[] | select(length==0) ] | length) > 0 then [err($id; "observability.status_contract_ats entries must be non-empty strings")]
        elif ([ $it.observability.status_contract_ats[] | select(test("^AT-[0-9]+$")|not) ] | length) > 0 then [err($id; "observability.status_contract_ats entries must match AT-###")]
        else [] end
      )
      + (
        if ($it.implementation_tests|type)!="array" then [err($id; "implementation_tests must be array")]
        elif ([ $it.implementation_tests[] | select(type!="string") ] | length) > 0 then [err($id; "implementation_tests must be array of strings")]
        else [] end
      )
      + (
        if ($it.contract_refs|type)!="array" or ($it.contract_refs|length==0) then [err($id; "contract_refs must be non-empty array")] else [] end
      )
      + (
        if ($it.plan_refs|type)!="array" or ($it.plan_refs|length==0) then [err($id; "plan_refs must be non-empty array")] else [] end
      )
      + (
        if ($it.needs_human_decision == true) then
          if ($it.human_blocker? | not) then [err($id; "needs_human_decision=true requires human_blocker")]
          else
            (missing_fields($it.human_blocker; ["why","question","options","recommended","unblock_steps"])
              | map(err($id; "missing human_blocker." + .)))
          end
        else [] end
      )
      + (
        if ($it.needs_human_decision == true) then [] else
          if has_placeholders($it) then [err($id; "placeholder tokens TODO/TBD/FIXME/??? require needs_human_decision=true")] else [] end
        end
      )
      + (
        if ($it.est_size|type)!="string" or ($it.est_size|test("^(XS|S|M)$")|not) then [err($id; "est_size must be XS|S|M")]
        elif ($it.est_size=="M") then [err($id; "est_size=M must be split (use XS|S)")]
        else [] end
      )
      + (
        if ($it.risk|type)!="string" or ($it.risk|test("^(low|med|high)$")|not) then [err($id; "risk must be low|med|high")] else [] end
      )
      + (check_dependencies($it; $ids; $by_id));

    (.items | if type=="array" then . else [] end) as $items
    | ($items | map(.id)) as $ids
    | ($items | map({key:.id, value:.}) | from_entries) as $by_id
    | (check_top + ($items | map(check_item(. ; $ids; $by_id)) | add // [])) | .[]
  ' "$PRD_FILE"
)"

if [[ -n "$errors" ]]; then
  echo "PRD schema violations:" >&2
  echo "$errors" >&2
  exit 5
fi

echo "PRD schema OK"
