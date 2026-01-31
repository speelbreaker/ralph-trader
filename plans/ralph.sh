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
PRD_SCHEMA_CHECK_SH="${PRD_SCHEMA_CHECK_SH:-./plans/prd_schema_check.sh}"
PRD_PREFLIGHT_SH="${PRD_PREFLIGHT_SH:-./plans/prd_preflight.sh}"
RPH_RUN_ID="${RPH_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
VERIFY_RUN_ID="${VERIFY_RUN_ID:-$RPH_RUN_ID}"
VERIFY_ARTIFACTS_DIR="${VERIFY_ARTIFACTS_DIR:-$REPO_ROOT/.ralph/verify/$VERIFY_RUN_ID}"
export VERIFY_RUN_ID VERIFY_ARTIFACTS_DIR

RPH_PROFILE="${RPH_PROFILE:-}"
RPH_PROFILE_VERIFY_MODE=""
RPH_PROFILE_AGENT_MODEL=""
RPH_PROFILE_ITER_TIMEOUT_SECS=""
RPH_PROFILE_SELF_HEAL=""
RPH_PROFILE_RATE_LIMIT_PER_HOUR=""
RPH_PROFILE_VERIFY_ONLY=""
RPH_PROFILE_MODE=""
RPH_PROFILE_FORBID_MARK_PASS=""
RPH_PROFILE_REQUIRE_MARK_PASS=""
RPH_PROFILE_REQUIRE_STORY_VERIFY=""
RPH_PROFILE_REQUIRE_FULL_VERIFY=""
RPH_PROFILE_REQUIRE_PROMOTION_VERIFY=""
RPH_PROFILE_WARNING=""

case "$RPH_PROFILE" in
  "")
    ;;
  fast)
    RPH_PROFILE_MODE="fast"
    RPH_PROFILE_VERIFY_MODE="quick"
    RPH_PROFILE_ITER_TIMEOUT_SECS="1200"
    ;;
  thorough)
    RPH_PROFILE_MODE="thorough"
    RPH_PROFILE_VERIFY_MODE="full"
    RPH_PROFILE_ITER_TIMEOUT_SECS="3600"
    ;;
  audit)
    RPH_PROFILE_MODE="audit"
    RPH_PROFILE_VERIFY_MODE="full"
    RPH_PROFILE_SELF_HEAL="0"
    ;;
  verify)
    RPH_PROFILE_MODE="verify"
    RPH_PROFILE_VERIFY_MODE="full"
    RPH_PROFILE_VERIFY_ONLY="1"
    ;;
  explore)
    RPH_PROFILE_MODE="explore"
    RPH_PROFILE_VERIFY_MODE="quick"
    RPH_PROFILE_FORBID_MARK_PASS="1"
    ;;
  promote)
    RPH_PROFILE_MODE="promote"
    RPH_PROFILE_VERIFY_MODE="full"
    RPH_PROFILE_REQUIRE_MARK_PASS="1"
    RPH_PROFILE_REQUIRE_STORY_VERIFY="1"
    RPH_PROFILE_REQUIRE_FULL_VERIFY="1"
    RPH_PROFILE_REQUIRE_PROMOTION_VERIFY="1"
    ;;
  max)
    RPH_PROFILE_MODE="max"
    RPH_PROFILE_VERIFY_MODE="full"
    RPH_PROFILE_ITER_TIMEOUT_SECS="7200"
    RPH_PROFILE_AGENT_MODEL="gpt-5.2-codex"
    RPH_PROFILE_RATE_LIMIT_PER_HOUR="40"
    ;;
  *)
    RPH_PROFILE_WARNING="unknown_profile"
    ;;
esac

if [[ -z "$RPH_PROFILE_MODE" ]]; then
  if [[ -n "$RPH_PROFILE" ]]; then
    RPH_PROFILE_MODE="$RPH_PROFILE"
  else
    RPH_PROFILE_MODE="standard"
  fi
fi

RPH_VERIFY_MODE="${RPH_VERIFY_MODE:-${RPH_PROFILE_VERIFY_MODE:-full}}"     # quick|full|promotion (your choice)
RPH_PROMOTION_VERIFY_MODE="${RPH_PROMOTION_VERIFY_MODE:-promotion}"        # full|promotion
RPH_FINAL_VERIFY_MODE="${RPH_FINAL_VERIFY_MODE:-full}"                     # quick|full|promotion
RPH_SELF_HEAL="${RPH_SELF_HEAL:-${RPH_PROFILE_SELF_HEAL:-0}}"            # 0|1
RPH_DRY_RUN="${RPH_DRY_RUN:-0}"                # 0|1
RPH_SELECTION_MODE="${RPH_SELECTION_MODE:-harness}"  # harness|agent
RPH_REQUIRE_STORY_VERIFY="${RPH_REQUIRE_STORY_VERIFY:-1}"  # legacy; gate is mandatory
RPH_FORBID_MARK_PASS="${RPH_FORBID_MARK_PASS:-${RPH_PROFILE_FORBID_MARK_PASS:-0}}"  # 0|1
RPH_REQUIRE_MARK_PASS="${RPH_REQUIRE_MARK_PASS:-${RPH_PROFILE_REQUIRE_MARK_PASS:-0}}"  # 0|1
RPH_REQUIRE_STORY_VERIFY_GATE="${RPH_REQUIRE_STORY_VERIFY_GATE:-${RPH_PROFILE_REQUIRE_STORY_VERIFY:-0}}"  # 0|1
RPH_REQUIRE_FULL_VERIFY="${RPH_REQUIRE_FULL_VERIFY:-${RPH_PROFILE_REQUIRE_FULL_VERIFY:-0}}"  # 0|1
RPH_REQUIRE_PROMOTION_VERIFY="${RPH_REQUIRE_PROMOTION_VERIFY:-${RPH_PROFILE_REQUIRE_PROMOTION_VERIFY:-0}}"  # 0|1
RPH_AGENT_CMD="${RPH_AGENT_CMD:-codex}"        # codex|claude|opencode|etc
# Default model depends on agent
_RPH_DEFAULT_MODEL="gpt-5.2-codex"
if [[ "$RPH_AGENT_CMD" == "claude" ]]; then
  _RPH_DEFAULT_MODEL="sonnet"
fi
RPH_AGENT_MODEL="${RPH_AGENT_MODEL:-${RPH_PROFILE_AGENT_MODEL:-$_RPH_DEFAULT_MODEL}}"
RPH_VERIFY_ONLY="${RPH_VERIFY_ONLY:-${RPH_PROFILE_VERIFY_ONLY:-0}}"       # 0|1 (use cheaper model for verification-only iterations)
RPH_VERIFY_ONLY_MODEL="${RPH_VERIFY_ONLY_MODEL:-gpt-5-mini}"
if [[ "$RPH_AGENT_CMD" == "claude" && "$RPH_VERIFY_ONLY_MODEL" == "gpt-5-mini" ]]; then
  RPH_VERIFY_ONLY_MODEL="haiku"
fi
if [[ "$RPH_VERIFY_ONLY" == "1" ]]; then
  RPH_AGENT_MODEL="$RPH_VERIFY_ONLY_MODEL"
fi
RPH_ITER_TIMEOUT_SECS="${RPH_ITER_TIMEOUT_SECS:-${RPH_PROFILE_ITER_TIMEOUT_SECS:-0}}"
if [[ -z "${RPH_AGENT_ARGS+x}" ]]; then
  if [[ "$RPH_AGENT_CMD" == "codex" ]]; then
    RPH_AGENT_ARGS="exec --model ${RPH_AGENT_MODEL} --cd ${REPO_ROOT} --sandbox danger-full-access"
  elif [[ "$RPH_AGENT_CMD" == "claude" ]]; then
    RPH_AGENT_ARGS="--model ${RPH_AGENT_MODEL} --permission-mode acceptEdits"
  else
    RPH_AGENT_ARGS="--permission-mode acceptEdits"
  fi
fi
if [[ "$RPH_AGENT_CMD" == "codex" && "$RPH_AGENT_ARGS" != *"--sandbox"* ]]; then
  RPH_AGENT_ARGS="${RPH_AGENT_ARGS} --sandbox danger-full-access"
fi
if [[ -z "${RPH_PROMPT_FLAG+x}" ]]; then
  if [[ "$RPH_AGENT_CMD" == "codex" ]]; then
    RPH_PROMPT_FLAG=""
  else
    RPH_PROMPT_FLAG="-p"
  fi
fi
RPH_COMPLETE_SENTINEL="${RPH_COMPLETE_SENTINEL:-<promise>COMPLETE</promise>}"

# Disallow agent from editing PRD directly (preferred; harness flips passes via <mark_pass>).
RPH_ALLOW_AGENT_PRD_EDIT="${RPH_ALLOW_AGENT_PRD_EDIT:-0}"  # 0|1 (legacy compatibility)
# Disallow verify.sh edits unless explicitly enabled (human-reviewed change).
RPH_ALLOW_VERIFY_SH_EDIT="${RPH_ALLOW_VERIFY_SH_EDIT:-0}"  # 0|1
# Disallow other harness file edits unless explicitly enabled (human-reviewed change).
RPH_ALLOW_HARNESS_EDIT="${RPH_ALLOW_HARNESS_EDIT:-0}"      # 0|1
# Contract alignment review gate (mandatory).
CONTRACT_FILE="${CONTRACT_FILE:-CONTRACT.md}"
IMPL_PLAN_FILE="${IMPL_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"
RPH_REQUIRE_CONTRACT_REVIEW="${RPH_REQUIRE_CONTRACT_REVIEW:-1}"  # 0|1 (mandatory)
RPH_CHEAT_DETECTION="${RPH_CHEAT_DETECTION:-block}"  # off|warn|block
RPH_CHEAT_ALLOWLIST="${RPH_CHEAT_ALLOWLIST:-}"      # regex of file paths to ignore
RPH_ALLOW_CHEAT_ALLOWLIST="${RPH_ALLOW_CHEAT_ALLOWLIST:-0}"  # 0|1
# Story verify allowlist (defense-in-depth against arbitrary commands).
RPH_STORY_VERIFY_ALLOWLIST_FILE="${RPH_STORY_VERIFY_ALLOWLIST_FILE:-plans/story_verify_allowlist.txt}"
RPH_ALLOW_UNSAFE_STORY_VERIFY="${RPH_ALLOW_UNSAFE_STORY_VERIFY:-0}"  # 0|1
# Agent pass-mark tags: print exactly <mark_pass>ID</mark_pass>
RPH_MARK_PASS_OPEN="${RPH_MARK_PASS_OPEN:-<mark_pass>}"
RPH_MARK_PASS_CLOSE="${RPH_MARK_PASS_CLOSE:-</mark_pass>}"
RPH_FINAL_VERIFY="${RPH_FINAL_VERIFY:-1}"  # 0|1
RPH_VERIFY_PASS_TAIL="${RPH_VERIFY_PASS_TAIL:-20}"
RPH_VERIFY_FAIL_TAIL="${RPH_VERIFY_FAIL_TAIL:-200}"
RPH_VERIFY_SUMMARY_MAX="${RPH_VERIFY_SUMMARY_MAX:-200}"
RPH_PASS_META_PATTERNS="${RPH_PASS_META_PATTERNS:-$'plans/prd.json\nplans/progress.txt\nplans/progress_archive.txt\nplans/logs/*\nartifacts/*\n.ralph/*'}"
ARTIFACT_MANIFEST="${ARTIFACT_MANIFEST:-.ralph/artifacts.json}"
SKIPPED_CHECKS_JSON="[]"

# Parse RPH_AGENT_ARGS (space-delimited) into an array (global IFS excludes spaces).
RPH_AGENT_ARGS_ARR=()
if [[ -n "${RPH_AGENT_ARGS:-}" ]]; then
  _old_ifs="$IFS"; IFS=$' \t\n'
  read -r -a RPH_AGENT_ARGS_ARR <<<"$RPH_AGENT_ARGS"
  IFS="$_old_ifs"
