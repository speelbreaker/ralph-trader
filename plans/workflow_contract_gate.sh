#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

spec_file="${WORKFLOW_CONTRACT_FILE:-specs/WORKFLOW_CONTRACT.md}"
map_file="${WORKFLOW_CONTRACT_MAP:-plans/workflow_contract_map.json}"
CACHE_DIR="${WORKFLOW_CONTRACT_GATE_CACHE_DIR:-}"

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

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

cache_dir_ready() {
  if [[ -z "$CACHE_DIR" ]]; then
    return 1
  fi
  mkdir -p "$CACHE_DIR" 2>/dev/null || true
  [[ -d "$CACHE_DIR" ]]
}

cache_path_for() {
  local prefix="$1"
  local file="$2"
  local hash
  hash="$(sha256_file "$file" 2>/dev/null || true)"
  if [[ -z "$hash" ]]; then
    return 1
  fi
  echo "${CACHE_DIR}/${prefix}_${hash}.txt"
}

extract_ids_all() {
  local file="$1"
  awk '
    {
      is_def = 0
      if ($0 ~ /^[[:space:]]*-[[:space:]]+\[WF-[0-9]+(\.[0-9]+)*\]/) is_def = 1
      else if ($0 ~ /^[[:space:]]*[0-9]+\)[[:space:]]+\[WF-[0-9]+(\.[0-9]+)*\]/) is_def = 1
      else if ($0 ~ /^[[:space:]]*\[WF-[0-9]+(\.[0-9]+)*\]/) is_def = 1
      else if ($0 ~ /^[[:space:]]*#+[[:space:]].*\[WF-[0-9]+(\.[0-9]+)*\][[:space:]]*$/) is_def = 1
      else if ($0 ~ /^[[:space:]]*[^[:space:]].*\[WF-[0-9]+(\.[0-9]+)*\][[:space:]]*$/ && $0 !~ /:[[:space:]]*$/) is_def = 1

      if (is_def == 1) {
        line = $0
        while (match(line, /\[WF-[0-9]+(\.[0-9]+)*\]/)) {
          print substr(line, RSTART + 1, RLENGTH - 2)
          line = substr(line, RSTART + RLENGTH)
        }
      }
    }
  ' "$file" || true
}

extract_ids() {
  local file="$1"
  local cache_path=""
  if cache_dir_ready; then
    cache_path="$(cache_path_for "spec_ids" "$file" || true)"
    if [[ -n "$cache_path" && -s "$cache_path" ]]; then
      cat "$cache_path"
      return 0
    fi
  fi
  if [[ -n "$cache_path" ]]; then
    extract_ids_all "$file" | sed '/^$/d' | sort | tee "$cache_path"
  else
    extract_ids_all "$file" | sed '/^$/d' | sort
  fi
}

# Skip markers that don't represent files
is_marker() {
  local entry="$1"
  case "$entry" in
    manual|CI) return 0 ;;
    .ralph/*) return 0 ;;
    "CI logs") return 0 ;;
    *) return 1 ;;
  esac
}

# Extract path from annotated entry like "plans/ralph.sh (preflight)"
extract_path() {
  local entry="$1"
  echo "$entry" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//'
}

# Check if path exists
path_exists() {
  local path="$1"
  [[ -f "$path" ]] || [[ -d "$path" ]]
}

validate_enforcement() {
  local errors="" entry path rule_id

  while IFS=$'\t' read -r rule_id entry; do
    [[ -z "$entry" ]] && continue
    is_marker "$entry" && continue

    path="$(extract_path "$entry")"
    if ! path_exists "$path"; then
      errors="${errors}${rule_id}: missing enforcement: ${path}\n"
    fi
  done < <(jq -r '.rules[] | "\(.id)\t\(.enforcement[])"' "$map_file")

  if [[ -n "$errors" ]]; then
    echo "ERROR: enforcement scripts/files not found:" >&2
    printf '%b' "$errors" | sed 's/^/- /' >&2
    return 1
  fi
}

get_acceptance_test_ids() {
  # Parse test_start lines directly (don't call --list, which has setup overhead)
  local ids dup_check cache_path=""
  if cache_dir_ready; then
    cache_path="$(cache_path_for "acceptance_ids" "plans/workflow_acceptance.sh" || true)"
    if [[ -n "$cache_path" && -s "$cache_path" ]]; then
      cat "$cache_path"
      return 0
    fi
  fi
  ids="$(sed -nE 's/^[[:space:]]*(if[[:space:]]+)?test_start[[:space:]]+"([^"]+)".*/\2/p' \
    plans/workflow_acceptance.sh)"

  # Check for duplicates
  dup_check="$(echo "$ids" | sort | uniq -d)"
  if [[ -n "$dup_check" ]]; then
    echo "ERROR: duplicate test IDs in workflow_acceptance.sh:" >&2
    echo "$dup_check" | sed 's/^/- /' >&2
    return 1
  fi

  if [[ -n "$cache_path" ]]; then
    echo "$ids" | sort -u | tee "$cache_path"
  else
    echo "$ids" | sort -u
  fi
}

