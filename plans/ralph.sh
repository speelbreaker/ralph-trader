#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RPH_MAX_ITERS="${RPH_MAX_ITERS:-50}"
if ! [[ "$RPH_MAX_ITERS" =~ ^[0-9]+$ ]] || [[ "$RPH_MAX_ITERS" -lt 1 ]]; then
  RPH_MAX_ITERS=50
fi
MAX_ITERS="${1:-$RPH_MAX_ITERS}"
if ! [[ "$MAX_ITERS" =~ ^[0-9]+$ ]] || [[ "$MAX_ITERS" -lt 1 ]]; then
  MAX_ITERS="$RPH_MAX_ITERS"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PRD_FILE="${PRD_FILE:-plans/prd.json}"
PROGRESS_FILE="${PROGRESS_FILE:-plans/progress.txt}"
VERIFY_SH="${VERIFY_SH:-./plans/verify.sh}"
ROTATE_PY="${ROTATE_PY:-./plans/rotate_progress.py}"

RPH_VERIFY_MODE="${RPH_VERIFY_MODE:-full}"     # quick|full|promotion (your choice)
RPH_SELF_HEAL="${RPH_SELF_HEAL:-0}"            # 0|1
RPH_DRY_RUN="${RPH_DRY_RUN:-0}"                # 0|1
RPH_SELECTION_MODE="${RPH_SELECTION_MODE:-harness}"  # harness|agent
RPH_REQUIRE_STORY_VERIFY="${RPH_REQUIRE_STORY_VERIFY:-1}"  # legacy; gate is mandatory
RPH_AGENT_CMD="${RPH_AGENT_CMD:-claude}"       # claude|codex|opencode|etc
if [[ -z "${RPH_AGENT_ARGS+x}" ]]; then
  RPH_AGENT_ARGS="--permission-mode acceptEdits"
fi
if [[ -z "${RPH_PROMPT_FLAG+x}" ]]; then
  RPH_PROMPT_FLAG="-p"
fi
RPH_COMPLETE_SENTINEL="${RPH_COMPLETE_SENTINEL:-<promise>COMPLETE</promise>}"

# Disallow agent from editing PRD directly (preferred; harness flips passes via <mark_pass>).
RPH_ALLOW_AGENT_PRD_EDIT="${RPH_ALLOW_AGENT_PRD_EDIT:-0}"  # 0|1 (legacy compatibility)
# Disallow verify.sh edits unless explicitly enabled (human-reviewed change).
RPH_ALLOW_VERIFY_SH_EDIT="${RPH_ALLOW_VERIFY_SH_EDIT:-0}"  # 0|1
# Contract alignment review gate (mandatory).
CONTRACT_FILE="${CONTRACT_FILE:-CONTRACT.md}"
IMPL_PLAN_FILE="${IMPL_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"
RPH_REQUIRE_CONTRACT_REVIEW="${RPH_REQUIRE_CONTRACT_REVIEW:-1}"  # 0|1 (mandatory)
RPH_CHEAT_DETECTION="${RPH_CHEAT_DETECTION:-block}"  # off|warn|block
RPH_CHEAT_ALLOWLIST="${RPH_CHEAT_ALLOWLIST:-}"      # regex of file paths to ignore
# Agent pass-mark tags: print exactly <mark_pass>ID</mark_pass>
RPH_MARK_PASS_OPEN="${RPH_MARK_PASS_OPEN:-<mark_pass>}"
RPH_MARK_PASS_CLOSE="${RPH_MARK_PASS_CLOSE:-</mark_pass>}"

# Parse RPH_AGENT_ARGS (space-delimited) into an array (global IFS excludes spaces).
RPH_AGENT_ARGS_ARR=()
if [[ -n "${RPH_AGENT_ARGS:-}" ]]; then
  _old_ifs="$IFS"; IFS=' '
  read -r -a RPH_AGENT_ARGS_ARR <<<"$RPH_AGENT_ARGS"
  IFS="$_old_ifs"
fi
RPH_RATE_LIMIT_PER_HOUR="${RPH_RATE_LIMIT_PER_HOUR:-100}"
RPH_RATE_LIMIT_FILE="${RPH_RATE_LIMIT_FILE:-.ralph/rate_limit.json}"
RPH_RATE_LIMIT_ENABLED="${RPH_RATE_LIMIT_ENABLED:-1}"
RPH_CIRCUIT_BREAKER_ENABLED="${RPH_CIRCUIT_BREAKER_ENABLED:-1}"
RPH_MAX_SAME_FAILURE="${RPH_MAX_SAME_FAILURE:-3}"
RPH_MAX_NO_PROGRESS="${RPH_MAX_NO_PROGRESS:-2}"
RPH_STATE_FILE="${RPH_STATE_FILE:-.ralph/state.json}"

mkdir -p .ralph
mkdir -p plans/logs

LOG_FILE="plans/logs/ralph.$(date +%Y%m%d-%H%M%S).log"
LAST_GOOD_FILE=".ralph/last_good_ref"
LAST_FAIL_FILE=".ralph/last_failure_path"
STATE_FILE="$RPH_STATE_FILE"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

write_blocked_basic() {
  local reason="$1"
  local details="$2"
  local prefix="${3:-blocked}"
  local block_dir
  block_dir=".ralph/${prefix}_$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$block_dir"
  if [[ -f "$PRD_FILE" ]]; then
    cp "$PRD_FILE" "$block_dir/prd_snapshot.json" || true
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg reason "$reason" \
      --arg details "$details" \
      '{reason: $reason, details: $details}' \
      > "$block_dir/blocked_item.json"
  else
    printf '{"reason":"%s","details":"%s"}\n' \
      "$(json_escape "$reason")" "$(json_escape "$details")" \
      > "$block_dir/blocked_item.json"
  fi
  echo "$block_dir"
}

block_preflight() {
  local reason="$1"
  local details="$2"
  local code="${3:-1}"
  local block_dir
  block_dir="$(write_blocked_basic "$reason" "$details")"
  echo "Blocked preflight: $reason ($details) in $block_dir" | tee -a "$LOG_FILE"
  exit "$code"
}

# --- preflight ---
command -v git >/dev/null 2>&1 || block_preflight "missing_git" "git required"
command -v jq  >/dev/null 2>&1 || block_preflight "missing_jq" "jq required"

[[ -f "$PRD_FILE" ]] || block_preflight "missing_prd" "missing $PRD_FILE"
jq . "$PRD_FILE" >/dev/null 2>&1 || block_preflight "invalid_prd_json" "$PRD_FILE invalid JSON"

