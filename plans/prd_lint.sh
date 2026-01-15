#!/usr/bin/env bash

set -o pipefail

errors=0
warnings=0
strict=0
prd_arg=""
json_out=""
json_out_next=0

default_json_out="-"

for arg in "$@"; do
  if [[ "$arg" == "--strict" ]]; then
    strict=1
  elif [[ "$arg" == "--json" ]]; then
    json_out_next=1
  elif (( json_out_next == 1 )); then
    json_out="$arg"
    json_out_next=0
  elif [[ -z "$prd_arg" ]]; then
    prd_arg="$arg"
  fi
done

if (( json_out_next == 1 )); then
  json_out="$default_json_out"
fi

prd_file="${PRD_FILE:-${prd_arg:-plans/prd.json}}"
strict_heuristics="${PRD_LINT_STRICT_HEURISTICS:-0}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for PRD lint" >&2
  exit 2
fi

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

errors_json=()
warnings_json=()

report_error() {
  local code="$1"
  local id="$2"
  local message="$3"
  printf 'ERROR %s %s: %s\n' "$code" "$id" "$message"
  errors=$((errors + 1))
  errors_json+=("{\"code\":\"$(json_escape "$code")\",\"id\":\"$(json_escape "$id")\",\"message\":\"$(json_escape "$message")\"}")
}

report_warn() {
  local code="$1"
  local id="$2"
  local message="$3"
  printf 'WARN  %s %s: %s\n' "$code" "$id" "$message"
  warnings=$((warnings + 1))
  warnings_json+=("{\"code\":\"$(json_escape "$code")\",\"id\":\"$(json_escape "$id")\",\"message\":\"$(json_escape "$message")\"}")
}

finish() {
  printf 'PRD_LINT: errors=%s warnings=%s\n' "$errors" "$warnings"
  if [[ -n "$json_out" ]]; then
    local errors_arr warnings_arr lint_json
    errors_arr="$(printf '%s\n' "${errors_json[@]}" | jq -s '.')"
    warnings_arr="$(printf '%s\n' "${warnings_json[@]}" | jq -s '.')"
    lint_json="$(jq -n --argjson errors "$errors_arr" --argjson warnings "$warnings_arr" '{errors:$errors,warnings:$warnings}')"
    if [[ "$json_out" == "-" ]]; then
      printf '%s\n' "$lint_json"
    else
      mkdir -p "$(dirname "$json_out")"
      printf '%s\n' "$lint_json" > "$json_out"
    fi
  fi
  if (( errors > 0 )); then
    exit 2
  fi
  if (( warnings > 0 && strict == 1 )); then
    exit 3
  fi
  exit 0
}

if [[ ! -f "$prd_file" ]]; then
  report_error MISSING_PRD GLOBAL "PRD file not found: $prd_file"
  finish
fi

if ! jq -e . "$prd_file" >/dev/null 2>&1; then
  report_error INVALID_JSON GLOBAL "PRD file is not valid JSON: $prd_file"
  finish
fi

if ! jq -e '.items and (.items | type == "array")' "$prd_file" >/dev/null 2>&1; then
  report_error MISSING_ITEMS GLOBAL "PRD missing top-level .items array"
  finish
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$repo_root" ]]; then
  report_error NO_GIT_ROOT GLOBAL "Unable to resolve git repo root"
  finish
fi

core_has_src=0
infra_has_src=0
if [[ -d "$repo_root/crates/soldier_core/src" ]]; then
  core_has_src=1
fi
if [[ -d "$repo_root/crates/soldier_infra/src" ]]; then
  infra_has_src=1
fi

# Duplicate ID check (ignore missing/empty ids here).
if command -v sort >/dev/null 2>&1; then
  dup_ids=$(jq -r '.items[] | .id // empty' "$prd_file" | sort | uniq -d)
  if [[ -n "$dup_ids" ]]; then
    while IFS= read -r dup; do
      [[ -z "$dup" ]] && continue
      report_error DUPLICATE_ID "$dup" "duplicate id"
    done <<< "$dup_ids"
  fi
fi

allowlist_raw="${PRD_LINT_VERIFY_ALLOWLIST:-}"
allowlist_raw="${allowlist_raw// /}"
IFS=',' read -r -a allow_ids <<< "$allowlist_raw"

is_allowlisted() {
  local id="$1"
  local entry
  for entry in "${allow_ids[@]}"; do
    [[ -n "$entry" && "$entry" == "$id" ]] && return 0
  done
  return 1
}

has_glob_chars() {
  local value="$1"
  [[ "$value" == *"*"* || "$value" == *"?"* || "$value" == *"["* || "$value" == *"]"* ]]
}

