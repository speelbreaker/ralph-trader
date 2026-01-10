#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

MAX_ITERS="${1:-10}"

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
RPH_REQUIRE_STORY_VERIFY="${RPH_REQUIRE_STORY_VERIFY:-1}"
RPH_AGENT_CMD="${RPH_AGENT_CMD:-claude}"       # claude|codex|opencode|etc
if [[ -z "${RPH_AGENT_ARGS+x}" ]]; then
  RPH_AGENT_ARGS="--permission-mode acceptEdits"
fi
if [[ -z "${RPH_PROMPT_FLAG+x}" ]]; then
  RPH_PROMPT_FLAG="-p"
fi
RPH_COMPLETE_SENTINEL="${RPH_COMPLETE_SENTINEL:-<promise>COMPLETE</promise>}"
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

# --- preflight ---
command -v git >/dev/null 2>&1 || { echo "ERROR: git required"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }

[[ -f "$PRD_FILE" ]] || { echo "ERROR: missing $PRD_FILE"; exit 1; }
jq . "$PRD_FILE" >/dev/null 2>&1 || { echo "ERROR: $PRD_FILE invalid JSON"; exit 1; }

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
  echo "ERROR: working tree dirty. Commit/stash first." | tee -a "$LOG_FILE"
  exit 2
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

save_iter_artifacts() {
  local iter_dir="$1"
  mkdir -p "$iter_dir"
  cp "$PRD_FILE" "${iter_dir}/prd_before.json" || true
  tail -n 200 "$PROGRESS_FILE" > "${iter_dir}/progress_tail_before.txt" || true
  git rev-parse HEAD > "${iter_dir}/head_before.txt" || true
}

save_iter_after() {
  local iter_dir="$1"
  cp "$PRD_FILE" "${iter_dir}/prd_after.json" || true
  tail -n 200 "$PROGRESS_FILE" > "${iter_dir}/progress_tail_after.txt" || true
  git rev-parse HEAD > "${iter_dir}/head_after.txt" || true
  git diff > "${iter_dir}/diff.patch" || true
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
  local block_dir
  block_dir=".ralph/blocked_$(date +%Y%m%d-%H%M%S)"
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
  local block_dir
  block_dir="$(write_blocked_artifacts "$reason" "$id" "$priority" "$desc" "$needs_human")"
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

  ACTIVE_SLICE="$(jq -r '
    def items:
      if type=="array" then . else (.items // []) end;
    [items[] | select(.passes==false) | .slice] | min // empty
  ' "$PRD_FILE")"
  if [[ -z "$ACTIVE_SLICE" ]]; then
    echo "All PRD items are passes=true. Done after $i iterations." | tee -a "$LOG_FILE"
    exit 0
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
      ($RPH_AGENT_CMD $RPH_AGENT_ARGS "$RPH_PROMPT_FLAG" "$SEL_PROMPT") > "$SEL_OUT" 2>&1
    else
      rate_limit_before_call
      ($RPH_AGENT_CMD $RPH_AGENT_ARGS "$SEL_PROMPT") > "$SEL_OUT" 2>&1
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
    exit 0
  fi

  if [[ "$RPH_SELECTION_MODE" == "agent" ]]; then
    SEL_SLICE="$(jq -r '.slice // empty' <<<"$NEXT_ITEM_JSON")"
    SEL_PASSES="$(jq -r 'if has("passes") then .passes else "" end' <<<"$NEXT_ITEM_JSON")"
    if [[ -z "$NEXT_ID" || -z "$NEXT_ITEM_JSON" || "$SEL_PASSES" != "false" || "$SEL_SLICE" != "$ACTIVE_SLICE" ]]; then
      BLOCK_DIR="$(write_blocked_artifacts "invalid_selection" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEXT_NEEDS_HUMAN")"
      echo "<promise>BLOCKED_INVALID_SELECTION</promise>" | tee -a "$LOG_FILE"
      echo "Blocked selection: $NEXT_ID" | tee -a "$LOG_FILE"
      exit 0
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
    exit 0
  fi

  if [[ "$RPH_REQUIRE_STORY_VERIFY" == "1" ]]; then
    if ! jq -e '(.verify // []) | index("./plans/verify.sh") != null' <<<"$NEXT_ITEM_JSON" >/dev/null; then
      BLOCK_DIR="$(write_blocked_artifacts "missing_verify_sh_in_story" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEXT_NEEDS_HUMAN")"
      echo "<promise>BLOCKED_MISSING_VERIFY_SH_IN_STORY</promise>" | tee -a "$LOG_FILE"
      echo "Blocked item: $NEXT_ID - missing ./plans/verify.sh in verify[]" | tee -a "$LOG_FILE"
      exit 0
    fi
  fi

  if [[ "$RPH_DRY_RUN" == "1" ]]; then
    echo "DRY RUN: would run $NEXT_ID - $NEXT_DESC" | tee -a "$LOG_FILE"
    exit 0
  fi

  # 1) Pre-verify baseline
  if [[ ! -x "$VERIFY_SH" ]]; then
    echo "ERROR: $VERIFY_SH missing or not executable." | tee -a "$LOG_FILE"
    echo "This harness requires verify.sh. Bootstrap must create it first." | tee -a "$LOG_FILE"
    exit 3
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

  if (( verify_pre_rc != 0 )); then
    echo "Baseline verify failed." | tee -a "$LOG_FILE"

    if [[ "$RPH_SELF_HEAL" == "1" ]]; then
      echo "$ITER_DIR" > "$LAST_FAIL_FILE"
      if ! revert_to_last_good; then exit 4; fi

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
        exit 5
      fi
    else
      echo "Fail-closed: fix baseline before continuing." | tee -a "$LOG_FILE"
      exit 6
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
- Update PRD ONLY via: ./plans/update_task.sh <id> true  (never edit JSON directly).
- Append to progress.txt (do not rewrite it).