# PRD schema sanity check (fail-closed)
if ! jq -e '
  def is_nonempty_str($v): ($v|type=="string" and ($v|length>0));
  def is_str_array($v): ($v|type=="array" and (($v|length)==0 or ($v|all(.[]; type=="string"))));
  def has_verify_sh($v): ($v|type=="array" and ($v|index("./plans/verify.sh") != null));
  def has_human_blocker($i):
    ($i|has("human_blocker") and ($i.human_blocker|type=="object") and
     ($i.human_blocker|has("why") and (is_nonempty_str($i.human_blocker.why))) and
     ($i.human_blocker|has("question") and (is_nonempty_str($i.human_blocker.question))) and
     ($i.human_blocker|has("options") and ($i.human_blocker.options|type=="array") and (($i.human_blocker.options|length)>0) and all($i.human_blocker.options[]; type=="string")) and
     ($i.human_blocker|has("recommended") and (is_nonempty_str($i.human_blocker.recommended))) and
     ($i.human_blocker|has("unblock_steps") and ($i.human_blocker.unblock_steps|type=="array") and (($i.human_blocker.unblock_steps|length)>0) and all($i.human_blocker.unblock_steps[]; type=="string"))
    );
  def source_ok($s):
    ($s|type=="object") and
    ($s|has("implementation_plan_path") and is_nonempty_str($s.implementation_plan_path)) and
    ($s|has("contract_path") and is_nonempty_str($s.contract_path));
  def item_ok($i):
    ($i|has("id") and is_nonempty_str($i.id)) and
    ($i|has("priority") and ($i.priority|type=="number")) and
    ($i|has("phase") and ($i.phase|type=="number")) and
    ($i|has("slice") and ($i.slice|type=="number")) and
    ($i|has("slice_ref") and is_nonempty_str($i.slice_ref)) and
    ($i|has("story_ref") and is_nonempty_str($i.story_ref)) and
    ($i|has("category") and is_nonempty_str($i.category)) and
    ($i|has("description") and is_nonempty_str($i.description)) and
    ($i|has("contract_refs") and is_str_array($i.contract_refs) and ($i.contract_refs|length>=1)) and
    ($i|has("plan_refs") and is_str_array($i.plan_refs) and ($i.plan_refs|length>=1)) and
    ($i|has("scope") and ($i.scope|type=="object") and ($i.scope|has("touch") and is_str_array($i.scope.touch)) and ($i.scope|has("avoid") and is_str_array($i.scope.avoid))) and
    ($i|has("acceptance") and is_str_array($i.acceptance) and ($i.acceptance|length>=3)) and
    ($i|has("steps") and is_str_array($i.steps) and ($i.steps|length>=5)) and
    ($i|has("verify") and is_str_array($i.verify) and has_verify_sh($i.verify)) and
    ($i|has("evidence") and is_str_array($i.evidence)) and
    ($i|has("dependencies") and is_str_array($i.dependencies)) and
    ($i|has("est_size") and is_nonempty_str($i.est_size)) and
    ($i|has("risk") and is_nonempty_str($i.risk)) and
    ($i|has("needs_human_decision") and ($i.needs_human_decision|type=="boolean")) and
    ($i|has("passes") and ($i.passes|type=="boolean")) and
    (if $i.needs_human_decision==true then has_human_blocker($i) else true end);
  (type=="object") and
  (has("project") and is_nonempty_str(.project)) and
  (has("source") and source_ok(.source)) and
  (has("rules") and (.rules|type=="object")) and
  (has("items") and (.items|type=="array") and (all(.items[]; item_ok(.))))
' "$PRD_FILE" >/dev/null 2>&1; then
  block_preflight "invalid_prd_schema" "$PRD_FILE schema invalid"
fi

# Required harness helpers (fail-closed with blocked artifacts)
[[ -x "$VERIFY_SH" ]] || block_preflight "missing_verify_sh" "$VERIFY_SH missing or not executable"
[[ -x "./plans/update_task.sh" ]] || block_preflight "missing_update_task_sh" "plans/update_task.sh missing or not executable"

if [[ ! -f "$CONTRACT_FILE" ]]; then
  if [[ -f "specs/CONTRACT.md" ]]; then
    CONTRACT_FILE="specs/CONTRACT.md"
  else
    block_preflight "missing_contract_file" "CONTRACT_FILE missing: $CONTRACT_FILE"
  fi
fi
if [[ ! -f "$IMPL_PLAN_FILE" ]]; then
  if [[ -f "specs/IMPLEMENTATION_PLAN.md" ]]; then
    IMPL_PLAN_FILE="specs/IMPLEMENTATION_PLAN.md"
  else
    block_preflight "missing_implementation_plan" "missing implementation plan: $IMPL_PLAN_FILE"
  fi
fi
if [[ "$RPH_REQUIRE_CONTRACT_REVIEW" != "1" ]]; then
  echo "WARN: RPH_REQUIRE_CONTRACT_REVIEW=0 ignored; gate is mandatory." | tee -a "$LOG_FILE"
  RPH_REQUIRE_CONTRACT_REVIEW="1"
fi

# progress file exists
mkdir -p "$(dirname "$PROGRESS_FILE")"
[[ -f "$PROGRESS_FILE" ]] || touch "$PROGRESS_FILE"

# state file exists
mkdir -p "$(dirname "$STATE_FILE")"
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{}' > "$STATE_FILE"
fi
if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  echo '{}' > "$STATE_FILE"
fi

# Fail if dirty at start (keeps history clean). Override only if you KNOW what you're doing.
if [[ -n "$(git status --porcelain)" ]]; then
  block_preflight "dirty_worktree" "working tree dirty. Commit/stash first." 2
fi

echo "Ralph starting max_iters=$MAX_ITERS mode=$RPH_VERIFY_MODE self_heal=$RPH_SELF_HEAL" | tee -a "$LOG_FILE"

# Initialize last_good_ref if missing
if [[ ! -f "$LAST_GOOD_FILE" ]]; then
  git rev-parse HEAD > "$LAST_GOOD_FILE"
fi

rotate_progress() {
  # portable rotation
  if [[ -x "$ROTATE_PY" ]]; then
    "$ROTATE_PY" --file "$PROGRESS_FILE" --keep 200 --archive plans/progress_archive.txt --max-lines 500 || true
  fi
}

run_verify() {
  local out="$1"
  shift
  set +e
  "$VERIFY_SH" "$RPH_VERIFY_MODE" "$@" 2>&1 | tee "$out"
  local rc=${PIPESTATUS[0]}
  set -e
  return $rc
}

run_story_verify() {
  local item_json="$1"
  local iter_dir="$2"
  local log="${iter_dir}/story_verify.log"
  local cmds=""
  local rc=0

  : > "$log"
  cmds="$(jq -r '(.verify // [])[]' <<<"$item_json" 2>/dev/null || true)"
  if [[ -z "$cmds" ]]; then
    echo "No story-specific verify commands." | tee -a "$log"
    return 0
  fi

  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    if [[ "$cmd" == "./plans/verify.sh" ]]; then
      continue
    fi
    echo "Running story verify: $cmd" | tee -a "$log" | tee -a "$LOG_FILE"
    set +e
    bash -c "$cmd" >> "$log" 2>&1
    local cmd_rc=$?
    set -e
    if (( cmd_rc != 0 )); then
      rc=1
      echo "FAIL: story verify command failed (rc=$cmd_rc): $cmd" | tee -a "$log" | tee -a "$LOG_FILE"
    fi
  done <<<"$cmds"

  return $rc
}

save_iter_artifacts() {
  local iter_dir="$1"
  mkdir -p "$iter_dir"
  cp "$PRD_FILE" "${iter_dir}/prd_before.json" || true
  tail -n 200 "$PROGRESS_FILE" > "${iter_dir}/progress_tail_before.txt" || true
  git rev-parse HEAD > "${iter_dir}/head_before.txt" || true
}

save_iter_after() {
  local iter_dir="$1"
  local head_before="${2:-}"
  local head_after="${3:-}"
  cp "$PRD_FILE" "${iter_dir}/prd_after.json" || true
  tail -n 200 "$PROGRESS_FILE" > "${iter_dir}/progress_tail_after.txt" || true
  git rev-parse HEAD > "${iter_dir}/head_after.txt" || true
  if [[ -n "$head_before" && -n "$head_after" ]]; then
    git diff "$head_before" "$head_after" > "${iter_dir}/diff.patch" || true
  else
    git diff > "${iter_dir}/diff.patch" || true
  fi
}

revert_to_last_good() {
  local last_good
  last_good="$(cat "$LAST_GOOD_FILE" 2>/dev/null || true)"
  if [[ -z "$last_good" ]]; then
    echo "ERROR: no last_good_ref available; cannot self-heal." | tee -a "$LOG_FILE"
    return 1
  fi
  echo "Self-heal: resetting to last good commit $last_good" | tee -a "$LOG_FILE"
  git reset --hard "$last_good"
  git clean -fd
}