python_missing=0
count_glob_matches() {
  local pattern="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    if (( python_missing == 0 )); then
      report_warn PYTHON3_MISSING GLOBAL "python3 missing; glob checks disabled"
      python_missing=1
    fi
    # Ensure a numeric count is always returned to callers using command substitution.
    echo 0
    return 0
  fi
  python3 - "$repo_root" "$pattern" <<'PY'
import glob
import os
import sys

root = os.path.abspath(sys.argv[1])
pattern = sys.argv[2]
abs_pattern = os.path.abspath(os.path.join(root, pattern))

# Ensure the resolved pattern does not escape the repository root.
try:
    common = os.path.commonpath([root, abs_pattern])
except ValueError:
    # On error determining common path, treat as no matches.
    print(0)
    raise SystemExit(0)

if common != root:
    # Pattern would escape the repo root; do not perform glob outside root.
    print(0)
    raise SystemExit(0)
if "**" in abs_pattern:
    matches = glob.glob(abs_pattern, recursive=True)
else:
    matches = glob.glob(abs_pattern)
count = 0
for path in matches:
    try:
        rel = os.path.relpath(path, root)
    except ValueError:
        continue
    parts = rel.split(os.sep)
    if '.git' in parts:
        continue
    if os.path.isfile(path):
        count += 1

print(count)
PY
}

