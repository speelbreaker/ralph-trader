#!/usr/bin/env bash

if [[ -n "${__VERIFY_CHECKPOINT_SOURCED:-}" ]]; then
  return 0
fi
__VERIFY_CHECKPOINT_SOURCED=1

if ! declare -f warn >/dev/null 2>&1; then
  warn() { echo "WARN: $*" >&2; }
fi

checkpoint_python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo "python"
    return 0
  fi
  return 1
}

checkpoint_schema_file() {
  if [[ -n "${CHECKPOINT_SCHEMA_FILE:-}" ]]; then
    echo "$CHECKPOINT_SCHEMA_FILE"
    return 0
  fi
  echo "$ROOT/plans/schemas/verify_checkpoint.schema.json"
}

checkpoint_resolve_rollout() {
  local raw="${VERIFY_CHECKPOINT_ROLLOUT:-off}"
  CHECKPOINT_ROLLOUT_REASON=""
  case "$raw" in
    off|dry_run|enforce)
      CHECKPOINT_ROLLOUT="$raw"
      ;;
    *)
      CHECKPOINT_ROLLOUT="off"
      CHECKPOINT_ROLLOUT_REASON="rollout_invalid_value"
      warn "rollout_invalid_value: VERIFY_CHECKPOINT_ROLLOUT='$raw' forced to off"
      ;;
  esac
}

checkpoint_capture_snapshot() {
  local dirty="${1:-0}"
  local change_ok="${2:-0}"
  local mode="${3:-quick}"
  local verify_mode="${4:-none}"
  local ci="${5:-0}"

  CHECKPOINT_SNAPSHOT_DIRTY="$dirty"
  CHECKPOINT_SNAPSHOT_CHANGE_DETECTION_OK="$change_ok"
  CHECKPOINT_SNAPSHOT_MODE="$mode"
  CHECKPOINT_SNAPSHOT_VERIFY_MODE="$verify_mode"
  CHECKPOINT_SNAPSHOT_IS_CI="$ci"
}