select_next_item() {
  local slice="$1"
  jq -c --argjson s "$slice" '
    def items:
      if type=="array" then . else (.items // []) end;
    items | map(select(.passes==false and .slice==$s)) | sort_by(.priority) | reverse | .[0] // empty
  ' "$PRD_FILE"
}

item_by_id() {
  local id="$1"
  jq -c --arg id "$id" '
    def items:
      if type=="array" then . else (.items // []) end;
    items[] | select(.id==$id)
  ' "$PRD_FILE"
}

all_items_passed() {
  jq -e '
    def items:
      if type=="array" then . else (.items // []) end;
    (items | length) > 0 and all(items[]; .passes == true)
  ' "$PRD_FILE" >/dev/null
}

write_blocked_artifacts() {
  local reason="$1"
  local id="$2"
  local priority="$3"
  local desc="$4"
  local needs_human="$5"
  local prefix="${6:-blocked}"
  local block_dir
  block_dir=".ralph/${prefix}_$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$block_dir"
  cp "$PRD_FILE" "$block_dir/prd_snapshot.json" || true
  jq -n \
    --arg reason "$reason" \
    --arg id "$id" \
    --argjson priority "$priority" \
    --arg description "$desc" \
    --argjson needs_human_decision "$needs_human" \
    '{reason: $reason, id: $id, priority: $priority, description: $description, needs_human_decision: $needs_human_decision}' \
    > "$block_dir/blocked_item.json"
  echo "$block_dir"
}

sha256_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

sha256_tail_200() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    tail -n 200 "$file" | sha256sum | awk '{print $1}'
  else
    tail -n 200 "$file" | shasum -a 256 | awk '{print $1}'
  fi
}

extract_mark_pass_id() {
  local file="$1"
  sed -n "s|.*${RPH_MARK_PASS_OPEN}\\([^<]*\\)${RPH_MARK_PASS_CLOSE}.*|\\1|p" "$file" | head -n 1
}

verify_log_has_sha() {
  local log="$1"
  grep -q '^VERIFY_SH_SHA=' "$log"
}

write_contract_review() {
  local out="$1"
  local status="$2"
  local notes="$3"
  jq -n \
    --arg status "$status" \
    --arg contract_path "$CONTRACT_FILE" \
    --arg notes "$notes" \
    '{status: $status, contract_path: $contract_path, notes: $notes}' \
    > "$out"
}

contract_review_ok() {
  local file="$1"
  jq -e '
    type=="object" and
    (.status=="pass") and
    (.contract_path|type=="string") and
    (.notes|type=="string")
  ' "$file" >/dev/null 2>&1
}

ensure_contract_review() {
  local iter_dir="$1"
  local out="${iter_dir}/contract_review.json"
  local notes="contract_review.json missing"
  local rc=0

  if [[ -x "./plans/contract_check.sh" ]]; then
    set +e
    CONTRACT_REVIEW_OUT="$out" CONTRACT_FILE="$CONTRACT_FILE" ./plans/contract_check.sh "$out"
    rc=$?
    set -e
    if [[ -f "$out" ]]; then
      notes="contract_check.sh exited ${rc}"
    else
      notes="contract_check.sh did not produce contract_review.json (rc=${rc})"
    fi
  else
    notes="contract_check.sh missing"
  fi

  if [[ ! -f "$out" ]]; then
    write_contract_review "$out" "fail" "$notes"
  else
    if ! jq -e '
      type=="object" and
      (.status=="pass" or .status=="fail") and
      (.contract_path|type=="string") and
      (.notes|type=="string")
    ' "$out" >/dev/null 2>&1; then
      write_contract_review "$out" "fail" "contract_review.json invalid schema"
    fi
  fi

  contract_review_ok "$out"
}

completion_requirements_met() {
  local iter_dir="$1"
  local verify_post_rc="$2"
  local missing=0

  if ! all_items_passed; then
    return 1
  fi

  if [[ -z "$verify_post_rc" ]]; then
    verify_post_rc="$(jq -r '.last_verify_post_rc // empty' "$STATE_FILE" 2>/dev/null || true)"
  fi
  if [[ "$verify_post_rc" != "0" ]]; then
    return 1
  fi

  if [[ -z "$iter_dir" ]]; then
    iter_dir="$(jq -r '.last_iter_dir // empty' "$STATE_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "$iter_dir" || ! -d "$iter_dir" ]]; then
    return 1
  fi

  for f in selected.json prd_before.json prd_after.json progress_tail_before.txt progress_tail_after.txt head_before.txt head_after.txt diff.patch prompt.txt agent.out verify_pre.log verify_post.log story_verify.log contract_review.json; do
    if [[ ! -f "$iter_dir/$f" ]]; then
      missing=1
    fi
  done
  if (( missing == 1 )); then
    return 1
  fi

  return 0
}

