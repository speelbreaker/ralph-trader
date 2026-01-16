#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE_REF="${BASE_REF:-origin/main}"
POSTMORTEM_DIR="${POSTMORTEM_DIR:-reviews/postmortems}"
POSTMORTEM_TEMPLATE="${POSTMORTEM_TEMPLATE:-$POSTMORTEM_DIR/PR_POSTMORTEM_TEMPLATE.md}"
POSTMORTEM_README="${POSTMORTEM_README:-$POSTMORTEM_DIR/README.md}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing required file: $path"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || fail "Missing required directory: $path"
}

require_dir "$POSTMORTEM_DIR"
require_file "$POSTMORTEM_TEMPLATE"
require_file "$POSTMORTEM_README"

if ! command -v git >/dev/null 2>&1; then
  fail "git is required for postmortem check"
fi

if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    fail "CI must be able to diff against BASE_REF=$BASE_REF"
  else
    warn "Cannot verify BASE_REF=$BASE_REF (skipping postmortem check locally)"
    exit 0
  fi
fi

changed_files="$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || true)"
if [[ -z "$changed_files" ]]; then
  echo "postmortem check: no changes detected"
  exit 0
fi

postmortem_changed="$(echo "$changed_files" | grep -E "^${POSTMORTEM_DIR}/.*\.md$" | grep -vE "(README|PR_POSTMORTEM_TEMPLATE)\.md$" || true)"
if [[ -z "$postmortem_changed" ]]; then
  fail "No postmortem entry changed under ${POSTMORTEM_DIR} (required for every PR)"
fi

field_value() {
  local file="$1"
  local label="$2"
  awk -v label="$label" '
    index($0, "- " label ":") == 1 {
      pos = index($0, ":")
      value = substr($0, pos + 1)
      gsub(/^[[:space:]]+/, "", value)
      print value
      exit
    }
  ' "$file"
}

require_field() {
  local file="$1"
  local label="$2"
  local value
  value="$(field_value "$file" "$label")"
  if [[ -z "$value" ]]; then
    fail "Missing or empty field '${label}' in ${file}"
  fi
}

require_numbered() {
  local file="$1"
  local num="$2"
  local ok=0
  while IFS= read -r line; do
    if [[ "$line" == "  ${num})"* ]]; then
      local rest="${line#*${num})}"
      rest="${rest# }"
      if [[ -n "$rest" ]]; then
        ok=1
        break
      fi
    fi
  done < "$file"
  if [[ "$ok" -ne 1 ]]; then
    fail "Missing or empty friction item ${num}) in ${file}"
  fi
}

validate_postmortem() {
  local file="$1"

  require_field "$file" "Outcome"
  require_field "$file" "Contract/plan requirement satisfied"

  require_field "$file" "Constraint encountered"
  require_field "$file" "Exploit (what I did now)"
  require_field "$file" "Subordinate (workflow changes needed)"
  require_field "$file" "Elevate (permanent fix proposal)"

  require_field "$file" "Critical MUSTs touched (CR-IDs or contract anchors)"
  require_field "$file" "Proof (tests/commands + outputs)"

  require_field "$file" "Assumption -> Where it should be proven -> Validated? (Y/N)"

  require_numbered "$file" 1
  require_numbered "$file" 2
  require_numbered "$file" 3

  require_field "$file" "Repro steps + fix + prevention check/test"

  require_field "$file" "Files/sections changed"
  require_field "$file" "Hot zones discovered"
  require_field "$file" "What next agent should avoid / coordinate on"

  require_field "$file" "Patterns/templates created (prompts, scripts, snippets)"
  require_field "$file" "New \"skill\" to add/update"
  require_field "$file" "How to apply it (so it compounds)"

  require_field "$file" "Recurring issue? (Y/N)"
  require_field "$file" "Enforcement type (script_check | contract_clarification | test | none)"
  require_field "$file" "Enforcement target (path added/updated in this PR)"
  require_field "$file" "WORKFLOW_FRICTION.md updated? (Y/N)"

  require_field "$file" "What new invariant did we just discover?"
  require_field "$file" "What is the cheapest automated check that enforces it?"
  require_field "$file" "Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script)"
  require_field "$file" "What would break if we remove your fix?"
}

recurring_required=0
recurring_targets=()

IFS=$'\n'
for file in $postmortem_changed; do
  validate_postmortem "$file"

  recurring="$(field_value "$file" "Recurring issue? (Y/N)")"
  enforcement_type="$(field_value "$file" "Enforcement type (script_check | contract_clarification | test | none)")"
  enforcement_target="$(field_value "$file" "Enforcement target (path added/updated in this PR)")"
  friction_updated="$(field_value "$file" "WORKFLOW_FRICTION.md updated? (Y/N)")"

  if [[ "$recurring" == "Y" ]]; then
    recurring_required=1
    if [[ "$enforcement_type" != "script_check" && "$enforcement_type" != "contract_clarification" && "$enforcement_type" != "test" ]]; then
      fail "Recurring issue requires enforcement type in ${file}"
    fi
    if [[ -z "$enforcement_target" || "$enforcement_target" == "none" ]]; then
      fail "Recurring issue requires enforcement target path in ${file}"
    fi
    if [[ "$friction_updated" != "Y" ]]; then
      fail "Recurring issue requires WORKFLOW_FRICTION.md updated? Y in ${file}"
    fi
    recurring_targets+=("$enforcement_target")
  else
    if [[ "$enforcement_type" != "none" && "$enforcement_type" != "" ]]; then
      warn "Non-recurring issue has enforcement type set in ${file} (allowed)"
    fi
  fi

  if [[ "$recurring" != "Y" && "$recurring" != "N" ]]; then
    fail "Recurring issue field must be Y or N in ${file}"
  fi
  if [[ "$friction_updated" != "Y" && "$friction_updated" != "N" ]]; then
    fail "WORKFLOW_FRICTION.md updated field must be Y or N in ${file}"
  fi
  if [[ "$enforcement_type" != "script_check" && "$enforcement_type" != "contract_clarification" && "$enforcement_type" != "test" && "$enforcement_type" != "none" ]]; then
    fail "Invalid enforcement type in ${file}"
  fi

  canonical_place="$(field_value "$file" "Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script)")"
  canonical_place_lower="$(echo "$canonical_place" | tr '[:upper:]' '[:lower:]')"
  if [[ "$canonical_place_lower" != "contract" && "$canonical_place_lower" != "plan" && "$canonical_place_lower" != "agents" && "$canonical_place_lower" != "skills" && "$canonical_place_lower" != "script" ]]; then
    fail "Canonical place must be one of contract|plan|AGENTS|SKILLS|script in ${file}"
  fi

done

if [[ "$recurring_required" -eq 1 ]]; then
  if ! echo "$changed_files" | grep -Fxq "WORKFLOW_FRICTION.md"; then
    fail "Recurring issue requires WORKFLOW_FRICTION.md to be updated"
  fi
  for target in "${recurring_targets[@]}"; do
    if [[ ! -e "$target" ]]; then
      fail "Enforcement target does not exist: $target"
    fi
    if ! echo "$changed_files" | grep -Fxq "$target"; then
      fail "Enforcement target must be updated in this PR: $target"
    fi
  done
fi

echo "postmortem check: OK"
