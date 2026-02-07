#!/usr/bin/env bash
# =============================================================================
# Stoic Trader / Ralph Verification Script
# -----------------------------------------------------------------------------
# Purpose:
#   One command that tells a coding agent (and CI): "is this repo in a mergeable,
#   green state for the selected verification level?"
#
# Usage:
#   ./plans/verify.sh [quick|full|promotion] [--census|--census-json]
#   (no arg defaults to full when CI=1, quick otherwise)
#
# Philosophy:
#   - quick: fast gate set for local iteration (subset of full).
#   - full: CI-grade gates (default in CI or when explicitly selected).
#   - promotion: optional release gate checks (e.g., F1 cert) ONLY when explicitly enabled.
#
# Logging/timeouts:
#   - VERIFY_RUN_ID=YYYYmmdd_HHMMSS (auto if unset)
#   - VERIFY_ARTIFACTS_DIR=artifacts/verify/<run_id>
#   - VERIFY_LOG_CAPTURE=1 (set 0 to disable per-step logs)
#   - VERIFY_CONSOLE=auto|quiet|verbose (auto => quiet in CI, verbose locally)
#   - VERIFY_FAIL_TAIL_LINES=80 (lines of log tail to print on failure in quiet mode)
#   - VERIFY_FAIL_SUMMARY_LINES=20 (grep summary lines to print on failure in quiet mode)
#   - ENABLE_TIMEOUTS=1 (set 0 to disable; uses timeout/gtimeout if available)
#
# CI alignment:
#   - If CI runs this script as the sole gate, set CI_GATES_SOURCE=verify.
#   - Otherwise, this script expects .github/workflows to exist so it can mirror CI.
#   - If neither is true, it emits <promise>BLOCKED_CI_COMMANDS</promise> in CI and exits non-zero.
# =============================================================================

set -euo pipefail

VERIFY_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify.sh"
if command -v sha256sum >/dev/null 2>&1; then
  VERIFY_SH_SHA="$(sha256sum "$VERIFY_SCRIPT_PATH" | awk '{print $1}')"
else
  VERIFY_SH_SHA="$(shasum -a 256 "$VERIFY_SCRIPT_PATH" | awk '{print $1}')"
fi

usage() {
  cat <<'EOF'
Usage: ./plans/verify.sh [quick|full|promotion] [--census|--census-json]

Options:
  --census        Output a non-mutating census (human-readable). No gates run.
  --census-json   Output a non-mutating census (JSON). No gates run.
  -h, --help      Show this help.

Environment:
  VERIFY_ALLOW_LOCAL_FULL=1  Allow full/promotion verify locally (default: blocked).
EOF
}

MODE=""                             # quick | full | promotion (default inferred)
CENSUS_FORMAT=""                    # human | json
CENSUS=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      quick|full|promotion)
        if [[ -n "$MODE" ]]; then
          echo "FAIL: multiple modes provided (already set to '$MODE')" >&2
          exit 2
        fi
        MODE="$1"
        shift
        ;;
      --census)
        if [[ -n "$CENSUS_FORMAT" ]]; then
          echo "FAIL: --census and --census-json are mutually exclusive" >&2
          exit 2
        fi
        CENSUS_FORMAT="human"
        shift
        ;;
      --census-json)
        if [[ -n "$CENSUS_FORMAT" ]]; then
          echo "FAIL: --census and --census-json are mutually exclusive" >&2
          exit 2
        fi
        CENSUS_FORMAT="json"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "FAIL: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

parse_args "$@"

if [[ -z "$MODE" ]]; then
  if [[ -n "${CI:-}" ]]; then
    MODE="full"
  else
    MODE="quick"
  fi
fi
# Allow "promotion" as a mode alias (full + VERIFY_MODE=promotion)
if [[ "$MODE" == "promotion" ]]; then
  MODE="full"
  export VERIFY_MODE="promotion"
fi
VERIFY_MODE="${VERIFY_MODE:-}"     # set to "promotion" for release-grade gates
if [[ -n "$CENSUS_FORMAT" ]]; then
  CENSUS=1
fi
if [[ "$MODE" == "full" && -z "${CI:-}" && "${VERIFY_ALLOW_LOCAL_FULL:-0}" != "1" ]]; then
  echo "FAIL: local full verify disabled; run in CI or set VERIFY_ALLOW_LOCAL_FULL=1 with approval" >&2
  exit 2
fi
if [[ "$CENSUS" != "1" ]]; then
  echo "VERIFY_SH_SHA=$VERIFY_SH_SHA"
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CI_GATES_SOURCE="${CI_GATES_SOURCE:-auto}"
VERIFY_RUN_ID="${VERIFY_RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
VERIFY_ARTIFACTS_DIR="${VERIFY_ARTIFACTS_DIR:-$ROOT/artifacts/verify/$VERIFY_RUN_ID}"
VERIFY_CHECKPOINT_COUNTER="${VERIFY_CHECKPOINT_COUNTER:-auto}" # auto|1|0
VERIFY_CHECKPOINT_FILE="${VERIFY_CHECKPOINT_FILE:-$ROOT/.ralph/verify_checkpoint.json}"
VERIFY_CHECKPOINT_ROLLOUT_RAW="${VERIFY_CHECKPOINT_ROLLOUT:-}"
VERIFY_CHECKPOINT_ROLLOUT="${VERIFY_CHECKPOINT_ROLLOUT_RAW:-off}" # off|dry_run|enforce
VERIFY_CHECKPOINT_KILL_SWITCH="${VERIFY_CHECKPOINT_KILL_SWITCH:-}"
VERIFY_CHECKPOINT_SKIP="${VERIFY_CHECKPOINT_SKIP:-0}"
MIN_SPEC_VALIDATORS="${MIN_SPEC_VALIDATORS:-7}"
VERIFY_CHECKPOINT_MAX_AGE_SECS="${VERIFY_CHECKPOINT_MAX_AGE_SECS:-86400}"
VERIFY_CHECKPOINT_MAX_CONSEC_SKIPS="${VERIFY_CHECKPOINT_MAX_CONSEC_SKIPS:-10}"
VERIFY_CHECKPOINT_FORCE_AFTER_SECS="${VERIFY_CHECKPOINT_FORCE_AFTER_SECS:-21600}"
VERIFY_CHECKPOINT_HASH_TARGET_MS="${VERIFY_CHECKPOINT_HASH_TARGET_MS:-500}"   # target 500ms
VERIFY_CHECKPOINT_HASH_BUDGET_MS="${VERIFY_CHECKPOINT_HASH_BUDGET_MS:-2000}" # hard ceiling 2.0s
VERIFY_CHECKPOINT_TELEMETRY_DIR="${VERIFY_CHECKPOINT_TELEMETRY_DIR:-$ROOT/.ralph/verify_telemetry}"
VERIFY_CHECKPOINT_TELEMETRY_MAX_FILES="${VERIFY_CHECKPOINT_TELEMETRY_MAX_FILES:-200}"
VERIFY_CHECKPOINT_TELEMETRY_MAX_BYTES="${VERIFY_CHECKPOINT_TELEMETRY_MAX_BYTES:-20971520}" # 20MB
VERIFY_CHECKPOINT_TELEMETRY_TTL_DAYS="${VERIFY_CHECKPOINT_TELEMETRY_TTL_DAYS:-}"
VERIFY_CHECKPOINT_LOCK_TIMEOUT_SECS="${VERIFY_CHECKPOINT_LOCK_TIMEOUT_SECS:-5}"
VERIFY_CHECKPOINT_LOCK_STALE_SECS="${VERIFY_CHECKPOINT_LOCK_STALE_SECS:-600}"
VERIFY_CHECKPOINT_LOCK_FILE="${VERIFY_CHECKPOINT_LOCK_FILE:-$(dirname "$VERIFY_CHECKPOINT_FILE")/verify_checkpoint.lock}"
VERIFY_LOG_CAPTURE="${VERIFY_LOG_CAPTURE:-1}" # 0 disables per-step log capture in verbose mode
WORKFLOW_ACCEPTANCE_POLICY="${WORKFLOW_ACCEPTANCE_POLICY:-auto}"
BASE_REF="${BASE_REF:-origin/main}"
export BASE_REF

CHECKPOINT_NON_TTY_DEFAULT_OFF=0
if [[ ! -t 1 && -z "$VERIFY_CHECKPOINT_ROLLOUT_RAW" ]]; then
  VERIFY_CHECKPOINT_ROLLOUT="off"
  CHECKPOINT_NON_TTY_DEFAULT_OFF=1
fi

# Contract/spec paths (align with ralph.sh)
CONTRACT_FILE="${CONTRACT_FILE:-specs/CONTRACT.md}"
IMPL_PLAN_FILE="${IMPL_PLAN_FILE:-specs/IMPLEMENTATION_PLAN.md}"
ARCH_FLOWS_FILE="${ARCH_FLOWS_FILE:-specs/flows/ARCH_FLOWS.yaml}"
GLOBAL_INVARIANTS_FILE="${GLOBAL_INVARIANTS_FILE:-specs/invariants/GLOBAL_INVARIANTS.md}"

if [[ "$CENSUS" != "1" ]]; then
  mkdir -p "$VERIFY_ARTIFACTS_DIR"
fi
if [[ "$CI_GATES_SOURCE" == "auto" ]]; then
  if [[ -d "$ROOT/.github/workflows" ]]; then
    CI_GATES_SOURCE="github"
  elif [[ -z "${CI:-}" ]]; then
    CI_GATES_SOURCE="verify"
  else
    CI_GATES_SOURCE=""
  fi
fi

if [[ "$CI_GATES_SOURCE" != "github" && "$CI_GATES_SOURCE" != "verify" ]]; then
  echo "<promise>BLOCKED_CI_COMMANDS</promise>"
  echo "Missing CI gate source. Set CI_GATES_SOURCE=verify or add .github/workflows for CI mirroring."
  exit 2
fi

# -----------------------------------------------------------------------------
# Logging & Utilities
# -----------------------------------------------------------------------------
source "$ROOT/plans/lib/verify_utils.sh"
source "$ROOT/plans/lib/verify_checkpoint.sh"
source "$ROOT/plans/lib/spec_validators_group.sh"

if [[ "$CHECKPOINT_NON_TTY_DEFAULT_OFF" == "1" ]]; then
  warn "non_tty_default_off: VERIFY_CHECKPOINT_ROLLOUT unset in non-TTY context; forcing rollout=off"
fi

CHECKPOINT_COUNTER_ENABLED=0
CHECKPOINT_ELIGIBLE=0
CHECKPOINT_WOULD_HIT=0
CHECKPOINT_FINGERPRINT=""
CHECKPOINT_PREV_FINGERPRINT=""
CHECKPOINT_PREV_HEAD_SHA=""
CHECKPOINT_PREV_HEAD_TREE=""
CHECKPOINT_HEAD_SHA=""
CHECKPOINT_HEAD_TREE=""
CHECKPOINT_CHANGED_FILES_HASH=""
CHECKPOINT_INELIGIBLE_REASON=""
CHECKPOINT_COUNTER_INELIGIBLE_REASON=""
CHECKPOINT_DIRTY="0"
CHECKPOINT_ROLLOUT="off"
CHECKPOINT_ROLLOUT_REASON=""
CHECKPOINT_LOCK_HELD=0
CHECKPOINT_LOCK_FILE=""
CHECKPOINT_LOCK_PROBE_DONE=0
CHECKPOINT_LOCK_PROBE_OK=0
CHECKPOINT_HASH_PHASE_MS=0
CHECKPOINT_HASH_BUDGET_EXCEEDED=0
CHECKPOINT_LAST_RUN_SKIPPED_GATE_COUNT=0
CHECKPOINT_LAST_RUN_SCHEDULED_GATE_COUNT=0
CHECKPOINT_LAST_RUN_SKIPPED_GATES=""
CHECKPOINT_DRY_RUN_WOULD_SKIP_CONTRACT_COVERAGE=0
CHECKPOINT_DRY_RUN_WOULD_SKIP_SPEC_VALIDATORS_GROUP=0
CHECKPOINT_ENFORCE_SKIPPED_CONTRACT_COVERAGE=0
CHECKPOINT_ENFORCE_SKIPPED_SPEC_VALIDATORS_GROUP=0

sha256_string() {
  local payload="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$payload" | shasum -a 256 | awk '{print $1}'
  fi
}

# Single checkpoint skip-decision entrypoint.
decide_skip_gate() {
  local gate="${1:-unknown_gate}"
  checkpoint_decide_skip_gate "$gate"
  local rc=$?
  case "$gate" in
    contract_coverage)
      if [[ "$rc" -eq 0 && "${CHECKPOINT_DECISION_REASON:-}" == "checkpoint_cache_hit" ]]; then
        CHECKPOINT_ENFORCE_SKIPPED_CONTRACT_COVERAGE=1
      elif [[ "$rc" -ne 0 && "${CHECKPOINT_DECISION_REASON:-}" == "dry_run_would_skip" ]]; then
        CHECKPOINT_DRY_RUN_WOULD_SKIP_CONTRACT_COVERAGE=1
      fi
      ;;
    spec_validators_group)
      if [[ "$rc" -eq 0 && "${CHECKPOINT_DECISION_REASON:-}" == "checkpoint_cache_hit" ]]; then
        CHECKPOINT_ENFORCE_SKIPPED_SPEC_VALIDATORS_GROUP=1
      elif [[ "$rc" -ne 0 && "${CHECKPOINT_DECISION_REASON:-}" == "dry_run_would_skip" ]]; then
        CHECKPOINT_DRY_RUN_WOULD_SKIP_SPEC_VALIDATORS_GROUP=1
      fi
      ;;
  esac
  return "$rc"
}