checkpoint_schema_is_available() {
  local schema
  local pybin
  schema="$(checkpoint_schema_file)"
  if [[ ! -f "$schema" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_schema_unavailable"
    return 1
  fi

  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_schema_unavailable"
    return 1
  fi

  if ! "$pybin" - "$schema" <<'PY' >/dev/null 2>&1; then
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    schema = json.load(fh)
if not isinstance(schema, dict):
    raise SystemExit(1)
required = schema.get("required")
if not isinstance(required, list):
    raise SystemExit(1)
PY
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_schema_unavailable"
    return 1
  fi
  return 0
}

checkpoint_validate_current_file() {
  local file="${VERIFY_CHECKPOINT_FILE:-}"
  local schema
  local pybin

  if [[ -z "$file" || ! -f "$file" ]]; then
    return 0
  fi

  schema="$(checkpoint_schema_file)"
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_schema_invalid"
    return 1
  fi

  if ! "$pybin" - "$schema" "$file" <<'PY' >/dev/null 2>&1; then
import json
import sys

schema_path = sys.argv[1]
data_path = sys.argv[2]

with open(schema_path, "r", encoding="utf-8") as sf:
    schema = json.load(sf)
with open(data_path, "r", encoding="utf-8") as df:
    data = json.load(df)

def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)

def _matches_type(value, expected):
    if expected == "object":
        return isinstance(value, dict)
    if expected == "integer":
        return _is_int(value)
    if expected == "string":
        return isinstance(value, str)
    if expected == "array":
        return isinstance(value, list)
    if expected == "boolean":
        return isinstance(value, bool)
    return True

def _validate_required_and_properties(data_obj, schema_obj):
    if not isinstance(schema_obj, dict) or not isinstance(data_obj, dict):
        raise SystemExit(1)

    required = schema_obj.get("required", [])
    if not isinstance(required, list):
        raise SystemExit(1)
    for key in required:
        if key not in data_obj:
            raise SystemExit(1)

    properties = schema_obj.get("properties", {})
    if not isinstance(properties, dict):
        return
    for key, prop in properties.items():
        if key not in data_obj:
            continue
        if not isinstance(prop, dict):
            continue
        value = data_obj[key]
        expected_type = prop.get("type")
        if expected_type and not _matches_type(value, expected_type):
            raise SystemExit(1)
        if "const" in prop and value != prop["const"]:
            raise SystemExit(1)
        enum_values = prop.get("enum")
        if isinstance(enum_values, list) and value not in enum_values:
            raise SystemExit(1)
        minimum = prop.get("minimum")
        if minimum is not None:
            if not _is_int(value) or value < minimum:
                raise SystemExit(1)

if not isinstance(schema, dict) or not isinstance(data, dict):
    raise SystemExit(1)

_validate_required_and_properties(data, schema)

skip_schema = schema.get("properties", {}).get("skip_cache")
skip_data = data.get("skip_cache")
if not isinstance(skip_schema, dict) or not isinstance(skip_data, dict):
    raise SystemExit(1)
_validate_required_and_properties(skip_data, skip_schema)

schema_version = data.get("schema_version", 0)
if not _is_int(schema_version) or schema_version < 2:
    raise SystemExit(1)
PY
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_schema_invalid"
    return 1
  fi
  return 0
}

checkpoint_read_kill_switch_token() {
  local file="${VERIFY_CHECKPOINT_FILE:-}"
  local pybin
  if [[ -z "$file" || ! -f "$file" ]]; then
    return 0
  fi
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    return 0
  fi
  "$pybin" - "$file" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    token = data.get("skip_cache", {}).get("kill_switch_token", "")
    if isinstance(token, str):
        print(token)
except Exception:
    pass
PY
}

checkpoint_enforce_kill_switch_policy() {
  if [[ "${CHECKPOINT_ROLLOUT:-off}" != "enforce" ]]; then
    return 0
  fi
  if [[ -z "${VERIFY_CHECKPOINT_KILL_SWITCH:-}" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="kill_switch_unset"
    return 1
  fi
  local current_token
  current_token="$(checkpoint_read_kill_switch_token)"
  if [[ -n "$current_token" && "$current_token" != "${VERIFY_CHECKPOINT_KILL_SWITCH:-}" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="kill_switch_mismatch"
    return 1
  fi
  return 0
}

checkpoint_existing_schema_version() {
  local file="${1:-${VERIFY_CHECKPOINT_FILE:-}}"
  local pybin
  if [[ -z "$file" || ! -f "$file" ]]; then
    return 0
  fi
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    return 0
  fi
  "$pybin" - "$file" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    version = data.get("schema_version")
    if isinstance(version, int):
        print(version)
except Exception:
    pass
PY
}

checkpoint_no_downgrade_ok() {
  local target_version="${1:?target schema version required}"
  local existing
  existing="$(checkpoint_existing_schema_version "${2:-}")"
  if [[ -z "$existing" ]]; then
    return 0
  fi
  if [[ "$existing" =~ ^[0-9]+$ ]] && (( existing > target_version )); then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_schema_downgrade"
    return 1
  fi
  return 0
}

checkpoint_now_epoch() {
  local now="${VERIFY_CHECKPOINT_NOW_EPOCH:-}"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    echo "$now"
    return 0
  fi
  date +%s
}

checkpoint_now_millis() {
  local now="${VERIFY_CHECKPOINT_NOW_EPOCH_MS:-}"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    echo "$now"
    return 0
  fi
  local secs
  secs="$(checkpoint_now_epoch)"
  if [[ "$secs" =~ ^[0-9]+$ ]]; then
    echo $((secs * 1000))
    return 0
  fi
  echo 0
}

checkpoint_read_skip_cache_ts() {
  local file="${VERIFY_CHECKPOINT_FILE:-}"
  local pybin
  if [[ -z "$file" || ! -f "$file" ]]; then
    return 0
  fi
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    return 0
  fi
  "$pybin" - "$file" <<'PY' 2>/dev/null || true
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    ts = data.get("skip_cache", {}).get("ts")
    if isinstance(ts, int) and ts >= 0:
        print(ts)
except Exception:
    pass
PY
}

checkpoint_age_within_limit() {
  local max_age="${VERIFY_CHECKPOINT_MAX_AGE_SECS:-86400}"
  if [[ ! "$max_age" =~ ^[0-9]+$ ]]; then
    max_age=86400
  fi
  if (( max_age <= 0 )); then
    return 0
  fi
  local ts
  ts="$(checkpoint_read_skip_cache_ts)"
  if [[ -z "$ts" ]]; then
    return 0
  fi
  if [[ ! "$ts" =~ ^[0-9]+$ ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_schema_invalid"
    return 1
  fi
  local now
  now="$(checkpoint_now_epoch)"
  if [[ ! "$now" =~ ^[0-9]+$ ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_now_invalid"
    return 1
  fi
  if (( now < ts )); then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_ts_in_future"
    return 1
  fi
  if (( now - ts > max_age )); then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_age_exceeded"
    return 1
  fi
  return 0
}

checkpoint_lock_file() {
  if [[ -n "${VERIFY_CHECKPOINT_LOCK_FILE:-}" ]]; then
    echo "$VERIFY_CHECKPOINT_LOCK_FILE"
    return 0
  fi
  local checkpoint_file="${VERIFY_CHECKPOINT_FILE:-$ROOT/.ralph/verify_checkpoint.json}"
  echo "$(dirname "$checkpoint_file")/verify_checkpoint.lock"
}

checkpoint_lock_save_traps() {
  CHECKPOINT_LOCK_PREV_EXIT_TRAP="$(trap -p EXIT | sed "s/^trap -- '\\(.*\\)' EXIT$/\\1/")"
  CHECKPOINT_LOCK_PREV_INT_TRAP="$(trap -p INT | sed "s/^trap -- '\\(.*\\)' INT$/\\1/")"
  CHECKPOINT_LOCK_PREV_TERM_TRAP="$(trap -p TERM | sed "s/^trap -- '\\(.*\\)' TERM$/\\1/")"
}

checkpoint_lock_restore_traps() {
  if [[ -n "${CHECKPOINT_LOCK_PREV_EXIT_TRAP:-}" ]]; then
    trap "$CHECKPOINT_LOCK_PREV_EXIT_TRAP" EXIT
  else
    trap - EXIT
  fi
  if [[ -n "${CHECKPOINT_LOCK_PREV_INT_TRAP:-}" ]]; then
    trap "$CHECKPOINT_LOCK_PREV_INT_TRAP" INT
  else
    trap - INT
  fi
  if [[ -n "${CHECKPOINT_LOCK_PREV_TERM_TRAP:-}" ]]; then
    trap "$CHECKPOINT_LOCK_PREV_TERM_TRAP" TERM
  else
    trap - TERM
  fi
}

checkpoint_lock_release() {
  if [[ "${CHECKPOINT_LOCK_HELD:-0}" != "1" ]]; then
    return 0
  fi
  if [[ -n "${CHECKPOINT_LOCK_FILE:-}" ]]; then
    rm -f "$CHECKPOINT_LOCK_FILE" 2>/dev/null || true
  fi
  CHECKPOINT_LOCK_HELD=0
  CHECKPOINT_LOCK_FILE=""
  return 0
}

checkpoint_lock_try_recover_stale() {
  local lock_file="${1:?lock file required}"
  local stale_secs="${2:-600}"
  if [[ ! -f "$lock_file" ]]; then
    return 1
  fi

  local pid=""
  local started=""
  pid="$(awk -F= '/^pid=/{print $2; exit}' "$lock_file" 2>/dev/null || true)"
  started="$(awk -F= '/^start_epoch=/{print $2; exit}' "$lock_file" 2>/dev/null || true)"
  [[ "$started" =~ ^[0-9]+$ ]] || started=0

  local now age
  now="$(checkpoint_now_epoch)"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  if (( now < started )); then
    age=0
  else
    age=$(( now - started ))
  fi

  if (( age < stale_secs )); then
    return 1
  fi
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  rm -f "$lock_file" 2>/dev/null || return 1
  CHECKPOINT_LOCK_EVENT="checkpoint_lock_stale_recovered"
  return 0
}

checkpoint_lock_acquire() {
  if [[ "${CHECKPOINT_LOCK_HELD:-0}" == "1" ]]; then
    return 0
  fi

  local lock_file timeout_secs stale_secs start now
  lock_file="$(checkpoint_lock_file)"
  timeout_secs="${VERIFY_CHECKPOINT_LOCK_TIMEOUT_SECS:-5}"
  stale_secs="${VERIFY_CHECKPOINT_LOCK_STALE_SECS:-600}"
  [[ "$timeout_secs" =~ ^[0-9]+$ ]] || timeout_secs=5
  [[ "$stale_secs" =~ ^[0-9]+$ ]] || stale_secs=600
  (( timeout_secs < 1 )) && timeout_secs=1
  (( stale_secs < 1 )) && stale_secs=1

  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  start="$(checkpoint_now_epoch)"
  [[ "$start" =~ ^[0-9]+$ ]] || start=0

  while true; do
    if ( set -o noclobber; : > "$lock_file" ) 2>/dev/null; then
      printf 'pid=%s\nstart_epoch=%s\n' "$$" "$(checkpoint_now_epoch)" >"$lock_file"
      CHECKPOINT_LOCK_FILE="$lock_file"
      CHECKPOINT_LOCK_HELD=1
      checkpoint_lock_save_traps
      trap checkpoint_lock_release EXIT INT TERM
      return 0
    fi

    checkpoint_lock_try_recover_stale "$lock_file" "$stale_secs" && continue

    now="$(checkpoint_now_epoch)"
    [[ "$now" =~ ^[0-9]+$ ]] || now=0
    if (( now - start >= timeout_secs )); then
      CHECKPOINT_INELIGIBLE_REASON="checkpoint_lock_unavailable"
      return 1
    fi
    sleep 1
  done
}

checkpoint_lock_probe_available() {
  if [[ "${CHECKPOINT_LOCK_PROBE_DONE:-0}" == "1" ]]; then
    if [[ "${CHECKPOINT_LOCK_PROBE_OK:-0}" == "1" ]]; then
      return 0
    fi
    return 1
  fi
  CHECKPOINT_LOCK_PROBE_DONE=1
  if ! checkpoint_lock_acquire; then
    CHECKPOINT_LOCK_PROBE_OK=0
    return 1
  fi
  CHECKPOINT_LOCK_PROBE_OK=1
  checkpoint_lock_release
  checkpoint_lock_restore_traps
  return 0
}

checkpoint_realpath() {
  local p="${1:?path required}"
  local pybin
  pybin="$(checkpoint_python_bin || true)"
  if [[ -n "$pybin" ]]; then
    "$pybin" - "$p" <<'PY' 2>/dev/null || echo "$p"
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi
  echo "$p"
}

checkpoint_is_trusted_path() {
  local file="${VERIFY_CHECKPOINT_FILE:-}"
  if [[ -z "$file" ]]; then
    return 0
  fi
  local resolved_file repo_dir home_dir resolved_dir
  resolved_file="$(checkpoint_realpath "$file")"
  resolved_dir="${resolved_file%/*}"
  repo_dir="$(checkpoint_realpath "$ROOT/.ralph/verify_checkpoint.json")"
  repo_dir="${repo_dir%/*}"
  home_dir="$(checkpoint_realpath "$HOME/.ralph/verify_checkpoint.json")"
  home_dir="${home_dir%/*}"

  if [[ "$resolved_dir" == "$repo_dir" || "$resolved_dir" == "$home_dir" ]]; then
    return 0
  fi
  CHECKPOINT_INELIGIBLE_REASON="checkpoint_untrusted_path"
  return 1
}

checkpoint_read_writer_ci() {
  local file="${VERIFY_CHECKPOINT_FILE:-}"
  local pybin
  if [[ -z "$file" || ! -f "$file" ]]; then
    echo "0"
    return 0
  fi
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    echo "0"
    return 0
  fi
  "$pybin" - "$file" <<'PY' 2>/dev/null || echo "0"
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    writer = data.get("skip_cache", {}).get("writer_ci", False)
    if writer is True or writer == 1 or str(writer).lower() in ("1", "true", "yes"):
        print("1")
    else:
        print("0")
except Exception:
    print("0")
PY
}

checkpoint_reader_is_local() {
  if [[ "${CHECKPOINT_SNAPSHOT_IS_CI:-0}" == "1" ]]; then
    return 0
  fi
  local writer_ci
  writer_ci="$(checkpoint_read_writer_ci)"
  if [[ "$writer_ci" == "1" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="writer_ci"
    return 1
  fi
  return 0
}

is_cache_eligible() {
  CHECKPOINT_INELIGIBLE_REASON=""

  if [[ "${CHECKPOINT_SNAPSHOT_IS_CI:-0}" == "1" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="ci_environment"
    return 1
  fi
  if [[ "${CHECKPOINT_SNAPSHOT_DIRTY:-0}" == "1" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="dirty_worktree"
    return 1
  fi
  if [[ "${CHECKPOINT_SNAPSHOT_CHANGE_DETECTION_OK:-0}" != "1" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="change_detection_unavailable"
    return 1
  fi
  if [[ "${CHECKPOINT_SNAPSHOT_MODE:-}" != "quick" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="mode_not_quick"
    return 1
  fi
  if [[ "${CHECKPOINT_SNAPSHOT_VERIFY_MODE:-none}" == "promotion" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="promotion_mode"
    return 1
  fi
  if [[ "${CHECKPOINT_HASH_BUDGET_EXCEEDED:-0}" == "1" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_hash_budget_exceeded"
    return 1
  fi
  if ! checkpoint_is_trusted_path; then
    return 1
  fi
  if ! checkpoint_reader_is_local; then
    return 1
  fi
  if ! checkpoint_lock_probe_available; then
    return 1
  fi
  if ! checkpoint_schema_is_available; then
    return 1
  fi
  if ! checkpoint_validate_current_file; then
    return 1
  fi
  if ! checkpoint_age_within_limit; then
    return 1
  fi
  if ! checkpoint_enforce_kill_switch_policy; then
    return 1
  fi
  return 0
}

checkpoint_is_cache_eligible() {
  is_cache_eligible
}

checkpoint_decide_skip_gate() {
  local gate="${1:-unknown_gate}"
  CHECKPOINT_DECISION_GATE="$gate"
  CHECKPOINT_DECISION_ACTION="run"
  CHECKPOINT_DECISION_REASON="rollout_off"

  if [[ -n "${CHECKPOINT_ROLLOUT_REASON:-}" ]]; then
    CHECKPOINT_DECISION_REASON="$CHECKPOINT_ROLLOUT_REASON"
    return 1
  fi
  if [[ "${CHECKPOINT_NON_TTY_DEFAULT_OFF:-0}" == "1" && "${CHECKPOINT_ROLLOUT:-off}" == "off" ]]; then
    CHECKPOINT_DECISION_REASON="non_tty_default_off"
    return 1
  fi

  if ! is_cache_eligible; then
    CHECKPOINT_DECISION_REASON="${CHECKPOINT_INELIGIBLE_REASON:-cache_ineligible}"
    return 1
  fi

  case "${CHECKPOINT_ROLLOUT:-off}" in
    off) CHECKPOINT_DECISION_REASON="rollout_off" ;;
    dry_run) CHECKPOINT_DECISION_REASON="dry_run_no_skip_authority" ;;
    enforce) CHECKPOINT_DECISION_REASON="enforce_skip_not_implemented" ;;
    *) CHECKPOINT_DECISION_REASON="rollout_invalid_value" ;;
  esac
  return 1
}
