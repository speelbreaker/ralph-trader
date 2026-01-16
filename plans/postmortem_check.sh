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

section_content() {
  local file="$1"
  local pattern="$2"
  awk -v pattern="$pattern" '
    $0 ~ "^## " && $0 ~ pattern {in_section=1; next}
    in_section && $0 ~ "^## " {exit}
    in_section {print}
  ' "$file"
}

require_count_between() {
  local count="$1"
  local min="$2"
  local max="$3"
  local label="$4"
  if (( count < min || count > max )); then
    fail "${label} count must be between ${min} and ${max}"
  fi
}

require_count_at_least() {
  local count="$1"
  local min="$2"
  local label="$3"
  if (( count < min )); then
    fail "${label} count must be at least ${min}"
  fi
}

validate_postmortem() {
  local file="$1"

  require_field "$file" "Outcome"
  require_field "$file" "Contract/plan requirement satisfied"
  require_field "$file" "Workstream (Ralph Loop workflow | Stoic Trader bot)"
  require_field "$file" "Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md)"

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

  local agents_section
  agents_section="$(section_content "$file" "What should we add to AGENTS\\.md\\?")"
  if [[ -z "$agents_section" ]]; then
    fail "Missing AGENTS.md proposals section in ${file}"
  fi
  local rules_count
  rules_count="$(echo "$agents_section" | grep -c '^- Rule:' || true)"
  require_count_between "$rules_count" 1 3 "AGENTS.md Rule"
  local rules_with_must_should
  rules_with_must_should="$(echo "$agents_section" | grep -cE '^- Rule: .*(MUST|SHOULD)([^A-Za-z]|$)' || true)"
  if (( rules_with_must_should < rules_count )); then
    fail "Each AGENTS.md Rule must include MUST/SHOULD in ${file}"
  fi
  local trigger_count
  local prevents_count
  local enforce_count
  trigger_count="$(echo "$agents_section" | grep -c '^- Trigger:' || true)"
  prevents_count="$(echo "$agents_section" | grep -c '^- Prevents:' || true)"
  enforce_count="$(echo "$agents_section" | grep -c '^- Enforce:' || true)"
  if (( trigger_count < rules_count || prevents_count < rules_count || enforce_count < rules_count )); then
    fail "Each AGENTS.md Rule must include Trigger/Prevents/Enforce in ${file}"
  fi

  local plan_section
  plan_section="$(section_content "$file" "Concrete Elevation Plan")"
  if [[ -z "$plan_section" ]]; then
    fail "Missing Concrete Elevation Plan section in ${file}"
  fi
  local change_count
  local owner_count
  local effort_count
  local expected_count
  local proof_count
  change_count="$(echo "$plan_section" | grep -c '^- Change:' || true)"
  owner_count="$(echo "$plan_section" | grep -c '^- Owner:' || true)"
  effort_count="$(echo "$plan_section" | grep -cE '^- Effort: (S|M|L)' || true)"
  expected_count="$(echo "$plan_section" | grep -c '^- Expected gain:' || true)"
  proof_count="$(echo "$plan_section" | grep -c '^- Proof of completion:' || true)"
  require_count_at_least "$change_count" 3 "Elevation plan Change"
  require_count_at_least "$owner_count" 3 "Elevation plan Owner"
  require_count_at_least "$effort_count" 3 "Elevation plan Effort"
  require_count_at_least "$expected_count" 3 "Elevation plan Expected gain"
  require_count_at_least "$proof_count" 3 "Elevation plan Proof"

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

  workstream="$(field_value "$file" "Workstream (Ralph Loop workflow | Stoic Trader bot)")"
  if [[ "$workstream" != "Ralph Loop workflow" && "$workstream" != "Stoic Trader bot" ]]; then
    fail "Workstream must be 'Ralph Loop workflow' or 'Stoic Trader bot' in ${file}"
  fi
  contract_used="$(field_value "$file" "Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md)")"
  if [[ "$contract_used" != "specs/WORKFLOW_CONTRACT.md" && "$contract_used" != "CONTRACT.md" ]]; then
    fail "Contract used must be specs/WORKFLOW_CONTRACT.md or CONTRACT.md in ${file}"
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