check_path_convention() {
  local item_id="$1"
  local raw_path="$2"
  local path="${raw_path#./}"

  if (( core_has_src == 1 )); then
    if [[ "$path" == crates/soldier_core/* && "$path" != crates/soldier_core/src/* ]]; then
      case "$path" in
        crates/soldier_core/execution*|crates/soldier_core/idempotency*|crates/soldier_core/recovery*|crates/soldier_core/venue*|crates/soldier_core/risk*|crates/soldier_core/strategy*)
          report_warn PATH_CONVENTION "$item_id" "path '$raw_path' should be under crates/soldier_core/src/"
          ;;
      esac
    fi
  fi

  if (( infra_has_src == 1 )); then
    if [[ "$path" == crates/soldier_infra/* && "$path" != crates/soldier_infra/src/* ]]; then
      case "$path" in
        crates/soldier_infra/deribit*|crates/soldier_infra/store*)
          report_warn PATH_CONVENTION "$item_id" "path '$raw_path' should be under crates/soldier_infra/src/"
          ;;
      esac
    fi
  fi
}

check_required() {
  local filter="$1"
  local field="$2"
  if ! printf '%s' "$item_json" | jq -e "$filter" >/dev/null 2>&1; then
    report_error INVALID_FIELD "$item_id" "$field missing or wrong type"
  fi
}

glob_warn="${PRD_LINT_GLOB_WARN:-25}"
glob_fail="${PRD_LINT_GLOB_FAIL:-100}"

items_stream=$(jq -c '.items | to_entries[]' "$prd_file")
while IFS= read -r entry; do
  idx=$(printf '%s' "$entry" | jq -r '.key')
  item_json=$(printf '%s' "$entry" | jq -c '.value')
  item_id=$(printf '%s' "$item_json" | jq -r '.id // empty')
  if [[ -z "$item_id" ]]; then
    item_id="ITEM_$idx"
  fi
  item_category=$(printf '%s' "$item_json" | jq -r '.category // empty')

  check_required '.id | type == "string" and length > 0' 'id'
  check_required '.slice | type == "number"' 'slice'
  check_required '.passes | type == "boolean"' 'passes'
  check_required '.needs_human_decision | type == "boolean"' 'needs_human_decision'
  check_required '.description | type == "string" and length > 0' 'description'
  check_required '.acceptance | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' 'acceptance'
  check_required '.verify | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' 'verify'

  if ! printf '%s' "$item_json" | jq -e '.scope.touch | type == "array" and all(.[]; type == "string" and length > 0)' >/dev/null 2>&1; then
    report_error INVALID_FIELD "$item_id" "scope.touch missing or wrong type"
  fi

  create_paths=()
  if printf '%s' "$item_json" | jq -e '.scope.create? != null' >/dev/null 2>&1; then
    if ! printf '%s' "$item_json" | jq -e '.scope.create | type == "array" and all(.[]; type == "string" and length > 0)' >/dev/null 2>&1; then
      report_error INVALID_FIELD "$item_id" "scope.create must be array of strings"
    else
      while IFS= read -r create; do
        [[ -z "$create" ]] && continue
        create_paths+=("$create")
      done <<< "$(printf '%s' "$item_json" | jq -r '.scope.create[]')"
    fi
  fi

  touch_count=0
  if printf '%s' "$item_json" | jq -e '.scope.touch | type == "array"' >/dev/null 2>&1; then
    touch_count="$(printf '%s' "$item_json" | jq -r '.scope.touch | length')"
    if ! [[ "$touch_count" =~ ^[0-9]+$ ]]; then
      touch_count=0
    fi
  fi
  if (( touch_count == 0 && ${#create_paths[@]} == 0 )); then
    report_error INVALID_FIELD "$item_id" "scope.touch must be non-empty unless scope.create is provided"
  fi

  if printf '%s' "$item_json" | jq -e 'has("contract_refs") and .contract_refs != null' >/dev/null 2>&1; then
    if ! printf '%s' "$item_json" | jq -e '.contract_refs | (type == "array" and all(.[]; type == "string"))' >/dev/null 2>&1; then
      report_error INVALID_FIELD "$item_id" "contract_refs must be array of strings"
    fi
  fi

  if printf '%s' "$item_json" | jq -e 'has("dependencies") and .dependencies != null' >/dev/null 2>&1; then
    if ! printf '%s' "$item_json" | jq -e '.dependencies | (type == "array")' >/dev/null 2>&1; then
      report_error INVALID_FIELD "$item_id" "dependencies must be array"
    fi
  fi

  if printf '%s' "$item_json" | jq -e '.verify | type == "array"' >/dev/null 2>&1; then
    if ! is_allowlisted "$item_id"; then
      if ! printf '%s' "$item_json" | jq -e '.verify | index("./plans/verify.sh") != null' >/dev/null 2>&1; then
        report_error MISSING_VERIFY_SH "$item_id" "verify must include ./plans/verify.sh"
      fi
    fi
  fi

  if printf '%s' "$item_json" | jq -e '.scope.touch | type == "array"' >/dev/null 2>&1; then
    while IFS= read -r touch; do
      [[ -z "$touch" ]] && continue
      check_path_convention "$item_id" "$touch"

      if [[ "$touch" == *".DS_Store"* ]]; then
        report_warn JUNK_PATH "$item_id" "scope.touch contains .DS_Store"
      fi

      if [[ "$item_category" == "workflow" && "$touch" == crates/* ]]; then
        report_error WORKFLOW_TOUCHES_CRATES "$item_id" "workflow story must not touch crates/"
      fi

      if [[ ( "$item_category" == "execution" || "$item_category" == "risk" ) && "$touch" == plans/* ]]; then
        report_error EXECUTION_TOUCHES_PLANS "$item_id" "execution/risk story must not touch plans/"
      fi

      if has_glob_chars "$touch"; then
        count=$(count_glob_matches "$touch") || true
        if [[ -n "$count" ]]; then
          if (( count > glob_fail )); then
            report_error GLOB_TOO_BROAD "$item_id" "glob '$touch' matches $count files (>${glob_fail})"
          elif (( count > glob_warn )); then
            report_warn GLOB_BROAD "$item_id" "glob '$touch' matches $count files (>${glob_warn})"
          fi
        fi
      else
        rel_path="${touch#./}"
        full_path="$repo_root/$rel_path"
        if [[ ! -e "$full_path" ]]; then
          report_error MISSING_PATH "$item_id" "path does not exist: $touch"
        fi
      fi
    done <<< "$(printf '%s' "$item_json" | jq -r '.scope.touch[]')"
  fi

  if printf '%s' "$item_json" | jq -e '.scope.avoid | type == "array"' >/dev/null 2>&1; then
    while IFS= read -r avoid; do
      [[ -z "$avoid" ]] && continue
      check_path_convention "$item_id" "$avoid"
    done <<< "$(printf '%s' "$item_json" | jq -r '.scope.avoid[]')"
  fi

  if (( ${#create_paths[@]} > 0 )); then
    for create_path in "${create_paths[@]}"; do
      check_path_convention "$item_id" "$create_path"
      if has_glob_chars "$create_path"; then
        report_error CREATE_PATH_GLOB "$item_id" "scope.create path contains glob characters: $create_path"
        continue
      fi
      rel_create="${create_path#./}"
      full_create="$repo_root/$rel_create"
      if [[ -e "$full_create" ]]; then
        report_error CREATE_PATH_EXISTS "$item_id" "scope.create path already exists: $create_path"
        continue
      fi
      parent_dir="$(dirname "$full_create")"
      if [[ ! -d "$parent_dir" ]]; then
        report_error CREATE_PARENT_MISSING "$item_id" "scope.create parent directory missing for: $create_path"
      fi
    done
  fi

  if printf '%s' "$item_json" | jq -e '.contract_refs | type == "array" and length > 0' >/dev/null 2>&1; then
    contract_refs=$(printf '%s' "$item_json" | jq -r '.contract_refs | join(" | ")')
    acceptance_refs=$(printf '%s' "$item_json" | jq -r '.acceptance | join(" | ")')

    contract_lc_scope=$(printf '%s' "$contract_refs" | tr '[:upper:]' '[:lower:]')
    acceptance_lc_scope=$(printf '%s' "$acceptance_refs" | tr '[:upper:]' '[:lower:]')

    report_heuristic() {
      local id="$1"
      local msg="$2"
      if [[ "$strict_heuristics" == "1" ]]; then
        report_error CONTRACT_ACCEPTANCE_MISMATCH "$id" "$msg"
      else
        report_warn CONTRACT_ACCEPTANCE_MISMATCH "$id" "$msg"
      fi
    }

    if [[ "$contract_lc_scope" == *"reject"* ]]; then
      if [[ "$acceptance_lc_scope" != *"reject"* && "$acceptance_lc_scope" != *"rejected"* ]]; then
        report_heuristic "$item_id" "contract mentions reject but acceptance missing reject/rejected"
      fi
    fi

    if [[ "$contract_lc_scope" == *"degraded"* || "$contract_lc_scope" == *"riskstate::degraded"* ]]; then
      if [[ "$acceptance_lc_scope" != *"degraded"* && "$acceptance_lc_scope" != *"riskstate"* ]]; then
        report_heuristic "$item_id" "contract mentions Degraded but acceptance missing Degraded/RiskState"
      fi
    fi

    if [[ "$contract_lc_scope" == *"fail-closed"* ]]; then
      if [[ "$acceptance_lc_scope" != *"fail-closed"* ]]; then
        report_heuristic "$item_id" "contract mentions fail-closed but acceptance missing fail-closed"
      fi
    fi

    if [[ "$contract_lc_scope" == *"must stop"* ]]; then
      if [[ "$acceptance_lc_scope" != *"must stop"* ]]; then
        report_heuristic "$item_id" "contract mentions must stop but acceptance missing must stop"
      fi
    fi
  fi

  if printf '%s' "$item_json" | jq -e '.acceptance | type == "array" and length > 0' >/dev/null 2>&1; then
    acceptance_refs=$(printf '%s' "$item_json" | jq -r '.acceptance | join(" | ")')
    acceptance_lc=$(printf '%s' "$acceptance_refs" | tr '[:upper:]' '[:lower:]')

    if [[ "$acceptance_lc" == *"policyguard"* || "$acceptance_lc" == *"evidenceguard"* || "$acceptance_lc" == *"f1"* || "$acceptance_lc" == *"replay"* || "$acceptance_lc" == *"wal"* ]]; then
      if [[ "${PRD_LINT_FORWARD_FAIL:-}" == "1" ]]; then
        report_error FORWARD_KEYWORD "$item_id" "forward-dependency keyword found; add dependency, move to later slice, or remove premature acceptance"
      else
        report_warn FORWARD_KEYWORD "$item_id" "forward-dependency keyword found; add dependency, move to later slice, or remove premature acceptance"
      fi
    fi
  fi

done <<< "$items_stream"

# Optional dependency sanity warnings.
if jq -e '.items[] | has("dependencies")' "$prd_file" >/dev/null 2>&1; then
  dep_lines=$(jq -r '
    .items as $items
    | $items[] as $item
    | ($item.dependencies // [])[]? as $dep
    | ($items | map(.id) | index($dep)) as $idx
    | if $idx == null then
        "MISSING_DEP|\($item.id // "UNKNOWN_ID")|\($dep)"
      else
        ($items[$idx].slice) as $dep_slice
        | if ($dep_slice > $item.slice) then
            "HIGHER_SLICE|\($item.id // "UNKNOWN_ID")|\($dep)|\($dep_slice)|\($item.slice)"
          else empty end
      end
  ' "$prd_file")

  if [[ -n "$dep_lines" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      code=$(printf '%s' "$line" | cut -d'|' -f1)
      if [[ "$code" == "MISSING_DEP" ]]; then
        item=$(printf '%s' "$line" | cut -d'|' -f2)
        dep=$(printf '%s' "$line" | cut -d'|' -f3)
        report_warn DEPENDENCY_MISSING "$item" "dependency '$dep' not found"
      elif [[ "$code" == "HIGHER_SLICE" ]]; then
        item=$(printf '%s' "$line" | cut -d'|' -f2)
        dep=$(printf '%s' "$line" | cut -d'|' -f3)
        dep_slice=$(printf '%s' "$line" | cut -d'|' -f4)
        item_slice=$(printf '%s' "$line" | cut -d'|' -f5)
        report_warn DEPENDENCY_SLICE "$item" "dependency '$dep' is in higher slice ($dep_slice > $item_slice)"
      fi
    done <<< "$dep_lines"
  fi
fi

finish
