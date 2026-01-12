#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

out="${CONTRACT_REVIEW_OUT:-${1:-}}"
contract_file="${CONTRACT_FILE:-CONTRACT.md}"
prd_file="${PRD_FILE:-plans/prd.json}"
allow_verify_edit="${RPH_ALLOW_VERIFY_SH_EDIT:-0}"

write_json() {
  local status="$1"
  local notes="$2"
  mkdir -p "$(dirname "$out")"
  jq -n \
    --arg status "$status" \
    --arg contract_path "$contract_file" \
    --arg notes "$notes" \
    '{status:$status, contract_path:$contract_path, notes:$notes}' \
    > "$out"
}

fail() {
  write_json "fail" "$1"
  exit 1
}

pass() {
  write_json "pass" "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[[ -n "$out" ]] || { echo "missing CONTRACT_REVIEW_OUT / output path" >&2; exit 2; }
[[ -f "$contract_file" ]] || fail "missing contract file: $contract_file"
[[ -f "$prd_file" ]] || fail "missing PRD file: $prd_file"

iter_dir="$(cd "$(dirname "$out")" && pwd -P)"
selected_json="$iter_dir/selected.json"
head_before_txt="$iter_dir/head_before.txt"
head_after_txt="$iter_dir/head_after.txt"

[[ -f "$selected_json" ]] || fail "missing iteration selected.json at $selected_json"
[[ -f "$head_before_txt" ]] || fail "missing iteration head_before.txt at $head_before_txt"
[[ -f "$head_after_txt" ]] || fail "missing iteration head_after.txt at $head_after_txt"

selected_id="$(jq -r '.selected_id // empty' "$selected_json")"
[[ -n "$selected_id" ]] || fail "selected_id missing in selected.json"

# Load story from PRD
story_json="$(jq -c --arg id "$selected_id" '
  def items: (if type=="array" then . else (.items // []) end);
  (items | map(select(.id==$id)) | .[0]) // empty
' "$prd_file")"

[[ -n "$story_json" ]] || fail "selected story not found in PRD: $selected_id"

# Enforce story has contract_refs + scope.touch (PRD schema already requires, but double-lock here)
contract_ref_count="$(jq -r '(.contract_refs // []) | length' <<<"$story_json")"
touch_count="$(jq -r '(.scope.touch // []) | length' <<<"$story_json")"
[[ "$contract_ref_count" -ge 1 ]] || fail "story $selected_id has empty contract_refs"
[[ "$touch_count" -ge 1 ]] || fail "story $selected_id has empty scope.touch"

head_before="$(cat "$head_before_txt")"
head_after="$(cat "$head_after_txt")"
[[ -n "$head_before" && -n "$head_after" ]] || fail "missing head_before/head_after values"

# Enforce: agent must have made exactly ONE commit for this story.
commit_count="$(git rev-list --count "${head_before}..${head_after}" 2>/dev/null || echo "0")"
if ! [[ "$commit_count" =~ ^[0-9]+$ ]]; then
  fail "could not compute commit_count for ${head_before}..${head_after}"
fi
if [[ "$commit_count" -ne 1 ]]; then
  # Also fail if there are uncommitted changes (classic “verify green but no commit” loophole)
  if [[ -n "$(git status --porcelain)" ]]; then
    fail "expected 1 commit, got ${commit_count}; also worktree is dirty (uncommitted changes present)"
  fi
  fail "expected exactly 1 commit for story, got ${commit_count}"
fi

# Files changed in the commit
mapfile -t changed_files < <(git diff-tree --no-commit-id --name-only -r "$head_after" | sed '/^$/d')

# Scope enforcement (this is the big missing guard you were failing before)
mapfile -t touch_patterns < <(jq -r '.scope.touch[]' <<<"$story_json")
mapfile -t avoid_patterns < <(jq -r '.scope.avoid[]?' <<<"$story_json")

shopt -s globstar

scope_violations=()

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

for f in "${changed_files[@]}"; do
  # avoid wins
  if [[ "${#avoid_patterns[@]}" -gt 0 ]] && matches_any "$f" "${avoid_patterns[@]}"; then
    scope_violations+=("avoid-match: $f")
    continue
  fi
  if ! matches_any "$f" "${touch_patterns[@]}"; then
    scope_violations+=("out-of-scope: $f")
    continue
  fi
done

if [[ "${#scope_violations[@]}" -gt 0 ]]; then
  notes="SCOPE FAIL for $selected_id: $(printf '%s; ' "${scope_violations[@]}")"
  fail "$notes"
fi

# Guard: verify.sh edits are human-reviewed unless explicitly allowed
for f in "${changed_files[@]}"; do
  if [[ "$f" == "plans/verify.sh" && "$allow_verify_edit" != "1" ]]; then
    fail "verify.sh modified in commit but RPH_ALLOW_VERIFY_SH_EDIT!=1 (human-reviewed gate)"
  fi
done

# Contract refs: mechanical “does the contract actually contain what you claim you referenced?”
# This is intentionally conservative: if it can’t find it, it fails (forces you to fix ref text or contract).
contract_text_lc="$(tr '[:upper:]' '[:lower:]' < "$contract_file")"

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

  # Definitions(x) style
  if echo "$r_lc" | grep -q "definitions" && echo "$r" | grep -q "("; then
    local inner
    inner="$(echo "$r" | sed -n 's/.*(\(.*\)).*/\1/p' | head -n 1)"
    inner="$(echo "$inner" | sed 's/^ *//; s/ *$//')"
    [[ -z "$inner" ]] && return 1
    echo "$contract_text_lc" | grep -Fqi "$(echo "$inner" | tr '[:upper:]' '[:lower:]')" && return 0
    return 1
  fi

  # Section style: "8 Release Gates ..." or "8.2 Minimum Test Suite ..."
  if [[ "$r" =~ ^([0-9]+(\.[0-9]+)?)\ (.+)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[3]}"

    # If ref is "8 ..." but contract headings are "8. ...", normalize integer sections to "8."
    local num_fmt="$num"
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      num_fmt="${num}."
      # accept integer section by finding "num.0" as well (your contract uses 1.0 / 1.1 etc)
      echo "$contract_text_lc" | grep -Fqi "${num}.0" && return 0
    fi

    # Build a small title key: first 2 words (alnum only)
    local title_key
    title_key="$(echo "$rest" | sed 's/[^[:alnum:][:space:]]/ /g' | awk '{print $1, $2}' | sed 's/ $//')"
    local needle="${num_fmt} ${title_key}"
    needle="$(echo "$needle" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"

    [[ -n "$title_key" ]] && echo "$contract_text_lc" | grep -Fqi "$needle" && return 0
    # fallback: at least find the numeric section token somewhere (still reasonably strong for 1.0, 8.2, etc)
    echo "$contract_text_lc" | grep -Fqi "$num" && return 0
  fi

  # Last resort: try the whole normalized ref (short refs)
  if [[ "${#r_lc}" -ge 8 ]]; then
    echo "$contract_text_lc" | grep -Fqi "$r_lc" && return 0
  fi

  return 1
}

mapfile -t contract_refs < <(jq -r '.contract_refs[]' <<<"$story_json")
for ref in "${contract_refs[@]}"; do
  if ! ref_ok "$ref"; then
    missing_refs+=("$ref")
  fi
done

if [[ "${#missing_refs[@]}" -gt 0 ]]; then
  fail "CONTRACT REF FAIL for $selected_id: missing/weak refs: $(printf '%s | ' "${missing_refs[@]}")"
fi

pass "ok: $selected_id scope+contract_refs+one_commit"