emit_skip_artifacts() {
  local gate="$1"
  local reason="${2:-checkpoint}"
  local logf="${VERIFY_ARTIFACTS_DIR}/${gate}.log"
  local statusf="${VERIFY_ARTIFACTS_DIR}/${gate}.status"
  local timef="${VERIFY_ARTIFACTS_DIR}/${gate}.time"
  local rcf="${VERIFY_ARTIFACTS_DIR}/${gate}.rc"

  printf 'skipped:%s\n' "$reason" > "$statusf"
  printf '0\n' > "$timef"
  printf '0\n' > "$rcf"
  {
    printf '[SKIP_DECISION] gate=%s action=skipped reason=%s\n' "$gate" "$reason"
    printf 'mode=%s verify_mode=%s rollout=%s\n' "$MODE" "${VERIFY_MODE:-none}" "${CHECKPOINT_ROLLOUT:-off}"
  } > "$logf"
}

emit_skip_artifacts_many() {
  local reason="${1:-checkpoint}"
  shift || true
  local gate
  for gate in "$@"; do
    emit_skip_artifacts "$gate" "$reason"
  done
}

checkpoint_counter_enabled() {
  local mode="${VERIFY_CHECKPOINT_COUNTER:-auto}"
  if [[ "$mode" == "auto" ]]; then
    if is_ci; then
      mode="0"
    else
      mode="1"
    fi
  fi
  [[ "$mode" == "1" ]]
}

checkpoint_counter_load_prev() {
  local file="$VERIFY_CHECKPOINT_FILE"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  local pybin=""
  if command -v python3 >/dev/null 2>&1; then
    pybin="python3"
  elif command -v python >/dev/null 2>&1; then
    pybin="python"
  else
    return 0
  fi
  local checkpoint_prev_data
  set +e
  checkpoint_prev_data="$(VERIFY_CHECKPOINT_FILE="$VERIFY_CHECKPOINT_FILE" "$pybin" - <<'PY'
import json
import os

path = os.environ.get("VERIFY_CHECKPOINT_FILE")
if not path:
    raise SystemExit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    fp = data.get("last_success", {}).get("fingerprint", "")
    skip = data.get("skip_cache", {}) if isinstance(data.get("skip_cache"), dict) else {}
    head_sha = skip.get("head_sha", "")
    head_tree = skip.get("head_tree", "")
    print(fp)
    print(head_sha if isinstance(head_sha, str) else "")
    print(head_tree if isinstance(head_tree, str) else "")
except Exception:
    pass
PY
  )"
  set -e
  CHECKPOINT_PREV_FINGERPRINT="$(printf '%s\n' "$checkpoint_prev_data" | sed -n '1p')"
  CHECKPOINT_PREV_HEAD_SHA="$(printf '%s\n' "$checkpoint_prev_data" | sed -n '2p')"
  CHECKPOINT_PREV_HEAD_TREE="$(printf '%s\n' "$checkpoint_prev_data" | sed -n '3p')"
}

checkpoint_counter_init() {
  CHECKPOINT_COUNTER_ENABLED=0
  CHECKPOINT_ELIGIBLE=0
  CHECKPOINT_WOULD_HIT=0
  CHECKPOINT_FINGERPRINT=""
  CHECKPOINT_PREV_FINGERPRINT=""
  CHECKPOINT_PREV_HEAD_SHA=""
  CHECKPOINT_PREV_HEAD_TREE=""
  CHECKPOINT_HEAD_SHA=""
  CHECKPOINT_HEAD_TREE=""
  CHECKPOINT_CHANGED_FILES_HASH=""
  CHECKPOINT_INELIGIBLE_REASON=""
  CHECKPOINT_COUNTER_INELIGIBLE_REASON=""
  CHECKPOINT_DIRTY="0"
  CHECKPOINT_HASH_PHASE_MS=0
  CHECKPOINT_HASH_BUDGET_EXCEEDED=0

  if [[ "${CENSUS:-0}" == "1" ]]; then
    return 0
  fi
  if ! checkpoint_counter_enabled; then
    return 0
  fi
  CHECKPOINT_COUNTER_ENABLED=1

  CHECKPOINT_DIRTY="${CHECKPOINT_SNAPSHOT_DIRTY:-0}"

  if ! command -v git >/dev/null 2>&1; then
    CHECKPOINT_INELIGIBLE_REASON="missing_git"
  elif ! checkpoint_is_cache_eligible; then
    if [[ -z "$CHECKPOINT_INELIGIBLE_REASON" ]]; then
      CHECKPOINT_INELIGIBLE_REASON="cache_ineligible"
    fi
  else
    CHECKPOINT_ELIGIBLE=1
  fi
  CHECKPOINT_COUNTER_INELIGIBLE_REASON="$CHECKPOINT_INELIGIBLE_REASON"

  if [[ "$CHECKPOINT_ELIGIBLE" != "1" ]]; then
    return 0
  fi

  CHECKPOINT_HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
  CHECKPOINT_HEAD_TREE="$(git rev-parse HEAD^{tree} 2>/dev/null || true)"
  local hash_phase_started_ms hash_phase_finished_ms
  hash_phase_started_ms="$(checkpoint_now_millis)"

  CHECKPOINT_CHANGED_FILES_HASH="$(sha256_string "${CHANGED_FILES:-}")"
  local override_fp tool_versions_json contract_hash spec_hash
  override_fp="$(checkpoint_override_fingerprint || true)"
  tool_versions_json="$(checkpoint_tool_versions_json || true)"
  contract_hash="$(checkpoint_gate_input_hash "contract_coverage" || true)"
  spec_hash="$(checkpoint_gate_input_hash "spec_validators_group" || true)"
  if [[ -z "$override_fp" || -z "$tool_versions_json" || -z "$contract_hash" || -z "$spec_hash" ]]; then
    if [[ -z "${CHECKPOINT_INELIGIBLE_REASON:-}" ]]; then
      CHECKPOINT_INELIGIBLE_REASON="checkpoint_hash_inputs_unavailable"
    fi
    CHECKPOINT_ELIGIBLE=0
    CHECKPOINT_COUNTER_INELIGIBLE_REASON="$CHECKPOINT_INELIGIBLE_REASON"
  fi

  local verify_mode="${VERIFY_MODE:-none}"
  local fingerprint_payload
  fingerprint_payload="verify_sh_sha=$VERIFY_SH_SHA
mode=$MODE
verify_mode=$verify_mode
base_ref=$BASE_REF
rollout=${CHECKPOINT_ROLLOUT:-off}
head_sha=$CHECKPOINT_HEAD_SHA
head_tree=$CHECKPOINT_HEAD_TREE
change_detection_ok=${CHANGE_DETECTION_OK:-0}
changed_files_hash=$CHECKPOINT_CHANGED_FILES_HASH
override_fingerprint=$override_fp
tool_versions_json=$tool_versions_json
contract_coverage_input_hash=$contract_hash
spec_validators_group_input_hash=$spec_hash"
  CHECKPOINT_FINGERPRINT="$(sha256_string "$fingerprint_payload")"

  hash_phase_finished_ms="$(checkpoint_now_millis)"
  if [[ "$hash_phase_started_ms" =~ ^[0-9]+$ && "$hash_phase_finished_ms" =~ ^[0-9]+$ && "$hash_phase_finished_ms" -ge "$hash_phase_started_ms" ]]; then
    CHECKPOINT_HASH_PHASE_MS=$((hash_phase_finished_ms - hash_phase_started_ms))
  else
    CHECKPOINT_HASH_PHASE_MS=0
  fi
  if [[ ! "$VERIFY_CHECKPOINT_HASH_BUDGET_MS" =~ ^[0-9]+$ ]]; then
    VERIFY_CHECKPOINT_HASH_BUDGET_MS=2000
  fi
  if (( CHECKPOINT_HASH_PHASE_MS > VERIFY_CHECKPOINT_HASH_BUDGET_MS )); then
    CHECKPOINT_HASH_BUDGET_EXCEEDED=1
    warn "checkpoint_hash_budget_exceeded: phase=${CHECKPOINT_HASH_PHASE_MS}ms budget=${VERIFY_CHECKPOINT_HASH_BUDGET_MS}ms"
    CHECKPOINT_ELIGIBLE=0
    CHECKPOINT_COUNTER_INELIGIBLE_REASON="checkpoint_hash_budget_exceeded"
  elif (( CHECKPOINT_HASH_PHASE_MS > VERIFY_CHECKPOINT_HASH_TARGET_MS )); then
    warn "checkpoint_hash_target_missed: phase=${CHECKPOINT_HASH_PHASE_MS}ms target=${VERIFY_CHECKPOINT_HASH_TARGET_MS}ms"
  fi

  if [[ "$CHECKPOINT_ELIGIBLE" != "1" ]]; then
    return 0
  fi

  checkpoint_counter_load_prev
  if [[ -n "$CHECKPOINT_PREV_FINGERPRINT" && "$CHECKPOINT_PREV_FINGERPRINT" == "$CHECKPOINT_FINGERPRINT" ]]; then
    CHECKPOINT_WOULD_HIT=1
  fi
}

