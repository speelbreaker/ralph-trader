#!/usr/bin/env bash

if [[ -n "${__VERIFY_UTILS_SOURCED:-}" ]]; then
  return 0
fi
__VERIFY_UTILS_SOURCED=1

RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
NC="${NC:-\033[0m}"
VERIFY_FAIL_TAIL_LINES="${VERIFY_FAIL_TAIL_LINES:-80}"
VERIFY_FAIL_SUMMARY_LINES="${VERIFY_FAIL_SUMMARY_LINES:-20}"

log()  { echo -e "\n${GREEN}=== $* ===${NC}"; }
warn() { echo -e "${YELLOW}WARN: $*${NC}" >&2; }
fail() { echo -e "${RED}FAIL: $*${NC}" >&2; exit 1; }
is_ci(){ [[ -n "${CI:-}" ]]; }

detect_cpus() {
  # Auto-detect CPU cores (portable: macOS + Linux)
  local cpus=2
  if command -v nproc >/dev/null 2>&1; then
    cpus=$(nproc)
  elif command -v sysctl >/dev/null 2>&1; then
    cpus=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
  fi
  echo "$cpus"
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

ensure_python() {
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
    return 0
  fi
  fail "Missing required command: python (or python3)"
}

node_script_exists() {
  local script="$1"
  command -v node >/dev/null 2>&1 || return 1
  node -e "const s=require('./package.json').scripts||{}; process.exit(s['$script']?0:1)" >/dev/null 2>&1
}

node_run_script() {
  local script="$1"
  case "$NODE_PM" in
    pnpm) pnpm -s run "$script" --if-present ;;
    npm) npm run -s "$script" --if-present ;;
    yarn)
      if node_script_exists "$script"; then
        yarn -s run "$script"
      fi
      ;;
    *) fail "No node package manager selected (missing lockfile)" ;;
  esac
}

node_run_bin() {
  local bin="$1"
  shift
  if [[ -x "./node_modules/.bin/$bin" ]]; then
    "./node_modules/.bin/$bin" "$@"
    return 0
  fi
  if command -v "$bin" >/dev/null 2>&1; then
    "$bin" "$@"
    return 0
  fi
  case "$NODE_PM" in
    pnpm) pnpm -s exec "$bin" -- "$@" ;;
    npm) npx --no-install "$bin" -- "$@" ;;
    yarn) yarn -s "$bin" "$@" ;;
    *) return 1 ;;
  esac
}

run_with_timeout() {
  local duration="$1"
  shift
  if [[ "$ENABLE_TIMEOUTS" != "1" || -z "$duration" ]]; then
    "$@"
    return $?
  fi
  if [[ -z "$TIMEOUT_BIN" ]]; then
    "$@"
    return $?
  fi
  "$TIMEOUT_BIN" "$duration" "$@"
}

emit_fail_excerpt() {
  local name="$1"
  local logfile="$2"
  local tail_lines="${VERIFY_FAIL_TAIL_LINES:-80}"
  local summary_lines="${VERIFY_FAIL_SUMMARY_LINES:-20}"
  local summary=""

  if [[ ! -f "$logfile" ]]; then
    warn "Logfile missing for ${name} (${logfile})"
    return 0
  fi

  echo "---- ${name} failure tail (last ${tail_lines} lines) ----"
  tail -n "$tail_lines" "$logfile" || true
  echo "---- ${name} failure summary (grep error:|FAIL|FAILED|panicked) ----"
  summary="$(grep -nE "error:|FAIL|FAILED|panicked" "$logfile" || true)"
  if [[ -n "$summary" ]]; then
    echo "$summary" | tail -n "$summary_lines" || true
  else
    echo "(no summary matches)"
  fi
}

emit_inner_excerpt() {
  local name="$1"
  if [[ -n "${RUN_LOGGED_SUPPRESS_EXCERPT:-}" ]]; then
    emit_fail_excerpt "$name" "${VERIFY_ARTIFACTS_DIR}/${name}.log"
  fi
}

run_logged() {
  local name="$1"
  local duration="$2"
  shift 2
  local logfile="${VERIFY_ARTIFACTS_DIR}/${name}.log"
  local rc=0
  local start_time end_time elapsed

  if [[ "$ENABLE_TIMEOUTS" == "1" && -n "$duration" && -z "$TIMEOUT_BIN" && "$TIMEOUT_WARNED" == "0" ]]; then
    warn "timeout not available; running without time limits (install coreutils for gtimeout on macOS)"
    TIMEOUT_WARNED=1
  fi

  # Timing instrumentation
  start_time=$(date +%s)

  if [[ "$VERIFY_CONSOLE" == "verbose" ]]; then
    if [[ "$VERIFY_LOG_CAPTURE" == "1" ]]; then
      set +e
      run_with_timeout "$duration" "$@" 2>&1 | tee "$logfile"
      rc="${PIPESTATUS[0]}"
      set -e
    else
      run_with_timeout "$duration" "$@"
      rc=$?
    fi
  else
    # Quiet console: always capture logs to artifacts for debugging.
    set +e
    run_with_timeout "$duration" "$@" > "$logfile" 2>&1
    rc=$?
    set -e
    if [[ "$rc" != "0" && -z "${RUN_LOGGED_SUPPRESS_EXCERPT:-}" ]]; then
      emit_fail_excerpt "$name" "$logfile"
    fi
  fi

  # Timing instrumentation: write elapsed time
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))
  echo "$elapsed" > "${VERIFY_ARTIFACTS_DIR}/${name}.time"

  # WRITE .rc FOR ALL GATES (pass or fail) - immediately after rc is known
  echo "$rc" > "${VERIFY_ARTIFACTS_DIR}/${name}.rc"

  # WRITE FAILED_GATE only for first failure (before timeout check)
  # Skip if RUN_LOGGED_SKIP_FAILED_GATE is set (parallel runner handles this)
  if [[ "$rc" != "0" && ! -f "${VERIFY_ARTIFACTS_DIR}/FAILED_GATE" && -z "${RUN_LOGGED_SKIP_FAILED_GATE:-}" ]]; then
    echo "$name" > "${VERIFY_ARTIFACTS_DIR}/FAILED_GATE"
  fi

  # VERIFY_TIMEOUT_PAREN_FIX: in [[ ]], && binds tighter than ||.
  # Without parens: (rc==124 || rc==137 && suppress) becomes
  # rc==124 || (rc==137 && suppress), so rc=124 ignores suppress.
  if [[ ( "$rc" == "124" || "$rc" == "137" ) && -z "${RUN_LOGGED_SUPPRESS_TIMEOUT_FAIL:-}" ]]; then
    fail "Timeout running ${name} (limit=${duration})"
  fi
  return "$rc"
}

run_logged_or_exit() {
  local name="$1"
  local timeout="$2"
  shift 2
  local rc
  local errexit=0
  case "$-" in *e*) errexit=1 ;; esac

  set +e
  run_logged "$name" "$timeout" "$@"
  rc=$?
  if [[ "$errexit" == "1" ]]; then
    set -e
  fi

  if [[ "$rc" != "0" ]]; then
    emit_inner_excerpt "$name"
    exit "$rc"
  fi
}
