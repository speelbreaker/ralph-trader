#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECKPOINT_FILE="${VERIFY_CHECKPOINT_FILE:-$ROOT/.ralph/verify_checkpoint.json}"
ROLL_RAW="${VERIFY_CHECKPOINT_ROLLOUT:-}"
ROLL_EFFECTIVE="${ROLL_RAW:-off}"
ROLL_SOURCE="default_off"

if [[ ! -t 1 && -z "$ROLL_RAW" ]]; then
  ROLL_EFFECTIVE="off"
  ROLL_SOURCE="non_tty_default_off"
elif [[ -n "$ROLL_RAW" ]]; then
  ROLL_SOURCE="env"
fi

case "$ROLL_EFFECTIVE" in
  off|dry_run|enforce)
    ;;
  *)
    if [[ "$ROLL_SOURCE" == "env" ]]; then
      ROLL_SOURCE="env_invalid_forced_off"
    else
      ROLL_SOURCE="invalid_forced_off"
    fi
    ROLL_EFFECTIVE="off"
    ;;
esac

show_help() {
  cat <<'EOF'
Usage: ./plans/verify_skip_status.sh [--help]

Prints effective checkpoint skip policy and recent checkpoint metadata.
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

if [[ "${1:-}" != "" ]]; then
  echo "FAIL: unknown argument: $1" >&2
  show_help >&2
  exit 2
fi

echo "rollout_effective=$ROLL_EFFECTIVE"
echo "rollout_source=$ROLL_SOURCE"
echo "skip_flag=${VERIFY_CHECKPOINT_SKIP:-0}"
echo "kill_switch_set=$([[ -n "${VERIFY_CHECKPOINT_KILL_SWITCH:-}" ]] && echo 1 || echo 0)"
echo "max_age_secs=${VERIFY_CHECKPOINT_MAX_AGE_SECS:-86400}"
echo "max_consec_skips=${VERIFY_CHECKPOINT_MAX_CONSEC_SKIPS:-10}"
echo "force_after_secs=${VERIFY_CHECKPOINT_FORCE_AFTER_SECS:-21600}"
echo "hash_target_ms=${VERIFY_CHECKPOINT_HASH_TARGET_MS:-500}"
echo "hash_budget_ms=${VERIFY_CHECKPOINT_HASH_BUDGET_MS:-2000}"
echo "telemetry_dir=${VERIFY_CHECKPOINT_TELEMETRY_DIR:-$ROOT/.ralph/verify_telemetry}"
echo "telemetry_max_files=${VERIFY_CHECKPOINT_TELEMETRY_MAX_FILES:-200}"
echo "telemetry_max_bytes=${VERIFY_CHECKPOINT_TELEMETRY_MAX_BYTES:-20971520}"
echo "telemetry_ttl_days=${VERIFY_CHECKPOINT_TELEMETRY_TTL_DAYS:-mode_default}"
echo "checkpoint_file=$CHECKPOINT_FILE"

if [[ ! -f "$CHECKPOINT_FILE" ]]; then
  echo "checkpoint_exists=0"
  exit 0
fi
echo "checkpoint_exists=1"

if command -v python3 >/dev/null 2>&1; then
  pybin="python3"
elif command -v python >/dev/null 2>&1; then
  pybin="python"
else
  echo "checkpoint_parse_error=missing_python"
  exit 0
fi

"$pybin" - "$CHECKPOINT_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("checkpoint_parse_error=invalid_json")
    raise SystemExit(0)

skip = data.get("skip_cache", {}) if isinstance(data.get("skip_cache", {}), dict) else {}
last = data.get("last_success", {}) if isinstance(data.get("last_success", {}), dict) else {}

def emit(key, value):
    if isinstance(value, bool):
        value = "1" if value else "0"
    elif value is None:
        value = ""
    print(f"{key}={value}")

emit("checkpoint_schema_version", data.get("schema_version", ""))
emit("skip_cache_schema_version", skip.get("schema_version", ""))
emit("skip_cache_ts", skip.get("ts", ""))
emit("skip_cache_rollout", skip.get("rollout", ""))
emit("skip_cache_writer_ci", skip.get("writer_ci", ""))
emit("skip_cache_writer_mode", skip.get("writer_mode", ""))
emit("skip_cache_written_by_verify_sh_sha", skip.get("written_by_verify_sh_sha", ""))
emit("last_run_skipped_gate_count", data.get("last_run_skipped_gate_count", ""))
emit("last_run_scheduled_gate_count", data.get("last_run_scheduled_gate_count", ""))
emit("last_run_hash_phase_ms", data.get("last_run_hash_phase_ms", ""))
emit("last_success_ineligible_reason", last.get("ineligible_reason", ""))
PY