You MUST implement ONLY this PRD item: ${NEXT_ID} — ${NEXT_DESC}
Do not choose a different item even if it looks easier.

PROCEDURE:
0) Get bearings: pwd; git log --oneline -10; read prd.json + progress.txt.
${LAST_FAIL_NOTE}
1) If plans/init.sh exists, run it.
2) Run: ${VERIFY_SH} ${RPH_VERIFY_MODE}  (baseline must be green; if not, fix baseline first).
3) Choose the highest-priority PRD item where passes=false.
4) Implement with minimal diff + add/adjust tests as needed.
5) Verify until green: ${VERIFY_SH} ${RPH_VERIFY_MODE}
6) Mark pass: ./plans/update_task.sh <id> true
7) Append to progress.txt: what changed, commands run, what’s next.
8) Commit: git add -A && git commit -m "PRD: <id> - <short description>"

If ALL items pass, output exactly: ${RPH_COMPLETE_SENTINEL}
PROMPT

  # 3) Run agent
  echo "$PROMPT" > "${ITER_DIR}/prompt.txt"

  set +e
  if [[ -n "$RPH_PROMPT_FLAG" ]]; then
    rate_limit_before_call
    ($RPH_AGENT_CMD $RPH_AGENT_ARGS "$RPH_PROMPT_FLAG" "$PROMPT") 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
  else
    rate_limit_before_call
    ($RPH_AGENT_CMD $RPH_AGENT_ARGS "$PROMPT") 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
  fi
  AGENT_RC=${PIPESTATUS[0]}
  set -e
  echo "Agent exit code: $AGENT_RC" | tee -a "$LOG_FILE"

  HEAD_AFTER="$(git rev-parse HEAD)"
  PRD_HASH_AFTER="$(sha256_file "$PRD_FILE")"
  PROGRESS_MADE=0
  if [[ "$HEAD_AFTER" != "$HEAD_BEFORE" || "$PRD_HASH_AFTER" != "$PRD_HASH_BEFORE" ]]; then
    PROGRESS_MADE=1
  fi

  # 4) Post-verify
  verify_post_rc=0
  if run_verify "${ITER_DIR}/verify_post.log"; then
    verify_post_rc=0
  else
    verify_post_rc=$?
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
    save_iter_after "$ITER_DIR"
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
        exit 0
      fi
    fi

    if [[ "$RPH_SELF_HEAL" == "1" ]]; then
      # If agent committed a broken state, rollback to last known green
      if ! revert_to_last_good; then exit 7; fi
      echo "Rolled back to last good; continuing." | tee -a "$LOG_FILE"
      POST_VERIFY_CONTINUE=1
    else
      echo "Fail-closed: stop. Fix the failure then rerun." | tee -a "$LOG_FILE"
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
      exit 0
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

  # 5) If green, update last_good_ref
  git rev-parse HEAD > "$LAST_GOOD_FILE"
  rm -f "$LAST_FAIL_FILE" || true
  state_merge \
    --arg last_good_ref "$HEAD_AFTER" \
    '.last_good_ref=$last_good_ref'

  save_iter_after "$ITER_DIR"

  # 6) Completion detection: sentinel OR PRD all-pass
  if grep -qxF "$RPH_COMPLETE_SENTINEL" "${ITER_DIR}/agent.out"; then
    echo "COMPLETE sentinel detected. Done after $i iterations." | tee -a "$LOG_FILE"
    exit 0
  fi

  if all_items_passed; then
    echo "All PRD items are passes=true. Done after $i iterations." | tee -a "$LOG_FILE"
    exit 0
  fi
done

echo "Reached max iterations ($MAX_ITERS) without completion." | tee -a "$LOG_FILE"
exit 0
