#!/usr/bin/env bash
# =============================================================================
# Stoic Trader / Ralph Verification Script
# -----------------------------------------------------------------------------
# Purpose:
#   One command that tells a coding agent (and CI): "is this repo in a mergeable,
#   green state for the selected verification level?"
#
# Usage:
#   ./plans/verify.sh [quick|full|promotion]
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
echo "VERIFY_SH_SHA=$VERIFY_SH_SHA"

MODE="${1:-}"                      # quick | full | promotion (default inferred)
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CI_GATES_SOURCE="${CI_GATES_SOURCE:-auto}"
VERIFY_RUN_ID="${VERIFY_RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
VERIFY_ARTIFACTS_DIR="${VERIFY_ARTIFACTS_DIR:-$ROOT/artifacts/verify/$VERIFY_RUN_ID}"
VERIFY_LOG_CAPTURE="${VERIFY_LOG_CAPTURE:-1}" # 0 disables per-step log capture in verbose mode
WORKFLOW_ACCEPTANCE_POLICY="${WORKFLOW_ACCEPTANCE_POLICY:-auto}"
BASE_REF="${BASE_REF:-origin/main}"
export BASE_REF

# Contract/spec paths (align with ralph.sh)
CONTRACT_FILE="${CONTRACT_FILE:-specs/CONTRACT.md}"
IMPL_PLAN_FILE="${IMPL_PLAN_FILE:-specs/IMPLEMENTATION_PLAN.md}"
ARCH_FLOWS_FILE="${ARCH_FLOWS_FILE:-specs/flows/ARCH_FLOWS.yaml}"
GLOBAL_INVARIANTS_FILE="${GLOBAL_INVARIANTS_FILE:-specs/invariants/GLOBAL_INVARIANTS.md}"

mkdir -p "$VERIFY_ARTIFACTS_DIR"
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
  echo "info: change_detection_ok=$CHANGE_DETECTION_OK files=$CHANGED_FILES_COUNT base_ref=$BASE_REF"
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

# -----------------------------------------------------------------------------
# 0) Repo sanity + reproducibility basics
# -----------------------------------------------------------------------------
log "0) Repo sanity"

echo "mode=$MODE verify_mode=${VERIFY_MODE:-none} root=$ROOT"
echo "verify_run_id=$VERIFY_RUN_ID artifacts_dir=$VERIFY_ARTIFACTS_DIR"
if is_ci; then echo "CI=1"; fi

# Dirty tree enforcement (fail closed in CI; local override with VERIFY_ALLOW_DIRTY=1)
if command -v git >/dev/null 2>&1; then
  dirty_status="$(git status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty_status" ]]; then
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
  ensure_python
  run_logged "contract_coverage" "$CONTRACT_COVERAGE_TIMEOUT" "$PYTHON_BIN" "plans/contract_coverage_matrix.py"
  if [[ -z "${CI:-}" && "$CONTRACT_COVERAGE_STRICT" == "1" && ! -f "$CONTRACT_COVERAGE_CI_SENTINEL" ]]; then
    warn "Contract coverage strict passed locally. Run ./plans/contract_coverage_promote.sh to enable strict coverage in CI."
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

# Build spec validator array (format: "name|timeout|command args")
SPEC_VALIDATOR_SPECS=(
  "contract_crossrefs|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_contract_crossrefs.py --contract $CONTRACT_FILE --strict --check-at --include-bare-section-refs"
  "arch_flows|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_arch_flows.py --contract $CONTRACT_FILE --flows $ARCH_FLOWS_FILE --strict"
  "state_machines|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_state_machines.py --dir specs/state_machines --strict --contract $CONTRACT_FILE --flows $ARCH_FLOWS_FILE --invariants $GLOBAL_INVARIANTS_FILE"
  "global_invariants|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_global_invariants.py --file $GLOBAL_INVARIANTS_FILE --contract $CONTRACT_FILE"
  "time_freshness|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_time_freshness.py --contract $CONTRACT_FILE --spec specs/flows/TIME_FRESHNESS.yaml --strict"
  "crash_matrix|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_crash_matrix.py --contract $CONTRACT_FILE --matrix specs/flows/CRASH_MATRIX.md"
  "crash_replay_idempotency|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_crash_replay_idempotency.py --contract $CONTRACT_FILE --spec specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml --strict"
  "reconciliation_matrix|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_reconciliation_matrix.py --matrix specs/flows/RECONCILIATION_MATRIX.md --contract $CONTRACT_FILE --strict"
  "csp_trace|$SPEC_LINT_TIMEOUT|$PYTHON_BIN scripts/check_csp_trace.py --contract $CONTRACT_FILE --trace specs/TRACE.yaml"
)

# Auto-detect CPU cores, cap at 4 to avoid CI thrashing
SPEC_LINT_JOBS=$(detect_cpus)
[[ $SPEC_LINT_JOBS -gt 4 ]] && SPEC_LINT_JOBS=4

# Run validators in parallel
run_parallel_group SPEC_VALIDATOR_SPECS "$SPEC_LINT_JOBS"

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
  echo "  $name: ${elapsed}s"
done

log "VERIFY OK (mode=$MODE)"
