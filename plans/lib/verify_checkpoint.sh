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
    if expected == "number":
        return (isinstance(value, int) or isinstance(value, float)) and not isinstance(value, bool)
    if expected == "string":
        return isinstance(value, str)
    if expected == "array":
        return isinstance(value, list)
    if expected == "boolean":
        return isinstance(value, bool)
    return True

def _validate(value, schema_obj):
    if not isinstance(schema_obj, dict):
        return

    expected_type = schema_obj.get("type")
    if expected_type and not _matches_type(value, expected_type):
        raise SystemExit(1)

    if "const" in schema_obj and value != schema_obj["const"]:
        raise SystemExit(1)

    enum_values = schema_obj.get("enum")
    if isinstance(enum_values, list) and value not in enum_values:
        raise SystemExit(1)

    minimum = schema_obj.get("minimum")
    if minimum is not None:
        if not _is_int(value) or value < minimum:
            raise SystemExit(1)

    if isinstance(value, dict):
        required = schema_obj.get("required", [])
        if required is not None and not isinstance(required, list):
            raise SystemExit(1)
        for key in required or []:
            if key not in value:
                raise SystemExit(1)

        properties = schema_obj.get("properties", {})
        if properties is not None and not isinstance(properties, dict):
            raise SystemExit(1)
        properties = properties or {}
        for key, prop_schema in properties.items():
            if key in value:
                _validate(value[key], prop_schema)

        additional = schema_obj.get("additionalProperties", None)
        if isinstance(additional, dict):
            for key, item in value.items():
                if key not in properties:
                    _validate(item, additional)
        elif additional is False:
            for key in value:
                if key not in properties:
                    raise SystemExit(1)

    if isinstance(value, list):
        items_schema = schema_obj.get("items")
        if isinstance(items_schema, dict):
            for item in value:
                _validate(item, items_schema)

if not isinstance(schema, dict) or not isinstance(data, dict):
    raise SystemExit(1)

_validate(data, schema)

allowed_gate_keys = {"contract_coverage", "spec_validators_group"}
gates = data.get("skip_cache", {}).get("gates", {})
if not isinstance(gates, dict):
    raise SystemExit(1)
for gate_key in gates:
    if gate_key not in allowed_gate_keys:
        raise SystemExit(1)

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