verify_iteration_artifacts() {
  local iter_dir="$1"
  local missing=()
  local f

  for f in selected.json prd_before.json prd_after.json progress_tail_before.txt progress_tail_after.txt head_before.txt head_after.txt diff.patch prompt.txt agent.out verify_pre.log verify_post.log story_verify.log contract_review.json; do
    if [[ ! -f "$iter_dir/$f" ]]; then
      missing+=("$f")
    fi
  done

  if [[ "$RPH_SELECTION_MODE" == "agent" && ! -f "$iter_dir/selection.out" ]]; then
    missing+=("selection.out")
  fi

  if (( ${#missing[@]} > 0 )); then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

is_ignored_file() {
  local file="$1"
  case "$file" in
    plans/prd.json|plans/progress.txt|plans/progress_archive.txt) return 0 ;;
    .ralph/*|plans/logs/*) return 0 ;;
  esac
  return 1
}

matches_patterns() {
  local file="$1"
  local patterns="$2"
  local pattern
  if command -v python3 >/dev/null 2>&1; then
    RPH_PATTERNS="$patterns" python3 -c '
import fnmatch, os, sys
file = sys.argv[1]
patterns = [p.strip() for p in os.environ.get("RPH_PATTERNS","").splitlines() if p.strip()]
for p in patterns:
    if fnmatch.fnmatchcase(file, p):
        sys.exit(0)
sys.exit(1)
' "$file"
    return $?
  fi
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if [[ "$file" == $pattern ]]; then
      return 0
    fi
  done <<<"$patterns"
  return 1
}

scope_gate() {
  local head_before="$1"
  local head_after="$2"
  local item_json="$3"
  local touch_patterns
  local avoid_patterns
  local changed_files
  local out_of_scope=""

  touch_patterns="$(jq -r '.scope.touch[]?' <<<"$item_json")"
  avoid_patterns="$(jq -r '.scope.avoid[]?' <<<"$item_json")"
  changed_files="$(git diff --name-only "$head_before" "$head_after")"

  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if is_ignored_file "$file"; then
      continue
    fi
    if [[ -n "$avoid_patterns" ]] && matches_patterns "$file" "$avoid_patterns"; then
      out_of_scope+="${file} (scope.avoid)"$'\n'
      continue
    fi
    if [[ -n "$touch_patterns" ]]; then
      if ! matches_patterns "$file" "$touch_patterns"; then
        out_of_scope+="${file} (not in scope.touch)"$'\n'
        continue
      fi
    else
      out_of_scope+="${file} (not in scope.touch)"$'\n'
      continue
    fi
  done <<<"$changed_files"

  if [[ -n "$out_of_scope" ]]; then
    printf '%s' "$out_of_scope"
    return 1
  fi
  return 0
}

progress_gate() {
  local before_size="$1"
  local before_hash="$2"
  local next_id="$3"
  local iter_dir="$4"
  local progress_file="$PROGRESS_FILE"
  local issues=()
  local after_size=0
  local appended_file="${iter_dir}/progress_appended.txt"

  if [[ ! -f "$progress_file" ]]; then
    issues+=("missing_progress_file")
  fi

  if [[ "${#issues[@]}" -eq 0 ]]; then
    after_size="$(wc -c < "$progress_file" | tr -d ' ')"
    if ! [[ "$after_size" =~ ^[0-9]+$ ]]; then after_size=0; fi
    if ! [[ "$before_size" =~ ^[0-9]+$ ]]; then before_size=0; fi

    if (( after_size <= before_size )); then
      issues+=("no_new_entry")
    fi
    if (( after_size < before_size )); then
      issues+=("truncated")
    fi

    if (( before_size > 0 )); then
      local prefix_hash=""
      if command -v sha256sum >/dev/null 2>&1; then
        prefix_hash="$(head -c "$before_size" "$progress_file" | sha256sum | awk '{print $1}')"
      else
        prefix_hash="$(head -c "$before_size" "$progress_file" | shasum -a 256 | awk '{print $1}')"
      fi
      if [[ -n "$before_hash" && "$prefix_hash" != "$before_hash" ]]; then
        issues+=("not_append_only")
      fi
    fi

    if (( after_size > before_size )); then
      tail -c +$((before_size + 1)) "$progress_file" > "$appended_file" || true
    else
      : > "$appended_file"
    fi

    if [[ -n "$next_id" ]]; then
      if ! grep -Fq "$next_id" "$appended_file"; then
        issues+=("missing_story_id")
      fi
    else
      issues+=("missing_story_id")
    fi
    if ! grep -Eq "20[0-9]{2}-[01][0-9]-[0-3][0-9]" "$appended_file"; then
      issues+=("missing_timestamp")
    fi
    if ! grep -qi "summary" "$appended_file"; then
      issues+=("missing_summary")
    fi
    if ! grep -qi "commands" "$appended_file"; then
      issues+=("missing_commands")
    fi
    if ! grep -qi "evidence" "$appended_file"; then
      issues+=("missing_evidence")
    fi
    if ! grep -qiE "(next|gotcha)" "$appended_file"; then
      issues+=("missing_next")
    fi
  else
    : > "$appended_file" 2>/dev/null || true
  fi

  if (( ${#issues[@]} > 0 )); then
    printf '%s' "${issues[*]}"
    return 1
  fi
  return 0
}

is_test_path() {
  local path="$1"
  case "$path" in
    */tests/*|*/__tests__/*|*/*_test.*|*_test.*|*.spec.*|*.test.*|test_*.*)
      return 0
      ;;
  esac
  return 1
}

detect_cheating() {
  local iter_dir="$1"
  local head_before="$2"
  local diff_file="${iter_dir}/diff_for_cheat_check.patch"
  local filtered="${iter_dir}/diff_for_cheat_check.filtered.patch"
  local allow_re="${RPH_CHEAT_ALLOWLIST:-}"
  local cheats=()

  if [[ -n "$head_before" ]]; then
    git diff "$head_before" > "$diff_file" 2>/dev/null || git diff > "$diff_file"
  else
    git diff > "$diff_file"
  fi

  if [[ -n "$allow_re" ]]; then
    awk -v re="$allow_re" '
      /^diff --git / {
        file=$4; sub(/^b\//,"",file);
        skip=(re!="" && file ~ re);
      }
      { if (!skip) print }
    ' "$diff_file" > "$filtered"
  else
    cp "$diff_file" "$filtered"
  fi

  local status_cmd=(git diff --name-status)
  if [[ -n "$head_before" ]]; then
    status_cmd=(git diff --name-status "$head_before")
  fi
  mapfile -t deletions < <("${status_cmd[@]}" | awk '$1 ~ /^D/ {print $2}')
  for path in "${deletions[@]}"; do
    if is_test_path "$path"; then
      cheats+=("deleted_test_file:$path")
    fi
  done

  if grep -qE '^\-.*\b(assert|expect|should|must)\b' "$filtered"; then
    cheats+=("removed_assertion")
  fi
  if grep -qE '^\+.*(#\[ignore\]|@pytest\.mark\.skip|\.skip\(|it\.skip|xtest|xit)' "$filtered"; then
    cheats+=("added_skip_marker")
  fi
  if grep -qE '^[-+]{3} [ab]/plans/verify\.sh' "$filtered"; then
    cheats+=("modified_verify_sh")
  fi
  if grep -qE '^[-+]{3} [ab]/\.github/workflows/|^[-+]{3} [ab]/\.gitlab-ci\.yml' "$filtered"; then
    cheats+=("modified_ci")
  fi
  if grep -qE '^\+.*(# noqa|// @ts-ignore|#!\[allow|eslint-disable|rubocop:disable)' "$filtered"; then
    cheats+=("added_suppression")
  fi

  if (( ${#cheats[@]} > 0 )); then
    printf '%s' "${cheats[*]}"
    return 1
  fi
  return 0
}

count_pass_flips() {
  local before_file="$1"
  local after_file="$2"
  jq -n --slurpfile before "$before_file" --slurpfile after "$after_file" '
    def items($x): ($x[0].items // $x[0] // []);
    (items($before) | map({key:.id, value:.passes}) | from_entries) as $b
    | (items($after) | map({key:.id, value:.passes}) | from_entries) as $a
    | [ $b | keys[] as $id | select(($b[$id] == false) and ($a[$id] == true)) ] | length
  '
}
state_merge() {
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

write_blocked_with_state() {
  local reason="$1"
  local id="$2"
  local priority="$3"
  local desc="$4"
  local needs_human="$5"
  local iter_dir="$6"
  local prefix="${7:-blocked}"
  local block_dir
  block_dir="$(write_blocked_artifacts "$reason" "$id" "$priority" "$desc" "$needs_human" "$prefix")"
  if [[ -n "$iter_dir" && -f "$iter_dir/verify_post.log" ]]; then
    cp "$iter_dir/verify_post.log" "$block_dir/verify_post.log" || true
  fi
  if [[ -f "$STATE_FILE" ]]; then
    cp "$STATE_FILE" "$block_dir/state.json" || true
  fi
  echo "$block_dir"
}

update_rate_limit_state_if_present() {
  local window_start="$1"
  local count="$2"
  local limit="$3"
  local last_sleep="$4"
  local state_file="$STATE_FILE"
  local tmp
  if [[ -f "$state_file" ]]; then
    tmp="$(mktemp)"
    jq \
      --argjson window_start_epoch "$window_start" \
      --argjson count "$count" \
      --argjson limit "$limit" \
      --argjson last_sleep_seconds "$last_sleep" \
      '.rate_limit = {window_start_epoch: $window_start_epoch, count: $count, limit: $limit, last_sleep_seconds: $last_sleep_seconds}' \
      "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi
}

rate_limit_before_call() {
  if [[ "$RPH_RATE_LIMIT_ENABLED" != "1" ]]; then
    return 0
  fi

  local now
  local limit
  local window_start
  local count
  local sleep_secs

  now="$(date +%s)"
  limit="$RPH_RATE_LIMIT_PER_HOUR"
  if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 ]]; then
    limit=100
  fi

  mkdir -p "$(dirname "$RPH_RATE_LIMIT_FILE")"
  if [[ ! -f "$RPH_RATE_LIMIT_FILE" ]]; then
    jq -n --argjson now "$now" '{window_start_epoch: $now, count: 0}' > "$RPH_RATE_LIMIT_FILE"
  fi
  if ! jq -e . "$RPH_RATE_LIMIT_FILE" >/dev/null 2>&1; then
    jq -n --argjson now "$now" '{window_start_epoch: $now, count: 0}' > "$RPH_RATE_LIMIT_FILE"
  fi

  window_start="$(jq -r '.window_start_epoch // 0' "$RPH_RATE_LIMIT_FILE")"
  count="$(jq -r '.count // 0' "$RPH_RATE_LIMIT_FILE")"
  if ! [[ "$window_start" =~ ^[0-9]+$ ]]; then window_start=0; fi
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then count=0; fi

  if (( window_start <= 0 )); then
    window_start="$now"
    count=0
  fi
  if (( now - window_start >= 3600 )); then
    window_start="$now"
    count=0
  fi

  sleep_secs=0
  if (( count >= limit )); then
    sleep_secs=$(( (window_start + 3600 - now) + 2 ))
    if (( sleep_secs < 0 )); then sleep_secs=0; fi
    echo "RateLimit: sleeping ${sleep_secs}s (count=${count} limit=${limit})" | tee -a "$LOG_FILE"
    if [[ "$RPH_DRY_RUN" != "1" ]]; then
      sleep "$sleep_secs"
    fi
    now="$(date +%s)"
    window_start="$now"
    count=0
  fi

  count=$((count + 1))
  jq -n \
    --argjson window_start_epoch "$window_start" \
    --argjson count "$count" \
    '{window_start_epoch: $window_start_epoch, count: $count}' \
    > "$RPH_RATE_LIMIT_FILE"
  update_rate_limit_state_if_present "$window_start" "$count" "$limit" "$sleep_secs"
}

# --- main loop ---
for ((i=1; i<=MAX_ITERS; i++)); do
  rotate_progress

  ITER_DIR=".ralph/iter_${i}_$(date +%Y%m%d-%H%M%S)"
  echo "" | tee -a "$LOG_FILE"
  echo "=== Iteration $i/$MAX_ITERS ===" | tee -a "$LOG_FILE"
  echo "Artifacts: $ITER_DIR" | tee -a "$LOG_FILE"

  save_iter_artifacts "$ITER_DIR"
  HEAD_BEFORE="$(git rev-parse HEAD)"
  PRD_HASH_BEFORE="$(sha256_file "$PRD_FILE")"
  PRD_PASSES_BEFORE="$(jq -c '.items | map({id, passes})' "$PRD_FILE")"
  PROGRESS_SIZE_BEFORE="$(wc -c < "$PROGRESS_FILE" | tr -d ' ')"
  if ! [[ "$PROGRESS_SIZE_BEFORE" =~ ^[0-9]+$ ]]; then
    PROGRESS_SIZE_BEFORE=0
  fi
  PROGRESS_HASH_BEFORE="$(sha256_file "$PROGRESS_FILE")"

  ACTIVE_SLICE="$(jq -r '
    def items:
      if type=="array" then . else (.items // []) end;
    [items[] | select(.passes==false) | .slice] | min // empty
  ' "$PRD_FILE")"
  if [[ -z "$ACTIVE_SLICE" ]]; then
    if completion_requirements_met "" ""; then
      echo "All PRD items are passes=true. Done after $i iterations." | tee -a "$LOG_FILE"
      exit 0
    fi
    BLOCK_DIR="$(write_blocked_basic "incomplete_completion" "completion requirements not met" "blocked_incomplete")"
    echo "<promise>BLOCKED_INCOMPLETE</promise>" | tee -a "$LOG_FILE"
    echo "Blocked incomplete completion: $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  LAST_FAILURE_HASH="$(jq -r '.last_failure_hash // empty' "$STATE_FILE" 2>/dev/null || true)"
  LAST_FAILURE_STREAK="$(jq -r '.last_failure_streak // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
  NO_PROGRESS_STREAK="$(jq -r '.no_progress_streak // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
  if ! [[ "$LAST_FAILURE_STREAK" =~ ^[0-9]+$ ]]; then LAST_FAILURE_STREAK=0; fi
  if ! [[ "$NO_PROGRESS_STREAK" =~ ^[0-9]+$ ]]; then NO_PROGRESS_STREAK=0; fi

  if [[ "$RPH_SELECTION_MODE" != "harness" && "$RPH_SELECTION_MODE" != "agent" ]]; then
    RPH_SELECTION_MODE="harness"
  fi

  ACTIVE_SLICE_JSON="null"
  if [[ -n "$ACTIVE_SLICE" ]]; then ACTIVE_SLICE_JSON="$ACTIVE_SLICE"; fi
  LAST_GOOD_REF="$(cat "$LAST_GOOD_FILE" 2>/dev/null || true)"
  state_merge \
    --argjson iteration "$i" \
    --argjson active_slice "$ACTIVE_SLICE_JSON" \
    --arg selection_mode "$RPH_SELECTION_MODE" \
    --arg iter_dir "$ITER_DIR" \
    --arg last_good_ref "$LAST_GOOD_REF" \
    '.iteration=$iteration | .active_slice=$active_slice | .selection_mode=$selection_mode | .last_iter_dir=$iter_dir | .last_good_ref=$last_good_ref'
  state_merge \
    --arg head_before "$HEAD_BEFORE" \
    --arg prd_hash_before "$PRD_HASH_BEFORE" \
    '.head_before=$head_before | .prd_hash_before=$prd_hash_before'

  NEXT_ITEM_JSON=""
  NEXT_ID=""
  NEXT_PRIORITY=0
  NEXT_DESC=""
  NEXT_NEEDS_HUMAN=false

  if [[ "$RPH_SELECTION_MODE" == "agent" ]]; then
    CANDIDATE_LINES="$(jq -r --argjson s "$ACTIVE_SLICE" '
      def items:
        if type=="array" then . else (.items // []) end;
      items[] | select(.passes==false and .slice==$s) | "\(.id) - \(.description)"
    ' "$PRD_FILE")"

    IFS= read -r -d '' SEL_PROMPT <<PROMPT || true
@${PRD_FILE} @${PROGRESS_FILE}

Active slice: ${ACTIVE_SLICE}
Candidates:
${CANDIDATE_LINES}

Output ONLY:
<selected_id>ITEM_ID</selected_id>
PROMPT

    SEL_OUT="${ITER_DIR}/selection.out"
    set +e
    if [[ -n "$RPH_PROMPT_FLAG" ]]; then
      rate_limit_before_call
      ($RPH_AGENT_CMD "${RPH_AGENT_ARGS_ARR[@]}" "$RPH_PROMPT_FLAG" "$SEL_PROMPT") > "$SEL_OUT" 2>&1
    else
      rate_limit_before_call
      ($RPH_AGENT_CMD "${RPH_AGENT_ARGS_ARR[@]}" "$SEL_PROMPT") > "$SEL_OUT" 2>&1
    fi
    set -e

    sel_line=""
    has_extra=0
    {
      IFS= read -r sel_line || true
      if IFS= read -r _; then
        has_extra=1
      fi
    } < "$SEL_OUT"
    sel_line="${sel_line//$'\r'/}"

    if [[ "$has_extra" -eq 0 ]] && echo "$sel_line" | grep -qE '^<selected_id>[^<]+</selected_id>$'; then
      NEXT_ID="${sel_line#<selected_id>}"
      NEXT_ID="${NEXT_ID%</selected_id>}"
      NEXT_ITEM_JSON="$(item_by_id "$NEXT_ID")"
    fi
  else
    NEXT_ITEM_JSON="$(select_next_item "$ACTIVE_SLICE")"
    if [[ -n "$NEXT_ITEM_JSON" ]]; then
      NEXT_ID="$(jq -r '.id // empty' <<<"$NEXT_ITEM_JSON")"
    fi
  fi

  if [[ -n "$NEXT_ITEM_JSON" ]]; then
    NEXT_PRIORITY="$(jq -r '.priority // 0' <<<"$NEXT_ITEM_JSON")"
    NEXT_DESC="$(jq -r '.description // ""' <<<"$NEXT_ITEM_JSON")"
    NEXT_NEEDS_HUMAN="$(jq -r '.needs_human_decision // false' <<<"$NEXT_ITEM_JSON")"
  fi

  jq -n \
    --argjson active_slice "$ACTIVE_SLICE" \
    --arg selection_mode "$RPH_SELECTION_MODE" \
    --arg selected_id "$NEXT_ID" \
    --arg selected_description "$NEXT_DESC" \
    --argjson needs_human_decision "$NEXT_NEEDS_HUMAN" \
    '{active_slice: $active_slice, selection_mode: $selection_mode, selected_id: $selected_id, selected_description: $selected_description, needs_human_decision: $needs_human_decision}' \
    > "${ITER_DIR}/selected.json"

  NEEDS_HUMAN_JSON="$NEXT_NEEDS_HUMAN"
  if [[ "$NEEDS_HUMAN_JSON" != "true" && "$NEEDS_HUMAN_JSON" != "false" ]]; then
    NEEDS_HUMAN_JSON="false"
  fi
  state_merge \
    --arg selected_id "$NEXT_ID" \
    --arg selected_description "$NEXT_DESC" \
    --argjson needs_human_decision "$NEEDS_HUMAN_JSON" \
    '.selected_id=$selected_id | .selected_description=$selected_description | .needs_human_decision=$needs_human_decision'

  if [[ -z "$NEXT_ITEM_JSON" ]]; then
    BLOCK_DIR="$(write_blocked_artifacts "invalid_selection" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEXT_NEEDS_HUMAN")"
    echo "<promise>BLOCKED_INVALID_SELECTION</promise>" | tee -a "$LOG_FILE"
    echo "Blocked selection: $NEXT_ID" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [[ "$RPH_SELECTION_MODE" == "agent" ]]; then
    SEL_SLICE="$(jq -r '.slice // empty' <<<"$NEXT_ITEM_JSON")"
    SEL_PASSES="$(jq -r 'if has("passes") then .passes else "" end' <<<"$NEXT_ITEM_JSON")"
    if [[ -z "$NEXT_ID" || -z "$NEXT_ITEM_JSON" || "$SEL_PASSES" != "false" || "$SEL_SLICE" != "$ACTIVE_SLICE" ]]; then
      BLOCK_DIR="$(write_blocked_artifacts "invalid_selection" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEXT_NEEDS_HUMAN")"
      echo "<promise>BLOCKED_INVALID_SELECTION</promise>" | tee -a "$LOG_FILE"
      echo "Blocked selection: $NEXT_ID" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  if [[ "$NEXT_NEEDS_HUMAN" == "true" ]]; then
    BLOCK_DIR="$(write_blocked_artifacts "needs_human_decision" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" true)"
    if [[ "$RPH_DRY_RUN" != "1" ]]; then
      if [[ -x "$VERIFY_SH" ]]; then
        run_verify "$BLOCK_DIR/verify_pre.log" || true
      fi
    fi
    echo "<promise>BLOCKED_NEEDS_HUMAN_DECISION</promise>" | tee -a "$LOG_FILE"
    echo "Blocked item: $NEXT_ID - $NEXT_DESC" | tee -a "$LOG_FILE"
    exit 1
  fi

  if ! jq -e '(.verify // []) | index("./plans/verify.sh") != null' <<<"$NEXT_ITEM_JSON" >/dev/null; then
    BLOCK_DIR="$(write_blocked_artifacts "missing_verify_sh_in_story" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEXT_NEEDS_HUMAN")"
    echo "<promise>BLOCKED_MISSING_VERIFY_SH_IN_STORY</promise>" | tee -a "$LOG_FILE"
    echo "Blocked item: $NEXT_ID - missing ./plans/verify.sh in verify[]" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [[ "$RPH_DRY_RUN" == "1" ]]; then
    echo "DRY RUN: would run $NEXT_ID - $NEXT_DESC" | tee -a "$LOG_FILE"
    exit 0
  fi

  # 1) Pre-verify baseline
  if [[ ! -x "$VERIFY_SH" ]]; then
    BLOCK_DIR="$(write_blocked_with_state "missing_verify_sh" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "ERROR: $VERIFY_SH missing or not executable." | tee -a "$LOG_FILE"
    echo "This harness requires verify.sh. Bootstrap must create it first." | tee -a "$LOG_FILE"
    echo "Blocked: missing verify.sh in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  verify_pre_rc=0
  if run_verify "${ITER_DIR}/verify_pre.log"; then
    verify_pre_rc=0
  else
    verify_pre_rc=$?
  fi
  state_merge \
    --argjson last_verify_pre_rc "$verify_pre_rc" \
    --arg verify_pre_log "${ITER_DIR}/verify_pre.log" \
    '.last_verify_pre_rc=$last_verify_pre_rc | .last_verify_pre_log=$verify_pre_log'

  if ! verify_log_has_sha "${ITER_DIR}/verify_pre.log"; then
    BLOCK_DIR="$(write_blocked_with_state "verify_sha_missing_pre" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "ERROR: VERIFY_SH_SHA missing from verify_pre.log" | tee -a "$LOG_FILE"
    echo "Blocked: verify signature missing in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  if (( verify_pre_rc != 0 )); then
    echo "Baseline verify failed." | tee -a "$LOG_FILE"

    if [[ "$RPH_SELF_HEAL" == "1" ]]; then
      echo "$ITER_DIR" > "$LAST_FAIL_FILE"
      if ! revert_to_last_good; then
        BLOCK_DIR="$(write_blocked_with_state "self_heal_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
        echo "Blocked: self-heal failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
        exit 1
      fi

      # Re-run baseline verify after revert
      verify_pre_after_rc=0
      if run_verify "${ITER_DIR}/verify_pre_after_heal.log"; then
        verify_pre_after_rc=0
      else
        verify_pre_after_rc=$?
      fi
      state_merge \
        --argjson last_verify_pre_after_rc "$verify_pre_after_rc" \
        --arg verify_pre_after_log "${ITER_DIR}/verify_pre_after_heal.log" \
        '.last_verify_pre_after_rc=$last_verify_pre_after_rc | .last_verify_pre_after_log=$verify_pre_after_log'

      if (( verify_pre_after_rc != 0 )); then
        echo "Baseline still failing after self-heal. Stop." | tee -a "$LOG_FILE"
        BLOCK_DIR="$(write_blocked_with_state "verify_pre_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
        echo "Blocked: verify_pre failed after self-heal in $BLOCK_DIR" | tee -a "$LOG_FILE"
        exit 1
      fi
    else
      BLOCK_DIR="$(write_blocked_with_state "verify_pre_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Fail-closed: fix baseline before continuing." | tee -a "$LOG_FILE"
      echo "Blocked: verify_pre failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  # 2) Build the prompt (carry forward last failure path if present)
  LAST_FAIL_NOTE=""
  if [[ -f "$LAST_FAIL_FILE" ]]; then
    LAST_FAIL_PATH="$(cat "$LAST_FAIL_FILE" || true)"
    if [[ -n "$LAST_FAIL_PATH" && -d "$LAST_FAIL_PATH" ]]; then
      LAST_FAIL_NOTE=$'\n'"Last iteration failed. Read these files FIRST:"$'\n'"- ${LAST_FAIL_PATH}/verify_post.log"$'\n'"- ${LAST_FAIL_PATH}/agent.out"$'\n'"Then fix baseline back to green before attempting new work."$'\n'
    fi
  fi

  IFS= read -r -d '' PROMPT <<PROMPT || true
@${PRD_FILE} @${PROGRESS_FILE}

You are running inside the Ralph harness.

NON-NEGOTIABLE RULES:
- Work on EXACTLY ONE PRD item per iteration.
- Do NOT mark passes=true unless ${VERIFY_SH} ${RPH_VERIFY_MODE} is GREEN.
- Do NOT delete/disable tests or loosen gates to make green.
- Do NOT edit PRD directly unless explicitly allowed (RPH_ALLOW_AGENT_PRD_EDIT=1).
- To mark a story pass, print exactly: ${RPH_MARK_PASS_OPEN}${NEXT_ID}${RPH_MARK_PASS_CLOSE}
- Append to progress.txt (do not rewrite it).

Selected story ID (ONLY): ${NEXT_ID}
You MUST implement ONLY this PRD item: ${NEXT_ID} — ${NEXT_DESC}
Do not choose a different item even if it looks easier.

PROCEDURE:
0) Get bearings: pwd; git log --oneline -10; read prd.json + progress.txt.
${LAST_FAIL_NOTE}
1) If plans/init.sh exists, run it.
2) Run: ${VERIFY_SH} ${RPH_VERIFY_MODE}  (baseline must be green; if not, fix baseline first).
3) Implement ONLY the selected story: ${NEXT_ID}. Do not choose another.
4) Implement with minimal diff + add/adjust tests as needed.
5) Verify until green: ${VERIFY_SH} ${RPH_VERIFY_MODE}
6) Mark pass by printing: ${RPH_MARK_PASS_OPEN}${NEXT_ID}${RPH_MARK_PASS_CLOSE}
7) Append to progress.txt: what changed, commands run, what’s next.
8) Commit: git add -A && git commit -m "PRD: ${NEXT_ID} - <short description>"