checkpoint_counter_record_success() {
  if [[ "$CHECKPOINT_COUNTER_ENABLED" != "1" ]]; then
    return 0
  fi
  local pybin=""
  if command -v python3 >/dev/null 2>&1; then
    pybin="python3"
  elif command -v python >/dev/null 2>&1; then
    pybin="python"
  else
    return 0
  fi

  mkdir -p "$(dirname "$VERIFY_CHECKPOINT_FILE")" 2>/dev/null || true
  local verify_mode="${VERIFY_MODE:-none}"
  local would_hit="$CHECKPOINT_WOULD_HIT"
  local eligible="$CHECKPOINT_ELIGIBLE"
  local ineligible_reason="$CHECKPOINT_COUNTER_INELIGIBLE_REASON"

  if ! checkpoint_no_downgrade_ok 2 "$VERIFY_CHECKPOINT_FILE"; then
    warn "checkpoint write skipped: $CHECKPOINT_INELIGIBLE_REASON"
    return 0
  fi

  if ! checkpoint_lock_acquire; then
    warn "checkpoint write skipped: ${CHECKPOINT_INELIGIBLE_REASON:-checkpoint_lock_unavailable}"
    return 0
  fi

  set +e
  local gate_contract_scheduled=0
  if should_run_contract_coverage; then
    gate_contract_scheduled=1
  fi
  local gate_contract_hash gate_spec_hash override_fp tool_versions_json
  gate_contract_hash="$(checkpoint_gate_input_hash "contract_coverage" || true)"
  gate_spec_hash="$(checkpoint_gate_input_hash "spec_validators_group" || true)"
  override_fp="$(checkpoint_override_fingerprint || true)"
  tool_versions_json="$(checkpoint_tool_versions_json || true)"
  VERIFY_CHECKPOINT_FILE="$VERIFY_CHECKPOINT_FILE" \
    CHECKPOINT_WOULD_HIT="$would_hit" \
    CHECKPOINT_ELIGIBLE="$eligible" \
    CHECKPOINT_INELIGIBLE_REASON="$ineligible_reason" \
    CHECKPOINT_FINGERPRINT="$CHECKPOINT_FINGERPRINT" \
    CHECKPOINT_HEAD_SHA="$CHECKPOINT_HEAD_SHA" \
    CHECKPOINT_HEAD_TREE="$CHECKPOINT_HEAD_TREE" \
    CHECKPOINT_CHANGED_FILES_HASH="$CHECKPOINT_CHANGED_FILES_HASH" \
    CHECKPOINT_MODE="$MODE" \
    CHECKPOINT_VERIFY_MODE="$verify_mode" \
    CHECKPOINT_BASE_REF="$BASE_REF" \
    CHECKPOINT_DIRTY="$CHECKPOINT_DIRTY" \
    CHECKPOINT_VERIFY_SH_SHA="$VERIFY_SH_SHA" \
    CHECKPOINT_ROLLOUT="${CHECKPOINT_ROLLOUT:-off}" \
    CHECKPOINT_KILL_SWITCH="${VERIFY_CHECKPOINT_KILL_SWITCH:-}" \
    CHECKPOINT_WRITER_CI="$([[ -n "${CI:-}" ]] && echo 1 || echo 0)" \
    CHECKPOINT_WRITER_MODE="$MODE" \
    CHECKPOINT_LAST_RUN_SKIPPED_GATE_COUNT="${CHECKPOINT_LAST_RUN_SKIPPED_GATE_COUNT:-0}" \
    CHECKPOINT_LAST_RUN_SCHEDULED_GATE_COUNT="${CHECKPOINT_LAST_RUN_SCHEDULED_GATE_COUNT:-0}" \
    CHECKPOINT_HASH_PHASE_MS="${CHECKPOINT_HASH_PHASE_MS:-0}" \
    CHECKPOINT_ARTIFACTS_DIR="$VERIFY_ARTIFACTS_DIR" \
    CHECKPOINT_GATE_CONTRACT_COVERAGE_SCHEDULED="$gate_contract_scheduled" \
    CHECKPOINT_GATE_SPEC_VALIDATORS_GROUP_SCHEDULED="1" \
    CHECKPOINT_GATE_INPUT_HASH_CONTRACT_COVERAGE="$gate_contract_hash" \
    CHECKPOINT_GATE_INPUT_HASH_SPEC_VALIDATORS_GROUP="$gate_spec_hash" \
    CHECKPOINT_OVERRIDE_FINGERPRINT="$override_fp" \
    CHECKPOINT_TOOL_VERSIONS_JSON="$tool_versions_json" \
    "$pybin" - <<'PY'
import json
import os
import time

path = os.environ.get("VERIFY_CHECKPOINT_FILE")
if not path:
    raise SystemExit(0)

def _int_env(name, default=0):
    val = os.environ.get(name)
    if val is None:
        return default
    try:
        return int(val)
    except Exception:
        return default

def _to_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

def _to_float(value, default=0.0):
    try:
        return float(value)
    except Exception:
        return default

def _gate_result(artifacts_dir, gate):
    status_path = os.path.join(artifacts_dir, f"{gate}.status")
    rc_path = os.path.join(artifacts_dir, f"{gate}.rc")
    time_path = os.path.join(artifacts_dir, f"{gate}.time")
    skipped = False
    reason = ""
    if os.path.exists(status_path):
        try:
            status_raw = open(status_path, "r", encoding="utf-8").read().strip()
        except Exception:
            status_raw = ""
        if status_raw.startswith("skipped:"):
            skipped = True
            reason = status_raw.split(":", 1)[1] if ":" in status_raw else "checkpoint_skip"

    rc = None
    if os.path.exists(rc_path):
        try:
            rc = int(open(rc_path, "r", encoding="utf-8").read().strip())
        except Exception:
            rc = None

    elapsed = 0.0
    if os.path.exists(time_path):
        try:
            raw = open(time_path, "r", encoding="utf-8").read().strip()
            elapsed = float(raw) if raw else 0.0
        except Exception:
            elapsed = 0.0
    return skipped, reason, rc, elapsed

def _update_gate(skip_cache, gate, scheduled, input_hash, artifacts_dir, now_ts):
    gates = skip_cache.get("gates")
    if not isinstance(gates, dict):
        gates = {}
    prev = gates.get(gate, {}) if isinstance(gates.get(gate, {}), dict) else {}

    if not scheduled:
        entry = dict(prev) if isinstance(prev, dict) else {}
        if input_hash:
            entry["input_hash"] = input_hash
        if "input_hash" not in entry:
            entry["input_hash"] = ""
        entry["last_real_run_ts"] = _to_int(entry.get("last_real_run_ts", 0), 0)
        entry["consecutive_skips"] = _to_int(entry.get("consecutive_skips", 0), 0)
        entry["elapsed_s"] = _to_float(entry.get("elapsed_s", 0.0), 0.0)
        entry["last_decision_reason"] = entry.get("last_decision_reason") or "unscheduled"
        gates[gate] = entry
        skip_cache["gates"] = gates
        return

    skipped, reason, rc, elapsed = _gate_result(artifacts_dir, gate)
    entry = dict(prev) if isinstance(prev, dict) else {}
    if input_hash:
        entry["input_hash"] = input_hash
    if "input_hash" not in entry:
        entry["input_hash"] = ""
    entry["elapsed_s"] = 0.0 if skipped else _to_float(elapsed, 0.0)
    if skipped:
        entry["consecutive_skips"] = _to_int(prev.get("consecutive_skips", 0), 0) + 1
        entry["last_real_run_ts"] = _to_int(prev.get("last_real_run_ts", 0), 0)
        entry["last_decision_reason"] = reason or "checkpoint_skip"
    else:
        # verify.sh reaches checkpoint write only on successful gate execution.
        entry["consecutive_skips"] = 0
        entry["last_real_run_ts"] = now_ts
        entry["last_decision_reason"] = "ran"
    gates[gate] = entry
    skip_cache["gates"] = gates

data = {
    "schema_version": 2,
    "success_runs": 0,
    "full_success_runs": 0,
    "partial_success_runs": 0,
    "eligible_success_runs": 0,
    "would_hit_success_runs": 0,
    "would_miss_success_runs": 0,
    "ineligible_success_runs": 0,
    "last_run_skipped_gate_count": 0,
    "last_run_scheduled_gate_count": 0,
    "last_run_hash_phase_ms": 0,
    "last_success": {},
    "skip_cache": {
        "schema_version": 1,
        "ts": 0,
        "rollout": "off",
        "kill_switch_token": "",
        "writer_ci": False,
        "writer_mode": "",
        "written_by_verify_sh_sha": "",
        "gates": {},
    },
}
loaded = {}
try:
    with open(path, "r", encoding="utf-8") as fh:
        loaded = json.load(fh)
        if isinstance(loaded, dict):
            data.update(loaded)
except Exception:
    loaded = {}

existing_schema = 0
try:
    existing_schema = int(loaded.get("schema_version", 0))
except Exception:
    existing_schema = 0
if existing_schema > 2:
    raise SystemExit(3)

data["schema_version"] = 2

data["success_runs"] = int(data.get("success_runs", 0)) + 1
data["last_run_skipped_gate_count"] = _int_env("CHECKPOINT_LAST_RUN_SKIPPED_GATE_COUNT", 0)
data["last_run_scheduled_gate_count"] = _int_env("CHECKPOINT_LAST_RUN_SCHEDULED_GATE_COUNT", 0)
data["last_run_hash_phase_ms"] = _int_env("CHECKPOINT_HASH_PHASE_MS", 0)
if data["last_run_skipped_gate_count"] > 0:
    data["partial_success_runs"] = int(data.get("partial_success_runs", 0)) + 1
else:
    data["full_success_runs"] = int(data.get("full_success_runs", 0)) + 1
eligible = _int_env("CHECKPOINT_ELIGIBLE", 0)
would_hit = _int_env("CHECKPOINT_WOULD_HIT", 0)
if eligible == 1:
    data["eligible_success_runs"] = int(data.get("eligible_success_runs", 0)) + 1
    if would_hit == 1:
        data["would_hit_success_runs"] = int(data.get("would_hit_success_runs", 0)) + 1
    else:
        data["would_miss_success_runs"] = int(data.get("would_miss_success_runs", 0)) + 1
else:
    data["ineligible_success_runs"] = int(data.get("ineligible_success_runs", 0)) + 1

if eligible == 1:
    last = {
        "ts": int(time.time()),
        "fingerprint": os.environ.get("CHECKPOINT_FINGERPRINT", ""),
        "mode": os.environ.get("CHECKPOINT_MODE", ""),
        "verify_mode": os.environ.get("CHECKPOINT_VERIFY_MODE", ""),
        "base_ref": os.environ.get("CHECKPOINT_BASE_REF", ""),
        "head_sha": os.environ.get("CHECKPOINT_HEAD_SHA", ""),
        "head_tree": os.environ.get("CHECKPOINT_HEAD_TREE", ""),
        "changed_files_hash": os.environ.get("CHECKPOINT_CHANGED_FILES_HASH", ""),
        "dirty": bool(_int_env("CHECKPOINT_DIRTY", 0)),
        "eligible": bool(eligible),
        "ineligible_reason": os.environ.get("CHECKPOINT_INELIGIBLE_REASON", ""),
    }
    data["last_success"] = last

skip_cache = data.get("skip_cache")
if not isinstance(skip_cache, dict):
    skip_cache = {}
# Top-level schema_version tracks checkpoint envelope compatibility.
# skip_cache.schema_version tracks nested skip-cache payload compatibility.
skip_cache["schema_version"] = 1
skip_cache["ts"] = int(time.time())
skip_cache["rollout"] = os.environ.get("CHECKPOINT_ROLLOUT", "off")
skip_cache["kill_switch_token"] = os.environ.get("CHECKPOINT_KILL_SWITCH", "")
skip_cache["writer_ci"] = bool(_int_env("CHECKPOINT_WRITER_CI", 0))
skip_cache["writer_mode"] = os.environ.get("CHECKPOINT_WRITER_MODE", "")
skip_cache["written_by_verify_sh_sha"] = os.environ.get("CHECKPOINT_VERIFY_SH_SHA", "")
skip_cache["verify_sh_sha"] = os.environ.get("CHECKPOINT_VERIFY_SH_SHA", "")
skip_cache["base_ref"] = os.environ.get("CHECKPOINT_BASE_REF", "")
skip_cache["head_sha"] = os.environ.get("CHECKPOINT_HEAD_SHA", "")
skip_cache["head_tree"] = os.environ.get("CHECKPOINT_HEAD_TREE", "")
skip_cache["mode"] = os.environ.get("CHECKPOINT_MODE", "")
skip_cache["verify_mode"] = os.environ.get("CHECKPOINT_VERIFY_MODE", "")
skip_cache["changed_files_hash"] = os.environ.get("CHECKPOINT_CHANGED_FILES_HASH", "")
skip_cache["override_fingerprint"] = os.environ.get("CHECKPOINT_OVERRIDE_FINGERPRINT", "")
tool_versions_raw = os.environ.get("CHECKPOINT_TOOL_VERSIONS_JSON", "")
try:
    tool_versions = json.loads(tool_versions_raw) if tool_versions_raw else {}
except Exception:
    tool_versions = {}
if not isinstance(tool_versions, dict):
    tool_versions = {}
skip_cache["tool_versions"] = tool_versions
if not isinstance(skip_cache.get("gates"), dict):
    skip_cache["gates"] = {}

artifact_dir = os.environ.get("CHECKPOINT_ARTIFACTS_DIR", "")
now_ts = int(time.time())
contract_scheduled = _int_env("CHECKPOINT_GATE_CONTRACT_COVERAGE_SCHEDULED", 0) == 1
spec_scheduled = _int_env("CHECKPOINT_GATE_SPEC_VALIDATORS_GROUP_SCHEDULED", 0) == 1
_update_gate(
    skip_cache,
    "contract_coverage",
    contract_scheduled,
    os.environ.get("CHECKPOINT_GATE_INPUT_HASH_CONTRACT_COVERAGE", ""),
    artifact_dir,
    now_ts,
)
_update_gate(
    skip_cache,
    "spec_validators_group",
    spec_scheduled,
    os.environ.get("CHECKPOINT_GATE_INPUT_HASH_SPEC_VALIDATORS_GROUP", ""),
    artifact_dir,
    now_ts,
)
data["skip_cache"] = skip_cache

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, separators=(",", ":"))
os.replace(tmp, path)
PY
  local checkpoint_write_rc=$?
  set -e
  checkpoint_lock_release
  checkpoint_lock_restore_traps
  if [[ "$checkpoint_write_rc" -ne 0 ]]; then
    warn "checkpoint write failed (rc=$checkpoint_write_rc)"
  fi
}

checkpoint_collect_gate_run_stats() {
  local scheduled_count=0
  local skipped_count=0
  local skipped_csv=""
  local statusf gate status

  if should_run_contract_coverage; then
    scheduled_count=$((scheduled_count + 1))
  fi
  # Spec validators are always scheduled in the current pipeline.
  scheduled_count=$((scheduled_count + 1))

  for gate in contract_coverage spec_validators_group; do
    statusf="${VERIFY_ARTIFACTS_DIR}/${gate}.status"
    [[ -f "$statusf" ]] || continue
    status="$(cat "$statusf" 2>/dev/null || true)"
    if [[ "$status" == skipped:* ]]; then
      skipped_count=$((skipped_count + 1))
      if [[ -n "$skipped_csv" ]]; then
        skipped_csv="${skipped_csv},${gate}"
      else
        skipped_csv="${gate}"
      fi
    fi
  done

  CHECKPOINT_LAST_RUN_SKIPPED_GATE_COUNT="$skipped_count"
  CHECKPOINT_LAST_RUN_SCHEDULED_GATE_COUNT="$scheduled_count"
  CHECKPOINT_LAST_RUN_SKIPPED_GATES="$skipped_csv"
}

