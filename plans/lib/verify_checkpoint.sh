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

  "$pybin" - "$schema" <<'PY' >/dev/null 2>&1
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
  if [[ "$?" != "0" ]]; then
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

  "$pybin" - "$schema" "$file" <<'PY' >/dev/null 2>&1
import json
import sys

schema_path = sys.argv[1]
data_path = sys.argv[2]

with open(schema_path, "r", encoding="utf-8") as sf:
    schema = json.load(sf)
with open(data_path, "r", encoding="utf-8") as df:
    data = json.load(df)

if not isinstance(schema, dict) or not isinstance(data, dict):
    raise SystemExit(1)

required_top = schema.get("required", [])
if not isinstance(required_top, list):
    raise SystemExit(1)
for key in required_top:
    if key not in data:
        raise SystemExit(1)

if not isinstance(data.get("skip_cache"), dict):
    raise SystemExit(1)
if int(data.get("schema_version", 0)) < 2:
    raise SystemExit(1)
PY
  if [[ "$?" != "0" ]]; then
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
  if ! checkpoint_schema_is_available; then
    return 1
  fi
  if ! checkpoint_validate_current_file; then
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