fi
RPH_RATE_LIMIT_PER_HOUR="${RPH_RATE_LIMIT_PER_HOUR:-${RPH_PROFILE_RATE_LIMIT_PER_HOUR:-100}}"
RPH_RATE_LIMIT_FILE="${RPH_RATE_LIMIT_FILE:-.ralph/rate_limit.json}"
RPH_RATE_LIMIT_ENABLED="${RPH_RATE_LIMIT_ENABLED:-1}"
RPH_RATE_LIMIT_RESTART_ON_SLEEP="${RPH_RATE_LIMIT_RESTART_ON_SLEEP:-1}"  # 0|1
RPH_RATE_LIMIT_SLEPT=0
RPH_RATE_LIMIT_SLEEP_SECS=0
RPH_CIRCUIT_BREAKER_ENABLED="${RPH_CIRCUIT_BREAKER_ENABLED:-1}"
RPH_MAX_SAME_FAILURE="${RPH_MAX_SAME_FAILURE:-3}"
RPH_MAX_NO_PROGRESS="${RPH_MAX_NO_PROGRESS:-2}"
RPH_STATE_FILE="${RPH_STATE_FILE:-.ralph/state.json}"
RPH_LOCK_DIR="${RPH_LOCK_DIR:-.ralph/lock}"
RPH_LOCK_TTL_SECS="${RPH_LOCK_TTL_SECS:-14400}"

mkdir -p .ralph
mkdir -p plans/logs
# Ensure the artifact manifest always corresponds to the current run.
rm -f "$ARTIFACT_MANIFEST" 2>/dev/null || true

LOG_FILE="plans/logs/ralph.$(date +%Y%m%d-%H%M%S).log"
LAST_GOOD_FILE=".ralph/last_good_ref"
LAST_FAIL_FILE=".ralph/last_failure_path"
STATE_FILE="$RPH_STATE_FILE"
LOCK_DIR="$RPH_LOCK_DIR"
LOCK_INFO_FILE="${LOCK_DIR}/lock.json"
LOCK_ACQUIRED=0

if [[ -n "$RPH_PROFILE_WARNING" ]]; then
  echo "WARN: unknown RPH_PROFILE=$RPH_PROFILE (ignoring profile presets)" | tee -a "$LOG_FILE"
fi

if [[ "$RPH_CHEAT_DETECTION" != "block" ]]; then
  echo "WARN: RPH_CHEAT_DETECTION=$RPH_CHEAT_DETECTION; cheat detection will not block changes." | tee -a "$LOG_FILE"
fi

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

add_skipped_check() {
  local name="${1:-}"
  local reason="${2:-}"
  if [[ -z "$name" ]]; then
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    SKIPPED_CHECKS_JSON="$(jq -c --arg name "$name" --arg reason "$reason" '. + [{name:$name, reason:$reason}]' <<<"$SKIPPED_CHECKS_JSON" 2>/dev/null || echo "$SKIPPED_CHECKS_JSON")"
    return 0
  fi
  local entry
  entry="{\"name\":\"$(json_escape "$name")\",\"reason\":\"$(json_escape "$reason")\"}"
  if [[ "$SKIPPED_CHECKS_JSON" == "[]" || -z "$SKIPPED_CHECKS_JSON" ]]; then
    SKIPPED_CHECKS_JSON="[$entry]"
  else
    SKIPPED_CHECKS_JSON="${SKIPPED_CHECKS_JSON%]},"$entry"]"
  fi
}

write_artifact_manifest() {
  local iter_dir="${1:-}"
  local final_log="${2:-}"
  local final_status="${3:-}"
  local blocked_dir="${4:-}"
  local blocked_reason="${5:-}"
  local blocked_details="${6:-}"
  local manifest="$ARTIFACT_MANIFEST"
  local tmp="${manifest}.tmp"
  local head_before=""
  local head_after=""
  local commit_count="null"
  local contract_review_path=""
  local verify_pre_log=""
  local verify_post_log=""

  if [[ -n "$iter_dir" && -d "$iter_dir" ]]; then
    if [[ -f "$iter_dir/head_before.txt" ]]; then
      head_before="$(cat "$iter_dir/head_before.txt" 2>/dev/null || true)"
    fi
    if [[ -f "$iter_dir/head_after.txt" ]]; then
      head_after="$(cat "$iter_dir/head_after.txt" 2>/dev/null || true)"
    fi
    if [[ -f "$iter_dir/contract_review.json" ]]; then
      contract_review_path="$iter_dir/contract_review.json"
    fi
    if [[ -f "$iter_dir/verify_pre.log" ]]; then
      verify_pre_log="$iter_dir/verify_pre.log"
    fi
    if [[ -f "$iter_dir/verify_post.log" ]]; then
      verify_post_log="$iter_dir/verify_post.log"
    fi
  fi

  if [[ -n "$head_before" && -n "$head_after" ]]; then
    local count_raw=""
    count_raw="$(git rev-list --count "${head_before}..${head_after}" 2>/dev/null || true)"
    if [[ "$count_raw" =~ ^[0-9]+$ ]]; then
      commit_count="$count_raw"
    fi
  fi

  mkdir -p "$(dirname "$manifest")" || true

  if ! command -v jq >/dev/null 2>&1; then
    cat > "$tmp" <<EOF
{
  "schema_version": 1,
  "run_id": "$(json_escape "${RPH_RUN_ID:-}")",
  "iter_dir": null,
  "head_before": null,
  "head_after": null,
  "commit_count": null,
  "verify_pre_log_path": null,
  "verify_post_log_path": null,
  "final_verify_log_path": null,
  "final_verify_status": null,
  "contract_review_path": null,
  "contract_check_report_path": null,
  "blocked_dir": null,
  "blocked_reason": null,
  "blocked_details": null,
  "skipped_checks": ${SKIPPED_CHECKS_JSON},
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    mv "$tmp" "$manifest"
    return 0
  fi

  jq -n \
    --argjson schema_version 1 \
    --arg run_id "${RPH_RUN_ID:-}" \
    --arg iter_dir "$iter_dir" \
    --arg head_before "$head_before" \
    --arg head_after "$head_after" \
    --arg final_verify_log_path "$final_log" \
    --arg final_verify_status "$final_status" \
    --arg contract_review_path "$contract_review_path" \
    --arg contract_check_report_path "$contract_review_path" \
    --arg verify_pre_log_path "$verify_pre_log" \
    --arg verify_post_log_path "$verify_post_log" \
    --arg blocked_dir "$blocked_dir" \
    --arg blocked_reason "$blocked_reason" \
    --arg blocked_details "$blocked_details" \
    --argjson commit_count "$commit_count" \
    --argjson skipped_checks "$SKIPPED_CHECKS_JSON" \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
      schema_version: $schema_version,
      run_id: ($run_id | if length>0 then . else null end),
      iter_dir: ($iter_dir | if length>0 then . else null end),
      head_before: ($head_before | if length>0 then . else null end),
      head_after: ($head_after | if length>0 then . else null end),
      commit_count: $commit_count,
      verify_pre_log_path: ($verify_pre_log_path | if length>0 then . else null end),
      verify_post_log_path: ($verify_post_log_path | if length>0 then . else null end),
      final_verify_log_path: ($final_verify_log_path | if length>0 then . else null end),
      final_verify_status: ($final_verify_status | if length>0 then . else null end),
      contract_review_path: ($contract_review_path | if length>0 then . else null end),
      contract_check_report_path: ($contract_check_report_path | if length>0 then . else null end),
      blocked_dir: ($blocked_dir | if length>0 then . else null end),
      blocked_reason: ($blocked_reason | if length>0 then . else null end),
      blocked_details: ($blocked_details | if length>0 then . else null end),
      skipped_checks: $skipped_checks,
      generated_at: $generated_at
    }' > "$tmp"
  mv "$tmp" "$manifest"
}

is_timeout_rc() {
  local rc="$1"
  [[ "$rc" == "124" || "$rc" == "137" ]]
}

ensure_agent_args_array() {
  if [[ "${RPH_AGENT_ARGS_ARR[@]+x}" != "x" ]]; then
    RPH_AGENT_ARGS_ARR=()
  fi
}

timeout_cmd() {
  local timeout_s="$1"
  shift

  if [[ -z "$timeout_s" || "$timeout_s" == "0" ]]; then
    "$@"
    return $?
  fi
  if ! [[ "$timeout_s" =~ ^[0-9]+$ ]] || [[ "$timeout_s" -le 0 ]]; then
    "$@"
    return $?
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_s" "$@"
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$timeout_s" "$@" <<'PY'
import subprocess
import sys

timeout_s = int(sys.argv[1])
cmd = sys.argv[2:]
if not cmd:
    sys.exit(1)
proc = subprocess.Popen(cmd)
try:
    proc.wait(timeout=timeout_s)
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    try:
        proc.terminate()
    except Exception:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except Exception:
            pass
    sys.exit(124)
PY
    return $?
  fi
  if command -v python >/dev/null 2>&1; then
    python - "$timeout_s" "$@" <<'PY'
import subprocess
import sys

timeout_s = int(sys.argv[1])
cmd = sys.argv[2:]
if not cmd:
    sys.exit(1)
proc = subprocess.Popen(cmd)
try:
    proc.wait(timeout=timeout_s)
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    try:
        proc.terminate()
    except Exception:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except Exception:
            pass
    sys.exit(124)
PY
    return $?
  fi

  echo "WARN: RPH_ITER_TIMEOUT_SECS=$timeout_s but no timeout/python available; running without timeout" >&2
  "$@"
  return $?
}