checkpoint_telemetry_prune() {
  local pybin=""
  pybin="$(checkpoint_python_bin || true)"
  [[ -n "$pybin" ]] || return 1

  mkdir -p "$VERIFY_CHECKPOINT_TELEMETRY_DIR" 2>/dev/null || return 1
  local now_epoch
  now_epoch="$(checkpoint_now_epoch)"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch="$(date +%s)"

  "$pybin" - "$VERIFY_CHECKPOINT_TELEMETRY_DIR" "$now_epoch" \
    "$VERIFY_CHECKPOINT_TELEMETRY_MAX_FILES" \
    "$VERIFY_CHECKPOINT_TELEMETRY_MAX_BYTES" \
    "${VERIFY_CHECKPOINT_TELEMETRY_TTL_DAYS:-}" <<'PY'
import json
import os
import sys

telemetry_dir = sys.argv[1]
now = int(sys.argv[2])
max_files = int(sys.argv[3]) if sys.argv[3].isdigit() else 200
max_bytes = int(sys.argv[4]) if sys.argv[4].isdigit() else 20 * 1024 * 1024
ttl_override = sys.argv[5].strip()

def _entry(path):
    ts = int(os.path.getmtime(path))
    mode = "off"
    try:
        with open(path, "r", encoding="utf-8") as fh:
            line = fh.readline().strip()
        if line:
            obj = json.loads(line)
            mode = str(obj.get("rollout_mode", mode))
            ts_val = obj.get("ts")
            if isinstance(ts_val, int) and ts_val >= 0:
                ts = ts_val
    except Exception:
        pass
    return {"path": path, "ts": ts, "mode": mode, "size": os.path.getsize(path)}

def _ttl_days(mode):
    if ttl_override:
        try:
            parsed = int(ttl_override)
            if parsed > 0:
                return parsed
        except Exception:
            pass
    return 30 if mode == "dry_run" else 7

files = []
for name in sorted(os.listdir(telemetry_dir)):
    if not (name.startswith("skip_telemetry_") and name.endswith(".jsonl")):
        continue
    files.append(_entry(os.path.join(telemetry_dir, name)))

# TTL prune first.
kept = []
for entry in files:
    ttl_days = _ttl_days(entry["mode"])
    if now - entry["ts"] > ttl_days * 86400:
        try:
            os.remove(entry["path"])
        except Exception:
            raise SystemExit(1)
        continue
    kept.append(entry)

# Deterministic oldest-first prune for file-count and byte limits.
kept.sort(key=lambda e: (e["ts"], e["path"]))
total_bytes = sum(e["size"] for e in kept)
while kept and (len(kept) > max_files or total_bytes > max_bytes):
    entry = kept.pop(0)
    try:
        os.remove(entry["path"])
    except Exception:
        raise SystemExit(1)
    total_bytes -= entry["size"]

raise SystemExit(0)
PY
}

checkpoint_write_opportunity_telemetry() {
  # Opportunity telemetry is local quick-mode only.
  if [[ "$MODE" != "quick" || -n "${CI:-}" ]]; then
    return 0
  fi

  local pybin=""
  pybin="$(checkpoint_python_bin || true)"
  [[ -n "$pybin" ]] || return 0

  local head_unchanged_since_last_run=0
  local would_skip_contract_coverage=0
  local would_skip_spec_validators_group=0
  local writer_ci=0
  local now_epoch

  if [[ -n "${CHECKPOINT_PREV_HEAD_SHA:-}" && "$CHECKPOINT_PREV_HEAD_SHA" == "${CHECKPOINT_HEAD_SHA:-}" ]]; then
    if [[ -z "${CHECKPOINT_PREV_HEAD_TREE:-}" || "$CHECKPOINT_PREV_HEAD_TREE" == "${CHECKPOINT_HEAD_TREE:-}" ]]; then
      head_unchanged_since_last_run=1
    fi
  elif [[ "$CHECKPOINT_WOULD_HIT" == "1" ]]; then
    # Backward-compatible fallback when prior checkpoint lacks explicit head metadata.
    head_unchanged_since_last_run=1
  fi
  if [[ "${CHECKPOINT_DRY_RUN_WOULD_SKIP_CONTRACT_COVERAGE:-0}" == "1" || "${CHECKPOINT_ENFORCE_SKIPPED_CONTRACT_COVERAGE:-0}" == "1" ]]; then
    would_skip_contract_coverage=1
  fi
  if [[ "${CHECKPOINT_DRY_RUN_WOULD_SKIP_SPEC_VALIDATORS_GROUP:-0}" == "1" || "${CHECKPOINT_ENFORCE_SKIPPED_SPEC_VALIDATORS_GROUP:-0}" == "1" ]]; then
    would_skip_spec_validators_group=1
  fi
  if [[ "$would_skip_contract_coverage" == "0" && "$would_skip_spec_validators_group" == "0" && "$CHECKPOINT_ELIGIBLE" == "1" && "$head_unchanged_since_last_run" == "1" ]]; then
    # Backward-compatible fallback for runs that do not invoke gate-level decisions.
    if should_run_contract_coverage; then
      would_skip_contract_coverage=1
    fi
    would_skip_spec_validators_group=1
  fi

  if [[ -n "${CI:-}" ]]; then
    writer_ci=1
  fi

  now_epoch="$(checkpoint_now_epoch)"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch="$(date +%s)"

  if ! checkpoint_telemetry_prune; then
    warn "checkpoint telemetry prune failed; opportunity telemetry skipped for this run"
    return 0
  fi

  mkdir -p "$VERIFY_CHECKPOINT_TELEMETRY_DIR" 2>/dev/null || {
    warn "checkpoint telemetry directory unavailable: $VERIFY_CHECKPOINT_TELEMETRY_DIR"
    return 0
  }

  local telemetry_file="$VERIFY_CHECKPOINT_TELEMETRY_DIR/skip_telemetry_${VERIFY_RUN_ID}.jsonl"
  VERIFY_CHECKPOINT_TELEMETRY_FILE="$telemetry_file" \
    CHECKPOINT_TELEMETRY_TS="$now_epoch" \
    CHECKPOINT_TELEMETRY_RUN_ID="$VERIFY_RUN_ID" \
    CHECKPOINT_TELEMETRY_MODE="$MODE" \
    CHECKPOINT_TELEMETRY_VERIFY_MODE="${VERIFY_MODE:-none}" \
    CHECKPOINT_TELEMETRY_ROLLOUT="${CHECKPOINT_ROLLOUT:-off}" \
    CHECKPOINT_TELEMETRY_WRITER_CI="$writer_ci" \
    CHECKPOINT_TELEMETRY_HEAD_SHA="${CHECKPOINT_HEAD_SHA:-}" \
    CHECKPOINT_TELEMETRY_HEAD_TREE="${CHECKPOINT_HEAD_TREE:-}" \
    CHECKPOINT_TELEMETRY_CHANGED_FILES_HASH="${CHECKPOINT_CHANGED_FILES_HASH:-}" \
    CHECKPOINT_TELEMETRY_HEAD_UNCHANGED="$head_unchanged_since_last_run" \
    CHECKPOINT_TELEMETRY_WOULD_SKIP_CONTRACT_COVERAGE="$would_skip_contract_coverage" \
    CHECKPOINT_TELEMETRY_WOULD_SKIP_SPEC_VALIDATORS_GROUP="$would_skip_spec_validators_group" \
    CHECKPOINT_TELEMETRY_SKIPPED_GATE_COUNT="${CHECKPOINT_LAST_RUN_SKIPPED_GATE_COUNT:-0}" \
    CHECKPOINT_TELEMETRY_SCHEDULED_GATE_COUNT="${CHECKPOINT_LAST_RUN_SCHEDULED_GATE_COUNT:-0}" \
    CHECKPOINT_TELEMETRY_SKIPPED_GATES="${CHECKPOINT_LAST_RUN_SKIPPED_GATES:-}" \
    CHECKPOINT_TELEMETRY_REPORTER_ID="${VERIFY_CHECKPOINT_REPORTER_ID:-}" \
    CHECKPOINT_TELEMETRY_WORKSTATION_HASH="${VERIFY_CHECKPOINT_WORKSTATION_ID_HASH:-}" \
    "$pybin" - <<'PY'
import json
import os
import sys

out_path = os.environ.get("VERIFY_CHECKPOINT_TELEMETRY_FILE")
if not out_path:
    raise SystemExit(0)

def _env_int(name, default=0):
    try:
        return int(os.environ.get(name, str(default)))
    except Exception:
        return default

def _env_bool(name):
    return _env_int(name, 0) == 1

skipped_gates_raw = os.environ.get("CHECKPOINT_TELEMETRY_SKIPPED_GATES", "")
skipped_gates = [g for g in skipped_gates_raw.split(",") if g]

record = {
    "ts": _env_int("CHECKPOINT_TELEMETRY_TS", 0),
    "run_id": os.environ.get("CHECKPOINT_TELEMETRY_RUN_ID", ""),
    "mode": os.environ.get("CHECKPOINT_TELEMETRY_MODE", ""),
    "verify_mode": os.environ.get("CHECKPOINT_TELEMETRY_VERIFY_MODE", ""),
    "rollout_mode": os.environ.get("CHECKPOINT_TELEMETRY_ROLLOUT", "off"),
    "writer_ci": _env_bool("CHECKPOINT_TELEMETRY_WRITER_CI"),
    "head_sha": os.environ.get("CHECKPOINT_TELEMETRY_HEAD_SHA", ""),
    "head_tree": os.environ.get("CHECKPOINT_TELEMETRY_HEAD_TREE", ""),
    "changed_files_hash": os.environ.get("CHECKPOINT_TELEMETRY_CHANGED_FILES_HASH", ""),
    "head_unchanged_since_last_run": _env_bool("CHECKPOINT_TELEMETRY_HEAD_UNCHANGED"),
    "would_skip": {
        "contract_coverage": _env_bool("CHECKPOINT_TELEMETRY_WOULD_SKIP_CONTRACT_COVERAGE"),
        "spec_validators_group": _env_bool("CHECKPOINT_TELEMETRY_WOULD_SKIP_SPEC_VALIDATORS_GROUP"),
    },
    "skipped_gate_count": _env_int("CHECKPOINT_TELEMETRY_SKIPPED_GATE_COUNT", 0),
    "scheduled_gate_count": _env_int("CHECKPOINT_TELEMETRY_SCHEDULED_GATE_COUNT", 0),
    "skipped_gates": skipped_gates,
}

reporter_id = os.environ.get("CHECKPOINT_TELEMETRY_REPORTER_ID", "")
if reporter_id:
    record["reporter_id"] = reporter_id
workstation_hash = os.environ.get("CHECKPOINT_TELEMETRY_WORKSTATION_HASH", "")
if workstation_hash:
    record["workstation_id_hash"] = workstation_hash

with open(out_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, separators=(",", ":")))
    fh.write("\n")
PY
}

checkpoint_run_telemetry_selftest() {
  local dirty_flag=0
  if command -v git >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
      dirty_flag=1
    fi
  fi
  init_change_detection
  checkpoint_resolve_rollout
  checkpoint_capture_snapshot "$dirty_flag" "${CHANGE_DETECTION_OK:-0}" "$MODE" "${VERIFY_MODE:-none}" "$([[ -n "${CI:-}" ]] && echo 1 || echo 0)"
  checkpoint_counter_init
  checkpoint_collect_gate_run_stats
  checkpoint_write_opportunity_telemetry
}

CENSUS_ENTRIES=()

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//"/\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  echo "$s"
}

census_add() {
  local gate="$1"
  local status="$2"
  local reason="${3:-}"
  local details="${4:-}"
  CENSUS_ENTRIES+=("${gate}|${status}|${reason}|${details}")
}

census_emit_human() {
  local started_at="$1"
  local ended_at="$2"
  local status
  local gate entry_status reason details
  local has_section

  echo "=== VERIFY CENSUS REPORT ==="
  echo "Mode: ${MODE}"
  echo "Started: ${started_at}"
  echo "Ended: ${ended_at}"
  echo ""

  for status in would_fail would_skip would_run; do
    has_section=0
    for entry in "${CENSUS_ENTRIES[@]}"; do
      IFS='|' read -r gate entry_status reason details <<< "$entry"
      if [[ "$entry_status" != "$status" ]]; then
        continue
      fi
      if [[ "$has_section" == "0" ]]; then
        case "$status" in
          would_fail) echo "WOULD FAIL:" ;;
          would_skip) echo "WOULD SKIP:" ;;
          would_run) echo "WOULD RUN:" ;;
        esac
        has_section=1
      fi
      line="  - ${gate}"
      if [[ -n "$reason" ]]; then
        line+=" (${reason})"
      fi
      if [[ -n "$details" ]]; then
        line+=": ${details}"
      fi
      echo "$line"
    done
    if [[ "$has_section" == "1" ]]; then
      echo ""
    fi
  done

  echo "Notes:"
  echo "  - Census is diagnostic-only"
  echo "  - Failures may cascade from a single root cause"
}

