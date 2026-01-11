#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${1:-plans/prd.json}"

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
  jq -r '
    def err($id; $msg): "\($id): \($msg)";
    def items($doc): if ($doc|type)=="array" then $doc else ($doc.items // []) end;
    def missing_fields($obj; $fields):
      [$fields[] as $f | select($obj | has($f) | not) | $f];

    def check_top:
      (if (has("project") and has("source") and has("rules") and has("items") and (.items|type=="array")) then [] else ["<top>: missing project/source/rules/items or items not array"] end)
      + (if (.source|has("implementation_plan_path")) then [] else ["<top>: missing source.implementation_plan_path"] end)
      + (if (.source|has("contract_path")) then [] else ["<top>: missing source.contract_path"] end)
      + (if ((.rules|has("one_story_per_iteration")) and (.rules.one_story_per_iteration==true)) then [] else ["<top>: rules.one_story_per_iteration must be true"] end)
      + (if ((.rules|has("one_commit_per_story")) and (.rules.one_commit_per_story==true)) then [] else ["<top>: rules.one_commit_per_story must be true"] end)
      + (if ((.rules|has("no_prd_rewrite")) and (.rules.no_prd_rewrite==true)) then [] else ["<top>: rules.no_prd_rewrite must be true"] end)
      + (if ((.rules|has("passes_only_flips_after_verify_green")) and (.rules.passes_only_flips_after_verify_green==true)) then [] else ["<top>: rules.passes_only_flips_after_verify_green must be true"] end);

    def check_item($it):
      ($it.id // "<no id>") as $id
      | (missing_fields($it; [
          "id","priority","phase","slice","slice_ref","story_ref","category","description",
          "contract_refs","plan_refs","scope","acceptance","steps","verify","evidence",
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
        elif ($it.acceptance|length < 3) then [err($id; "acceptance must have >=3 items")]
        else [] end
      )
      + (
        if ($it.steps|type)!="array" then [err($id; "steps must be array")]
        elif ($it.steps|length < 5) then [err($id; "steps must have >=5 items")]
        else [] end
      )
      + (
        if ($it.verify|type)!="array" then [err($id; "verify must be array")]
        elif ($it.verify | index("./plans/verify.sh") == null) then [err($id; "verify[] missing ./plans/verify.sh")]
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
        if ($it.est_size|type)!="string" or ($it.est_size|test("^(XS|S|M)$")|not) then [err($id; "est_size must be XS|S|M")] else [] end
      )
      + (
        if ($it.risk|type)!="string" or ($it.risk|test("^(low|med|high)$")|not) then [err($id; "risk must be low|med|high")] else [] end
      );

    (check_top + (items(.) | map(check_item(.)) | add // [])) | .[]
  ' "$PRD_FILE"
)"

if [[ -n "$errors" ]]; then
  echo "PRD schema violations:" >&2
  echo "$errors" >&2
  exit 5
fi

# Soft warnings (non-fatal)
warnings="$(
  jq -r '
    def items($doc): if ($doc|type)=="array" then $doc else ($doc.items // []) end;
    items(.)[] | select(.est_size=="M") | "WARN: \(.id): est_size=M (should be split)"
  ' "$PRD_FILE"
)"

if [[ -n "$warnings" ]]; then
  echo "$warnings" >&2
fi

echo "PRD schema OK"