If ALL items pass, output exactly: ${RPH_COMPLETE_SENTINEL}
PROMPT

  # 3) Run agent
  echo "$PROMPT" > "${ITER_DIR}/prompt.txt"

  set +e
  if [[ -n "$RPH_PROMPT_FLAG" ]]; then
    rate_limit_before_call
    if (( ${#RPH_AGENT_ARGS_ARR[@]} > 0 )); then
      ($RPH_AGENT_CMD "${RPH_AGENT_ARGS_ARR[@]}" "$RPH_PROMPT_FLAG" "$PROMPT") 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    else
      ($RPH_AGENT_CMD "$RPH_PROMPT_FLAG" "$PROMPT") 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    fi
  else
    rate_limit_before_call
    if (( ${#RPH_AGENT_ARGS_ARR[@]} > 0 )); then
      ($RPH_AGENT_CMD "${RPH_AGENT_ARGS_ARR[@]}" "$PROMPT") 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    else
      ($RPH_AGENT_CMD "$PROMPT") 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    fi
  fi
  AGENT_RC=${PIPESTATUS[0]}
  set -e
  echo "Agent exit code: $AGENT_RC" | tee -a "$LOG_FILE"

  HEAD_AFTER="$(git rev-parse HEAD)"
  PRD_HASH_AFTER="$(sha256_file "$PRD_FILE")"
  PRD_PASSES_AFTER="$(jq -c '.items | map({id, passes})' "$PRD_FILE")"
  MARK_PASS_ID=""
  if [[ -f "${ITER_DIR}/agent.out" ]]; then
    MARK_PASS_ID="$(extract_mark_pass_id "${ITER_DIR}/agent.out" || true)"
  fi
  if [[ -n "$MARK_PASS_ID" && "$MARK_PASS_ID" != "$NEXT_ID" ]]; then
    echo "ERROR: mark_pass id mismatch (got=$MARK_PASS_ID expected=$NEXT_ID)." | tee -a "$LOG_FILE"
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "mark_pass_mismatch" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "Blocked: mark_pass id mismatch in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi
  if [[ "$PRD_PASSES_AFTER" != "$PRD_PASSES_BEFORE" ]]; then
    echo "ERROR: PRD passes changed by agent; harness is sole authority." | tee -a "$LOG_FILE"
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "agent_pass_flip" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "Blocked: agent attempted pass flip in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi
  if [[ "$RPH_ALLOW_AGENT_PRD_EDIT" != "1" && "$PRD_HASH_AFTER" != "$PRD_HASH_BEFORE" ]]; then
    echo "ERROR: PRD was modified by agent but RPH_ALLOW_AGENT_PRD_EDIT=0." | tee -a "$LOG_FILE"
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "agent_prd_edit" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "Blocked: agent edited PRD in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [[ "$RPH_ALLOW_VERIFY_SH_EDIT" != "1" ]]; then
    if git diff --name-only "$HEAD_BEFORE" "$HEAD_AFTER" | grep -qx "plans/verify.sh"; then
      BLOCK_DIR="$(write_blocked_with_state "verify_sh_modified" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "<promise>BLOCKED_VERIFY_SH_MODIFIED</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: plans/verify.sh was modified in this iteration (human-reviewed change required) in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  DIRTY_STATUS="$(git status --porcelain 2>/dev/null || true)"
  if [[ -n "$DIRTY_STATUS" ]]; then
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "dirty_worktree" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "<promise>BLOCKED_DIRTY_WORKTREE</promise>" | tee -a "$LOG_FILE"
    echo "ERROR: working tree is dirty after agent run; commit required." | tee -a "$LOG_FILE"
    echo "$DIRTY_STATUS" | tee -a "$LOG_FILE"
    printf '%s\n' "$DIRTY_STATUS" > "$BLOCK_DIR/dirty_status.txt" || true
    echo "Blocked: dirty worktree in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  out_of_scope=""
  if ! out_of_scope="$(scope_gate "$HEAD_BEFORE" "$HEAD_AFTER" "$NEXT_ITEM_JSON")"; then
    BLOCK_DIR="$(write_blocked_with_state "scope_violation" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "ERROR: scope violation detected." | tee -a "$LOG_FILE"
    echo "$out_of_scope" | tee -a "$LOG_FILE"
    echo "Blocked: scope violation in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  CHEAT_RESULT=""
  if [[ "$RPH_CHEAT_DETECTION" != "off" ]]; then
    if ! CHEAT_RESULT="$(detect_cheating "$ITER_DIR" "$HEAD_BEFORE")"; then
      echo "Cheating patterns detected: $CHEAT_RESULT" | tee -a "$LOG_FILE"
      echo "Details in: $ITER_DIR/diff_for_cheat_check.patch" | tee -a "$LOG_FILE"
      if [[ "$RPH_CHEAT_DETECTION" == "warn" ]]; then
        echo "WARNING: cheat detection in warn mode; continuing." | tee -a "$LOG_FILE"
      else
        save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
        BLOCK_DIR="$(write_blocked_with_state "cheating_detected" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
        echo "<promise>BLOCKED_CHEATING_DETECTED</promise>" | tee -a "$LOG_FILE"
        echo "Blocked: cheating detected in $BLOCK_DIR" | tee -a "$LOG_FILE"
        if [[ "$RPH_SELF_HEAL" == "1" ]]; then
          revert_to_last_good || exit 9
        fi
        exit 9
      fi
    fi
  fi

  # 4) Post-verify
  verify_post_rc=0
  if run_verify "${ITER_DIR}/verify_post.log"; then
    verify_post_rc=0
  else
    verify_post_rc=$?
  fi

  if ! verify_log_has_sha "${ITER_DIR}/verify_post.log"; then
    BLOCK_DIR="$(write_blocked_with_state "verify_sha_missing_post" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "ERROR: VERIFY_SH_SHA missing from verify_post.log" | tee -a "$LOG_FILE"
    echo "Blocked: verify signature missing in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  if (( verify_post_rc == 0 )); then
    if run_story_verify "$NEXT_ITEM_JSON" "$ITER_DIR"; then
      :
    else
      verify_post_rc=1
    fi
  else
    : > "${ITER_DIR}/story_verify.log"
    echo "Skipped story-specific verify commands because verify.sh failed." >> "${ITER_DIR}/story_verify.log"
  fi

  state_merge \
    --argjson last_verify_post_rc "$verify_post_rc" \
    --arg verify_post_log "${ITER_DIR}/verify_post.log" \
    '.last_verify_post_rc=$last_verify_post_rc | .last_verify_post_log=$verify_post_log'

  POST_VERIFY_FAILED=0
  POST_VERIFY_EXIT=0
  POST_VERIFY_CONTINUE=0
  if (( verify_post_rc != 0 )); then
    POST_VERIFY_FAILED=1
    echo "Post-iteration verify failed." | tee -a "$LOG_FILE"
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    echo "$ITER_DIR" > "$LAST_FAIL_FILE"

    FAILURE_SIG="$(sha256_tail_200 "${ITER_DIR}/verify_post.log")"
    if [[ -n "$FAILURE_SIG" && "$FAILURE_SIG" == "$LAST_FAILURE_HASH" ]]; then
      LAST_FAILURE_STREAK=$((LAST_FAILURE_STREAK + 1))
    else
      LAST_FAILURE_HASH="$FAILURE_SIG"
      LAST_FAILURE_STREAK=1
    fi
    state_merge \
      --arg last_failure_hash "$LAST_FAILURE_HASH" \
      --argjson last_failure_streak "$LAST_FAILURE_STREAK" \
      '.last_failure_hash=$last_failure_hash | .last_failure_streak=$last_failure_streak'

    MAX_SAME_FAILURE="$RPH_MAX_SAME_FAILURE"
    if ! [[ "$MAX_SAME_FAILURE" =~ ^[0-9]+$ ]] || [[ "$MAX_SAME_FAILURE" -lt 1 ]]; then
      MAX_SAME_FAILURE=3
    fi

    if [[ "$RPH_CIRCUIT_BREAKER_ENABLED" == "1" && "$LAST_FAILURE_STREAK" -ge "$MAX_SAME_FAILURE" ]]; then
      if [[ "$RPH_DRY_RUN" == "1" ]]; then
        echo "DRY RUN: would block for circuit breaker (streak=${LAST_FAILURE_STREAK} max=${MAX_SAME_FAILURE})" | tee -a "$LOG_FILE"
      else
        BLOCK_DIR="$(write_blocked_with_state "circuit_breaker" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
        echo "<promise>BLOCKED_CIRCUIT_BREAKER</promise>" | tee -a "$LOG_FILE"
        echo "Blocked: circuit breaker in $BLOCK_DIR" | tee -a "$LOG_FILE"
        exit 1
      fi
    fi

    if [[ "$RPH_SELF_HEAL" == "1" ]]; then
      # If agent committed a broken state, rollback to last known green
      if ! revert_to_last_good; then
        BLOCK_DIR="$(write_blocked_with_state "self_heal_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
        echo "Blocked: self-heal failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
        exit 1
      fi
      echo "Rolled back to last good; continuing." | tee -a "$LOG_FILE"
      POST_VERIFY_CONTINUE=1
    else
      echo "Fail-closed: stop. Fix the failure then rerun." | tee -a "$LOG_FILE"
      BLOCK_DIR="$(write_blocked_with_state "verify_post_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Blocked: verify_post failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
      POST_VERIFY_EXIT=1
    fi
  else
    LAST_FAILURE_HASH=""
    LAST_FAILURE_STREAK=0
    state_merge \
      --arg last_failure_hash "$LAST_FAILURE_HASH" \
      --argjson last_failure_streak "$LAST_FAILURE_STREAK" \
      '.last_failure_hash=$last_failure_hash | .last_failure_streak=$last_failure_streak'
  fi

  CONTRACT_REVIEW_OK=0
  if (( POST_VERIFY_FAILED == 0 )); then
    if ensure_contract_review "$ITER_DIR"; then
      CONTRACT_REVIEW_OK=1
    else
      BLOCK_DIR="$(write_blocked_with_state "contract_review_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Blocked: contract review failed or missing in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  if [[ -n "$MARK_PASS_ID" ]]; then
    if (( POST_VERIFY_FAILED == 1 )); then
      echo "WARNING: mark_pass ignored because post-verify failed." | tee -a "$LOG_FILE"
    else
      if (( CONTRACT_REVIEW_OK == 1 )); then
        RPH_UPDATE_TASK_OK=1 RPH_STATE_FILE="$STATE_FILE" ./plans/update_task.sh "$MARK_PASS_ID" true
        git add -A
        if [[ "$HEAD_AFTER" != "$HEAD_BEFORE" ]]; then
          git commit --amend --no-edit
        else
          git commit -m "PRD: ${MARK_PASS_ID} - ${NEXT_DESC}"
        fi
        HEAD_AFTER="$(git rev-parse HEAD)"
        PRD_HASH_AFTER="$(sha256_file "$PRD_FILE")"
      else
        echo "WARNING: mark_pass ignored because contract review failed." | tee -a "$LOG_FILE"
      fi
    fi
  fi

  PROGRESS_MADE=0
  if [[ "$HEAD_AFTER" != "$HEAD_BEFORE" || "$PRD_HASH_AFTER" != "$PRD_HASH_BEFORE" ]]; then
    PROGRESS_MADE=1
  fi

  if (( PROGRESS_MADE == 1 )); then
    NO_PROGRESS_STREAK=0
  else
    NO_PROGRESS_STREAK=$((NO_PROGRESS_STREAK + 1))
  fi
  state_merge \
    --arg head_after "$HEAD_AFTER" \
    --arg prd_hash_after "$PRD_HASH_AFTER" \
    --argjson last_progress "$PROGRESS_MADE" \
    --argjson no_progress_streak "$NO_PROGRESS_STREAK" \
    '.head_after=$head_after | .prd_hash_after=$prd_hash_after | .last_progress=$last_progress | .no_progress_streak=$no_progress_streak'

  MAX_NO_PROGRESS="$RPH_MAX_NO_PROGRESS"
  if ! [[ "$MAX_NO_PROGRESS" =~ ^[0-9]+$ ]] || [[ "$MAX_NO_PROGRESS" -lt 1 ]]; then
    MAX_NO_PROGRESS=2
  fi

  if [[ "$RPH_CIRCUIT_BREAKER_ENABLED" == "1" && "$NO_PROGRESS_STREAK" -ge "$MAX_NO_PROGRESS" ]]; then
    if [[ "$RPH_DRY_RUN" == "1" ]]; then
      echo "DRY RUN: would block for no progress (streak=${NO_PROGRESS_STREAK} max=${MAX_NO_PROGRESS})" | tee -a "$LOG_FILE"
    else
      BLOCK_DIR="$(write_blocked_with_state "no_progress" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "<promise>BLOCKED_NO_PROGRESS</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: no progress in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  if (( POST_VERIFY_FAILED == 1 )); then
    if (( POST_VERIFY_EXIT == 1 )); then
      exit 8
    fi
    if (( POST_VERIFY_CONTINUE == 1 )); then
      continue
    fi
  fi

  progress_issues=""
  if ! progress_issues="$(progress_gate "$PROGRESS_SIZE_BEFORE" "$PROGRESS_HASH_BEFORE" "$NEXT_ID" "$ITER_DIR")"; then
    echo "ERROR: progress.txt gate failed: $progress_issues" | tee -a "$LOG_FILE"
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "progress_invalid" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "<promise>BLOCKED_PROGRESS_INVALID</promise>" | tee -a "$LOG_FILE"
    echo "Blocked: progress.txt gate failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  # 5) If green, update last_good_ref
  git rev-parse HEAD > "$LAST_GOOD_FILE"
  rm -f "$LAST_FAIL_FILE" || true
  state_merge \
    --arg last_good_ref "$HEAD_AFTER" \
    '.last_good_ref=$last_good_ref'

  save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"

  PASS_FLIPS="$(count_pass_flips "$ITER_DIR/prd_before.json" "$ITER_DIR/prd_after.json" || echo "error")"
  if [[ "$PASS_FLIPS" == "error" ]]; then
    BLOCK_DIR="$(write_blocked_with_state "pass_flip_check_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "ERROR: failed to compute pass flips." | tee -a "$LOG_FILE"
    echo "Blocked: pass flip check failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi
  if ! [[ "$PASS_FLIPS" =~ ^[0-9]+$ ]]; then
    PASS_FLIPS=0
  fi
  if (( PASS_FLIPS > 1 )); then
    BLOCK_DIR="$(write_blocked_with_state "multiple_pass_flips" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "ERROR: multiple pass flips detected (${PASS_FLIPS}) in iteration." | tee -a "$LOG_FILE"
    echo "Blocked: multiple pass flips in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  if ! missing_artifacts="$(verify_iteration_artifacts "$ITER_DIR")"; then
    BLOCK_DIR="$(write_blocked_with_state "missing_iteration_artifacts" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "ERROR: missing required iteration artifacts:" | tee -a "$LOG_FILE"
    echo "$missing_artifacts" | tee -a "$LOG_FILE"
    echo "Blocked: missing iteration artifacts in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  # 6) Completion detection: sentinel OR PRD all-pass
  if grep -qF "$RPH_COMPLETE_SENTINEL" "${ITER_DIR}/agent.out"; then
    if completion_requirements_met "$ITER_DIR" "$verify_post_rc"; then
      echo "Agent signaled COMPLETE and PRD is fully passed. Exiting." | tee -a "$LOG_FILE"
      exit 0
    fi
    BLOCK_DIR="$(write_blocked_artifacts "incomplete_completion" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "blocked_incomplete")"
    echo "<promise>BLOCKED_INCOMPLETE</promise>" | tee -a "$LOG_FILE"
    echo "Blocked incomplete completion: $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  if all_items_passed; then
    if completion_requirements_met "$ITER_DIR" "$verify_post_rc"; then
      echo "All PRD items are passes=true. Done after $i iterations." | tee -a "$LOG_FILE"
      exit 0
    fi
    BLOCK_DIR="$(write_blocked_artifacts "incomplete_completion" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "blocked_incomplete")"
    echo "<promise>BLOCKED_INCOMPLETE</promise>" | tee -a "$LOG_FILE"
    echo "Blocked incomplete completion: $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi
done

BLOCK_DIR="$(write_blocked_basic "max_iters_exceeded" "Reached max iterations ($MAX_ITERS) without completion." "blocked_max_iters")"
echo "Reached max iterations ($MAX_ITERS) without completion." | tee -a "$LOG_FILE"
echo "Blocked: max iterations exceeded in $BLOCK_DIR" | tee -a "$LOG_FILE"
exit 1
