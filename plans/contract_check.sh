#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

out="${CONTRACT_REVIEW_OUT:-${1:-}}"
contract_file="${CONTRACT_FILE:-CONTRACT.md}"
prd_file="${PRD_FILE:-plans/prd.json}"
state_file="${RPH_STATE_FILE:-.ralph/state.json}"
allow_verify_edit="${RPH_ALLOW_VERIFY_SH_EDIT:-0}"
validator="${CONTRACT_REVIEW_VALIDATE:-./plans/contract_review_validate.sh}"

json_array_from_lines() {
  if [[ "$#" -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -R 'select(length>0)' | jq -s '.'
}

json_array_from_json_lines() {
  if [[ "$#" -eq 0 ]]; then
    echo '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -s '.'
}

read_lines() {
  local var="$1"
  local line
  eval "$var=()"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    eval "$var+=(\"\$line\")"
  done
}

story_jq_r() {
  local filter="$1"
  jq -r --arg id "$selected_id" "
    def items: (if type==\"array\" then . else (.items // []) end);
    (items | map(select(.id==\$id)) | .[0]) // {} | ${filter}
  " "$prd_file"
}

story_jq_c() {
  local filter="$1"
  jq -c --arg id "$selected_id" "
    def items: (if type==\"array\" then . else (.items // []) end);
    (items | map(select(.id==\$id)) | .[0]) // {} | ${filter}
  " "$prd_file"
}

add_followup() {
  local msg="$1"
  required_followups+=("$msg")
}

add_rationale() {
  local msg="$1"
  rationale+=("$msg")
}

add_violation() {
  local severity="$1"
  local contract_ref="$2"
  local description="$3"
  local evidence_in_diff="$4"
  local recommended_action="$5"
  shift 5
  local changed_files_json
  changed_files_json="$(json_array_from_lines "$@")"
  local v
  v="$(jq -n \
    --arg severity "$severity" \
    --arg contract_ref "$contract_ref" \
    --arg description "$description" \
    --arg evidence_in_diff "$evidence_in_diff" \
    --arg recommended_action "$recommended_action" \
    --argjson changed_files "$changed_files_json" \
    '{severity:$severity, contract_ref:$contract_ref, description:$description, evidence_in_diff:$evidence_in_diff, changed_files:$changed_files, recommended_action:$recommended_action}'
  )"
  violations+=("$v")
}

write_review_json() {
  local out_path="$1"
  jq -n \
    --arg selected_story_id "$selected_id" \
    --arg decision "$decision" \
    --arg confidence "$confidence" \
    --argjson contract_refs_checked "$contract_refs_checked_json" \
    --argjson scope_changed_files "$changed_files_json" \
    --argjson scope_out_files "$out_of_scope_files_json" \
    --argjson scope_notes "$scope_notes_json" \
    --argjson verify_post_present "$verify_post_present" \
    --argjson verify_post_green "$verify_post_green" \
    --argjson verify_notes "$verify_notes_json" \
    --arg requested_mark_pass_id "$requested_mark_pass_id" \
    --argjson prd_passes_before "$prd_passes_before" \
    --argjson prd_passes_after "$prd_passes_after" \
    --argjson evidence_required "$evidence_required_json" \
    --argjson evidence_found "$evidence_found_json" \
    --argjson evidence_missing "$evidence_missing_json" \
    --arg decision_on_pass_flip "$decision_on_pass_flip" \
    --argjson violations "$violations_json" \
    --argjson required_followups "$required_followups_json" \
    --argjson rationale "$rationale_json" \
    '{
      selected_story_id: $selected_story_id,
      decision: $decision,
      confidence: $confidence,
      contract_refs_checked: $contract_refs_checked,
      scope_check: {
        changed_files: $scope_changed_files,
        out_of_scope_files: $scope_out_files,
        notes: $scope_notes
      },
      verify_check: {
        verify_post_present: $verify_post_present,
        verify_post_green: $verify_post_green,
        notes: $verify_notes
      },
      pass_flip_check: {
        requested_mark_pass_id: $requested_mark_pass_id,
        prd_passes_before: $prd_passes_before,
        prd_passes_after: $prd_passes_after,
        evidence_required: $evidence_required,
        evidence_found: $evidence_found,
        evidence_missing: $evidence_missing,
        decision_on_pass_flip: $decision_on_pass_flip
      },
      violations: $violations,
      required_followups: $required_followups,
      rationale: $rationale
    }' > "$out_path"
}

write_fail_schema() {
  local out_path="$1"
  local reason="$2"
  local violation_code="$3"
  local selected="unknown"
  local refs_json="[]"

  if [[ -f "$out_path" ]]; then
    rm -f "$out_path"
  fi

  if [[ -f "$iter_dir/selected.json" ]]; then
    selected="$(jq -r '.selected_id // "unknown"' "$iter_dir/selected.json" 2>/dev/null || echo "unknown")"
  fi
  if [[ -f "$prd_file" && "$selected" != "unknown" ]]; then
    refs_json="$(jq -c --arg id "$selected" '
      def items: (if type=="array" then . else (.items // []) end);
      (items | map(select(.id==$id)) | .[0].contract_refs // [])
    ' "$prd_file" 2>/dev/null || echo '[]')"
  fi

  local v
  v="$(jq -n \
    --arg severity "MAJOR" \
    --arg contract_ref "$violation_code" \
    --arg description "$reason" \
    --arg evidence_in_diff "$reason" \
    --arg recommended_action "NEEDS_HUMAN" \
    '{severity:$severity, contract_ref:$contract_ref, description:$description, evidence_in_diff:$evidence_in_diff, changed_files:[], recommended_action:$recommended_action}'
  )"

  selected_id="$selected"
  decision="FAIL"
  confidence="low"
  contract_refs_checked_json="$refs_json"
  changed_files_json="[]"
  out_of_scope_files_json="[]"
  scope_notes_json="$(json_array_from_lines "$reason")"
  verify_post_present=false
  verify_post_green=false
  verify_notes_json="$(json_array_from_lines "contract review failed before verify check")"
  requested_mark_pass_id="$selected"
  prd_passes_before=false
  prd_passes_after=false
  evidence_required_json="[]"
  evidence_found_json="[]"
  evidence_missing_json="[]"
  decision_on_pass_flip="BLOCKED"
  violations_json="$(json_array_from_json_lines "$v")"
  required_followups_json="$(json_array_from_lines "$reason")"
  rationale_json="$(json_array_from_lines "contract review failed in deterministic checker")"

  write_review_json "$out_path"
}

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[[ -n "$out" ]] || { echo "missing CONTRACT_REVIEW_OUT / output path" >&2; exit 2; }

iter_dir="$(cd "$(dirname "$out")" && pwd -P)"
selected_json="$iter_dir/selected.json"
head_before_txt="$iter_dir/head_before.txt"
head_after_txt="$iter_dir/head_after.txt"
prd_before_json="$iter_dir/prd_before.json"
prd_after_json="$iter_dir/prd_after.json"
diff_patch="$iter_dir/diff.patch"
verify_post_log="$iter_dir/verify_post.log"

violations=()
required_followups=()
rationale=()
scope_notes=()
verify_notes=()

selected_id="unknown"
if [[ -f "$selected_json" ]]; then
  selected_id="$(jq -r '.selected_id // empty' "$selected_json" 2>/dev/null || true)"
  if [[ -z "$selected_id" ]]; then
    selected_id="unknown"
    add_followup "selected.json missing selected_id"
  fi
else
  add_followup "missing selected.json in iteration artifacts"
fi

story_json=""
if [[ -f "$prd_file" && "$selected_id" != "unknown" ]]; then
  story_json="$(jq -c --arg id "$selected_id" '
    def items: (if type=="array" then . else (.items // []) end);
    (items | map(select(.id==$id)) | .[0]) // empty
  ' "$prd_file" 2>/dev/null || true)"
fi

if [[ -z "$story_json" ]]; then
  add_violation "MAJOR" "PRD" "selected story not found in PRD" "plans/prd.json" "NEEDS_HUMAN"
fi

contract_refs_checked_json="[]"
touch_patterns=()
avoid_patterns=()
evidence_required=()

if [[ -n "$story_json" ]]; then
  contract_refs_checked_json="$(story_jq_c '(.contract_refs // [])' 2>/dev/null || echo '[]')"
  read_lines touch_patterns < <(story_jq_r '.scope.touch[]?' 2>/dev/null || true)
  read_lines avoid_patterns < <(story_jq_r '.scope.avoid[]?' 2>/dev/null || true)
  read_lines evidence_required < <(story_jq_r '.evidence[]?' 2>/dev/null || true)
fi

contract_ref_count="$(story_jq_r '(.contract_refs // []) | length' 2>/dev/null || echo "0")"
if ! [[ "$contract_ref_count" =~ ^[0-9]+$ ]]; then
  contract_ref_count=0
fi
if [[ "$contract_ref_count" -lt 1 ]]; then
  add_violation "MAJOR" "PRD" "story has empty contract_refs" "plans/prd.json" "NEEDS_HUMAN"
fi

touch_count="$(story_jq_r '(.scope.touch // []) | length' 2>/dev/null || echo "0")"
if ! [[ "$touch_count" =~ ^[0-9]+$ ]]; then
  touch_count=0
fi
if [[ "$touch_count" -lt 1 ]]; then
  add_violation "MAJOR" "PRD" "story has empty scope.touch" "plans/prd.json" "NEEDS_HUMAN"
fi

if [[ ! -f "$contract_file" ]]; then
  add_violation "CRITICAL" "CONTRACT_FILE" "missing contract file: $contract_file" "$contract_file" "NEEDS_HUMAN"
fi

contract_text_lc=""
if [[ -f "$contract_file" ]]; then
  contract_text_lc="$(tr '[:upper:]' '[:lower:]' < "$contract_file")"
fi

missing_refs=()
normalize_ref() {
  local r="$1"
  r="${r#CONTRACT.md }"
  r="${r#CONTRACT.md}"
  r="${r//$'\xc2\xa7'/}"
  echo "$r" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//'
}

ref_ok() {
  local ref="$1"
  local r; r="$(normalize_ref "$ref")"
  local r_lc; r_lc="$(echo "$r" | tr '[:upper:]' '[:lower:]')"

  if echo "$r_lc" | grep -q "definitions" && echo "$r" | grep -q "("; then
    local inner
    inner="$(echo "$r" | sed -n 's/.*(\(.*\)).*/\1/p' | head -n 1)"
    inner="$(echo "$inner" | sed 's/^ *//; s/ *$//')"
    [[ -z "$inner" ]] && return 1
    echo "$contract_text_lc" | grep -Fqi "$(echo "$inner" | tr '[:upper:]' '[:lower:]')" && return 0
    return 1
  fi

  if [[ "$r" =~ ^([0-9]+(\.[0-9]+)?)\ (.+)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[3]}"

    local num_fmt="$num"
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      num_fmt="${num}."
      echo "$contract_text_lc" | grep -Fqi "${num}.0" && return 0
    fi

    local title_key
    title_key="$(echo "$rest" | sed 's/[^[:alnum:][:space:]]/ /g' | awk '{print $1, $2}' | sed 's/ $//')"
    local needle="${num_fmt} ${title_key}"
    needle="$(echo "$needle" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"

    [[ -n "$title_key" ]] && echo "$contract_text_lc" | grep -Fqi "$needle" && return 0
    echo "$contract_text_lc" | grep -Fqi "$num" && return 0
  fi

  if [[ "${#r_lc}" -ge 8 ]]; then
    echo "$contract_text_lc" | grep -Fqi "$r_lc" && return 0
  fi

  return 1
}

if [[ -n "$story_json" && -n "$contract_text_lc" ]]; then
  read_lines contract_refs < <(story_jq_r '.contract_refs[]?' 2>/dev/null || true)
  for ref in "${contract_refs[@]+${contract_refs[@]}}"; do
    if ! ref_ok "$ref"; then
      missing_refs+=("$ref")
    fi
  done
fi

if [[ "${#missing_refs[@]}" -gt 0 ]]; then
  add_violation "MAJOR" "CONTRACT_REFS" "missing/weak contract refs: $(printf '%s; ' "${missing_refs[@]}")" "$contract_file" "PATCH_CONTRACT"
fi

head_before=""
head_after=""
commit_count=""
commit_proof="strong"
if [[ -f "$head_before_txt" && -f "$head_after_txt" ]]; then
  head_before="$(cat "$head_before_txt" 2>/dev/null || true)"
  head_after="$(cat "$head_after_txt" 2>/dev/null || true)"
  if [[ -n "$head_before" && -n "$head_after" ]]; then
    commit_count="$(git rev-list --count "${head_before}..${head_after}" 2>/dev/null || echo "")"
  fi
else
  commit_proof="weak"
  add_followup "missing head_before/head_after; using fallback diff"
fi

if [[ -z "$commit_count" && "$commit_proof" == "weak" ]]; then
  commit_count="$(git rev-list --count HEAD~1..HEAD 2>/dev/null || echo "")"
fi

if ! [[ "$commit_count" =~ ^[0-9]+$ ]]; then
  add_followup "could not compute commit count for iteration"
else
  if [[ "$commit_count" -ne 1 ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
      add_violation "MAJOR" "WORKFLOW_CONTRACT" "expected 1 commit; worktree dirty (uncommitted changes present)" "git status --porcelain" "REVERT"
    fi
    add_violation "MAJOR" "WORKFLOW_CONTRACT" "expected exactly 1 commit for story, got ${commit_count}" "git rev-list --count" "REVERT"
  fi
fi

changed_files=()
diff_source="none"
if [[ -f "$diff_patch" ]]; then
  diff_source="patch"
  read_lines changed_files < <(awk '/^\+\+\+ b\// {print substr($0,7)}' "$diff_patch" | grep -v '^/dev/null$' | sort -u)
elif [[ -n "$head_before" && -n "$head_after" ]]; then
  diff_source="range"
  read_lines changed_files < <(git diff --name-only "$head_before" "$head_after" | sed '/^$/d' | sort -u)
else
  diff_source="fallback"
  read_lines changed_files < <(git diff --name-only HEAD~1..HEAD 2>/dev/null | sed '/^$/d' | sort -u)
  if [[ "$commit_proof" != "strong" ]]; then
    add_followup "diff derived from HEAD~1..HEAD without head_before/head_after"
  fi
fi

scope_notes+=("changed_files source: ${diff_source}")
if [[ "${#changed_files[@]}" -eq 0 ]]; then
  scope_notes+=("no changed files detected")
fi

shopt -s globstar 2>/dev/null || true

scope_violations=()
out_of_scope_files=()

matches_any() {
  local path="$1"; shift
  local pat
  for pat in "$@"; do
    [[ -z "$pat" ]] && continue
    if [[ "$path" == $pat ]]; then
      return 0
    fi
  done
  return 1
}

for f in "${changed_files[@]+${changed_files[@]}}"; do
  if [[ "${#avoid_patterns[@]}" -gt 0 ]] && matches_any "$f" "${avoid_patterns[@]+${avoid_patterns[@]}}"; then
    scope_violations+=("avoid-match: $f")
    out_of_scope_files+=("$f")
    continue
  fi
  if [[ "${#touch_patterns[@]}" -gt 0 ]]; then
    if ! matches_any "$f" "${touch_patterns[@]+${touch_patterns[@]}}"; then
      scope_violations+=("out-of-scope: $f")
      out_of_scope_files+=("$f")
      continue
    fi
  fi
done

if [[ "${#scope_violations[@]}" -gt 0 ]]; then
  add_violation "MAJOR" "SCOPE" "scope violations: $(printf '%s; ' "${scope_violations[@]}")" "$diff_patch" "REVERT"
fi

for f in "${changed_files[@]+${changed_files[@]}}"; do
  if [[ "$f" == "plans/verify.sh" && "$allow_verify_edit" != "1" ]]; then
    add_violation "CRITICAL" "WORKFLOW_CONTRACT" "verify.sh modified but RPH_ALLOW_VERIFY_SH_EDIT!=1" "plans/verify.sh" "NEEDS_HUMAN"
  fi
done

verify_post_present=false
verify_post_green=false
if [[ -f "$verify_post_log" ]]; then
  verify_post_present=true
else
  add_followup "missing verify_post.log"
fi

verify_post_rc=""
if [[ -f "$state_file" ]]; then
  verify_post_rc="$(jq -r '.last_verify_post_rc // empty' "$state_file" 2>/dev/null || true)"
fi
if [[ "$verify_post_rc" == "0" ]]; then
  verify_post_green=true
else
  if [[ -n "$verify_post_rc" ]]; then
    verify_notes+=("verify_post rc=${verify_post_rc}")
    add_followup "verify_post rc=${verify_post_rc}"
  else
    verify_notes+=("verify_post rc missing in state")
    add_followup "verify_post rc missing in state"
  fi
fi

prd_passes_before=false
prd_passes_after=false
pass_flip=false
if [[ -f "$prd_before_json" && -f "$prd_after_json" && "$selected_id" != "unknown" ]]; then
  prd_passes_before="$(jq -r --arg id "$selected_id" '
    def items: (if type=="array" then . else (.items // []) end);
    (items | map(select(.id==$id)) | .[0].passes // empty)
  ' "$prd_before_json" 2>/dev/null || true)"
  prd_passes_after="$(jq -r --arg id "$selected_id" '
    def items: (if type=="array" then . else (.items // []) end);
    (items | map(select(.id==$id)) | .[0].passes // empty)
  ' "$prd_after_json" 2>/dev/null || true)"
else
  add_followup "missing prd_before.json or prd_after.json"
fi

if [[ "$prd_passes_before" != "true" && "$prd_passes_before" != "false" ]]; then
  prd_passes_before=false
fi
if [[ "$prd_passes_after" != "true" && "$prd_passes_after" != "false" ]]; then
  prd_passes_after=false
fi

if [[ "$prd_passes_before" == "false" && "$prd_passes_after" == "true" ]]; then
  pass_flip=true
fi

requested_mark_pass_id="none"
if [[ "$pass_flip" == "true" ]]; then
  requested_mark_pass_id="$selected_id"
fi

evidence_found=()
evidence_missing=()
for ev in "${evidence_required[@]+${evidence_required[@]}}"; do
  [[ -z "$ev" ]] && continue
  if [[ -f "$verify_post_log" ]] && grep -Fq "$ev" "$verify_post_log"; then
    evidence_found+=("$ev")
    continue
  fi
  if [[ -f "$diff_patch" ]] && grep -Fq "$ev" "$diff_patch"; then
    evidence_found+=("$ev")
    continue
  fi
  evidence_missing+=("$ev")
done

decision_on_pass_flip="DENY"
if [[ "$pass_flip" == "true" ]]; then
  if [[ "$verify_post_green" != "true" ]]; then
    decision_on_pass_flip="DENY"
  else
    if [[ "${#evidence_missing[@]}" -gt 0 ]]; then
      decision_on_pass_flip="BLOCKED"
      add_followup "evidence missing for pass flip: $(printf '%s; ' "${evidence_missing[@]}")"
    else
      decision_on_pass_flip="ALLOW"
    fi
  fi
fi

decision="PASS"
confidence="high"
if [[ "${#violations[@]}" -gt 0 ]]; then
  decision="FAIL"
  confidence="low"
elif [[ "${#required_followups[@]}" -gt 0 ]]; then
  decision="BLOCKED"
  confidence="med"
fi

if [[ "$decision" != "PASS" && "${#required_followups[@]}" -eq 0 ]]; then
  add_followup "review contract_review.json and resolve blocking issues"
fi

if [[ "${#rationale[@]}" -eq 0 ]]; then
  add_rationale "deterministic contract_check.sh evaluation"
fi

changed_files_json="$(json_array_from_lines "${changed_files[@]+${changed_files[@]}}")"
out_of_scope_files_json="$(json_array_from_lines "${out_of_scope_files[@]+${out_of_scope_files[@]}}")"
scope_notes_json="$(json_array_from_lines "${scope_notes[@]+${scope_notes[@]}}")"
verify_notes_json="$(json_array_from_lines "${verify_notes[@]+${verify_notes[@]}}")"
evidence_required_json="$(json_array_from_lines "${evidence_required[@]+${evidence_required[@]}}")"
evidence_found_json="$(json_array_from_lines "${evidence_found[@]+${evidence_found[@]}}")"
evidence_missing_json="$(json_array_from_lines "${evidence_missing[@]+${evidence_missing[@]}}")"
violations_json="$(json_array_from_json_lines "${violations[@]+${violations[@]}}")"
required_followups_json="$(json_array_from_lines "${required_followups[@]+${required_followups[@]}}")"
rationale_json="$(json_array_from_lines "${rationale[@]+${rationale[@]}}")"

write_review_json "$out"

if [[ -x "$validator" ]]; then
  if ! "$validator" "$out"; then
    write_fail_schema "$out" "contract_review.json invalid schema" "CONTRACT_REVIEW_INVALID"
    exit 1
  fi
else
  write_fail_schema "$out" "contract_review_validate.sh missing" "CONTRACT_REVIEW_INVALID"
  exit 1
fi

if [[ "$decision" == "PASS" ]]; then
  exit 0
fi
exit 1