census_emit_json() {
  local started_at="$1"
  local ended_at="$2"
  local entry gate status reason details
  local fail_count=0 skip_count=0 run_count=0
  local first=1

  for entry in "${CENSUS_ENTRIES[@]}"; do
    IFS='|' read -r gate status reason details <<< "$entry"
    case "$status" in
      would_fail) fail_count=$((fail_count + 1)) ;;
      would_skip) skip_count=$((skip_count + 1)) ;;
      would_run) run_count=$((run_count + 1)) ;;
    esac
  done

  printf '{'
  printf '"schema_version":1,'
  printf '"tool":"verify.sh",'
  printf '"mode":"%s",' "$(json_escape "$MODE")"
  printf '"census":true,'
  printf '"started_at":"%s",' "$(json_escape "$started_at")"
  printf '"ended_at":"%s",' "$(json_escape "$ended_at")"
  printf '"results":['
  for entry in "${CENSUS_ENTRIES[@]}"; do
    IFS='|' read -r gate status reason details <<< "$entry"
    if [[ "$first" == "0" ]]; then
      printf ','
    fi
    first=0
    printf '{'
    printf '"gate":"%s",' "$(json_escape "$gate")"
    printf '"status":"%s"' "$(json_escape "$status")"
    if [[ -n "$reason" ]]; then
      printf ',"reason":"%s"' "$(json_escape "$reason")"
    fi
    if [[ -n "$details" ]]; then
      printf ',"details":"%s"' "$(json_escape "$details")"
    fi
    printf '}'
  done
  printf '],'
  printf '"summary":{'
  printf '"would_fail":%d,' "$fail_count"
  printf '"would_skip":%d,' "$skip_count"
  printf '"would_run":%d' "$run_count"
  printf '},'
  printf '"notes":["Census results are non-authoritative","Fixing earlier failures may resolve later ones"]'
  printf '}'
  printf '\n'
}