# Helper: extract Test tokens with grep (required)
extract_test_tokens() {
  local input="$1"
  if ! command -v grep >/dev/null 2>&1; then
    echo "ERROR: grep required for test token extraction" >&2
    return 1
  fi
  printf '%s' "$input" | grep -oE 'Test[[:space:]]+[^,)]+' || true
}

extract_test_ids() {
  local test_ref="$1"
  local tokens token ids segment left right i segments_str

  # Pull only explicit "Test ..." tokens; ignore descriptive text.
  # Examples matched: "Test 12", "Test 0h/0i/0j/12", "Test 6-9"
  tokens="$(extract_test_tokens "$test_ref")"
  [[ -z "$tokens" ]] && return 0

  while IFS= read -r token; do
    ids="${token#Test }"
    ids="$(printf '%s' "$ids" | tr -d '[:space:]')"

    # Split on slash or comma: 0h/0i/0j/12, 1,2,3
    # Use here-string to avoid subshell (pipe creates subshell, losing output)
    segments_str="$(printf '%s' "$ids" | tr '/,' '\n')"
    while IFS= read -r segment; do
      [[ -z "$segment" ]] && continue
      if [[ "$segment" == *-* ]]; then
        left="${segment%%-*}"
        right="${segment##*-}"
        # Only allow numeric ranges; reject anything else
        if [[ ! "$left" =~ ^[0-9]+$ || ! "$right" =~ ^[0-9]+$ ]]; then
          echo "__RANGE_INVALID__:${segment}"
          continue
        fi
        # Pure bash range expansion (no seq dependency)
        if (( left <= right )); then
          for ((i=left; i<=right; i++)); do
            echo "$i"
          done
        else
          for ((i=left; i>=right; i--)); do
            echo "$i"
          done
        fi
      else
        echo "$segment"
      fi
    done <<< "$segments_str"
  done <<< "$tokens"
}

validate_tests() {
  local errors=""

  # Pre-load acceptance test IDs once (direct sed parsing, not --list which has setup overhead)
  local acceptance_ids
  if [[ -f "plans/workflow_acceptance.sh" ]]; then
    acceptance_ids="$(get_acceptance_test_ids)"
  fi

  while IFS=$'\t' read -r rule_id test_ref; do
    [[ -z "$test_ref" ]] && continue
    is_marker "$test_ref" && continue

    local script_path
    script_path="$(extract_path "$test_ref")"

    if ! path_exists "$script_path"; then
      errors="${errors}${rule_id}: missing test script: ${script_path}\n"
      continue
    fi

    if [[ "$script_path" == "plans/workflow_acceptance.sh" ]]; then
      while IFS= read -r test_id; do
        [[ -z "$test_id" ]] && continue
        # Handle invalid range marker from extract_test_ids
        if [[ "$test_id" == __RANGE_INVALID__:* ]]; then
          local bad_range="${test_id#__RANGE_INVALID__:}"
          errors="${errors}${rule_id}: invalid test range '${bad_range}' in ${test_ref} (ranges must be numeric; list explicit ids)\n"
          continue
        fi
        if ! echo "$acceptance_ids" | grep -qFx "$test_id"; then
          errors="${errors}${rule_id}: unknown test id '${test_id}' in ${test_ref}\n"
        fi
      done < <(extract_test_ids "$test_ref")
    fi
  done < <(jq -r '.rules[] | "\(.id)\t\(.tests[])"' "$map_file")

  if [[ -n "$errors" ]]; then
    echo "ERROR: test references not found:" >&2
    printf '%b' "$errors" | sed 's/^/- /' >&2
    return 1
  fi
}

spec_ids_all="$(extract_ids "$spec_file")"
spec_dup_ids="$(printf '%s\n' "$spec_ids_all" | uniq -d)"
if [[ -n "$spec_dup_ids" ]]; then
  echo "ERROR: duplicate workflow rule ids in spec:" >&2
  printf '%s\n' "$spec_dup_ids" | sed 's/^/- /' >&2
  exit 1
fi

map_ids_all="$(jq -r '.rules[].id' "$map_file" | sed '/^$/d' | sort)"
map_dup_ids="$(printf '%s\n' "$map_ids_all" | uniq -d)"
if [[ -n "$map_dup_ids" ]]; then
  echo "ERROR: duplicate rule ids in map:" >&2
  printf '%s\n' "$map_dup_ids" | sed 's/^/- /' >&2
  exit 1
fi

spec_ids="$(printf '%s\n' "$spec_ids_all" | sort -u)"
map_ids="$(printf '%s\n' "$map_ids_all" | sort -u)"

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

if ! validate_enforcement; then
  exit 1
fi

if ! validate_tests; then
  exit 1
fi

echo "workflow contract gate: OK"