checkpoint_extract_semver() {
  local raw="${1:-}"
  local ver
  ver="$(printf '%s\n' "$raw" | sed -E 's/.*([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' | head -n 1)"
  if [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$ver"
    return 0
  fi
  return 1
}

checkpoint_probe_tool_version() {
  local cmd="$1"
  shift
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing"
    return 0
  fi
  local raw
  raw="$("$cmd" "$@" 2>&1 | head -n 1 || true)"
  if [[ -z "$raw" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="toolchain_probe_failed"
    return 1
  fi
  local parsed
  parsed="$(checkpoint_extract_semver "$raw" || true)"
  if [[ -n "$parsed" ]]; then
    echo "$parsed"
    return 0
  fi
  # Fall back to normalized raw output when semver extraction fails.
  echo "$raw" | tr '[:space:]' '_' | tr -cd '[:alnum:]_.-'
  return 0
}

checkpoint_tool_versions_json() {
  if [[ -n "${CHECKPOINT_TOOL_VERSIONS_JSON:-}" ]]; then
    echo "$CHECKPOINT_TOOL_VERSIONS_JSON"
    return 0
  fi
  local py jqv rgv
  py="$(checkpoint_probe_tool_version python3 --version || true)"
  if [[ -z "$py" || "$py" == "missing" ]]; then
    py="$(checkpoint_probe_tool_version python --version || true)"
  fi
  jqv="$(checkpoint_probe_tool_version jq --version || true)"
  rgv="$(checkpoint_probe_tool_version rg --version || true)"
  if [[ -z "$py" || -z "$jqv" || -z "$rgv" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="toolchain_probe_failed"
    return 1
  fi
  CHECKPOINT_TOOL_VERSIONS_JSON="$(printf '{"python":"%s","jq":"%s","rg":"%s"}' "$py" "$jqv" "$rgv")"
  echo "$CHECKPOINT_TOOL_VERSIONS_JSON"
}

checkpoint_env_manifest_file() {
  if [[ -n "${CHECKPOINT_ENV_MANIFEST_FILE:-}" ]]; then
    echo "$CHECKPOINT_ENV_MANIFEST_FILE"
    return 0
  fi
  echo "$ROOT/plans/checkpoint_fingerprint_env_manifest.txt"
}

checkpoint_override_fingerprint() {
  if [[ -n "${CHECKPOINT_OVERRIDE_FINGERPRINT:-}" ]]; then
    echo "$CHECKPOINT_OVERRIDE_FINGERPRINT"
    return 0
  fi
  local manifest pybin
  manifest="$(checkpoint_env_manifest_file)"
  if [[ ! -f "$manifest" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_manifest_unavailable"
    return 1
  fi
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_manifest_unavailable"
    return 1
  fi
  CHECKPOINT_OVERRIDE_FINGERPRINT="$("$pybin" - "$manifest" <<'PY' 2>/dev/null || true
import hashlib
import os
import sys

manifest = sys.argv[1]
keys = []
with open(manifest, "r", encoding="utf-8") as fh:
    for line in fh:
        key = line.strip()
        if not key or key.startswith("#"):
            continue
        keys.append(key)

payload = []
for key in sorted(set(keys)):
    payload.append(f"{key}={os.environ.get(key, '')}")

digest = hashlib.sha256("\n".join(payload).encode("utf-8")).hexdigest()
print(digest)
PY
)"
  if [[ ! "${CHECKPOINT_OVERRIDE_FINGERPRINT:-}" =~ ^[0-9a-f]{64}$ ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_manifest_invalid"
    return 1
  fi
  echo "$CHECKPOINT_OVERRIDE_FINGERPRINT"
}

checkpoint_dependency_manifest_file() {
  if [[ -n "${CHECKPOINT_DEPENDENCY_MANIFEST_FILE:-}" ]]; then
    echo "$CHECKPOINT_DEPENDENCY_MANIFEST_FILE"
    return 0
  fi
  echo "$ROOT/plans/checkpoint_dependency_manifest.json"
}

checkpoint_gate_input_hash() {
  local gate="${1:?gate required}"
  local cache_var
  case "$gate" in
    contract_coverage) cache_var="CHECKPOINT_INPUT_HASH_CONTRACT_COVERAGE" ;;
    spec_validators_group) cache_var="CHECKPOINT_INPUT_HASH_SPEC_VALIDATORS_GROUP" ;;
    *)
      CHECKPOINT_INELIGIBLE_REASON="gate_not_allowlisted"
      return 1
      ;;
  esac

  eval "local cached=\${$cache_var:-}"
  if [[ -n "${cached:-}" ]]; then
    echo "$cached"
    return 0
  fi

  local manifest pybin
  manifest="$(checkpoint_dependency_manifest_file)"
  if [[ ! -f "$manifest" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_manifest_unavailable"
    return 1
  fi
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    CHECKPOINT_INELIGIBLE_REASON="checkpoint_manifest_unavailable"
    return 1
  fi

  local out rc
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac
  set +e
  out="$("$pybin" - "$manifest" "$ROOT" "$gate" <<'PY' 2>&1
import hashlib
import json
import os
import sys

manifest_path = sys.argv[1]
root = os.path.realpath(sys.argv[2])
gate = sys.argv[3]

def fail(msg):
    print(msg)
    raise SystemExit(2)

try:
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
except Exception as exc:
    fail(f"manifest_read_error:{exc}")

if not isinstance(manifest, dict):
    fail("manifest_invalid")

shared = manifest.get("shared", [])
gates = manifest.get("gates", {})
if not isinstance(shared, list) or not isinstance(gates, dict):
    fail("manifest_invalid")
if gate not in gates:
    fail("gate_not_allowlisted")

paths = []
for item in shared + gates.get(gate, []):
    if not isinstance(item, str) or not item.strip():
        fail("manifest_invalid")
    p = os.path.realpath(os.path.join(root, item))
    if not p.startswith(root + os.sep) and p != root:
        fail("dependency_outside_repo")
    paths.append((item, p))

def hash_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()

rows = []
for rel, abspath in paths:
    if not os.path.exists(abspath):
        fail(f"dependency_missing:{rel}")
    if os.path.isdir(abspath):
        files = []
        for dirpath, _, filenames in os.walk(abspath):
            for name in filenames:
                fpath = os.path.join(dirpath, name)
                rel_f = os.path.relpath(fpath, root)
                files.append((rel_f, fpath))
        files.sort()
        for rel_f, fpath in files:
            rows.append(f"{rel_f}:{hash_file(fpath)}")
    else:
        rel_f = os.path.relpath(abspath, root)
        rows.append(f"{rel_f}:{hash_file(abspath)}")

payload = "\n".join(rows).encode("utf-8")
print(hashlib.sha256(payload).hexdigest())
PY
)"
  rc=$?
  if [[ "$had_errexit" == "1" ]]; then
    set -e
  fi
  if [[ "$rc" -ne 0 || ! "$out" =~ ^[0-9a-f]{64}$ ]]; then
    case "$out" in
      *dependency_outside_repo*) CHECKPOINT_INELIGIBLE_REASON="dependency_outside_repo" ;;
      *dependency_missing*) CHECKPOINT_INELIGIBLE_REASON="dependency_missing" ;;
      *gate_not_allowlisted*) CHECKPOINT_INELIGIBLE_REASON="gate_not_allowlisted" ;;
      *manifest*) CHECKPOINT_INELIGIBLE_REASON="checkpoint_manifest_invalid" ;;
      *) CHECKPOINT_INELIGIBLE_REASON="gate_input_hash_failed" ;;
    esac
    return 1
  fi

  eval "$cache_var='$out'"
  echo "$out"
}

checkpoint_evaluate_gate_skip() {
  local gate="${1:?gate required}"
  local input_hash="${2:?input hash required}"
  local override_fingerprint="${3:?override fingerprint required}"
  local tool_versions_json="${4:?tool versions json required}"
  local pybin
  pybin="$(checkpoint_python_bin || true)"
  if [[ -z "$pybin" ]]; then
    CHECKPOINT_DECISION_REASON="toolchain_probe_failed"
    return 1
  fi
  if [[ -z "${VERIFY_CHECKPOINT_FILE:-}" || ! -f "${VERIFY_CHECKPOINT_FILE:-}" ]]; then
    CHECKPOINT_DECISION_REASON="checkpoint_missing"
    return 1
  fi

  local now_epoch
  now_epoch="$(checkpoint_now_epoch)"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch="$(date +%s)"

  local eval_out eval_rc
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac
  set +e
  eval_out="$(
    CURRENT_GATE="$gate" \
    CURRENT_GATE_INPUT_HASH="$input_hash" \
    CURRENT_OVERRIDE_FINGERPRINT="$override_fingerprint" \
    CURRENT_TOOL_VERSIONS_JSON="$tool_versions_json" \
    CURRENT_VERIFY_SH_SHA="${VERIFY_SH_SHA:-}" \
    CURRENT_BASE_REF="${BASE_REF:-}" \
    CURRENT_HEAD_SHA="${CHECKPOINT_HEAD_SHA:-}" \
    CURRENT_HEAD_TREE="${CHECKPOINT_HEAD_TREE:-}" \
    CURRENT_MODE="${CHECKPOINT_SNAPSHOT_MODE:-}" \
    CURRENT_VERIFY_MODE="${CHECKPOINT_SNAPSHOT_VERIFY_MODE:-none}" \
    CURRENT_CHANGED_FILES_HASH="${CHECKPOINT_CHANGED_FILES_HASH:-}" \
    CURRENT_NOW_EPOCH="$now_epoch" \
    CURRENT_MAX_CONSEC_SKIPS="${VERIFY_CHECKPOINT_MAX_CONSEC_SKIPS:-10}" \
    CURRENT_FORCE_AFTER_SECS="${VERIFY_CHECKPOINT_FORCE_AFTER_SECS:-21600}" \
    "$pybin" - "$VERIFY_CHECKPOINT_FILE" <<'PY'
import json
import os
import sys

path = sys.argv[1]

def emit(reason, rc):
    print(reason)
    raise SystemExit(rc)

def to_int(raw, default=0):
    try:
        return int(raw)
    except Exception:
        return default

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    emit("checkpoint_schema_invalid", 1)

skip = data.get("skip_cache")
if not isinstance(skip, dict):
    emit("checkpoint_schema_invalid", 1)

required = [
    "written_by_verify_sh_sha",
    "verify_sh_sha",
    "base_ref",
    "head_sha",
    "head_tree",
    "mode",
    "verify_mode",
    "changed_files_hash",
    "override_fingerprint",
    "tool_versions",
    "gates",
]
for key in required:
    if key not in skip:
        emit("checkpoint_schema_invalid", 1)

expect = {
    "written_by_verify_sh_sha": os.environ.get("CURRENT_VERIFY_SH_SHA", ""),
    "verify_sh_sha": os.environ.get("CURRENT_VERIFY_SH_SHA", ""),
    "base_ref": os.environ.get("CURRENT_BASE_REF", ""),
    "head_sha": os.environ.get("CURRENT_HEAD_SHA", ""),
    "head_tree": os.environ.get("CURRENT_HEAD_TREE", ""),
    "mode": os.environ.get("CURRENT_MODE", ""),
    "verify_mode": os.environ.get("CURRENT_VERIFY_MODE", "none"),
    "changed_files_hash": os.environ.get("CURRENT_CHANGED_FILES_HASH", ""),
    "override_fingerprint": os.environ.get("CURRENT_OVERRIDE_FINGERPRINT", ""),
}
reason_map = {
    "written_by_verify_sh_sha": "verify_sh_sha_mismatch",
    "verify_sh_sha": "verify_sh_sha_mismatch",
    "base_ref": "base_ref_mismatch",
    "head_sha": "head_sha_mismatch",
    "head_tree": "head_tree_mismatch",
    "mode": "mode_mismatch",
    "verify_mode": "verify_mode_mismatch",
    "changed_files_hash": "changed_files_hash_mismatch",
    "override_fingerprint": "override_fingerprint_mismatch",
}
for key, expected in expect.items():
    if str(skip.get(key, "")) != str(expected):
        emit(reason_map[key], 1)

try:
    expected_tools = json.loads(os.environ.get("CURRENT_TOOL_VERSIONS_JSON", "{}"))
except Exception:
    emit("toolchain_probe_failed", 1)
if not isinstance(skip.get("tool_versions"), dict) or skip.get("tool_versions") != expected_tools:
    emit("tool_versions_mismatch", 1)

gates = skip.get("gates")
if not isinstance(gates, dict):
    emit("checkpoint_schema_invalid", 1)
gate = os.environ.get("CURRENT_GATE", "")
gate_data = gates.get(gate)
if not isinstance(gate_data, dict):
    emit("gate_not_cached", 1)
if str(gate_data.get("input_hash", "")) != os.environ.get("CURRENT_GATE_INPUT_HASH", ""):
    emit("gate_input_hash_mismatch", 1)

max_consec = to_int(os.environ.get("CURRENT_MAX_CONSEC_SKIPS", "10"), 10)
force_after = to_int(os.environ.get("CURRENT_FORCE_AFTER_SECS", "21600"), 21600)
now_epoch = to_int(os.environ.get("CURRENT_NOW_EPOCH", "0"), 0)
consecutive = to_int(gate_data.get("consecutive_skips", 0), 0)
last_real = to_int(gate_data.get("last_real_run_ts", 0), 0)
if max_consec > 0 and consecutive >= max_consec:
    emit("forced_run_max_consecutive_skips", 1)
if force_after > 0:
    if last_real <= 0:
        emit("forced_run_missing_last_real_run", 1)
    if now_epoch > last_real and (now_epoch - last_real) >= force_after:
        emit("forced_run_elapsed", 1)

emit("checkpoint_cache_hit", 0)
PY
  )"
  eval_rc=$?
  if [[ "$had_errexit" == "1" ]]; then
    set -e
  fi

  CHECKPOINT_DECISION_REASON="${eval_out:-checkpoint_schema_invalid}"
  if [[ "$eval_rc" -eq 0 ]]; then
    return 0
  fi
  return 1
}