run_verify_census() {
  local started_at ended_at
  local -a spec_missing
  local -a status_missing
  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  init_change_detection >/dev/null 2>&1 || true

  census_add "repo_sanity" "would_run"

  if [[ -x "plans/preflight.sh" ]]; then
    census_add "workflow_preflight" "would_run"
  else
    census_add "workflow_preflight" "would_fail" "missing_preflight" "plans/preflight.sh"
  fi

  if [[ -x "plans/test_parallel_smoke.sh" ]]; then
    census_add "parallel_smoke" "would_run"
  else
    census_add "parallel_smoke" "would_fail" "missing_smoke" "plans/test_parallel_smoke.sh"
  fi

  if [[ ! -f "plans/contract_coverage_matrix.py" ]]; then
    census_add "contract_coverage" "would_fail" "missing_script" "plans/contract_coverage_matrix.py"
  elif should_run_contract_coverage; then
    census_add "contract_coverage" "would_run"
  else
    census_add "contract_coverage" "would_skip" "no_relevant_changes"
  fi

  spec_missing=()
  if ! command -v python >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    spec_missing+=("python")
  fi
  for f in "$CONTRACT_FILE" "$ARCH_FLOWS_FILE" "$GLOBAL_INVARIANTS_FILE" \
    "scripts/check_contract_crossrefs.py" "scripts/check_arch_flows.py" \
    "scripts/check_state_machines.py" "scripts/check_global_invariants.py" \
    "scripts/check_time_freshness.py" "scripts/check_crash_matrix.py" \
    "scripts/check_crash_replay_idempotency.py" "scripts/check_reconciliation_matrix.py" \
    "scripts/check_csp_trace.py" "specs/flows/TIME_FRESHNESS.yaml" \
    "specs/flows/CRASH_MATRIX.md" "specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml" \
    "specs/flows/RECONCILIATION_MATRIX.md" "specs/TRACE.yaml"; do
    if [[ ! -f "$f" ]]; then
      spec_missing+=("$f")
    fi
  done
  if [[ ! -d "specs/state_machines" ]]; then
    spec_missing+=("specs/state_machines/")
  fi
  if (( ${#spec_missing[@]} > 0 )); then
    census_add "spec_integrity" "would_fail" "missing_paths" "$(IFS=','; echo "${spec_missing[*]}")"
  else
    census_add "spec_integrity" "would_run"
  fi

  status_missing=()
  for f in "tools/validate_status.py" \
    "python/schemas/status_csp_min.schema.json" \
    "python/schemas/status_csp_exact.schema.json" \
    "specs/status/status_reason_registries_manifest.json"; do
    if [[ ! -f "$f" ]]; then
      status_missing+=("$f")
    fi
  done
  if (( ${#status_missing[@]} > 0 )); then
    census_add "status_validation" "would_fail" "missing_paths" "$(IFS=','; echo "${status_missing[*]}")"
  elif [[ -d "tests/fixtures/status" ]]; then
    census_add "status_validation" "would_run"
  else
    census_add "status_validation" "would_skip" "no_fixtures"
  fi

  ENDPOINT_GATE="${ENDPOINT_GATE:-1}"
  if [[ "$ENDPOINT_GATE" == "0" && -z "${CI:-}" ]]; then
    census_add "endpoint_gate" "would_skip" "disabled"
  else
    if [[ "${CHANGE_DETECTION_OK:-0}" != "1" && -n "${CI:-}" ]]; then
      census_add "endpoint_gate" "would_fail" "change_detection_unavailable"
    elif [[ -z "${CHANGED_FILES:-}" ]]; then
      census_add "endpoint_gate" "would_skip" "no_changes"
    else
      ENDPOINT_PATTERNS="${ENDPOINT_PATTERNS:-'(^|/)(routes|router|api|endpoints|controllers|handlers)(/|$)|(^|/)(web|http)/|(^|/)(fastapi|django|flask)/'}"
      TEST_PATTERNS="${TEST_PATTERNS:-'(^|/)(tests?|__tests__)/|(\\.spec\\.|\\.test\\.)|(^|/)integration_tests/'}"
      endpoint_changed="$(echo "$CHANGED_FILES" | grep -E "$ENDPOINT_PATTERNS" || true)"
      tests_changed="$(echo "$CHANGED_FILES" | grep -E "$TEST_PATTERNS" || true)"
      if [[ -z "$endpoint_changed" ]]; then
        census_add "endpoint_gate" "would_skip" "no_endpoint_changes"
      elif [[ -z "$tests_changed" ]]; then
        census_add "endpoint_gate" "would_fail" "missing_tests"
      else
        census_add "endpoint_gate" "would_run"
      fi
    fi
  fi

  POSTMORTEM_GATE="${POSTMORTEM_GATE:-1}"
  if [[ "$POSTMORTEM_GATE" == "0" && -z "${CI:-}" ]]; then
    census_add "postmortem_gate" "would_skip" "disabled"
  elif [[ ! -x "plans/postmortem_check.sh" ]]; then
    census_add "postmortem_gate" "would_fail" "missing_script" "plans/postmortem_check.sh"
  else
    census_add "postmortem_gate" "would_run"
  fi

  if [[ -f Cargo.toml ]]; then
    if [[ ! -f "specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml" ]]; then
      census_add "vendor_docs_lint" "would_fail" "missing_vendor_docs" "specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml"
    else
      census_add "vendor_docs_lint" "would_run"
    fi
  else
    census_add "vendor_docs_lint" "would_skip" "no_rust"
  fi

  if [[ -f Cargo.toml ]]; then
    if should_run_rust_gates; then
      census_add "rust_gates" "would_run"
    else
      census_add "rust_gates" "would_skip" "no_relevant_changes"
    fi
  else
    census_add "rust_gates" "would_skip" "no_rust"
  fi

  if [[ -f pyproject.toml || -f requirements.txt ]]; then
    if should_run_python_gates; then
      census_add "python_gates" "would_run"
    else
      census_add "python_gates" "would_skip" "no_relevant_changes"
    fi
  else
    census_add "python_gates" "would_skip" "no_python"
  fi

  if [[ -f package.json ]]; then
    if should_run_node_gates; then
      if [[ -z "$NODE_PM" ]]; then
        census_add "node_gates" "would_skip" "missing_lockfile"
      else
        census_add "node_gates" "would_run"
      fi
    else
      census_add "node_gates" "would_skip" "no_relevant_changes"
    fi
  else
    census_add "node_gates" "would_skip" "no_node"
  fi

  REQUIRE_VQ_EVIDENCE="${REQUIRE_VQ_EVIDENCE:-0}"
  if [[ -f "scripts/check_vq_evidence.py" ]]; then
    census_add "vq_evidence" "would_run"
  else
    if [[ "$REQUIRE_VQ_EVIDENCE" == "1" ]]; then
      census_add "vq_evidence" "would_fail" "missing_script" "scripts/check_vq_evidence.py"
    else
      census_add "vq_evidence" "would_skip" "missing_script"
    fi
  fi

  census_add "promotion_gates" "would_skip" "promotion_only"

  INTEGRATION_SMOKE="${INTEGRATION_SMOKE:-0}"
  if [[ "$MODE" == "full" && "$INTEGRATION_SMOKE" == "1" ]]; then
    if command -v docker >/dev/null 2>&1 && ([[ -f docker-compose.yml || -f compose.yml ]]); then
      census_add "integration_smoke" "would_run"
    else
      census_add "integration_smoke" "would_skip" "docker_unavailable"
    fi
  else
    census_add "integration_smoke" "would_skip" "disabled"
  fi

  E2E="${E2E:-0}"
  E2E_CMD="${E2E_CMD:-}"
  if [[ "$E2E" == "1" ]]; then
    if [[ -n "$E2E_CMD" ]]; then
      census_add "e2e" "would_run"
    elif [[ -f package.json ]]; then
      if node_script_exists "e2e" || node_script_exists "test:e2e"; then
        census_add "e2e" "would_run"
      elif has_playwright_config || has_cypress_config; then
        census_add "e2e" "would_run"
      else
        census_add "e2e" "would_fail" "no_harness"
      fi
    elif has_playwright_config || has_cypress_config; then
      census_add "e2e" "would_run"
    else
      census_add "e2e" "would_fail" "no_harness"
    fi
  else
    census_add "e2e" "would_skip" "disabled"
  fi

  if should_run_workflow_acceptance >/dev/null 2>&1; then
    census_add "workflow_acceptance" "would_run" "mode:$(workflow_acceptance_mode)"
  else
    if is_ci; then
      census_add "workflow_acceptance" "would_run" "ci_default"
    elif [[ "${WORKFLOW_ACCEPTANCE_POLICY:-auto}" == "never" ]]; then
      census_add "workflow_acceptance" "would_skip" "policy_never"
    elif [[ "${CHANGE_DETECTION_OK:-0}" != "1" ]]; then
      census_add "workflow_acceptance" "would_run" "change_detection_unavailable"
    else
      census_add "workflow_acceptance" "would_skip" "no_relevant_changes"
    fi
  fi

  ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [[ "$CENSUS_FORMAT" == "json" ]]; then
    census_emit_json "$started_at" "$ended_at"
  else
    census_emit_human "$started_at" "$ended_at"
  fi
}

workflow_acceptance_jobs() {
  local jobs

  case "${WORKFLOW_ACCEPTANCE_JOBS:-auto}" in
    auto)
      jobs=$(detect_cpus)
      ;;
    *)
      jobs="$WORKFLOW_ACCEPTANCE_JOBS"
      if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
        fail "Invalid WORKFLOW_ACCEPTANCE_JOBS: $jobs (must be positive integer or auto)"
      fi
      ;;
  esac

  # Cap at 8 to avoid OOM in CI runners with limited memory per worker
  [[ "$jobs" -gt 8 ]] && jobs=8
  [[ "$jobs" -lt 1 ]] && jobs=1
  echo "$jobs"
}

VERIFY_CONSOLE="${VERIFY_CONSOLE:-auto}"
case "$VERIFY_CONSOLE" in
  auto)
    if is_ci; then
      VERIFY_CONSOLE="quiet"
    else
      VERIFY_CONSOLE="verbose"
    fi
    ;;
  quiet|verbose) ;;
  *)
    warn "Unknown VERIFY_CONSOLE=$VERIFY_CONSOLE (expected auto|quiet|verbose); defaulting to verbose"
    VERIFY_CONSOLE="verbose"
    ;;
esac

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi
TIMEOUT_WARNED=0
ENABLE_TIMEOUTS="${ENABLE_TIMEOUTS:-1}"

run_parallel_group() {
  # Wave-based parallel execution for Bash 3.2+ compatibility
  # Args: array_name max_jobs
  # Array format: "name|timeout|command args"
  local specs_array_name="$1"
  local max_jobs="${2:-4}"

  # Get array contents (Bash 3.2 compatible - no nameref)
  eval "local -a specs=(\"\${$specs_array_name[@]}\")"

  local spec name timeout cmd rc
  local job_count=0
  local -a wave_pids

  for spec in "${specs[@]}"; do
    # Parse spec: "name|timeout|command args"
    name="$(echo "$spec" | cut -d'|' -f1)"
    timeout="$(echo "$spec" | cut -d'|' -f2)"
    cmd="$(echo "$spec" | cut -d'|' -f3-)"

    # Policy: specs must be simple commands (no shell metacharacters or quotes).
    # This enforces "simple command" format, not eval safety (eval is removed).
    # Specs are space-separated tokens only - no quoted args or globs supported.
    if [[ "$cmd" =~ [\;\`\$\(\)\&\|\>\<$'\n'\"\'] ]]; then
      warn "Rejecting spec with non-simple command: $name"
      echo "1" > "${VERIFY_ARTIFACTS_DIR}/${name}.rc"
      continue
    fi

    # RUN_PARALLEL_NO_EVAL: Parse command into array (no eval - structurally safe)
    local -a cmd_array
    read -ra cmd_array <<< "$cmd"
    # Launch in background with run_logged safety flags
    (
      RUN_LOGGED_SUPPRESS_EXCERPT=1 \
      RUN_LOGGED_SKIP_FAILED_GATE=1 \
      RUN_LOGGED_SUPPRESS_TIMEOUT_FAIL=1 \
      run_logged "$name" "$timeout" "${cmd_array[@]}"
    ) &
    wave_pids+=($!)
    job_count=$((job_count + 1))

    # Wave scheduling: wait when batch full
    if (( job_count >= max_jobs )); then
      for pid in "${wave_pids[@]}"; do
        wait "$pid" || true
      done
      wave_pids=()
      job_count=0
    fi
  done

  # Wait for final wave
  for pid in "${wave_pids[@]}"; do
    wait "$pid" || true
  done

  # Deterministic failure detection (check .rc files in array order)
  for spec in "${specs[@]}"; do
    name="$(echo "$spec" | cut -d'|' -f1)"
    if [[ -f "${VERIFY_ARTIFACTS_DIR}/${name}.rc" ]]; then
      rc="$(cat "${VERIFY_ARTIFACTS_DIR}/${name}.rc")"
      if [[ "$rc" != "0" ]]; then
        # First failure sets FAILED_GATE
        if [[ ! -f "${VERIFY_ARTIFACTS_DIR}/FAILED_GATE" ]]; then
          echo "$name" > "${VERIFY_ARTIFACTS_DIR}/FAILED_GATE"
          # Print excerpt for first failure only
          if [[ -f "${VERIFY_ARTIFACTS_DIR}/${name}.log" ]]; then
            emit_fail_excerpt "$name" "${VERIFY_ARTIFACTS_DIR}/${name}.log"
          fi
        fi
        return "$rc"
      fi
    fi
  done

  return 0
}

is_workflow_file() {
  local allowlist="$ROOT/plans/workflow_files_allowlist.txt"
  if [[ ! -f "$allowlist" ]]; then
    fail "Missing $allowlist (workflow allowlist required)"
  fi
  local file="${1#./}"
  file="${file%/}"
  grep -F -x -q "$file" "$allowlist"
}

source "$ROOT/plans/lib/change_detection.sh"

CHANGE_DETECTION_OK=0
CHANGED_FILES=""
CHANGED_FILES_COUNT=0

collect_changed_files() {
  local base_ref="$1"
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi

  if git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    {
      git diff --name-only "$base_ref"...HEAD 2>/dev/null || true
      git diff --name-only --cached 2>/dev/null || true
      git diff --name-only 2>/dev/null || true
    } | sed '/^$/d' | sort -u
  else
    warn "Cannot verify BASE_REF=$base_ref; checking only staged/unstaged changes for workflow diffs"
    {
      git diff --name-only --cached 2>/dev/null || true
      git diff --name-only 2>/dev/null || true
    } | sed '/^$/d' | sort -u
  fi
}

init_change_detection() {
  CHANGE_DETECTION_OK=0
  CHANGED_FILES=""
  CHANGED_FILES_COUNT=0

  if ! command -v git >/dev/null 2>&1; then
    warn "git not found; change detection disabled; defaulting to full gates"
    return 0
  fi

  if is_ci; then
    git fetch --no-tags --prune origin +refs/heads/main:refs/remotes/origin/main >/dev/null 2>&1 || true
  fi

  if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    CHANGE_DETECTION_OK=1
  else
    warn "Cannot verify BASE_REF=$BASE_REF; change detection disabled; defaulting to full gates"
  fi

  CHANGED_FILES="$(collect_changed_files "$BASE_REF")"
  if [[ -n "$CHANGED_FILES" ]]; then
    CHANGED_FILES_COUNT="$(echo "$CHANGED_FILES" | sed '/^$/d' | wc -l | tr -d ' ')"
  fi
  if [[ "${CENSUS:-0}" != "1" ]]; then
    echo "info: change_detection_ok=$CHANGE_DETECTION_OK files=$CHANGED_FILES_COUNT base_ref=$BASE_REF"
  fi
}

export_stack_env() {
  export ROOT MODE VERIFY_ARTIFACTS_DIR VERIFY_CONSOLE VERIFY_LOG_CAPTURE
  export TIMEOUT_BIN ENABLE_TIMEOUTS VERIFY_FAIL_TAIL_LINES VERIFY_FAIL_SUMMARY_LINES TIMEOUT_WARNED
  export RUST_FMT_TIMEOUT RUST_CLIPPY_TIMEOUT RUST_TEST_TIMEOUT
  export RUFF_TIMEOUT PYTEST_TIMEOUT MYPY_TIMEOUT
  export NODE_LINT_TIMEOUT NODE_TYPECHECK_TIMEOUT NODE_TEST_TIMEOUT
  export NODE_PM PYTHON_BIN
}

run_stack_gates_sequential() {
  local rust_enabled="$1"
  local python_enabled="$2"
  local node_enabled="$3"

  if [[ "$rust_enabled" == "1" ]]; then
    bash "$ROOT/plans/lib/rust_gates.sh"
  fi
  if [[ "$python_enabled" == "1" ]]; then
    bash "$ROOT/plans/lib/python_gates.sh"
  fi
  if [[ "$node_enabled" == "1" ]]; then
    bash "$ROOT/plans/lib/node_gates.sh"
  fi
}

run_stack_gates_parallel() {
  local rust_enabled="$1"
  local python_enabled="$2"
  local node_enabled="$3"
  local enabled_count="$4"

  local total_cores per_stack_threads available_mem_mb PARALLEL_MIN_CORES

  total_cores=$(detect_cpus)
  per_stack_threads=$(( total_cores / enabled_count ))
  [[ "$per_stack_threads" -lt 1 ]] && per_stack_threads=1

  [[ -z "${RUST_TEST_THREADS:-}" ]] && export RUST_TEST_THREADS="$per_stack_threads"
  [[ -z "${CARGO_BUILD_JOBS:-}" ]] && export CARGO_BUILD_JOBS="$per_stack_threads"
  [[ -z "${PYTEST_XDIST_NUMPROCESSES:-}" ]] && export PYTEST_XDIST_NUMPROCESSES="$per_stack_threads"

  available_mem_mb=""
  if command -v free >/dev/null 2>&1; then
    available_mem_mb=$(free -m | awk '/^Mem:/{print $7}')
  elif command -v vm_stat >/dev/null 2>&1; then
    parse_vm_stat() {
      local key="$1"
      vm_stat | awk -v key="$key" '
        $0 ~ key {
          gsub(/[^0-9]/, "", $NF)
          print $NF
          exit
        }'
    }
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
    pages_free=$(parse_vm_stat "Pages free")
    pages_inactive=$(parse_vm_stat "Pages inactive")
    if [[ "$pages_free" =~ ^[0-9]+$ && "$pages_inactive" =~ ^[0-9]+$ ]]; then
      available_mem_mb=$(( (pages_free + pages_inactive) * page_size / 1024 / 1024 ))
    fi
  fi

  PARALLEL_MIN_CORES="${PARALLEL_MIN_CORES:-2}"

  if [[ "$total_cores" -lt "$PARALLEL_MIN_CORES" ]]; then
    warn "Low core count ($total_cores), running sequential"
    run_stack_gates_sequential "$rust_enabled" "$python_enabled" "$node_enabled"
    return $?
  fi
  if [[ -n "$available_mem_mb" && "$available_mem_mb" -lt 4096 ]]; then
    warn "Low available memory (${available_mem_mb}MB), running sequential"
    run_stack_gates_sequential "$rust_enabled" "$python_enabled" "$node_enabled"
    return $?
  fi

  local prev_console="$VERIFY_CONSOLE"
  local prev_parallel="${VERIFY_PARALLEL_STACK:-}"
  VERIFY_CONSOLE="quiet"
  VERIFY_PARALLEL_STACK=1
  export VERIFY_CONSOLE VERIFY_PARALLEL_STACK

  log "PARALLEL_STACK_MODE: stacks=${enabled_count}"

  local -a STACK_SPECS
  STACK_SPECS=()
  if [[ "$rust_enabled" == "1" ]]; then
    STACK_SPECS+=("rust_stack||bash plans/lib/rust_gates.sh")
  fi
  if [[ "$python_enabled" == "1" ]]; then
    STACK_SPECS+=("python_stack||bash plans/lib/python_gates.sh")
  fi
  if [[ "$node_enabled" == "1" ]]; then
    STACK_SPECS+=("node_stack||bash plans/lib/node_gates.sh")
  fi

  local prev_exit_trap prev_int_trap prev_term_trap
  prev_exit_trap="$(trap -p EXIT | sed "s/^trap -- '\\(.*\\)' EXIT$/\\1/")"
  prev_int_trap="$(trap -p INT | sed "s/^trap -- '\\(.*\\)' INT$/\\1/")"
  prev_term_trap="$(trap -p TERM | sed "s/^trap -- '\\(.*\\)' TERM$/\\1/")"

  cleanup_parallel() {
    local rc=$?
    local pids
    pids="$(jobs -p 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      kill $pids 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    if [[ -n "$prev_exit_trap" ]]; then eval "$prev_exit_trap"; fi
    if [[ -n "$prev_int_trap" ]]; then eval "$prev_int_trap"; fi
    if [[ -n "$prev_term_trap" ]]; then eval "$prev_term_trap"; fi
    return $rc
  }
  trap cleanup_parallel EXIT INT TERM

  run_parallel_group STACK_SPECS "$enabled_count"
  local rc=$?

  if [[ -n "$prev_exit_trap" ]]; then
    trap "$prev_exit_trap" EXIT
  else
    trap - EXIT
  fi
  if [[ -n "$prev_int_trap" ]]; then
    trap "$prev_int_trap" INT
  else
    trap - INT
  fi
  if [[ -n "$prev_term_trap" ]]; then
    trap "$prev_term_trap" TERM
  else
    trap - TERM
  fi

  VERIFY_CONSOLE="$prev_console"
  if [[ -n "$prev_parallel" ]]; then
    VERIFY_PARALLEL_STACK="$prev_parallel"
  else
    VERIFY_PARALLEL_STACK=""
  fi
  export VERIFY_CONSOLE VERIFY_PARALLEL_STACK

  return "$rc"
}

run_stack_gates() {
  local rust_present=0 python_present=0 node_present=0
  local rust_enabled=0 python_enabled=0 node_enabled=0

  if [[ -f Cargo.toml ]]; then
    rust_present=1
    if should_run_rust_gates; then
      rust_enabled=1
    else
      echo "info: rust gates skipped (no rust-affecting changes detected)"
    fi
  fi

  if [[ -f pyproject.toml || -f requirements.txt ]]; then
    python_present=1
    if should_run_python_gates; then
      python_enabled=1
    else
      echo "info: python gates skipped (no python-affecting changes detected)"
    fi
  fi

  if [[ -f package.json ]]; then
    node_present=1
    if should_run_node_gates; then
      node_enabled=1
    else
      echo "info: node gates skipped (no node-affecting changes detected)"
    fi
  fi

  local enabled_count=$((rust_enabled + python_enabled + node_enabled))
  if [[ "$enabled_count" -eq 0 ]]; then
    return 0
  fi

  export_stack_env

  if [[ "${VERIFY_SEQUENTIAL:-0}" == "1" ]]; then
    run_stack_gates_sequential "$rust_enabled" "$python_enabled" "$node_enabled"
    return $?
  fi

  if [[ "${VERIFY_FORCE_PARALLEL_TEST:-0}" == "1" ]]; then
    run_stack_gates_parallel "$rust_enabled" "$python_enabled" "$node_enabled" "$enabled_count"
    return $?
  fi

  if [[ "$enabled_count" -le 1 ]]; then
    run_stack_gates_sequential "$rust_enabled" "$python_enabled" "$node_enabled"
    return $?
  fi

  run_stack_gates_parallel "$rust_enabled" "$python_enabled" "$node_enabled" "$enabled_count"
}
RUST_FMT_TIMEOUT="${RUST_FMT_TIMEOUT:-10m}"
RUST_CLIPPY_TIMEOUT="${RUST_CLIPPY_TIMEOUT:-20m}"
RUST_TEST_TIMEOUT="${RUST_TEST_TIMEOUT:-20m}"
PYTEST_TIMEOUT="${PYTEST_TIMEOUT:-10m}"
RUFF_TIMEOUT="${RUFF_TIMEOUT:-5m}"
MYPY_TIMEOUT="${MYPY_TIMEOUT:-10m}"
NODE_LINT_TIMEOUT="${NODE_LINT_TIMEOUT:-5m}"
NODE_TYPECHECK_TIMEOUT="${NODE_TYPECHECK_TIMEOUT:-5m}"
NODE_TEST_TIMEOUT="${NODE_TEST_TIMEOUT:-10m}"
CONTRACT_COVERAGE_TIMEOUT="${CONTRACT_COVERAGE_TIMEOUT:-2m}"
SPEC_LINT_TIMEOUT="${SPEC_LINT_TIMEOUT:-2m}"
POSTMORTEM_CHECK_TIMEOUT="${POSTMORTEM_CHECK_TIMEOUT:-1m}"
WORKFLOW_ACCEPTANCE_TIMEOUT="${WORKFLOW_ACCEPTANCE_TIMEOUT:-30m}"
WORKFLOW_ACCEPTANCE_JOBS="${WORKFLOW_ACCEPTANCE_JOBS:-auto}"
VENDOR_DOCS_LINT_TIMEOUT="${VENDOR_DOCS_LINT_TIMEOUT:-1m}"
CONTRACT_COVERAGE_CI_SENTINEL="${CONTRACT_COVERAGE_CI_SENTINEL:-plans/contract_coverage_ci_strict}"

has_playwright_config() {
  [[ -f playwright.config.ts || -f playwright.config.js || -f playwright.config.mjs || -f playwright.config.cjs ]]
}

has_cypress_config() {
  [[ -f cypress.config.ts || -f cypress.config.js || -f cypress.config.mjs || -f cypress.config.cjs ]]
}

capture_e2e_artifacts() {
  local found=0

  if [[ -d "playwright-report" ]]; then
    mkdir -p "$E2E_ARTIFACTS_DIR/playwright-report"
    cp -R "playwright-report"/. "$E2E_ARTIFACTS_DIR/playwright-report/"
    found=1
  fi

  if [[ -d "test-results" ]]; then
    mkdir -p "$E2E_ARTIFACTS_DIR/playwright-test-results"
    cp -R "test-results"/. "$E2E_ARTIFACTS_DIR/playwright-test-results/"
    found=1
  fi

  if [[ -d "cypress/screenshots" ]]; then
    mkdir -p "$E2E_ARTIFACTS_DIR/cypress-screenshots"
    cp -R "cypress/screenshots"/. "$E2E_ARTIFACTS_DIR/cypress-screenshots/"
    found=1
  fi

  if [[ -d "cypress/videos" ]]; then
    mkdir -p "$E2E_ARTIFACTS_DIR/cypress-videos"
    cp -R "cypress/videos"/. "$E2E_ARTIFACTS_DIR/cypress-videos/"
    found=1
  fi

  if [[ "$found" == "0" ]]; then
    warn "No E2E artifacts found to capture"
  fi
}

case "$MODE" in
  quick|full) ;;
  *) fail "Unknown mode: $MODE (expected quick or full)" ;;
esac

NODE_PM=""
if [[ -f pnpm-lock.yaml ]]; then NODE_PM="pnpm"; fi
if [[ -z "$NODE_PM" && -f package-lock.json ]]; then NODE_PM="npm"; fi
if [[ -z "$NODE_PM" && -f yarn.lock ]]; then NODE_PM="yarn"; fi

if [[ "$CENSUS" == "1" ]]; then
  if [[ "${VERIFY_CHECKPOINT_TELEMETRY_SELFTEST:-0}" == "1" ]]; then
    checkpoint_run_telemetry_selftest
  fi
  run_verify_census
  exit 0
fi

# -----------------------------------------------------------------------------
# 0) Repo sanity + reproducibility basics
# -----------------------------------------------------------------------------
log "0) Repo sanity"

echo "mode=$MODE verify_mode=${VERIFY_MODE:-none} root=$ROOT"
echo "verify_run_id=$VERIFY_RUN_ID artifacts_dir=$VERIFY_ARTIFACTS_DIR"
if is_ci; then echo "CI=1"; fi

# Dirty tree enforcement (fail closed in CI; local override with VERIFY_ALLOW_DIRTY=1)
dirty_tree_flag="0"
if command -v git >/dev/null 2>&1; then
  dirty_status="$(git status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty_status" ]]; then
    dirty_tree_flag="1"
    if is_ci; then
      fail "Working tree is dirty in CI"
    fi
    if [[ "${VERIFY_ALLOW_DIRTY:-0}" != "1" ]]; then
      fail "Working tree is dirty (set VERIFY_ALLOW_DIRTY=1 to continue locally)"
    fi
    warn "Working tree is dirty (VERIFY_ALLOW_DIRTY=1)"
    printf '%s\n' "$dirty_status" >&2
  fi
fi

# Lockfile enforcement (fail-closed in CI; warn locally)
if [[ -f Cargo.toml && ! -f Cargo.lock ]]; then
  fail "Cargo.lock missing (commit lockfile for reproducibility)"
fi

if [[ -f package.json ]]; then
  if [[ ! -f pnpm-lock.yaml && ! -f package-lock.json && ! -f yarn.lock ]]; then
    if is_ci; then
      fail "No JS lockfile found (expected pnpm-lock.yaml or package-lock.json or yarn.lock)"
    else
      warn "No JS lockfile found (expected pnpm-lock.yaml or package-lock.json or yarn.lock)"
    fi
  fi
fi

# Default to strict coverage locally; enable in CI only after promotion.
if [[ -z "${CONTRACT_COVERAGE_STRICT:-}" ]]; then
  if is_ci; then
    if [[ -f "$CONTRACT_COVERAGE_CI_SENTINEL" ]]; then
      CONTRACT_COVERAGE_STRICT=1
    else
      CONTRACT_COVERAGE_STRICT=0
    fi
  else
    CONTRACT_COVERAGE_STRICT=1
  fi
fi
export CONTRACT_COVERAGE_STRICT

# Change detection for stack gating (fail-closed if unavailable)
init_change_detection
checkpoint_resolve_rollout
checkpoint_capture_snapshot "$dirty_tree_flag" "${CHANGE_DETECTION_OK:-0}" "$MODE" "${VERIFY_MODE:-none}" "$([[ -n "${CI:-}" ]] && echo 1 || echo 0)"
checkpoint_counter_init

# -----------------------------------------------------------------------------
# 0.1) Workflow preflight
# -----------------------------------------------------------------------------
log "0.1) Workflow preflight"
preflight_strict=""
if is_ci || [[ "${VERIFY_PREFLIGHT_STRICT:-0}" == "1" ]]; then
  preflight_strict="--strict"
fi
if [[ -n "$preflight_strict" ]]; then
  run_logged "preflight" "30s" ./plans/preflight.sh "$preflight_strict"
else
  run_logged "preflight" "30s" ./plans/preflight.sh
fi

# -----------------------------------------------------------------------------
# 0a) Parallel primitives smoke test
# -----------------------------------------------------------------------------
log "0a) Parallel primitives smoke test"
if [[ ! -x "plans/test_parallel_smoke.sh" ]]; then
  fail "Missing or non-executable: plans/test_parallel_smoke.sh"
fi
run_logged "parallel_smoke" "1m" ./plans/test_parallel_smoke.sh

# -----------------------------------------------------------------------------
# 0b) Contract coverage matrix
# -----------------------------------------------------------------------------
log "0b) Contract coverage matrix"
if [[ ! -f "plans/contract_coverage_matrix.py" ]]; then
  fail "Missing contract coverage script: plans/contract_coverage_matrix.py"
fi
if should_run_contract_coverage; then
  if decide_skip_gate "contract_coverage"; then
    emit_skip_artifacts "contract_coverage" "${CHECKPOINT_DECISION_REASON:-checkpoint_skip}"
    echo "info: contract_coverage skipped (${CHECKPOINT_DECISION_REASON:-checkpoint_skip})"
  else
    ensure_python
    run_logged "contract_coverage" "$CONTRACT_COVERAGE_TIMEOUT" "$PYTHON_BIN" "plans/contract_coverage_matrix.py"
    if [[ -z "${CI:-}" && "$CONTRACT_COVERAGE_STRICT" == "1" && ! -f "$CONTRACT_COVERAGE_CI_SENTINEL" ]]; then
      warn "Contract coverage strict passed locally. Run ./plans/contract_coverage_promote.sh to enable strict coverage in CI."
    fi
  fi
else
  echo "info: contract coverage skipped (no relevant changes detected)"
fi

# -----------------------------------------------------------------------------
# 0c) Spec integrity gates
# -----------------------------------------------------------------------------
log "0c) Spec integrity gates"
ensure_python

[[ -f "$CONTRACT_FILE" ]] || fail "Missing $CONTRACT_FILE"
[[ -f "$ARCH_FLOWS_FILE" ]] || fail "Missing $ARCH_FLOWS_FILE"
[[ -f "$GLOBAL_INVARIANTS_FILE" ]] || fail "Missing $GLOBAL_INVARIANTS_FILE"
[[ -d "specs/state_machines" ]] || fail "Missing specs/state_machines"

# Existence checks for all validators (fail fast before parallelization)
[[ -f "scripts/check_contract_crossrefs.py" ]] || fail "Missing scripts/check_contract_crossrefs.py"
[[ -f "scripts/check_arch_flows.py" ]] || fail "Missing scripts/check_arch_flows.py"
[[ -f "scripts/check_state_machines.py" ]] || fail "Missing scripts/check_state_machines.py"
[[ -f "scripts/check_global_invariants.py" ]] || fail "Missing scripts/check_global_invariants.py"
[[ -f "scripts/check_time_freshness.py" ]] || fail "Missing scripts/check_time_freshness.py"
[[ -f "scripts/check_crash_matrix.py" ]] || fail "Missing scripts/check_crash_matrix.py"
[[ -f "scripts/check_crash_replay_idempotency.py" ]] || fail "Missing scripts/check_crash_replay_idempotency.py"
[[ -f "scripts/check_reconciliation_matrix.py" ]] || fail "Missing scripts/check_reconciliation_matrix.py"
[[ -f "scripts/check_csp_trace.py" ]] || fail "Missing scripts/check_csp_trace.py"
[[ -f "specs/flows/TIME_FRESHNESS.yaml" ]] || fail "Missing specs/flows/TIME_FRESHNESS.yaml"
[[ -f "specs/flows/CRASH_MATRIX.md" ]] || fail "Missing specs/flows/CRASH_MATRIX.md"
[[ -f "specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml" ]] || fail "Missing specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml"
[[ -f "specs/flows/RECONCILIATION_MATRIX.md" ]] || fail "Missing specs/flows/RECONCILIATION_MATRIX.md"
[[ -f "specs/TRACE.yaml" ]] || fail "Missing specs/TRACE.yaml"

if ! spec_validators_group_build_specs; then
  fail "spec_validators_group_build_specs failed (validator list invalid)"
fi

# Auto-detect CPU cores, cap at 4 to avoid CI thrashing
SPEC_LINT_JOBS=$(detect_cpus)
[[ $SPEC_LINT_JOBS -gt 4 ]] && SPEC_LINT_JOBS=4

# Run validators in parallel
if decide_skip_gate "spec_validators_group"; then
  emit_skip_artifacts "spec_validators_group" "${CHECKPOINT_DECISION_REASON:-checkpoint_skip}"
  emit_skip_artifacts_many "${CHECKPOINT_DECISION_REASON:-checkpoint_skip}" "${SPEC_VALIDATOR_NAMES[@]}"
  echo "info: spec_validators_group skipped (${CHECKPOINT_DECISION_REASON:-checkpoint_skip})"
else
  run_parallel_group SPEC_VALIDATOR_SPECS "$SPEC_LINT_JOBS"
fi

# -----------------------------------------------------------------------------
# 0d) Status contract validation (CSP)
# -----------------------------------------------------------------------------
log "0d) Status contract validation (CSP)"

STATUS_SCHEMA="python/schemas/status_csp_min.schema.json"
STATUS_EXACT_SCHEMA="python/schemas/status_csp_exact.schema.json"
STATUS_MANIFEST="specs/status/status_reason_registries_manifest.json"
STATUS_FIXTURES_DIR="tests/fixtures/status"
STATUS_VALIDATION_TIMEOUT="${STATUS_VALIDATION_TIMEOUT:-2m}"

# Drift guard: ensure canonical files exist
test -f "tools/validate_status.py" || fail "Missing tools/validate_status.py"
test -f "$STATUS_SCHEMA" || fail "Missing $STATUS_SCHEMA"
test -f "$STATUS_EXACT_SCHEMA" || fail "Missing $STATUS_EXACT_SCHEMA"
test -f "$STATUS_MANIFEST" || fail "Missing $STATUS_MANIFEST"

# Validate fixtures against exact schema (no extra keys allowed)
if [[ -d "$STATUS_FIXTURES_DIR" ]]; then
  # Build status fixture validation array
  STATUS_FIXTURE_SPECS=()
  fixture_count=0

  # Build quiet flag if needed
  QUIET_FLAG=""
  if [[ "$VERIFY_CONSOLE" == "quiet" ]]; then
    QUIET_FLAG="--quiet"
  fi

  # Glob fixtures in deterministic order (sorted by name)
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    fixture_name="$(basename "$f" .json)"
    # Format: "name|timeout|command args"
    STATUS_FIXTURE_SPECS+=("status_fixture_${fixture_name}|$STATUS_VALIDATION_TIMEOUT|$PYTHON_BIN tools/validate_status.py --file $f --schema $STATUS_EXACT_SCHEMA --manifest $STATUS_MANIFEST --strict $QUIET_FLAG")
    fixture_count=$((fixture_count + 1))
  done < <(ls -1 "$STATUS_FIXTURES_DIR"/*.json 2>/dev/null | sort || true)

  if [[ "$fixture_count" -eq 0 ]]; then
    warn "No status fixtures found in $STATUS_FIXTURES_DIR"
  else
    # Auto-detect CPU cores, cap at 4 (status validation is lightweight)
    STATUS_JOBS=$(detect_cpus)
    [[ $STATUS_JOBS -gt 4 ]] && STATUS_JOBS=4

    # Run fixture validations in parallel
    run_parallel_group STATUS_FIXTURE_SPECS "$STATUS_JOBS"
    echo "✓ validated $fixture_count status fixture(s)"
  fi
else
  warn "Status fixtures directory not found: $STATUS_FIXTURES_DIR"
fi

# -----------------------------------------------------------------------------
# 1) Endpoint-level test gate (workflow non-negotiable)
# -----------------------------------------------------------------------------
# Goal: if endpoint/router/controller code changes, tests must change too.
# This is a simple, deterministic proxy for "new/changed endpoint must have an endpoint-level test."
#
# Controls:
#   ENDPOINT_GATE=0      -> disable locally (ignored in CI)
#   BASE_REF=origin/main -> diff base
log "1) Endpoint-level test gate"

ENDPOINT_GATE="${ENDPOINT_GATE:-1}"

if [[ "$ENDPOINT_GATE" == "0" && -z "${CI:-}" ]]; then
  warn "ENDPOINT_GATE=0 (disabled locally)"
else
  if [[ "$CHANGE_DETECTION_OK" != "1" ]]; then
    if is_ci; then
      fail "CI must be able to diff against BASE_REF=$BASE_REF (fetch-depth must be 0 and main must be present)."
    else
      warn "Change detection unavailable; running endpoint gate on local diffs only"
    fi
  fi

  if [[ -z "$CHANGED_FILES" ]]; then
    echo "info: endpoint gate skipped (no changes detected)"
  else
    # Broad but practical patterns across stacks
    # TODO: tighten ENDPOINT_PATTERNS to repo-specific paths once Python/HTTP layout is introduced.
    ENDPOINT_PATTERNS="${ENDPOINT_PATTERNS:-'(^|/)(routes|router|api|endpoints|controllers|handlers)(/|$)|(^|/)(web|http)/|(^|/)(fastapi|django|flask)/'}"
    TEST_PATTERNS="${TEST_PATTERNS:-'(^|/)(tests?|__tests__)/|(\\.spec\\.|\\.test\\.)|(^|/)integration_tests/'}"
    endpoint_changed="$(echo "$CHANGED_FILES" | grep -E "$ENDPOINT_PATTERNS" || true)"
    tests_changed="$(echo "$CHANGED_FILES" | grep -E "$TEST_PATTERNS" || true)"

    if [[ -z "$endpoint_changed" ]]; then
      echo "info: endpoint gate skipped (no endpoint-affecting changes detected)"
    elif [[ -z "$tests_changed" ]]; then
      fail "Endpoint-ish files changed without corresponding test changes:
$endpoint_changed

Fix: add/update endpoint-level tests for the changed endpoints."
    else
      echo "✓ endpoint gate passed"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 1b) PR postmortem gate (no postmortem, no merge)
# -----------------------------------------------------------------------------
log "1b) PR postmortem gate"
POSTMORTEM_GATE="${POSTMORTEM_GATE:-1}"
if [[ "$POSTMORTEM_GATE" == "0" && -z "${CI:-}" ]]; then
  warn "POSTMORTEM_GATE=0 (disabled locally)"
else
  if [[ -x "$ROOT/plans/postmortem_check.sh" ]]; then
    run_logged "postmortem_check" "$POSTMORTEM_CHECK_TIMEOUT" "$ROOT/plans/postmortem_check.sh"
  else
    fail "Missing postmortem check script: plans/postmortem_check.sh"
  fi
fi

# -----------------------------------------------------------------------------
# 1c) Rust vendor docs lint
# -----------------------------------------------------------------------------
if [[ -f Cargo.toml ]]; then
  if [[ -f "specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml" ]]; then
    log "1c) Rust vendor docs lint"
    ensure_python
    run_logged "vendor_docs_lint_rust" "$VENDOR_DOCS_LINT_TIMEOUT" "$PYTHON_BIN" "tools/vendor_docs_lint_rust.py"
  else
    fail "Missing vendor docs config: specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml"
  fi
fi

# -----------------------------------------------------------------------------
# 2-4) Stack gates (Rust, Python, Node)
# -----------------------------------------------------------------------------
run_stack_gates

# -----------------------------------------------------------------------------
# 5) Optional project-specific evidence / cert / smoke hooks
# -----------------------------------------------------------------------------
# These are OFF by default for Ralph/PR throughput. Enable explicitly.
#
#   VERIFY_MODE=promotion   -> enforce release-grade gates (e.g., F1 cert PASS)
#   RUN_F1_CERT=1           -> generate F1 cert if tooling exists
#   REQUIRE_VQ_EVIDENCE=1   -> require venue facts evidence check if tool exists
#   INTEGRATION_SMOKE=1     -> run docker-compose smoke in full mode
#   E2E=1                   -> run UI E2E gate (Playwright/Cypress or E2E_CMD)
#   E2E_CMD="..."           -> explicit E2E command to run
#   E2E_ARTIFACTS_DIR=...   -> where to collect E2E artifacts (default: artifacts/e2e)
#
log "5) Optional gates (only when enabled)"

# 5a) Venue facts evidence check (optional strictness)
REQUIRE_VQ_EVIDENCE="${REQUIRE_VQ_EVIDENCE:-0}"
if [[ -f "$ROOT/scripts/check_vq_evidence.py" ]]; then
  ensure_python
  "$PYTHON_BIN" "$ROOT/scripts/check_vq_evidence.py" || fail "Venue facts evidence check failed"
  echo "✓ venue evidence check passed"
else
  if [[ "$REQUIRE_VQ_EVIDENCE" == "1" ]]; then
    fail "REQUIRE_VQ_EVIDENCE=1 but scripts/check_vq_evidence.py is missing"
  else
    echo "info: venue evidence check skipped (scripts/check_vq_evidence.py not found)"
  fi
fi

# 5b) Promotion-grade F1 cert gate (explicit only)
REQUIRE_F1_CERT="${REQUIRE_F1_CERT:-0}"
RUN_F1_CERT="${RUN_F1_CERT:-0}"
F1_CERT="$ROOT/artifacts/F1_CERT.json"
F1_TOOL="$ROOT/python/tools/f1_certify.py"

if [[ "$VERIFY_MODE" == "promotion" || "$REQUIRE_F1_CERT" == "1" ]]; then
  log "5b) Promotion gates active"
  need jq

  # Generate cert if requested and tool exists
  if [[ "$RUN_F1_CERT" == "1" && -f "$F1_TOOL" ]]; then
    ensure_python
    mkdir -p "$ROOT/artifacts"
    "$PYTHON_BIN" "$F1_TOOL" --window=24h --out="$F1_CERT"
  fi

  [[ -f "$F1_CERT" ]] || fail "F1 cert required but missing: artifacts/F1_CERT.json"
  status="$(jq -r '.status // "MISSING"' "$F1_CERT")"
  [[ "$status" == "PASS" ]] || fail "F1 cert status=$status (must be PASS)"

  echo "✓ F1 cert PASS"
else
  # Not required; show info if present
  if [[ -f "$F1_CERT" ]] && command -v jq >/dev/null 2>&1; then
    status="$(jq -r '.status // "UNKNOWN"' "$F1_CERT" 2>/dev/null || echo UNKNOWN)"
    echo "info: F1 cert present (status=$status) [not required]"
  fi
fi

# 5c) Integration smoke (explicit only; full mode recommended)
INTEGRATION_SMOKE="${INTEGRATION_SMOKE:-0}"
if [[ "$MODE" == "full" && "$INTEGRATION_SMOKE" == "1" ]]; then
  log "5c) Integration smoke (docker compose)"

  if command -v docker >/dev/null 2>&1 && ([[ -f docker-compose.yml || -f compose.yml ]]); then
    cleanup() { docker compose down -v >/dev/null 2>&1 || true; }
    trap cleanup EXIT

    docker compose up -d --build

    # Optionally check one or more URLs (space-separated)
    # Example: SMOKE_URLS="http://localhost:8000/health http://localhost:8000/api/v1/status"
    SMOKE_URLS="${SMOKE_URLS:-}"
    if [[ -n "$SMOKE_URLS" ]]; then
      need curl
      for url in $SMOKE_URLS; do
        echo "checking $url"
        ok=0
        for i in {1..30}; do
          if curl -fsS "$url" >/dev/null 2>&1; then ok=1; break; fi
          sleep 1
        done
        [[ "$ok" == "1" ]] || fail "Smoke check failed: $url"
        echo "✓ smoke ok: $url"
      done
    else
      warn "SMOKE_URLS not set; docker stack started but no HTTP checks executed"
    fi
  else
    warn "docker compose not available; skipping integration smoke"
  fi
fi

# 5d) UI end-to-end verification (opt-in)
E2E="${E2E:-0}"
E2E_CMD="${E2E_CMD:-}"
E2E_ARTIFACTS_DIR="${E2E_ARTIFACTS_DIR:-$ROOT/artifacts/e2e/$VERIFY_RUN_ID}"

if [[ "$E2E" == "1" ]]; then
  log "5d) UI E2E (opt-in)"
  mkdir -p "$E2E_ARTIFACTS_DIR"

  e2e_ran=0

  if [[ -n "$E2E_CMD" ]]; then
    bash -lc "$E2E_CMD"
    e2e_ran=1
  else
    if [[ -f package.json ]]; then
      if node_script_exists "e2e"; then
        node_run_script "e2e"
        e2e_ran=1
      elif node_script_exists "test:e2e"; then
        node_run_script "test:e2e"
        e2e_ran=1
      fi
    fi

    if [[ "$e2e_ran" == "0" ]]; then
      if has_playwright_config || [[ -x "./node_modules/.bin/playwright" ]]; then
        if ! node_run_bin playwright test; then
          fail "Playwright config found but Playwright is not available (install deps or set E2E_CMD)"
        fi
        e2e_ran=1
      elif has_cypress_config || [[ -x "./node_modules/.bin/cypress" ]]; then
        if ! node_run_bin cypress run; then
          fail "Cypress config found but Cypress is not available (install deps or set E2E_CMD)"
        fi
        e2e_ran=1
      fi
    fi
  fi

  if [[ "$e2e_ran" == "0" ]]; then
    fail "E2E=1 but no E2E harness found. Set E2E_CMD or add Playwright/Cypress config."
  fi

  capture_e2e_artifacts
  echo "✓ e2e gate passed"
fi

if should_run_workflow_acceptance; then
  WORKFLOW_ACCEPTANCE_MODE="$(workflow_acceptance_mode)"
  log "6) Workflow acceptance (${WORKFLOW_ACCEPTANCE_MODE})"
  # VERIFY_WA_PARALLEL_INTEGRATION: full mode uses parallel acceptance runner when available
  if [[ "$WORKFLOW_ACCEPTANCE_MODE" == "full" && -x ./plans/workflow_acceptance_parallel.sh ]]; then
    WA_JOBS="$(workflow_acceptance_jobs)"
    log "    using parallel runner with $WA_JOBS workers"
    run_logged "workflow_acceptance" "$WORKFLOW_ACCEPTANCE_TIMEOUT" \
      ./plans/workflow_acceptance_parallel.sh --jobs "$WA_JOBS" --mode "$WORKFLOW_ACCEPTANCE_MODE"
  else
    run_logged "workflow_acceptance" "$WORKFLOW_ACCEPTANCE_TIMEOUT" \
      ./plans/workflow_acceptance.sh --mode "$WORKFLOW_ACCEPTANCE_MODE"
  fi
  echo "✓ workflow acceptance passed (${WORKFLOW_ACCEPTANCE_MODE})"
else
  if [[ "${CI:-}" == "" && "${WORKFLOW_ACCEPTANCE_POLICY}" == "never" ]]; then
    echo "info: workflow acceptance skipped (policy=never)"
  else
    echo "info: workflow acceptance skipped (no workflow file changes detected)"
  fi
fi

# Timing summary
log "Timing Summary"
for f in "${VERIFY_ARTIFACTS_DIR}"/*.time; do
  [[ -f "$f" ]] || continue  # handles no-match case (glob returns literal)
  name="$(basename "$f" .time)"
  elapsed="$(cat "$f")"
  statusf="${VERIFY_ARTIFACTS_DIR}/${name}.status"
  if [[ -f "$statusf" ]]; then
    status_val="$(cat "$statusf" 2>/dev/null || true)"
    if [[ "$status_val" == skipped:* ]]; then
      echo "  $name: ${elapsed}s (skipped)"
      continue
    fi
  fi
  echo "  $name: ${elapsed}s"
done

checkpoint_collect_gate_run_stats
checkpoint_counter_record_success
checkpoint_write_opportunity_telemetry
log "VERIFY OK (mode=$MODE)"
