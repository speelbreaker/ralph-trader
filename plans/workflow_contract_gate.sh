#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

spec_file="${WORKFLOW_CONTRACT_FILE:-specs/WORKFLOW_CONTRACT.md}"
map_file="${WORKFLOW_CONTRACT_MAP:-plans/workflow_contract_map.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

# Check that at least one of rg or grep is available
if ! command -v rg >/dev/null 2>&1 && ! command -v grep >/dev/null 2>&1; then
  echo "ERROR: either ripgrep or grep required" >&2
  exit 2
fi
if [[ ! -f "$spec_file" ]]; then
  echo "ERROR: workflow contract not found: $spec_file" >&2
  exit 1
fi

if [[ ! -f "$map_file" ]]; then
  echo "ERROR: workflow contract map not found: $map_file" >&2
  exit 1
fi

if ! jq -e . "$map_file" >/dev/null 2>&1; then
  echo "ERROR: invalid JSON in $map_file" >&2
  exit 1
fi

extract_ids() {
  local file="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -o 'WF-[0-9]+(\.[0-9]+)*' "$file" | sort -u
  else
    grep -oE 'WF-[0-9]+(\.[0-9]+)*' "$file" | sort -u
  fi
}

spec_ids="$(extract_ids "$spec_file")"
map_ids="$(jq -r '.rules[].id' "$map_file" | sort -u)"

missing_ids="$(comm -23 <(printf '%s\n' "$spec_ids") <(printf '%s\n' "$map_ids"))"
extra_ids="$(comm -13 <(printf '%s\n' "$spec_ids") <(printf '%s\n' "$map_ids"))"

if [[ -n "$missing_ids" ]]; then
  echo "ERROR: unmapped workflow rule ids:" >&2
  printf '%s\n' "$missing_ids" | sed 's/^/- /' >&2
  exit 1
fi

if [[ -n "$extra_ids" ]]; then
  echo "ERROR: map contains unknown rule ids:" >&2
  printf '%s\n' "$extra_ids" | sed 's/^/- /' >&2
  exit 1
fi

bad_ids="$(jq -r '
  .rules[]
  | select(
      (.id|type!="string" or length==0)
      or (.enforcement|type!="array" or (map(select(type=="string" and length>0))|length)==0)
      or (.artifacts|type!="array" or (map(select(type=="string" and length>0))|length)==0)
      or (.tests|type!="array")
    )
  | .id
' "$map_file")"

if [[ -n "$bad_ids" ]]; then
  echo "ERROR: mapping entries missing enforcement/artifacts/tests:" >&2
  printf '%s\n' "$bad_ids" | sed 's/^/- /' >&2
  exit 1
fi

dup_ids="$(jq -r '.rules[].id' "$map_file" | sort | uniq -d)"
if [[ -n "$dup_ids" ]]; then
  echo "ERROR: duplicate rule ids in map:" >&2
  printf '%s\n' "$dup_ids" | sed 's/^/- /' >&2
  exit 1
fi

# Validate enforcement paths (if token looks like a repo path, it must exist).
while IFS= read -r enforcement; do
  [[ -z "$enforcement" ]] && continue
  path="${enforcement%% *}"
  case "$path" in
    */*|*.sh|*.py|*.json)
      if [[ ! -e "$path" ]]; then
        echo "ERROR: enforcement path missing: $path" >&2
        exit 1
      fi
      ;;
    *)
      ;;
  esac
done < <(jq -r '.rules[].enforcement[]' "$map_file")

# Validate workflow acceptance test references if present in map.
acceptance_ids=""
if [[ -x "plans/workflow_acceptance.sh" ]]; then
  acceptance_ids="$(./plans/workflow_acceptance.sh --list 2>/dev/null | awk '{print $1}')"
fi

while IFS= read -r test_ref; do
  [[ -z "$test_ref" ]] && continue
  case "$test_ref" in
    *"plans/workflow_acceptance.sh"*)
      if [[ -z "$acceptance_ids" ]]; then
        echo "ERROR: unable to list workflow acceptance test ids" >&2
        exit 1
      fi
      ids_part="${test_ref#*Test }"
      ids_part="${ids_part%%)*}"
      ids_part="$(echo "$ids_part" | tr '/,' '  ' | tr -s ' ')"
      for token in $ids_part; do
        if [[ "$token" == *-* ]]; then
          start="${token%-*}"
          end="${token#*-}"
          for id in "$start" "$end"; do
            if [[ -n "$id" ]] && ! printf '%s\n' "$acceptance_ids" | grep -qx "$id"; then
              echo "ERROR: unknown workflow acceptance test id: $id" >&2
              exit 1
            fi
          done
        else
          if ! printf '%s\n' "$acceptance_ids" | grep -qx "$token"; then
            echo "ERROR: unknown workflow acceptance test id: $token" >&2
            exit 1
          fi
        fi
      done
      ;;
    *)
      ;;
  esac
done < <(jq -r '.rules[].tests[]' "$map_file")

echo "workflow contract gate: OK"