checkpoint_decide_skip_gate() {
  local gate="${1:-unknown_gate}"
  local rollout="${CHECKPOINT_ROLLOUT:-off}"
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

  if [[ "${VERIFY_CHECKPOINT_SKIP:-0}" != "1" ]]; then
    CHECKPOINT_DECISION_REASON="skip_flag_disabled"
    return 1
  fi

  case "$rollout" in
    off)
      CHECKPOINT_DECISION_REASON="rollout_off"
      return 1
      ;;
    dry_run|enforce)
      ;;
    *)
      CHECKPOINT_DECISION_REASON="rollout_invalid_value"
      return 1
      ;;
  esac

  local hash_start_ms hash_end_ms hash_elapsed_ms
  local input_hash override_fingerprint tool_versions_json
  hash_start_ms="$(checkpoint_now_millis)"
  input_hash="$(checkpoint_gate_input_hash "$gate" || true)"
  if [[ -z "$input_hash" ]]; then
    CHECKPOINT_DECISION_REASON="${CHECKPOINT_INELIGIBLE_REASON:-gate_input_hash_failed}"
    return 1
  fi
  override_fingerprint="$(checkpoint_override_fingerprint || true)"
  if [[ -z "$override_fingerprint" ]]; then
    CHECKPOINT_DECISION_REASON="${CHECKPOINT_INELIGIBLE_REASON:-override_fingerprint_missing}"
    return 1
  fi
  tool_versions_json="$(checkpoint_tool_versions_json || true)"
  if [[ -z "$tool_versions_json" ]]; then
    CHECKPOINT_DECISION_REASON="${CHECKPOINT_INELIGIBLE_REASON:-toolchain_probe_failed}"
    return 1
  fi
  hash_end_ms="$(checkpoint_now_millis)"
  if [[ "$hash_start_ms" =~ ^[0-9]+$ && "$hash_end_ms" =~ ^[0-9]+$ && "$hash_end_ms" -ge "$hash_start_ms" ]]; then
    hash_elapsed_ms=$((hash_end_ms - hash_start_ms))
    if (( hash_elapsed_ms > ${VERIFY_CHECKPOINT_HASH_BUDGET_MS:-2000} )); then
      CHECKPOINT_HASH_BUDGET_EXCEEDED=1
      CHECKPOINT_INELIGIBLE_REASON="checkpoint_hash_budget_exceeded"
      CHECKPOINT_DECISION_REASON="checkpoint_hash_budget_exceeded"
      return 1
    fi
    CHECKPOINT_HASH_PHASE_MS="$hash_elapsed_ms"
  fi

  if checkpoint_evaluate_gate_skip "$gate" "$input_hash" "$override_fingerprint" "$tool_versions_json"; then
    if [[ "$rollout" == "enforce" ]]; then
      CHECKPOINT_DECISION_ACTION="skip"
      CHECKPOINT_DECISION_REASON="checkpoint_cache_hit"
      return 0
    fi
    CHECKPOINT_DECISION_ACTION="run"
    CHECKPOINT_DECISION_REASON="dry_run_would_skip"
    return 1
  fi

  if [[ "$rollout" == "dry_run" ]]; then
    CHECKPOINT_DECISION_ACTION="run"
    if [[ "${CHECKPOINT_DECISION_REASON:-}" == "checkpoint_cache_hit" ]]; then
      CHECKPOINT_DECISION_REASON="dry_run_would_skip"
    fi
    return 1
  fi

  return 1
}