lock_info_field() {
  local field="$1"
  local file="$LOCK_INFO_FILE"
  [[ -f "$file" ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$field" <<'PY'
import json
import sys

path = sys.argv[1]
key = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    val = data.get(key, "")
    if isinstance(val, (dict, list)):
        sys.exit(0)
    print(val)
except Exception:
    pass
PY
    return 0
  fi
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\{0,1\\}\\([^\",}]*\\)\"\\{0,1\\}.*/\\1/p" "$file" | head -n 1
}

lock_dir_mtime() {
  if stat -f '%m' "$LOCK_DIR" >/dev/null 2>&1; then
    stat -f '%m' "$LOCK_DIR"
    return 0
  fi
  stat -c '%Y' "$LOCK_DIR" 2>/dev/null || true
}

lock_age_seconds() {
  local now
  local epoch
  local started_at
  local mtime
  now="$(date +%s)"
  epoch="$(lock_info_field "started_at_epoch")"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    echo $((now - epoch))
    return 0
  fi
  started_at="$(lock_info_field "started_at")"
  if [[ -n "$started_at" && -n "$(command -v python3 || true)" ]]; then
    python3 - "$started_at" "$now" <<'PY'
import datetime
import sys

raw = sys.argv[1]
now = int(sys.argv[2])
try:
    dt = datetime.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ")
    epoch = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
    print(max(0, now - epoch))
except Exception:
    pass
PY
    return 0
  fi
  mtime="$(lock_dir_mtime)"
  if [[ "$mtime" =~ ^[0-9]+$ ]]; then
    echo $((now - mtime))
    return 0
  fi
  echo ""
}

write_lock_info() {
  local now
  local now_epoch
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_epoch="$(date +%s)"
  printf '{"pid":%s,"started_at":"%s","started_at_epoch":%s,"cwd":"%s","cmd":"%s"}\n' \
    "$$" \
    "$(json_escape "$now")" \
    "$now_epoch" \
    "$(json_escape "$PWD")" \
    "$(json_escape "$0")" \
    > "$LOCK_INFO_FILE" || true
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    write_lock_info
    return 0
  fi
  local pid
  local age
  local ttl
  pid="$(lock_info_field "pid")"
  age="$(lock_age_seconds)"
  ttl="$RPH_LOCK_TTL_SECS"
  if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
    ttl=14400
  fi
  if [[ -n "$pid" ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
  fi
  if [[ -n "$age" && "$age" -gt "$ttl" ]]; then
    echo "WARN: clearing stale lock (age=${age}s ttl=${ttl}s pid=${pid:-unknown})" | tee -a "$LOG_FILE"
    rm -rf "$LOCK_DIR" || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_ACQUIRED=1
      write_lock_info
      return 0
    fi
  fi
  return 1
}

release_lock() {
  if [[ "$LOCK_ACQUIRED" == "1" ]]; then
    rm -rf "$LOCK_DIR" || true
  fi
}

write_blocked_basic() {
  local reason="$1"
  local details="$2"
  local prefix="${3:-blocked}"
  local block_dir
  block_dir=".ralph/${prefix}_$(date +%Y%m%d-%H%M%S)_$$_$RANDOM"
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

run_verify() {
  local out="$1"
  shift
  local mode="$RPH_VERIFY_MODE"
  if [[ "${1:-}" == "quick" || "${1:-}" == "full" || "${1:-}" == "promotion" ]]; then
    mode="$1"
    shift
  fi
  local pass_tail="$RPH_VERIFY_PASS_TAIL"
  local fail_tail="$RPH_VERIFY_FAIL_TAIL"
  local summary_max="$RPH_VERIFY_SUMMARY_MAX"
  if ! [[ "$pass_tail" =~ ^[0-9]+$ ]]; then pass_tail=20; fi
  if ! [[ "$fail_tail" =~ ^[0-9]+$ ]]; then fail_tail=200; fi
  if ! [[ "$summary_max" =~ ^[0-9]+$ ]]; then summary_max=200; fi
  local out_dir
  local summary_file
  out_dir="$(dirname "$out")"
  summary_file="${out_dir}/verify_summary.txt"
  local cmd=( "$VERIFY_SH" "$mode" "$@" )
  echo "verify command: ${cmd[*]}"
  set +e
  timeout_cmd "$RPH_ITER_TIMEOUT_SECS" "$VERIFY_SH" "$mode" "$@" >"$out" 2>&1
  local rc=$?
  set -e
  : > "$summary_file"
  if [[ -s "$out" ]]; then
    if command -v rg >/dev/null 2>&1; then
      rg -n -i -e 'error:|failed|panicked' "$out" | head -n "$summary_max" > "$summary_file" || true
    else
      grep -nE -i 'error:|failed|panicked' "$out" | head -n "$summary_max" > "$summary_file" || true
    fi
  fi
  if (( rc == 0 )); then
    tail -n "$pass_tail" "$out" || true
  else
    if [[ -s "$summary_file" ]]; then
      echo "verify summary (first ${summary_max} lines):" >&2
      cat "$summary_file" >&2
    else
      echo "verify summary: (no matches)" >&2
    fi
    echo "verify failed (showing last ${fail_tail} lines):" >&2
    tail -n "$fail_tail" "$out" >&2 || true
  fi
  return $rc
}

attempt_blocked_verify_pre() {
  local block_dir="$1"
  if [[ "$RPH_DRY_RUN" == "1" ]]; then
    return 0
  fi
  if [[ -x "$VERIFY_SH" ]]; then
    run_verify "$block_dir/verify_pre.log" || true
  fi
  return 0
}

block_preflight() {
  local reason="$1"
  local details="$2"
  local code="${3:-1}"
  local block_dir
  block_dir="$(write_blocked_basic "$reason" "$details")"
  attempt_blocked_verify_pre "$block_dir" || true
  add_skipped_check "verify_pre" "preflight_blocked"
  add_skipped_check "verify_post" "preflight_blocked"
  add_skipped_check "story_verify" "preflight_blocked"
  add_skipped_check "final_verify" "preflight_blocked"
  write_artifact_manifest "" "" "BLOCKED" "$block_dir" "$reason" "$details"
  echo "Blocked preflight: $reason ($details) in $block_dir" | tee -a "$LOG_FILE"
  exit "$code"
}

# Profile gating that must fail-closed before running.
if [[ "$RPH_REQUIRE_PROMOTION_VERIFY" == "1" && "$RPH_PROMOTION_VERIFY_MODE" != "promotion" ]]; then
  block_preflight "profile_requires_promotion_verify" "RPH_PROFILE_MODE=$RPH_PROFILE_MODE requires RPH_PROMOTION_VERIFY_MODE=promotion (got $RPH_PROMOTION_VERIFY_MODE)"
fi
if [[ "$RPH_REQUIRE_FULL_VERIFY" == "1" && "$RPH_VERIFY_MODE" != "full" && "$RPH_VERIFY_MODE" != "promotion" ]]; then
  block_preflight "profile_requires_full_verify" "RPH_PROFILE_MODE=$RPH_PROFILE_MODE requires RPH_VERIFY_MODE=full (got $RPH_VERIFY_MODE)"
fi

# --- lock (fail-closed) ---
if ! acquire_lock; then
  block_preflight "lock_held" "Ralph lock exists at $LOCK_DIR. If no run is active, remove $LOCK_DIR and retry."
fi
trap release_lock EXIT INT TERM

# --- preflight ---
command -v git >/dev/null 2>&1 || block_preflight "missing_git" "git required"
command -v jq  >/dev/null 2>&1 || block_preflight "missing_jq" "jq required"
git_email="$(git config --get user.email 2>/dev/null || true)"
git_name="$(git config --get user.name 2>/dev/null || true)"
if [[ -z "$git_email" ]]; then
  git config user.email "ralph@local"
fi
if [[ -z "$git_name" ]]; then
  git config user.name "ralph"
fi
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  block_preflight "missing_timeout_or_python3" "timeout/gtimeout or python3 required for iteration timeouts"
fi
if [[ -n "$RPH_CHEAT_ALLOWLIST" && "$RPH_ALLOW_CHEAT_ALLOWLIST" != "1" ]]; then
  block_preflight "cheat_allowlist_requires_opt_in" "RPH_CHEAT_ALLOWLIST set but RPH_ALLOW_CHEAT_ALLOWLIST!=1"
fi
if [[ "$RPH_DRY_RUN" != "1" ]]; then
  if [[ -z "${RPH_AGENT_CMD:-}" ]]; then
    block_preflight "missing_agent_cmd" "RPH_AGENT_CMD is empty"
  fi
  command -v "$RPH_AGENT_CMD" >/dev/null 2>&1 || block_preflight "missing_agent_cmd" "agent command not found: $RPH_AGENT_CMD"
fi

[[ -f "$PRD_FILE" ]] || block_preflight "missing_prd" "missing $PRD_FILE"
jq . "$PRD_FILE" >/dev/null 2>&1 || block_preflight "invalid_prd_json" "$PRD_FILE invalid JSON"

# PRD preflight (schema+lint+ref+allowlist) if available; fallback to schema check
if [[ -f "$PRD_PREFLIGHT_SH" && ! -x "$PRD_PREFLIGHT_SH" ]]; then
  block_preflight "missing_prd_preflight" "$PRD_PREFLIGHT_SH missing or not executable"
fi
if [[ -x "$PRD_PREFLIGHT_SH" ]]; then
  preflight_out=""
  preflight_rc=0
  set +e
  preflight_out="$("$PRD_PREFLIGHT_SH" --strict "$PRD_FILE" 2>&1)"
  preflight_rc=$?
  set -e
  if (( preflight_rc != 0 )); then
    echo "$preflight_out" | tee -a "$LOG_FILE"
    block_preflight "prd_preflight_failed" "PRD preflight failed (run $PRD_PREFLIGHT_SH --strict $PRD_FILE for details)"
  fi
else
  # PRD schema sanity check (single source of truth; fail-closed)
  if [[ ! -x "$PRD_SCHEMA_CHECK_SH" ]]; then
    block_preflight "missing_prd_schema_check" "$PRD_SCHEMA_CHECK_SH missing or not executable"
  fi
  schema_out=""
  schema_rc=0
  set +e
  schema_out="$("$PRD_SCHEMA_CHECK_SH" "$PRD_FILE" 2>&1)"
  schema_rc=$?
  set -e
  if (( schema_rc != 0 )); then
    echo "$schema_out" | tee -a "$LOG_FILE"
    block_preflight "invalid_prd_schema" "$PRD_FILE schema invalid (run $PRD_SCHEMA_CHECK_SH $PRD_FILE for details)"
  fi
fi
if [[ "${PRD_SCHEMA_DRAFT_MODE:-0}" == "1" ]]; then
  block_preflight "prd_schema_draft_mode" "PRD_SCHEMA_DRAFT_MODE=1 set; drafting mode is blocked from execution."
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

# Initialize metrics if missing
if ! jq -e '.metrics' "$STATE_FILE" >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq '. + {metrics: {total_iterations: 0, pass_count: 0, fail_count: 0, verify_pre_fail_count: 0, verify_post_fail_count: 0, failure_modes: []}}' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
fi

# Fail if dirty at start (keeps history clean). Override only if you KNOW what you're doing.
if [[ -n "$(git status --porcelain)" ]]; then
  block_preflight "dirty_worktree" "working tree dirty. Commit/stash first." 2
fi

echo "Ralph starting max_iters=$MAX_ITERS mode=$RPH_VERIFY_MODE self_heal=$RPH_SELF_HEAL iter_timeout_s=$RPH_ITER_TIMEOUT_SECS profile=${RPH_PROFILE:-none} profile_mode=$RPH_PROFILE_MODE" | tee -a "$LOG_FILE"

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

story_verify_cmd_allowed() {
  local cmd="$1"
  if [[ "$RPH_ALLOW_UNSAFE_STORY_VERIFY" == "1" ]]; then
    return 0
  fi
  local allow_file="$RPH_STORY_VERIFY_ALLOWLIST_FILE"
  if [[ ! -f "$allow_file" ]]; then
    echo "ERROR: story verify allowlist missing: $allow_file" | tee -a "$LOG_FILE"
    return 1
  fi
  awk -v cmd="$cmd" '
    { sub(/\r$/, ""); }
    /^[[:space:]]*($|#)/ { next }
    { line=$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); }
    line == cmd { found=1; exit }
    END { exit found?0:1 }
  ' "$allow_file"
}

run_story_verify() {
  local item_json="$1"
  local iter_dir="$2"
  local log="${iter_dir}/story_verify.log"
  local cmds=""
  local rc=0
  local saw_extra=0

  : > "$log"
  cmds="$(jq -r '(.verify // [])[]' <<<"$item_json" 2>/dev/null || true)"
  if [[ -z "$cmds" ]]; then
    echo "No story-specific verify commands." | tee -a "$log"
    add_skipped_check "story_verify" "no_story_verify_commands"
    return 0
  fi

  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    # Ignore verify.sh itself and its syntax check; they are not story-specific.
    if [[ "$cmd" == "./plans/verify.sh" || "$cmd" == "bash -n plans/verify.sh" || "$cmd" == "bash -n ./plans/verify.sh" ]]; then
      continue
    fi
    saw_extra=1
    if ! story_verify_cmd_allowed "$cmd"; then
      rc=1
      echo "FAIL: story verify command not allowlisted: $cmd" | tee -a "$log" | tee -a "$LOG_FILE"
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

  if (( saw_extra == 0 )); then
    echo "No story-specific verify commands." | tee -a "$log"
    add_skipped_check "story_verify" "no_story_verify_commands"
  fi

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
  git clean -fdx -e .ralph
}

select_next_item() {
  local slice="$1"
  jq -c --argjson s "$slice" '
    def items:
      (.items // []);
    items | map(select(.passes==false and .slice==$s)) | sort_by(.priority) | reverse | .[0] // empty
  ' "$PRD_FILE"
}

item_by_id() {
  local id="$1"
  jq -c --arg id "$id" '
    def items:
      (.items // []);
    items[] | select(.id==$id)
  ' "$PRD_FILE"
}

dependency_analysis_for_slice() {
  local slice="$1"
  jq -c --argjson s "$slice" '
    (.items // []) as $items
    | ($items | map({key:.id, value:.}) | from_entries) as $by_id
    | [$items[] | select(.passes==false and .slice==$s)
      | . as $it
      | ($it.dependencies // []) as $deps
      | {
          id: $it.id,
          priority: ($it.priority // 0),
          description: ($it.description // ""),
          needs_human_decision: ($it.needs_human_decision // false),
          unsatisfied_dependencies: (
            $deps | map(
              . as $dep_id
              | if ($by_id | has($dep_id) | not) then {id:$dep_id,status:"missing_dependency_id"}
                else
                  ($by_id[$dep_id]) as $dep
                  | if ($dep.passes == true) then empty
                    elif ($dep.needs_human_decision == true) then {id:$dep_id,status:"blocked_by_human_decision"}
                    else {id:$dep_id,status:"unsatisfied_not_passed"}
                    end
                end
            )
          )
        }
      | . + {eligible: ((.unsatisfied_dependencies | length) == 0)}
    ]
  ' "$PRD_FILE"
}

eligible_count_from_analysis() {
  local analysis="$1"
  jq -r '[.[] | select(.eligible==true)] | length' <<<"$analysis"
}

missing_dependency_count_from_analysis() {
  local analysis="$1"
  jq -r '[.[] | .unsatisfied_dependencies[]? | select(.status=="missing_dependency_id")] | length' <<<"$analysis"
}

select_eligible_id_from_analysis() {
  local analysis="$1"
  jq -r '[.[] | select(.eligible==true)] | sort_by(.priority) | reverse | .[0].id // empty' <<<"$analysis"
}

eligible_lines_from_analysis() {
  local analysis="$1"
  jq -r '.[] | select(.eligible==true) | "\(.id) - \(.description)"' <<<"$analysis"
}

dependency_info_from_analysis() {
  local analysis="$1"
  local id="$2"
  jq -c --arg id "$id" '(.[] | select(.id==$id)) // empty' <<<"$analysis"
}

write_dependency_block() {
  local reason="$1"
  local slice="$2"
  local analysis_json="$3"
  local details="$4"
  local prefix="${5:-blocked_dependency_deadlock}"
  local block_dir
  block_dir="$(write_blocked_artifacts "$reason" "dependency" 0 "$details" false "$prefix")"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg reason "$reason" \
      --argjson active_slice "$slice" \
      --argjson candidates "$analysis_json" \
      '{
        reason: $reason,
        active_slice: $active_slice,
        eligible_count: ($candidates | map(select(.eligible==true)) | length),
        candidates: ($candidates | map({
          id,
          priority,
          needs_human_decision,
          eligible,
          unsatisfied_dependencies
        }))
      }' > "$block_dir/dependency_deadlock.json"
  fi
  echo "$block_dir"
}

all_items_passed() {
  jq -e '
    def items:
      (.items // []);
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
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p ".ralph"
  block_dir="$(mktemp -d ".ralph/${prefix}_${stamp}_XXXXXX")"
  cp "$PRD_FILE" "$block_dir/prd_snapshot.json" || true
  if [[ -n "${VERIFY_PRE_LOG_PATH:-}" && -f "$VERIFY_PRE_LOG_PATH" ]]; then
    cp "$VERIFY_PRE_LOG_PATH" "$block_dir/verify_pre.log" || true
    local pre_summary
    pre_summary="$(dirname "$VERIFY_PRE_LOG_PATH")/verify_summary.txt"
    if [[ -f "$pre_summary" ]]; then
      cp "$pre_summary" "$block_dir/verify_summary.txt" || true
    fi
  fi
  jq -n \
    --arg reason "$reason" \
    --arg id "$id" \
    --argjson priority "$priority" \
    --arg description "$desc" \
    --argjson needs_human_decision "$needs_human" \
    '{reason: $reason, id: $id, priority: $priority, description: $description, needs_human_decision: $needs_human_decision}' \
    > "$block_dir/blocked_item.json"
  write_artifact_manifest "${ITER_DIR:-}" "" "BLOCKED" "$block_dir" "$reason" "$desc"
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

hash_ralph_json_files() {
  if [[ ! -d ".ralph" ]]; then
    echo ""
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  find .ralph -type f -name '*.json' 2>/dev/null | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$(sha256_file "$file")" "$file"
  done > "$tmp"
  sha256_file "$tmp"
  rm -f "$tmp"
}

# Fix 7: Diff size limit - prevent massive changes
RPH_MAX_DIFF_LINES="${RPH_MAX_DIFF_LINES:-2000}"

check_diff_size() {
  local head_before="$1"
  local head_after="$2"
  local iter_dir="$3"

  if [[ "$head_before" == "$head_after" ]]; then
    echo "0"
    return 0
  fi

  local stat_line
  stat_line="$(git diff --stat "$head_before" "$head_after" 2>/dev/null | tail -1)"

  # Extract insertions and deletions
  local insertions=0 deletions=0
  if [[ "$stat_line" =~ ([0-9]+)\ insertion ]]; then
    insertions="${BASH_REMATCH[1]}"
  fi
  if [[ "$stat_line" =~ ([0-9]+)\ deletion ]]; then
    deletions="${BASH_REMATCH[1]}"
  fi

  local total=$((insertions + deletions))
  echo "$total"

  # Save diff stats for metrics
  if [[ -n "$iter_dir" ]]; then
    printf 'insertions=%d\ndeletions=%d\ntotal=%d\n' "$insertions" "$deletions" "$total" > "$iter_dir/diff_stats.txt" 2>/dev/null || true
  fi
}

# Fix 8: Artifact retention - prevent disk exhaustion
RPH_MAX_ITER_DIRS="${RPH_MAX_ITER_DIRS:-20}"
RPH_ARCHIVE_OLD_ITERS="${RPH_ARCHIVE_OLD_ITERS:-1}"

prune_old_iterations() {
  local state_dir="${1:-.ralph}"
  local max_keep="${2:-$RPH_MAX_ITER_DIRS}"
  local archive_dir="$state_dir/archive"

  # Count existing iter directories
  local iter_count
  iter_count="$(find "$state_dir" -maxdepth 1 -type d -name 'iter_*' 2>/dev/null | wc -l | tr -d ' ')"

  if (( iter_count <= max_keep )); then
    return 0
  fi

  local to_prune=$((iter_count - max_keep))

  if [[ "$RPH_ARCHIVE_OLD_ITERS" == "1" ]]; then
    mkdir -p "$archive_dir"
    find "$state_dir" -maxdepth 1 -type d -name 'iter_*' 2>/dev/null | sort -V | head -n "$to_prune" | while read -r dir; do
      local base
      base="$(basename "$dir")"
      # Compress and move to archive
      tar -czf "$archive_dir/${base}.tar.gz" -C "$state_dir" "$base" 2>/dev/null && rm -rf "$dir" || true
    done
  else
    # Just delete old iterations
    find "$state_dir" -maxdepth 1 -type d -name 'iter_*' 2>/dev/null | sort -V | head -n "$to_prune" | xargs rm -rf 2>/dev/null || true
  fi
}

# Fix 9: Metrics file - structured JSONL for monitoring
METRICS_FILE="${RPH_METRICS_FILE:-.ralph/metrics.jsonl}"

append_metrics() {
  local iter="$1"
  local story_id="$2"
  local status="$3"
  local verify_rc="$4"
  local duration_s="$5"
  local diff_lines="$6"
  local cheats="$7"
  local block_reason="${8:-}"

  local ts
  ts="$(date +%s)"

  mkdir -p "$(dirname "$METRICS_FILE")"

  jq -nc \
    --argjson ts "$ts" \
    --argjson iter "$iter" \
    --arg story_id "$story_id" \
    --arg status "$status" \
    --argjson verify_rc "$verify_rc" \
    --argjson duration_s "$duration_s" \
    --argjson diff_lines "$diff_lines" \
    --arg cheats "$cheats" \
    --arg block_reason "$block_reason" \
    '{
      ts: $ts,
      iter: $iter,
      story_id: $story_id,
      status: $status,
      verify_rc: $verify_rc,
      duration_s: $duration_s,
      diff_lines: $diff_lines,
      cheats: $cheats,
      block_reason: $block_reason
    }' >> "$METRICS_FILE" 2>/dev/null || true
}

# Fix 10: Test co-change gate - require test changes with source changes
RPH_TEST_COCHANGE_ENABLED="${RPH_TEST_COCHANGE_ENABLED:-1}"
RPH_TEST_COCHANGE_STRICT="${RPH_TEST_COCHANGE_STRICT:-0}"
RPH_TEST_COCHANGE_SRC_PATTERNS="${RPH_TEST_COCHANGE_SRC_PATTERNS:-^src/|^lib/|^app/|^pkg/|^internal/|^cmd/|\.rs$|\.py$|\.ts$|\.js$}"
RPH_TEST_COCHANGE_TEST_PATTERNS="${RPH_TEST_COCHANGE_TEST_PATTERNS:-^tests?/|_test\.|\.test\.|\.spec\.|^__tests__/}"
RPH_TEST_COCHANGE_EXEMPT_PATTERNS="${RPH_TEST_COCHANGE_EXEMPT_PATTERNS:-\.md$|\.txt$|\.json$|\.yaml$|\.yml$|\.toml$|^docs/|^specs/|^plans/}"

check_test_cochange() {
  local head_before="$1"
  local head_after="$2"

  if [[ "$RPH_TEST_COCHANGE_ENABLED" != "1" ]]; then
    return 0
  fi

  if [[ "$head_before" == "$head_after" ]]; then
    return 0
  fi

  local changed_files
  changed_files="$(git diff --name-only "$head_before" "$head_after" 2>/dev/null)"

  if [[ -z "$changed_files" ]]; then
    return 0
  fi

  # Filter out exempt files
  local src_files test_files
  src_files="$(echo "$changed_files" | grep -E "$RPH_TEST_COCHANGE_SRC_PATTERNS" | grep -vE "$RPH_TEST_COCHANGE_EXEMPT_PATTERNS" | grep -vE "$RPH_TEST_COCHANGE_TEST_PATTERNS" || true)"
  test_files="$(echo "$changed_files" | grep -E "$RPH_TEST_COCHANGE_TEST_PATTERNS" || true)"

  local src_count test_count
  src_count="$(echo "$src_files" | grep -c . || true)"
  test_count="$(echo "$test_files" | grep -c . || true)"
  if [[ -z "$src_count" ]]; then src_count=0; fi
  if [[ -z "$test_count" ]]; then test_count=0; fi

  if (( src_count > 0 && test_count == 0 )); then
    echo "src_changed=$src_count test_changed=$test_count"
    echo "Source files changed:"
    echo "$src_files" | head -10
    return 1
  fi

  return 0
}

# Fix 6: Protect critical files during agent execution
lock_state_files() {
  # Make state.json and PRD read-only during agent execution
  # This prevents the agent from directly manipulating harness state
  if [[ -f "$STATE_FILE" ]]; then
    chmod a-w "$STATE_FILE" 2>/dev/null || true
  fi
  if [[ "${RPH_LOCK_PRD_DURING_AGENT:-1}" == "1" && -f "$PRD_FILE" ]]; then
    chmod a-w "$PRD_FILE" 2>/dev/null || true
  fi
}

unlock_state_files() {
  # Restore write access after agent execution
  if [[ -f "$STATE_FILE" ]]; then
    chmod u+w "$STATE_FILE" 2>/dev/null || true
  fi
  if [[ -f "$PRD_FILE" ]]; then
    chmod u+w "$PRD_FILE" 2>/dev/null || true
  fi
}

hash_workflow_scripts() {
  # Hash all workflow scripts to detect transitive tampering
  local tmp
  tmp="$(mktemp)"
  local scripts=(
    "plans/ralph.sh"
    "plans/update_task.sh"
    "plans/init.sh"
    "plans/verify.sh"
    "plans/contract_check.sh"
    "plans/contract_review_validate.sh"
    "plans/workflow_acceptance.sh"
    "plans/ssot_lint.sh"
    "plans/prd_gate.sh"
    "plans/prd_schema_check.sh"
  )
  for script in "${scripts[@]}"; do
    if [[ -f "$script" ]]; then
      printf '%s %s\n' "$(sha256_file "$script")" "$script"
    fi
  done | LC_ALL=C sort > "$tmp"
  sha256_file "$tmp"
  rm -f "$tmp"
}

capture_agent_guard_hashes() {
  HARNESS_SHA_BEFORE=""
  RALPH_JSON_SHA_BEFORE=""
  WORKFLOW_SCRIPTS_SHA_BEFORE=""
  if [[ "$RPH_ALLOW_HARNESS_EDIT" != "1" ]]; then
    HARNESS_SHA_BEFORE="$(sha256_file "plans/ralph.sh")"
    WORKFLOW_SCRIPTS_SHA_BEFORE="$(hash_workflow_scripts)"
  fi
  RALPH_JSON_SHA_BEFORE="$(hash_ralph_json_files)"
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

extract_verify_log_sha() {
  local log="$1"
  local line=""
  if [[ -f "$log" ]]; then
    line="$(grep -m1 '^VERIFY_SH_SHA=' "$log" || true)"
  fi
  if [[ -z "$line" ]]; then
    echo ""
    return 0
  fi
  echo "${line#VERIFY_SH_SHA=}"
}

extract_verify_mode_line() {
  local log="$1"
  if [[ ! -f "$log" ]]; then
    return 0
  fi
  grep -m1 '^mode=' "$log" || true
}

extract_verify_log_mode() {
  local log="$1"
  local line=""
  line="$(extract_verify_mode_line "$log")"
  if [[ -z "$line" ]]; then
    echo ""
    return 0
  fi
  local mode="${line#mode=}"
  mode="${mode%% *}"
  echo "$mode"
}

extract_verify_log_verify_mode() {
  local log="$1"
  local line=""
  line="$(extract_verify_mode_line "$log")"
  if [[ -z "$line" ]]; then
    echo ""
    return 0
  fi
  if [[ "$line" != *"verify_mode="* ]]; then
    echo ""
    return 0
  fi
  local verify_mode="${line#*verify_mode=}"
  verify_mode="${verify_mode%% *}"
  echo "$verify_mode"
}

run_final_verify() {
  local iter_dir="${1:-${ITER_DIR:-}}"
  if [[ "$RPH_FINAL_VERIFY" != "1" || "$RPH_DRY_RUN" == "1" ]]; then
    if [[ "$RPH_DRY_RUN" == "1" ]]; then
      add_skipped_check "final_verify" "dry_run"
      write_artifact_manifest "$iter_dir" "" "SKIPPED" "" "" ""
    else
      add_skipped_check "final_verify" "disabled"
      write_artifact_manifest "$iter_dir" "" "SKIPPED" "" "" ""
    fi
    return 0
  fi
  local mode="$RPH_FINAL_VERIFY_MODE"
  if [[ "$mode" != "quick" && "$mode" != "full" && "$mode" != "promotion" ]]; then
    mode="full"
  fi
  local log=".ralph/final_verify_$(date +%Y%m%d-%H%M%S).log"
  if ! run_verify "$log" "$mode"; then
    local block_dir
    block_dir="$(write_blocked_basic "final_verify_failed" "Final verify failed (see $log)" "blocked_final_verify")"
    write_artifact_manifest "$iter_dir" "$log" "FAIL" "$block_dir" "final_verify_failed" "Final verify failed (see $log)"
    echo "<promise>BLOCKED_FINAL_VERIFY_FAILED</promise>" | tee -a "$LOG_FILE"
    echo "Blocked: final verify failed in $block_dir" | tee -a "$LOG_FILE"
    return 1
  fi
  if ! verify_log_has_sha "$log"; then
    local block_dir
    block_dir="$(write_blocked_basic "final_verify_missing_sha" "VERIFY_SH_SHA missing in $log" "blocked_final_verify")"
    write_artifact_manifest "$iter_dir" "$log" "BLOCKED" "$block_dir" "final_verify_missing_sha" "VERIFY_SH_SHA missing in $log"
    echo "<promise>BLOCKED_FINAL_VERIFY_MISSING_SHA</promise>" | tee -a "$LOG_FILE"
    echo "Blocked: final verify missing SHA in $block_dir" | tee -a "$LOG_FILE"
    return 1
  fi
  if [[ -n "$iter_dir" ]]; then
    if [[ ! -d "$iter_dir" ]]; then
      local block_dir
      block_dir="$(write_blocked_basic "final_verify_missing_iter_dir" "Final verify iter dir missing: $iter_dir" "blocked_final_verify")"
      write_artifact_manifest "$iter_dir" "$log" "BLOCKED" "$block_dir" "final_verify_missing_iter_dir" "Final verify iter dir missing: $iter_dir"
      echo "<promise>BLOCKED_FINAL_VERIFY_MISSING_ITER_DIR</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: final verify iter dir missing in $block_dir" | tee -a "$LOG_FILE"
      return 1
    fi
    local dest="${iter_dir}/final_verify.log"
    if ! cp "$log" "$dest"; then
      local block_dir
      block_dir="$(write_blocked_basic "final_verify_log_copy_failed" "Final verify log copy failed: $log -> $dest" "blocked_final_verify")"
      write_artifact_manifest "$iter_dir" "$log" "BLOCKED" "$block_dir" "final_verify_log_copy_failed" "Final verify log copy failed: $log -> $dest"
      echo "<promise>BLOCKED_FINAL_VERIFY_LOG_COPY</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: final verify log copy failed in $block_dir" | tee -a "$LOG_FILE"
      return 1
    fi
    write_artifact_manifest "$iter_dir" "$dest" "PASS" "" "" ""
  else
    write_artifact_manifest "$iter_dir" "$log" "PASS" "" "" ""
  fi
  return 0
}

write_contract_review_fail() {
  local out="$1"
  local reason="$2"
  local violation_code="$3"
  local iter_dir
  iter_dir="$(cd "$(dirname "$out")" && pwd -P)"
  local selected_id="unknown"
  local refs_json="[]"
  local verify_post_present=false

  if [[ -f "$iter_dir/selected.json" ]]; then
    selected_id="$(jq -r '.selected_id // "unknown"' "$iter_dir/selected.json" 2>/dev/null || echo "unknown")"
  fi
  if [[ -f "$PRD_FILE" && "$selected_id" != "unknown" ]]; then
    refs_json="$(jq -c --arg id "$selected_id" '
      def items: (.items // []);
      (items | map(select(.id==$id)) | .[0].contract_refs // [])
    ' "$PRD_FILE" 2>/dev/null || echo '[]')"
  fi
  if [[ -f "$iter_dir/verify_post.log" ]]; then
    verify_post_present=true
  fi

  jq -n \
    --arg selected_story_id "$selected_id" \
    --arg decision "FAIL" \
    --arg confidence "low" \
    --argjson contract_refs_checked "$refs_json" \
    --argjson verify_post_present "$verify_post_present" \
    --arg reason "$reason" \
    --arg violation_code "$violation_code" \
    '{
      selected_story_id: $selected_story_id,
      decision: $decision,
      confidence: $confidence,
      contract_refs_checked: $contract_refs_checked,
      scope_check: { changed_files: [], out_of_scope_files: [], notes: [$reason] },
      verify_check: { verify_post_present: $verify_post_present, verify_post_green: false, notes: [$reason] },
      pass_flip_check: {
        requested_mark_pass_id: $selected_story_id,
        prd_passes_before: false,
        prd_passes_after: false,
        evidence_required: [],
        evidence_found: [],
        evidence_missing: [],
        decision_on_pass_flip: "BLOCKED"
      },
      violations: [
        {
          severity: "MAJOR",
          contract_ref: $violation_code,
          description: $reason,
          evidence_in_diff: $reason,
          changed_files: [],
          recommended_action: "NEEDS_HUMAN"
        }
      ],
      required_followups: [$reason],
      rationale: [$reason]
    }' > "$out"
}

contract_review_valid() {
  local file="$1"
  if [[ ! -x "./plans/contract_review_validate.sh" ]]; then
    return 1
  fi
  ./plans/contract_review_validate.sh "$file"
}

contract_review_ok() {
  local file="$1"
  if ! contract_review_valid "$file"; then
    return 1
  fi
  jq -e '.decision=="PASS"' "$file" >/dev/null 2>&1
}

ensure_contract_review() {
  local iter_dir="$1"
  local out="${iter_dir}/contract_review.json"
  local notes="contract_review.json missing"
  local rc=0

  if [[ -x "./plans/contract_check.sh" ]]; then
    set +e
    CONTRACT_REVIEW_OUT="$out" CONTRACT_FILE="$CONTRACT_FILE" PRD_FILE="$PRD_FILE" ./plans/contract_check.sh "$out"
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
    write_contract_review_fail "$out" "$notes" "CONTRACT_CHECK_MISSING"
    return 1
  fi
  if ! contract_review_valid "$out"; then
    write_contract_review_fail "$out" "contract_review.json invalid schema" "CONTRACT_REVIEW_INVALID"
    return 1
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

  for f in selected.json selected_item.json prd_before.json prd_after.json progress_tail_before.txt progress_tail_after.txt head_before.txt head_after.txt diff.patch prompt.txt agent.out verify_pre.log verify_post.log story_verify.log contract_review.json; do
    if [[ ! -f "$iter_dir/$f" ]]; then
      missing=1
    fi
  done
  if (( missing == 1 )); then
    return 1
  fi

  if ! verify_log_has_sha "$iter_dir/verify_post.log"; then
    return 1
  fi

  if ! contract_review_ok "$iter_dir/contract_review.json"; then
    return 1
  fi

  return 0
}

verify_iteration_artifacts() {
  local iter_dir="$1"
  local missing=()
  local f

  for f in selected.json selected_item.json prd_before.json prd_after.json progress_tail_before.txt progress_tail_after.txt head_before.txt head_after.txt diff.patch prompt.txt agent.out verify_pre.log verify_post.log story_verify.log contract_review.json; do
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
  local create_patterns
  local avoid_patterns
  local allowed_patterns
  local changed_files
  local out_of_scope=""

  touch_patterns="$(jq -r '.scope.touch[]?' <<<"$item_json")"
  create_patterns="$(jq -r '.scope.create[]?' <<<"$item_json")"
  if [[ -n "$touch_patterns" && -n "$create_patterns" ]]; then
    allowed_patterns="${touch_patterns}"$'\n'"${create_patterns}"
  elif [[ -n "$touch_patterns" ]]; then
    allowed_patterns="$touch_patterns"
  else
    allowed_patterns="$create_patterns"
  fi
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
    if [[ -n "$allowed_patterns" ]]; then
      if ! matches_patterns "$file" "$allowed_patterns"; then
        out_of_scope+="${file} (not in scope.touch/create)"$'\n'
        continue
      fi
    else
      out_of_scope+="${file} (not in scope.touch/create)"$'\n'
      continue
    fi
  done <<<"$changed_files"

  if [[ -n "$out_of_scope" ]]; then
    printf '%s' "$out_of_scope"
    return 1
  fi
  return 0
}

pass_touch_gate() {
  local head_before="$1"
  local head_after="$2"
  local item_json="$3"
  local touch_patterns
  local meta_patterns
  local changed_files
  local has_touch=0
  local has_non_meta=0

  touch_patterns="$(jq -r '.scope.touch[]?' <<<"$item_json")"
  meta_patterns="${RPH_PASS_META_PATTERNS:-}"
  changed_files="$(git diff --name-only "$head_before" "$head_after")"

  if [[ -z "$changed_files" ]]; then
    echo "no_changes"
    return 1
  fi

  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if [[ -n "$touch_patterns" ]] && matches_patterns "$file" "$touch_patterns"; then
      has_touch=1
    fi
    if [[ -n "$meta_patterns" ]] && matches_patterns "$file" "$meta_patterns"; then
      :
    else
      has_non_meta=1
    fi
  done <<<"$changed_files"

  if (( has_touch == 1 || has_non_meta == 1 )); then
    return 0
  fi
  echo "only_meta_changes"
  return 1
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

    # Fix 5: Structured progress validation - require meaningful content, not just keywords
    # Extract field values and validate they have real content
    local summary_content commands_content evidence_content next_content

    # Extract content after "Summary:" label (case-insensitive, multiline until next label or EOF)
    summary_content="$(sed -n '/^[Ss]ummary[[:space:]]*:/,/^[A-Za-z]*[[:space:]]*:/{/^[Ss]ummary[[:space:]]*:/d;/^[A-Za-z]*[[:space:]]*:/d;p;}' "$appended_file" | tr -d '[:space:]')"
    if [[ -z "$summary_content" ]]; then
      # Fallback: check single-line format "Summary: content"
      summary_content="$(grep -i '^[Ss]ummary[[:space:]]*:' "$appended_file" | sed 's/^[Ss]ummary[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')"
    fi
    if [[ -z "$summary_content" || ${#summary_content} -lt 20 ]]; then
      issues+=("summary_too_short")
    fi

    commands_content="$(sed -n '/^[Cc]ommands[[:space:]]*:/,/^[A-Za-z]*[[:space:]]*:/{/^[Cc]ommands[[:space:]]*:/d;/^[A-Za-z]*[[:space:]]*:/d;p;}' "$appended_file" | tr -d '[:space:]')"
    if [[ -z "$commands_content" ]]; then
      commands_content="$(grep -i '^[Cc]ommands[[:space:]]*:' "$appended_file" | sed 's/^[Cc]ommands[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')"
    fi
    if [[ -z "$commands_content" || ${#commands_content} -lt 10 ]]; then
      issues+=("commands_too_short")
    fi

    evidence_content="$(sed -n '/^[Ee]vidence[[:space:]]*:/,/^[A-Za-z]*[[:space:]]*:/{/^[Ee]vidence[[:space:]]*:/d;/^[A-Za-z]*[[:space:]]*:/d;p;}' "$appended_file" | tr -d '[:space:]')"
    if [[ -z "$evidence_content" ]]; then
      evidence_content="$(grep -i '^[Ee]vidence[[:space:]]*:' "$appended_file" | sed 's/^[Ee]vidence[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')"
    fi
    if [[ -z "$evidence_content" || ${#evidence_content} -lt 10 ]]; then
      issues+=("evidence_too_short")
    fi

    next_content="$(sed -n '/^[Nn]ext[[:space:]]*:/,/^[A-Za-z]*[[:space:]]*:/{/^[Nn]ext[[:space:]]*:/d;/^[A-Za-z]*[[:space:]]*:/d;p;}' "$appended_file" | tr -d '[:space:]')"
    if [[ -z "$next_content" ]]; then
      next_content="$(grep -iE '^([Nn]ext|[Gg]otcha)[[:space:]]*:' "$appended_file" | sed 's/^[NnGg][oOeE][txTX][ctCT][hHaA]*[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')"
    fi
    if [[ -z "$next_content" || ${#next_content} -lt 5 ]]; then
      issues+=("next_too_short")
    fi

    # Overall content length check
    local content_len
    content_len="$(wc -c < "$appended_file" | tr -d ' ')"
    if (( content_len < 200 )); then
      issues+=("content_too_short")
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
    tests/*|*/tests/*|__tests__/*|*/__tests__/*|*/*_test.*|*_test.*|*.spec.*|*.test.*|test_*.*)
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
  local deletions=()
  while IFS=$'\t' read -r status path; do
    [[ -z "$status" ]] && continue
    if [[ "$status" == D* ]]; then
      deletions+=("$path")
    fi
  done < <("${status_cmd[@]}")
  for path in "${deletions[@]:-}"; do
    if is_test_path "$path"; then
      cheats+=("deleted_test_file:$path")
    fi
  done

  if grep -qE '^\-.*\b(assert|expect|should|must)\b' "$filtered"; then
    cheats+=("removed_assertion")
  fi
  if grep -qE '^\+.*(#\[ignore\]|@pytest\.mark\.(skip|skipif)|\.skip\(|it\.skip|xtest|xit|pending\(|\.pending\()' "$filtered"; then
    cheats+=("added_skip_marker")
  fi
  if grep -qE '^[-+]{3} [ab]/plans/verify\.sh' "$filtered"; then
    cheats+=("modified_verify_sh")
  fi
  if grep -qE '^[-+]{3} [ab]/\.github/workflows/|^[-+]{3} [ab]/\.gitlab-ci\.yml' "$filtered"; then
    cheats+=("modified_ci")
  fi
  if grep -qE '^\+.*(# noqa|// @ts-(ignore|expect-error)|#!\[allow|eslint-disable|rubocop:disable|# type: ignore)' "$filtered"; then
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
    def items($x): ($x[0].items // []);
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

update_iteration_metrics() {
  local outcome="$1"  # pass|fail|verify_pre_fail|verify_post_fail
  local failure_mode="${2:-}"
  local tmp
  tmp="$(mktemp)"

  # Update counters based on outcome
  case "$outcome" in
    pass)
      jq '.metrics.total_iterations += 1 | .metrics.pass_count += 1' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
    fail)
      jq --arg mode "$failure_mode" '
        .metrics.total_iterations += 1 |
        .metrics.fail_count += 1 |
        if $mode != "" then
          .metrics.failure_modes = ((.metrics.failure_modes // []) + [$mode] | unique)
        else . end
      ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
    verify_pre_fail)
      jq --arg mode "$failure_mode" '
        .metrics.total_iterations += 1 |
        .metrics.fail_count += 1 |
        .metrics.verify_pre_fail_count += 1 |
        if $mode != "" then
          .metrics.failure_modes = ((.metrics.failure_modes // []) + [$mode] | unique)
        else . end
      ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
    verify_post_fail)
      jq --arg mode "$failure_mode" '
        .metrics.total_iterations += 1 |
        .metrics.fail_count += 1 |
        .metrics.verify_post_fail_count += 1 |
        if $mode != "" then
          .metrics.failure_modes = ((.metrics.failure_modes // []) + [$mode] | unique)
        else . end
      ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
  esac
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

  RPH_RATE_LIMIT_SLEPT=0
  RPH_RATE_LIMIT_SLEEP_SECS=0

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
    RPH_RATE_LIMIT_SLEPT=1
    RPH_RATE_LIMIT_SLEEP_SECS="$sleep_secs"
  fi

  count=$((count + 1))
  jq -n \
    --argjson window_start_epoch "$window_start" \
    --argjson count "$count" \
    '{window_start_epoch: $window_start_epoch, count: $count}' \
    > "$RPH_RATE_LIMIT_FILE"
  update_rate_limit_state_if_present "$window_start" "$count" "$limit" "$sleep_secs"
}

rate_limit_restart_if_slept() {
  if [[ "$RPH_RATE_LIMIT_RESTART_ON_SLEEP" != "1" ]]; then
    return 1
  fi
  if [[ "${RPH_RATE_LIMIT_SLEPT:-0}" != "1" ]]; then
    return 1
  fi
  if [[ -n "${ITER_DIR:-}" ]]; then
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$(git rev-parse HEAD)"
  fi
  echo "RateLimit: slept during iteration; restarting iteration." | tee -a "$LOG_FILE"
  return 0
}

# --- main loop ---
for ((i=1; i<=MAX_ITERS; i++)); do
  rotate_progress

  # Fix 8: Prune old iterations to prevent disk exhaustion
  prune_old_iterations ".ralph" "$RPH_MAX_ITER_DIRS"

  ITER_START_TS="$(date +%s)"
  ITER_DIR=".ralph/iter_${i}_$(date +%Y%m%d-%H%M%S)"
  echo "" | tee -a "$LOG_FILE"
  echo "=== Iteration $i/$MAX_ITERS ===" | tee -a "$LOG_FILE"
  echo "Artifacts: $ITER_DIR" | tee -a "$LOG_FILE"

  save_iter_artifacts "$ITER_DIR"
  printf '%s\n' "$RPH_AGENT_MODEL" > "${ITER_DIR}/agent_model.txt"
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
      (.items // []);
    [items[] | select(.passes==false) | .slice] | min // empty
  ' "$PRD_FILE")"
  if [[ -z "$ACTIVE_SLICE" ]]; then
    if completion_requirements_met "" ""; then
      if ! run_final_verify "$ITER_DIR"; then
        exit 1
      fi
      echo "All PRD items are passes=true. Done after $i iterations." | tee -a "$LOG_FILE"
      exit 0
    fi
    BLOCK_DIR="$(write_blocked_basic "incomplete_completion" "completion requirements not met" "blocked_incomplete")"
    write_artifact_manifest "$ITER_DIR" "" "BLOCKED" "$BLOCK_DIR" "incomplete_completion" "completion requirements not met"
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
    --arg agent_model "$RPH_AGENT_MODEL" \
    --arg agent_cmd "$RPH_AGENT_CMD" \
    --arg verify_only "$RPH_VERIFY_ONLY" \
    '.agent_model=$agent_model | .agent_cmd=$agent_cmd | .verify_only=$verify_only'
  state_merge \
    --arg head_before "$HEAD_BEFORE" \
    --arg prd_hash_before "$PRD_HASH_BEFORE" \
    '.head_before=$head_before | .prd_hash_before=$prd_hash_before'

  NEXT_ITEM_JSON=""
  NEXT_ID=""
  NEXT_PRIORITY=0
  NEXT_DESC=""
  NEXT_NEEDS_HUMAN=false
  NEXT_ELIGIBLE="false"
  NEXT_UNSAT="[]"

  DEP_ANALYSIS_JSON="$(dependency_analysis_for_slice "$ACTIVE_SLICE")"
  MISSING_DEP_COUNT="$(missing_dependency_count_from_analysis "$DEP_ANALYSIS_JSON")"
  ELIGIBLE_COUNT="$(eligible_count_from_analysis "$DEP_ANALYSIS_JSON")"
  if ! [[ "$MISSING_DEP_COUNT" =~ ^[0-9]+$ ]]; then MISSING_DEP_COUNT=0; fi
  if ! [[ "$ELIGIBLE_COUNT" =~ ^[0-9]+$ ]]; then ELIGIBLE_COUNT=0; fi

  if (( MISSING_DEP_COUNT > 0 )); then
    BLOCK_DIR="$(write_dependency_block "missing_dependency_id" "$ACTIVE_SLICE" "$DEP_ANALYSIS_JSON" "missing dependency id(s) in active slice candidates")"
    attempt_blocked_verify_pre "$BLOCK_DIR"
    echo "<promise>BLOCKED_MISSING_DEPENDENCY_ID</promise>" | tee -a "$LOG_FILE"
    echo "Blocked dependency: missing dependency id(s) in active slice" | tee -a "$LOG_FILE"
    exit 1
  fi

  if (( ELIGIBLE_COUNT == 0 )); then
    BLOCK_DIR="$(write_dependency_block "dependency_deadlock" "$ACTIVE_SLICE" "$DEP_ANALYSIS_JSON" "no eligible items in active slice")"
    attempt_blocked_verify_pre "$BLOCK_DIR"
    echo "<promise>BLOCKED_DEPENDENCY_DEADLOCK</promise>" | tee -a "$LOG_FILE"
    echo "Blocked dependency deadlock: no eligible items in active slice" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [[ "$RPH_SELECTION_MODE" == "agent" ]]; then
    CANDIDATE_LINES="$(eligible_lines_from_analysis "$DEP_ANALYSIS_JSON")"

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
      if rate_limit_restart_if_slept; then
        set -e
        i=$((i-1))
        continue
      fi
      if (( ${#RPH_AGENT_ARGS_ARR[@]} > 0 )); then
        ($RPH_AGENT_CMD "${RPH_AGENT_ARGS_ARR[@]}" "$RPH_PROMPT_FLAG" "$SEL_PROMPT") > "$SEL_OUT" 2>&1
      else
        ($RPH_AGENT_CMD "$RPH_PROMPT_FLAG" "$SEL_PROMPT") > "$SEL_OUT" 2>&1
      fi
    else
      rate_limit_before_call
      if rate_limit_restart_if_slept; then
        set -e
        i=$((i-1))
        continue
      fi
      if (( ${#RPH_AGENT_ARGS_ARR[@]} > 0 )); then
        ($RPH_AGENT_CMD "${RPH_AGENT_ARGS_ARR[@]}" "$SEL_PROMPT") > "$SEL_OUT" 2>&1
      else
        ($RPH_AGENT_CMD "$SEL_PROMPT") > "$SEL_OUT" 2>&1
      fi
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
    NEXT_ID="$(select_eligible_id_from_analysis "$DEP_ANALYSIS_JSON")"
    if [[ -n "$NEXT_ID" ]]; then
      NEXT_ITEM_JSON="$(item_by_id "$NEXT_ID")"
    fi
  fi

  if [[ -n "$NEXT_ID" ]]; then
    NEXT_INFO="$(dependency_info_from_analysis "$DEP_ANALYSIS_JSON" "$NEXT_ID")"
    if [[ -n "$NEXT_INFO" ]]; then
      NEXT_ELIGIBLE="$(jq -r '.eligible // false' <<<"$NEXT_INFO")"
      NEXT_UNSAT="$(jq -c '.unsatisfied_dependencies // []' <<<"$NEXT_INFO")"
    fi
  fi
  if [[ "$NEXT_ELIGIBLE" != "true" && "$NEXT_ELIGIBLE" != "false" ]]; then
    NEXT_ELIGIBLE="false"
  fi
  if [[ -z "$NEXT_UNSAT" ]]; then
    NEXT_UNSAT="[]"
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
    --argjson eligible "$NEXT_ELIGIBLE" \
    --argjson unsatisfied_dependencies "$NEXT_UNSAT" \
    '{active_slice: $active_slice, selection_mode: $selection_mode, selected_id: $selected_id, selected_description: $selected_description, needs_human_decision: $needs_human_decision, eligible: $eligible, unsatisfied_dependencies: $unsatisfied_dependencies}' \
    > "${ITER_DIR}/selected.json"
  printf '%s\n' "$NEXT_ITEM_JSON" > "${ITER_DIR}/selected_item.json"

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
    attempt_blocked_verify_pre "$BLOCK_DIR"
    echo "<promise>BLOCKED_INVALID_SELECTION</promise>" | tee -a "$LOG_FILE"
    echo "Blocked selection: $NEXT_ID" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [[ "$RPH_SELECTION_MODE" == "agent" ]]; then
    SEL_SLICE="$(jq -r '.slice // empty' <<<"$NEXT_ITEM_JSON")"
    SEL_PASSES="$(jq -r 'if has("passes") then .passes else "" end' <<<"$NEXT_ITEM_JSON")"
    if [[ -z "$NEXT_ID" || -z "$NEXT_ITEM_JSON" || "$SEL_PASSES" != "false" || "$SEL_SLICE" != "$ACTIVE_SLICE" || "$NEXT_ELIGIBLE" != "true" ]]; then
      BLOCK_DIR="$(write_blocked_artifacts "invalid_selection" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEXT_NEEDS_HUMAN")"
      attempt_blocked_verify_pre "$BLOCK_DIR"
      echo "<promise>BLOCKED_INVALID_SELECTION</promise>" | tee -a "$LOG_FILE"
      echo "Blocked selection: $NEXT_ID" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  if [[ "$NEXT_NEEDS_HUMAN" == "true" ]]; then
    BLOCK_DIR="$(write_blocked_artifacts "needs_human_decision" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" true)"
    attempt_blocked_verify_pre "$BLOCK_DIR"
    echo "<promise>BLOCKED_NEEDS_HUMAN_DECISION</promise>" | tee -a "$LOG_FILE"
    echo "Blocked item: $NEXT_ID - $NEXT_DESC" | tee -a "$LOG_FILE"
    exit 1
  fi

  if ! jq -e '(.verify // []) | index("./plans/verify.sh") != null' <<<"$NEXT_ITEM_JSON" >/dev/null; then
    BLOCK_DIR="$(write_blocked_artifacts "missing_verify_sh_in_story" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEXT_NEEDS_HUMAN")"
    attempt_blocked_verify_pre "$BLOCK_DIR"
    echo "<promise>BLOCKED_MISSING_VERIFY_SH_IN_STORY</promise>" | tee -a "$LOG_FILE"
    echo "Blocked item: $NEXT_ID - missing ./plans/verify.sh in verify[]" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [[ "$RPH_DRY_RUN" == "1" ]]; then
    echo "DRY RUN: would run $NEXT_ID - $NEXT_DESC" | tee -a "$LOG_FILE"
    add_skipped_check "final_verify" "dry_run"
    write_artifact_manifest "$ITER_DIR" "" "SKIPPED"
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

  VERIFY_PRE_LOG_PATH="${ITER_DIR}/verify_pre.log"
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
    if is_timeout_rc "$verify_pre_rc"; then
      echo "verify_pre timed out after ${RPH_ITER_TIMEOUT_SECS}s" | tee -a "$LOG_FILE"
    fi
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
        add_skipped_check "verify_post" "verify_pre_failed"
        add_skipped_check "story_verify" "verify_pre_failed"
        add_skipped_check "final_verify" "verify_pre_failed"
        write_artifact_manifest "$ITER_DIR" "" "BLOCKED" "$BLOCK_DIR" "verify_pre_failed" "verify_pre failed after self-heal"
        update_iteration_metrics "verify_pre_fail" "verify_pre_failed_after_self_heal"
        echo "Blocked: verify_pre failed after self-heal in $BLOCK_DIR" | tee -a "$LOG_FILE"
        exit 1
      fi
    else
      BLOCK_DIR="$(write_blocked_with_state "verify_pre_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Fail-closed: fix baseline before continuing." | tee -a "$LOG_FILE"
      add_skipped_check "verify_post" "verify_pre_failed"
      add_skipped_check "story_verify" "verify_pre_failed"
      add_skipped_check "final_verify" "verify_pre_failed"
      write_artifact_manifest "$ITER_DIR" "" "BLOCKED" "$BLOCK_DIR" "verify_pre_failed" "verify_pre failed"
      update_iteration_metrics "verify_pre_fail" "verify_pre_failed"
      echo "Blocked: verify_pre failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  # 2) Build the prompt (carry forward last failure path if present)
  LAST_FAIL_NOTE=""
  if [[ -f "$LAST_FAIL_FILE" ]]; then
    LAST_FAIL_PATH="$(cat "$LAST_FAIL_FILE" || true)"
    if [[ -n "$LAST_FAIL_PATH" && -d "$LAST_FAIL_PATH" ]]; then
      LAST_FAIL_NOTE=$'\n'"Last iteration failed. Read these files FIRST:"$'\n'"- ${LAST_FAIL_PATH}/verify_summary.txt"$'\n'"- ${LAST_FAIL_PATH}/verify_post.log"$'\n'"- ${LAST_FAIL_PATH}/agent.out"$'\n'"Then fix baseline back to green before attempting new work."$'\n'
    fi
  fi

  IFS= read -r -d '' PROMPT <<PROMPT || true
@AGENTS.md
@${ITER_DIR}/selected_item.json
@${ITER_DIR}/progress_tail_before.txt

You are running inside the Ralph harness.

NON-NEGOTIABLE RULES:
- Work on EXACTLY ONE PRD item per iteration.
- Do NOT mark passes=true unless ${VERIFY_SH} ${RPH_VERIFY_MODE} is GREEN.
- Do NOT delete/disable tests or loosen gates to make green.
- Do NOT edit PRD directly unless explicitly allowed (RPH_ALLOW_AGENT_PRD_EDIT=1).
- To mark a story pass, print exactly: ${RPH_MARK_PASS_OPEN}${NEXT_ID}${RPH_MARK_PASS_CLOSE}
- Append to progress.txt (do not rewrite it).

OUTPUT DISCIPLINE:
- Do not paste full verify output into chat. Use verify_summary.txt and the tail of verify_pre.log/verify_post.log.

Selected story ID (ONLY): ${NEXT_ID}
You MUST implement ONLY this PRD item: ${NEXT_ID} — ${NEXT_DESC}
Do not choose a different item even if it looks easier.

PROCEDURE:
0) Restate scope constraints (allowed paths from scope.touch/scope.create and avoid list), list acceptance tests, and state verify mode (${RPH_VERIFY_MODE}).
0.1) Get bearings: pwd; git log --oneline -10; read AGENTS.md + selected_item.json + progress_tail_before.txt (full PRD/progress available if needed).
0.2) Acknowledge AGENTS.md and progress.txt by noting it in your progress entry.
0.5) Handoff hygiene (when relevant):
    - Update docs/codebase/* with verified facts if you touched new areas.
    - Append deferred ideas to plans/ideas.md.
    - If pausing mid-story, fill plans/pause.md.
    - Append to plans/progress.txt; include Assumptions/Open questions when applicable.
Operator tip: For verification-only iterations, set RPH_VERIFY_ONLY=1 (uses RPH_VERIFY_ONLY_MODEL, default gpt-5-mini); tests/CI run in shell.
${LAST_FAIL_NOTE}
1) If plans/init.sh exists, run it.
2) Run: ${VERIFY_SH} ${RPH_VERIFY_MODE}  (baseline must be green; if not, fix baseline first).
3) Implement ONLY the selected story: ${NEXT_ID}. Do not choose another.
4) Implement with minimal diff + add/adjust tests as needed.
5) Small tests first: Run the smallest targeted test(s) first; only then run full verify: ${VERIFY_SH} ${RPH_VERIFY_MODE}
6) Mark pass by printing: ${RPH_MARK_PASS_OPEN}${NEXT_ID}${RPH_MARK_PASS_CLOSE}
7) Append to progress.txt with required labels: Summary:, Commands:, Evidence:, Next:. Keep command logs short (key commands only). Include story ID and a YYYY-MM-DD date. Append-only.
   Copy/paste template:
   Story: ${NEXT_ID}
   Date: YYYY-MM-DD
   Summary: ...
   Commands: ...
   Evidence: ...
   Next: ...
8) Commit: git add -A && git commit -m "PRD: ${NEXT_ID} - <short description>"

If ALL items pass, output exactly: ${RPH_COMPLETE_SENTINEL}
PROMPT

  # 3) Run agent
  echo "$PROMPT" > "${ITER_DIR}/prompt.txt"

  set +e
  ensure_agent_args_array

  # Fix 6: Lock state files before agent runs
  lock_state_files
  # Ensure we unlock even on unexpected exit
  trap 'unlock_state_files' EXIT

  if [[ -n "$RPH_PROMPT_FLAG" ]]; then
    rate_limit_before_call
    if rate_limit_restart_if_slept; then
      unlock_state_files
      set -e
      i=$((i-1))
      continue
    fi
    capture_agent_guard_hashes
    if (( ${#RPH_AGENT_ARGS_ARR[@]} > 0 )); then
      timeout_cmd "$RPH_ITER_TIMEOUT_SECS" "$RPH_AGENT_CMD" "${RPH_AGENT_ARGS_ARR[@]}" "$RPH_PROMPT_FLAG" "$PROMPT" 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    else
      timeout_cmd "$RPH_ITER_TIMEOUT_SECS" "$RPH_AGENT_CMD" "$RPH_PROMPT_FLAG" "$PROMPT" 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    fi
  else
    rate_limit_before_call
    if rate_limit_restart_if_slept; then
      unlock_state_files
      set -e
      i=$((i-1))
      continue
    fi
    capture_agent_guard_hashes
    if (( ${#RPH_AGENT_ARGS_ARR[@]} > 0 )); then
      timeout_cmd "$RPH_ITER_TIMEOUT_SECS" "$RPH_AGENT_CMD" "${RPH_AGENT_ARGS_ARR[@]}" "$PROMPT" 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    else
      timeout_cmd "$RPH_ITER_TIMEOUT_SECS" "$RPH_AGENT_CMD" "$PROMPT" 2>&1 | tee "${ITER_DIR}/agent.out" | tee -a "$LOG_FILE"
    fi
  fi
  AGENT_RC=${PIPESTATUS[0]}

  # Fix 6: Unlock state files after agent exits
  unlock_state_files
  trap - EXIT

  set -e
  echo "Agent exit code: $AGENT_RC" | tee -a "$LOG_FILE"
  if [[ "$RPH_ALLOW_HARNESS_EDIT" != "1" ]]; then
    HARNESS_SHA_AFTER="$(sha256_file "plans/ralph.sh")"
    if [[ -n "${HARNESS_SHA_BEFORE:-}" && "$HARNESS_SHA_AFTER" != "$HARNESS_SHA_BEFORE" ]]; then
      BLOCK_DIR="$(write_blocked_with_state "harness_sha_mismatch" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Blocked: plans/ralph.sh changed during agent run in $BLOCK_DIR" | tee -a "$LOG_FILE"
      printf 'before=%s\nafter=%s\n' "$HARNESS_SHA_BEFORE" "$HARNESS_SHA_AFTER" > "$BLOCK_DIR/harness_sha_mismatch.txt" || true
      exit 1
    fi
    # Fix 4: Check all workflow scripts for transitive tampering
    WORKFLOW_SCRIPTS_SHA_AFTER="$(hash_workflow_scripts)"
    if [[ -n "${WORKFLOW_SCRIPTS_SHA_BEFORE:-}" && "$WORKFLOW_SCRIPTS_SHA_AFTER" != "$WORKFLOW_SCRIPTS_SHA_BEFORE" ]]; then
      BLOCK_DIR="$(write_blocked_with_state "workflow_scripts_modified" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Blocked: workflow scripts changed during agent run in $BLOCK_DIR" | tee -a "$LOG_FILE"
      printf 'before=%s\nafter=%s\n' "$WORKFLOW_SCRIPTS_SHA_BEFORE" "$WORKFLOW_SCRIPTS_SHA_AFTER" > "$BLOCK_DIR/workflow_scripts_modified.txt" || true
      exit 1
    fi
  fi
  RALPH_JSON_SHA_AFTER="$(hash_ralph_json_files)"
  if [[ -n "${RALPH_JSON_SHA_BEFORE:-}" && "$RALPH_JSON_SHA_AFTER" != "$RALPH_JSON_SHA_BEFORE" ]]; then
    BLOCK_DIR="$(write_blocked_with_state "ralph_dir_modified" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "Blocked: .ralph JSON files changed during agent run in $BLOCK_DIR" | tee -a "$LOG_FILE"
    printf 'before=%s\nafter=%s\n' "$RALPH_JSON_SHA_BEFORE" "$RALPH_JSON_SHA_AFTER" > "$BLOCK_DIR/ralph_dir_modified.txt" || true
    exit 1
  fi
  AGENT_TIMED_OUT=0
  if [[ "$RPH_ITER_TIMEOUT_SECS" =~ ^[0-9]+$ && "$RPH_ITER_TIMEOUT_SECS" -gt 0 ]]; then
    if is_timeout_rc "$AGENT_RC"; then
      AGENT_TIMED_OUT=1
      echo "ERROR: agent timed out after ${RPH_ITER_TIMEOUT_SECS}s" | tee -a "$LOG_FILE"
    fi
  fi

  HEAD_AFTER="$(git rev-parse HEAD)"
  PRD_HASH_AFTER="$(sha256_file "$PRD_FILE")"
  PRD_PASSES_AFTER="$(jq -c '.items | map({id, passes})' "$PRD_FILE")"

  # Fix 7: Check diff size - block massive changes
  DIFF_LINES="$(check_diff_size "$HEAD_BEFORE" "$HEAD_AFTER" "$ITER_DIR")"
  if ! [[ "$DIFF_LINES" =~ ^[0-9]+$ ]]; then DIFF_LINES=0; fi
  if (( DIFF_LINES > RPH_MAX_DIFF_LINES )); then
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "diff_too_large" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "<promise>BLOCKED_DIFF_TOO_LARGE</promise>" | tee -a "$LOG_FILE"
    echo "ERROR: Diff too large (${DIFF_LINES} lines > ${RPH_MAX_DIFF_LINES} max)" | tee -a "$LOG_FILE"
    echo "Blocked: diff too large in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi
  MARK_PASS_ID=""
  if [[ -f "${ITER_DIR}/agent.out" ]]; then
    MARK_PASS_ID="$(extract_mark_pass_id "${ITER_DIR}/agent.out" || true)"
  fi
  if (( AGENT_TIMED_OUT == 1 )); then
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "agent_timeout" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "<promise>BLOCKED_AGENT_TIMEOUT</promise>" | tee -a "$LOG_FILE"
    echo "Blocked: agent timeout in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi
  if [[ -n "$MARK_PASS_ID" && "$MARK_PASS_ID" != "$NEXT_ID" ]]; then
    echo "ERROR: mark_pass id mismatch (got=$MARK_PASS_ID expected=$NEXT_ID)." | tee -a "$LOG_FILE"
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "mark_pass_mismatch" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "Blocked: mark_pass id mismatch in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi
  if [[ "$RPH_FORBID_MARK_PASS" == "1" && -n "$MARK_PASS_ID" ]]; then
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "mark_pass_forbidden" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "<promise>BLOCKED_MARK_PASS_FORBIDDEN</promise>" | tee -a "$LOG_FILE"
    echo "Blocked: mark_pass forbidden for profile $RPH_PROFILE_MODE in $BLOCK_DIR" | tee -a "$LOG_FILE"
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

  if [[ "$RPH_ALLOW_HARNESS_EDIT" != "1" ]]; then
    for pscript in plans/ralph.sh plans/update_task.sh plans/init.sh plans/contract_check.sh plans/story_verify_allowlist.txt; do
      if git diff --name-only "$HEAD_BEFORE" "$HEAD_AFTER" | grep -qx "$pscript"; then
        BLOCK_DIR="$(write_blocked_with_state "harness_file_modified" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
        echo "<promise>BLOCKED_HARNESS_FILE_MODIFIED</promise>" | tee -a "$LOG_FILE"
        echo "Blocked: $pscript was modified in this iteration (human-reviewed change required) in $BLOCK_DIR" | tee -a "$LOG_FILE"
        exit 1
      fi
    done
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

  # Fix 10: Test co-change gate - require test changes with source changes
  TEST_COCHANGE_RESULT=""
  if ! TEST_COCHANGE_RESULT="$(check_test_cochange "$HEAD_BEFORE" "$HEAD_AFTER")"; then
    echo "WARNING: Source files changed without corresponding test changes" | tee -a "$LOG_FILE"
    echo "$TEST_COCHANGE_RESULT" | tee -a "$LOG_FILE"
    if [[ "$RPH_TEST_COCHANGE_ENABLED" == "1" && "$RPH_TEST_COCHANGE_STRICT" == "1" ]]; then
      save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
      BLOCK_DIR="$(write_blocked_with_state "no_test_changes" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "<promise>BLOCKED_NO_TEST_CHANGES</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: source changed without tests in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  if [[ -n "$MARK_PASS_ID" ]]; then
    pass_touch_issue=""
    if ! pass_touch_issue="$(pass_touch_gate "$HEAD_BEFORE" "$HEAD_AFTER" "$NEXT_ITEM_JSON")"; then
      echo "ERROR: mark_pass requires a non-meta change or scope.touch match (${pass_touch_issue})" | tee -a "$LOG_FILE"
      save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
      BLOCK_DIR="$(write_blocked_with_state "pass_flip_no_touch" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "<promise>BLOCKED_PASS_FLIP_NO_TOUCH</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: pass flip without meaningful change in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  # 4) Post-verify
  VERIFY_POST_MODE="$RPH_VERIFY_MODE"
  if [[ -n "$MARK_PASS_ID" ]]; then
    VERIFY_POST_MODE="$RPH_PROMOTION_VERIFY_MODE"
  fi
  if [[ "$VERIFY_POST_MODE" != "quick" && "$VERIFY_POST_MODE" != "full" && "$VERIFY_POST_MODE" != "promotion" ]]; then
    VERIFY_POST_MODE="full"
  fi
  if [[ -n "$MARK_PASS_ID" && "$VERIFY_POST_MODE" == "quick" ]]; then
    VERIFY_POST_MODE="full"
  fi
  VERIFY_POST_MODE_ARG="$VERIFY_POST_MODE"
  verify_post_rc=0
  if run_verify "${ITER_DIR}/verify_post.log" "$VERIFY_POST_MODE_ARG"; then
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

  STORY_VERIFY_RAN=0
  STORY_VERIFY_OK=0
  if (( verify_post_rc == 0 )); then
    STORY_VERIFY_RAN=1
    if run_story_verify "$NEXT_ITEM_JSON" "$ITER_DIR"; then
      STORY_VERIFY_OK=1
    else
      STORY_VERIFY_OK=0
      verify_post_rc=1
    fi
  else
    : > "${ITER_DIR}/story_verify.log"
    echo "Skipped story-specific verify commands because verify.sh failed." >> "${ITER_DIR}/story_verify.log"
    add_skipped_check "story_verify" "verify_post_failed"
  fi

  VERIFY_POST_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
  VERIFY_POST_LOG_SHA="$(sha256_file "${ITER_DIR}/verify_post.log")"
  VERIFY_POST_TS="$(date +%s)"
  VERIFY_POST_MODE="$(extract_verify_log_mode "${ITER_DIR}/verify_post.log")"
  VERIFY_POST_VERIFY_MODE="$(extract_verify_log_verify_mode "${ITER_DIR}/verify_post.log")"
  VERIFY_POST_VERIFY_SH_SHA="$(extract_verify_log_sha "${ITER_DIR}/verify_post.log")"
  VERIFY_POST_CMD="${VERIFY_SH} ${VERIFY_POST_MODE_ARG}"
  state_merge \
    --argjson last_verify_post_rc "$verify_post_rc" \
    --arg verify_post_log "${ITER_DIR}/verify_post.log" \
    --arg verify_post_head "$VERIFY_POST_HEAD" \
    --arg verify_post_log_sha256 "$VERIFY_POST_LOG_SHA" \
    --arg verify_post_mode "$VERIFY_POST_MODE" \
    --arg verify_post_verify_mode "$VERIFY_POST_VERIFY_MODE" \
    --arg verify_post_cmd "$VERIFY_POST_CMD" \
    --arg verify_post_verify_sh_sha "$VERIFY_POST_VERIFY_SH_SHA" \
    --argjson verify_post_ts "$VERIFY_POST_TS" \
    '.last_verify_post_rc=$last_verify_post_rc
      | .last_verify_post_log=$verify_post_log
      | .last_verify_post_head=$verify_post_head
      | .last_verify_post_log_sha256=$verify_post_log_sha256
      | .last_verify_post_mode=$verify_post_mode
      | .last_verify_post_verify_mode=$verify_post_verify_mode
      | .last_verify_post_cmd=$verify_post_cmd
      | .last_verify_post_verify_sh_sha=$verify_post_verify_sh_sha
      | .last_verify_post_ts=$verify_post_ts'

  POST_VERIFY_FAILED=0
  POST_VERIFY_EXIT=0
  POST_VERIFY_CONTINUE=0
  if (( verify_post_rc != 0 )); then
    if is_timeout_rc "$verify_post_rc"; then
      echo "verify_post timed out after ${RPH_ITER_TIMEOUT_SECS}s" | tee -a "$LOG_FILE"
    fi
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
        update_iteration_metrics "verify_post_fail" "circuit_breaker"
        exit 1
      fi
    fi

    if [[ "$RPH_SELF_HEAL" == "1" ]]; then
      # If agent committed a broken state, rollback to last known green
      if ! revert_to_last_good; then
        BLOCK_DIR="$(write_blocked_with_state "self_heal_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
        echo "Blocked: self-heal failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
        update_iteration_metrics "verify_post_fail" "self_heal_failed"
        exit 1
      fi
      echo "Rolled back to last good; continuing." | tee -a "$LOG_FILE"
      POST_VERIFY_CONTINUE=1
    else
      echo "Fail-closed: stop. Fix the failure then rerun." | tee -a "$LOG_FILE"
      BLOCK_DIR="$(write_blocked_with_state "verify_post_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Blocked: verify_post failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
      write_artifact_manifest "$ITER_DIR" "" "BLOCKED" "$BLOCK_DIR" "verify_post_failed" "$NEXT_DESC"
      update_iteration_metrics "verify_post_fail" "verify_post_failed"
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
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    if ensure_contract_review "$ITER_DIR"; then
      CONTRACT_REVIEW_OK=1
    else
      BLOCK_DIR="$(write_blocked_with_state "contract_review_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "Blocked: contract review failed or missing in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  if [[ "$RPH_REQUIRE_STORY_VERIFY_GATE" == "1" ]]; then
    if (( STORY_VERIFY_RAN == 0 )); then
      save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
      BLOCK_DIR="$(write_blocked_with_state "promote_story_verify_missing" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "<promise>BLOCKED_PROMOTE_STORY_VERIFY_MISSING</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: story verify missing for profile $RPH_PROFILE_MODE in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
    if (( STORY_VERIFY_OK == 0 )); then
      save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
      BLOCK_DIR="$(write_blocked_with_state "promote_story_verify_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
      echo "<promise>BLOCKED_PROMOTE_STORY_VERIFY_FAILED</promise>" | tee -a "$LOG_FILE"
      echo "Blocked: story verify failed for profile $RPH_PROFILE_MODE in $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  if [[ "$RPH_REQUIRE_MARK_PASS" == "1" && -z "$MARK_PASS_ID" ]]; then
    save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
    BLOCK_DIR="$(write_blocked_with_state "promote_mark_pass_missing" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
    echo "<promise>BLOCKED_PROMOTE_MARK_PASS_MISSING</promise>" | tee -a "$LOG_FILE"
    echo "Blocked: mark_pass missing for profile $RPH_PROFILE_MODE in $BLOCK_DIR" | tee -a "$LOG_FILE"
    exit 1
  fi

  if [[ -n "$MARK_PASS_ID" ]]; then
    if (( POST_VERIFY_FAILED == 1 )); then
      echo "WARNING: mark_pass ignored because post-verify failed." | tee -a "$LOG_FILE"
    else
      if (( CONTRACT_REVIEW_OK == 1 )); then
        set +e
        RPH_UPDATE_TASK_OK=1 RPH_STATE_FILE="$STATE_FILE" ./plans/update_task.sh "$MARK_PASS_ID" true
        update_task_rc=$?
        set -e
        if (( update_task_rc != 0 )); then
          save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
          BLOCK_DIR="$(write_blocked_with_state "update_task_failed" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "$ITER_DIR")"
          echo "<promise>BLOCKED_UPDATE_TASK_FAILED</promise>" | tee -a "$LOG_FILE"
          echo "Blocked: update_task failed in $BLOCK_DIR" | tee -a "$LOG_FILE"
          exit 1
        fi
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
      add_skipped_check "final_verify" "verify_post_failed"
      write_artifact_manifest "$ITER_DIR" "" "BLOCKED" "$BLOCK_DIR" "verify_post_failed" "verify_post failed"
      exit 8
    fi
    if (( POST_VERIFY_CONTINUE == 1 )); then
      continue
    fi
  fi

  if grep -Fx "$RPH_COMPLETE_SENTINEL" "${ITER_DIR}/agent.out"; then
    if ! all_items_passed || [[ "$verify_post_rc" != "0" ]]; then
      save_iter_after "$ITER_DIR" "$HEAD_BEFORE" "$HEAD_AFTER"
      BLOCK_DIR="$(write_blocked_artifacts "incomplete_completion" "$NEXT_ID" "$NEXT_PRIORITY" "$NEXT_DESC" "$NEEDS_HUMAN_JSON" "blocked_incomplete")"
      echo "<promise>BLOCKED_INCOMPLETE</promise>" | tee -a "$LOG_FILE"
      echo "Blocked incomplete completion: $BLOCK_DIR" | tee -a "$LOG_FILE"
      exit 1
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

  # Track successful iteration
  update_iteration_metrics "pass"

  # Fix 9: Record structured metrics for monitoring
  ITER_END_TS="$(date +%s)"
  ITER_DURATION=$((ITER_END_TS - ITER_START_TS))
  append_metrics "$i" "$NEXT_ID" "pass" "$verify_post_rc" "$ITER_DURATION" "$DIFF_LINES" "${CHEAT_RESULT:-}" ""

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
  if grep -Fx "$RPH_COMPLETE_SENTINEL" "${ITER_DIR}/agent.out"; then
    if completion_requirements_met "$ITER_DIR" "$verify_post_rc"; then
      if ! run_final_verify "$ITER_DIR"; then
        exit 1
      fi
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
      if ! run_final_verify "$ITER_DIR"; then
        exit 1
      fi
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
write_artifact_manifest "$ITER_DIR" "" "BLOCKED" "$BLOCK_DIR" "max_iters_exceeded" "Reached max iterations ($MAX_ITERS) without completion."
echo "Reached max iterations ($MAX_ITERS) without completion." | tee -a "$LOG_FILE"
echo "Blocked: max iterations exceeded in $BLOCK_DIR" | tee -a "$LOG_FILE"
exit 1
