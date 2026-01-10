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
RPH_AGENT_CMD="${RPH_AGENT_CMD:-claude}"       # claude|codex|opencode|etc
RPH_AGENT_ARGS="${RPH_AGENT_ARGS:---permission-mode acceptEdits}"
RPH_COMPLETE_SENTINEL="${RPH_COMPLETE_SENTINEL:-<promise>COMPLETE</promise>}"

mkdir -p .ralph
mkdir -p plans/logs

LOG_FILE="plans/logs/ralph.$(date +%Y%m%d-%H%M%S).log"
LAST_GOOD_FILE=".ralph/last_good_ref"
LAST_FAIL_FILE=".ralph/last_failure_path"

# --- preflight ---
command -v git >/dev/null 2>&1 || { echo "ERROR: git required"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }

[[ -f "$PRD_FILE" ]] || { echo "ERROR: missing $PRD_FILE"; exit 1; }
jq . "$PRD_FILE" >/dev/null 2>&1 || { echo "ERROR: $PRD_FILE invalid JSON"; exit 1; }

# progress file exists
mkdir -p "$(dirname "$PROGRESS_FILE")"
[[ -f "$PROGRESS_FILE" ]] || touch "$PROGRESS_FILE"

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

# --- main loop ---
for ((i=1; i<=MAX_ITERS; i++)); do
  rotate_progress

  ITER_DIR=".ralph/iter_${i}_$(date +%Y%m%d-%H%M%S)"
  echo "" | tee -a "$LOG_FILE"
  echo "=== Iteration $i/$MAX_ITERS ===" | tee -a "$LOG_FILE"
  echo "Artifacts: $ITER_DIR" | tee -a "$LOG_FILE"

  save_iter_artifacts "$ITER_DIR"

  # 1) Pre-verify baseline
  if [[ ! -x "$VERIFY_SH" ]]; then
    echo "ERROR: $VERIFY_SH missing or not executable." | tee -a "$LOG_FILE"
    echo "This harness requires verify.sh. Bootstrap must create it first." | tee -a "$LOG_FILE"
    exit 3
  fi

  if ! run_verify "${ITER_DIR}/verify_pre.log"; then
    echo "Baseline verify failed." | tee -a "$LOG_FILE"

    if [[ "$RPH_SELF_HEAL" == "1" ]]; then
      echo "$ITER_DIR" > "$LAST_FAIL_FILE"
      if ! revert_to_last_good; then exit 4; fi

      # Re-run baseline verify after revert
      if ! run_verify "${ITER_DIR}/verify_pre_after_heal.log"; then
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

  PROMPT="$(cat <<PROMPT
@${PRD_FILE} @${PROGRESS_FILE}

You are running inside the Ralph harness.

NON-NEGOTIABLE RULES:
- Work on EXACTLY ONE PRD item per iteration.
- Do NOT mark passes=true unless ${VERIFY_SH} ${RPH_VERIFY_MODE} is GREEN.
- Do NOT delete/disable tests or loosen gates to make green.
- Update PRD ONLY via: ./plans/update_task.sh <id> true  (never edit JSON directly).
- Append to progress.txt (do not rewrite it).

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
)"

  # 3) Run agent
  echo "$PROMPT" > "${ITER_DIR}/prompt.txt"

  set +e
  ($RPH_AGENT_CMD $RPH_AGENT_ARGS -p "$PROMPT") 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
  AGENT_RC=${PIPESTATUS[0]}
  set -e
  echo "Agent exit code: $AGENT_RC" | tee -a "$LOG_FILE"

  # 4) Post-verify
  if ! run_verify "${ITER_DIR}/verify_post.log"; then
    echo "Post-iteration verify failed." | tee -a "$LOG_FILE"
    save_iter_after "$ITER_DIR"
    echo "$ITER_DIR" > "$LAST_FAIL_FILE"

    if [[ "$RPH_SELF_HEAL" == "1" ]]; then
      # If agent committed a broken state, rollback to last known green
      if ! revert_to_last_good; then exit 7; fi
      echo "Rolled back to last good; continuing." | tee -a "$LOG_FILE"
      continue
    else
      echo "Fail-closed: stop. Fix the failure then rerun." | tee -a "$LOG_FILE"
      exit 8
    fi
  fi

  # 5) If green, update last_good_ref
  git rev-parse HEAD > "$LAST_GOOD_FILE"
  rm -f "$LAST_FAIL_FILE" || true

  save_iter_after "$ITER_DIR"

  # 6) Completion detection: sentinel OR PRD all-pass
  if grep -qF "$RPH_COMPLETE_SENTINEL" "${ITER_DIR}/agent.out"; then
    echo "COMPLETE sentinel detected. Done after $i iterations." | tee -a "$LOG_FILE"
    exit 0
  fi

  if jq -e '(.items | length) > 0 and all(.items[]; .passes == true)' "$PRD_FILE" >/dev/null; then
    echo "All PRD items are passes=true. Done after $i iterations." | tee -a "$LOG_FILE"
    exit 0
  fi
done

echo "Reached max iterations ($MAX_ITERS) without completion." | tee -a "$LOG_FILE"
exit 0
