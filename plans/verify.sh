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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "\n${GREEN}=== $* ===${NC}"; }
warn() { echo -e "${YELLOW}WARN: $*${NC}" >&2; }
fail() { echo -e "${RED}FAIL: $*${NC}" >&2; exit 1; }
is_ci(){ [[ -n "${CI:-}" ]]; }

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

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi
TIMEOUT_WARNED=0
ENABLE_TIMEOUTS="${ENABLE_TIMEOUTS:-1}"

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

run_logged() {
  local name="$1"
  local duration="$2"
  shift 2
  local logfile="${VERIFY_ARTIFACTS_DIR}/${name}.log"
  local rc=0

  if [[ "$ENABLE_TIMEOUTS" == "1" && -n "$duration" && -z "$TIMEOUT_BIN" && "$TIMEOUT_WARNED" == "0" ]]; then
    warn "timeout not available; running without time limits (install coreutils for gtimeout on macOS)"
    TIMEOUT_WARNED=1
  fi

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
    if [[ "$rc" != "0" ]]; then
      emit_fail_excerpt "$name" "$logfile"
    fi
  fi

  # WRITE .rc FOR ALL GATES (pass or fail) - immediately after rc is known
  echo "$rc" > "${VERIFY_ARTIFACTS_DIR}/${name}.rc"

  # WRITE FAILED_GATE only for first failure (before timeout check)
  if [[ "$rc" != "0" && ! -f "${VERIFY_ARTIFACTS_DIR}/FAILED_GATE" ]]; then
    echo "$name" > "${VERIFY_ARTIFACTS_DIR}/FAILED_GATE"
  fi

  if [[ "$rc" == "124" || "$rc" == "137" ]]; then
    fail "Timeout running ${name} (limit=${duration})"
  fi
  return "$rc"
}

is_workflow_file() {
  case "$1" in
    AGENTS.md|specs/WORKFLOW_CONTRACT.md|specs/CONTRACT.md|specs/IMPLEMENTATION_PLAN.md|specs/POLICY.md|specs/SOURCE_OF_TRUTH.md|IMPLEMENTATION_PLAN.md|POLICY.md) return 0 ;;
    verify.sh) return 0 ;;
    plans/verify.sh|plans/workflow_acceptance.sh|plans/workflow_acceptance_parallel.sh|plans/workflow_contract_gate.sh|plans/workflow_contract_map.json|plans/ssot_lint.sh|plans/prd_gate.sh|plans/prd_audit_check.sh|plans/tests/test_workflow_acceptance_fallback.sh) return 0 ;;
    plans/workflow_verify.sh) return 0 ;;
    plans/contract_coverage_matrix.py|plans/contract_coverage_promote.sh) return 0 ;;
    plans/contract_check.sh|plans/contract_review_validate.sh|plans/init.sh|plans/ralph.sh) return 0 ;;
    plans/autofix.sh) return 0 ;;
    plans/story_verify_allowlist.txt) return 0 ;;
    plans/story_verify_allowlist_check.sh) return 0 ;;
    plans/story_verify_allowlist_lint.sh) return 0 ;;
    plans/story_verify_allowlist_suggest.sh) return 0 ;;
    plans/prd_preflight.sh) return 0 ;;
    specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml) return 0 ;;
    tools/vendor_docs_lint_rust.py) return 0 ;;
    scripts/build_contract_kernel.py|scripts/check_contract_kernel.py|scripts/contract_kernel_lib.py|scripts/test_contract_kernel.py) return 0 ;;
    scripts/check_contract_crossrefs.py|scripts/check_arch_flows.py|scripts/check_state_machines.py|scripts/check_global_invariants.py) return 0 ;;
    scripts/check_time_freshness.py|scripts/check_crash_matrix.py|scripts/check_crash_replay_idempotency.py|scripts/check_reconciliation_matrix.py) return 0 ;;
    scripts/check_csp_trace.py|scripts/generate_impact_report.py|scripts/check_vq_evidence.py|scripts/extract_contract_excerpts.py) return 0 ;;
    specs/TRACE.yaml) return 0 ;;
    docs/contract_kernel.json|docs/contract_anchors.md|docs/validation_rules.md) return 0 ;;
    *) return 1 ;;
  esac
}

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

files_match_any() {
  local matcher="$1"
  local f
  if [[ -z "$CHANGED_FILES" ]]; then
    return 1
  fi
  while IFS= read -r f; do
    if "$matcher" "$f"; then
      return 0
    fi
  done <<< "$CHANGED_FILES"
  return 1
}

is_rust_affecting_file() {
  case "$1" in
    *.rs|Cargo.toml|Cargo.lock|rust-toolchain|rust-toolchain.toml|rustfmt.toml|clippy.toml|.cargo/*) return 0 ;;
    */Cargo.toml|*/Cargo.lock|*/rust-toolchain|*/rust-toolchain.toml|*/rustfmt.toml|*/clippy.toml) return 0 ;;
    *) return 1 ;;
  esac
}

is_python_affecting_file() {
  case "$1" in
    *.py|*.pyi|pyproject.toml|requirements*.txt|setup.cfg|setup.py|tox.ini|mypy.ini|pytest.ini|.mypy.ini|.pytest.ini) return 0 ;;
    poetry.lock|uv.lock|ruff.toml|.ruff.toml|Pipfile|Pipfile.lock|.python-version) return 0 ;;
    */pyproject.toml|*/requirements*.txt|*/setup.cfg|*/setup.py|*/tox.ini|*/mypy.ini|*/pytest.ini) return 0 ;;
    */poetry.lock|*/uv.lock|*/ruff.toml|*/.ruff.toml|*/Pipfile|*/Pipfile.lock|*/.python-version) return 0 ;;
    *) return 1 ;;
  esac
}

is_node_affecting_file() {
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) return 0 ;;
    package.json|pnpm-lock.yaml|package-lock.json|yarn.lock|.nvmrc|.node-version) return 0 ;;
    tsconfig.json|tsconfig.*.json|eslint.config.*|.eslintrc*|.prettierrc*|prettier.config.*) return 0 ;;
    jest.config.*|vitest.config.*|babel.config.*|vite.config.*|next.config.*) return 0 ;;
    webpack.config.*|rollup.config.*) return 0 ;;
    */package.json|*/pnpm-lock.yaml|*/package-lock.json|*/yarn.lock|*/.nvmrc|*/.node-version) return 0 ;;
    */tsconfig.json|*/tsconfig.*.json|*/eslint.config.*|*/.eslintrc*|*/.prettierrc*|*/prettier.config.*) return 0 ;;
    */jest.config.*|*/vitest.config.*|*/babel.config.*|*/vite.config.*|*/next.config.*) return 0 ;;
    */webpack.config.*|*/rollup.config.*) return 0 ;;
    *) return 1 ;;
  esac
}

is_contract_coverage_input_file() {
  case "$1" in
    plans/prd.json|docs/contract_anchors.md|docs/validation_rules.md|plans/contract_coverage_matrix.py) return 0 ;;
    *) return 1 ;;
  esac
}

workflow_files_changed() {
  files_match_any is_workflow_file
}

should_run_contract_coverage() {
  if [[ "$MODE" == "full" ]]; then
    return 0
  fi
  if [[ "$CHANGE_DETECTION_OK" != "1" ]]; then
    return 0
  fi
  files_match_any is_contract_coverage_input_file
}

should_run_rust_gates() {
  if [[ "$CHANGE_DETECTION_OK" != "1" ]]; then
    return 0
  fi
  files_match_any is_rust_affecting_file
}

should_run_python_gates() {
  if [[ "$CHANGE_DETECTION_OK" != "1" ]]; then
    return 0
  fi
  files_match_any is_python_affecting_file
}

should_run_node_gates() {
  if [[ "$CHANGE_DETECTION_OK" != "1" ]]; then
    return 0
  fi
  files_match_any is_node_affecting_file
}

should_run_workflow_acceptance() {
  if is_ci; then
    return 0
  fi

  case "$WORKFLOW_ACCEPTANCE_POLICY" in
    always) return 0 ;;
    never) return 1 ;;
    auto) ;;
    *) warn "Unknown WORKFLOW_ACCEPTANCE_POLICY=$WORKFLOW_ACCEPTANCE_POLICY (expected auto|always|never); defaulting to auto" ;;
  esac

  if [[ "$CHANGE_DETECTION_OK" != "1" ]]; then
    warn "change detection unavailable; running workflow acceptance to be safe"
    return 0
  fi

  if [[ -z "$CHANGED_FILES" ]]; then
    return 1
  fi

  local f
  while IFS= read -r f; do
    if is_workflow_file "$f"; then
      echo "workflow acceptance required: changed workflow file: $f"
      return 0
    fi
  done <<< "$CHANGED_FILES"

  return 1
}

workflow_acceptance_mode() {
  if [[ "$CHANGE_DETECTION_OK" != "1" ]]; then
    echo "full"
    return 0
  fi
  if workflow_files_changed; then
    echo "full"
    return 0
  fi
  if is_ci; then
    echo "smoke"
    return 0
  fi
  if [[ "$MODE" == "full" ]]; then
    echo "full"
    return 0
  fi
  echo "smoke"
}
RUST_FMT_TIMEOUT="${RUST_FMT_TIMEOUT:-10m}"
RUST_CLIPPY_TIMEOUT="${RUST_CLIPPY_TIMEOUT:-20m}"
RUST_TEST_TIMEOUT="${RUST_TEST_TIMEOUT:-20m}"
PYTEST_TIMEOUT="${PYTEST_TIMEOUT:-10m}"
RUFF_TIMEOUT="${RUFF_TIMEOUT:-5m}"
MYPY_TIMEOUT="${MYPY_TIMEOUT:-10m}"
CONTRACT_COVERAGE_TIMEOUT="${CONTRACT_COVERAGE_TIMEOUT:-2m}"
SPEC_LINT_TIMEOUT="${SPEC_LINT_TIMEOUT:-2m}"
POSTMORTEM_CHECK_TIMEOUT="${POSTMORTEM_CHECK_TIMEOUT:-1m}"
WORKFLOW_ACCEPTANCE_TIMEOUT="${WORKFLOW_ACCEPTANCE_TIMEOUT:-20m}"
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
# 0a) Harness script syntax
# -----------------------------------------------------------------------------
log "0a) Harness script syntax"
run_logged "bash_syntax_workflow_acceptance" "1m" bash -n plans/workflow_acceptance.sh

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

[[ -f "scripts/check_contract_crossrefs.py" ]] || fail "Missing scripts/check_contract_crossrefs.py"
run_logged "contract_crossrefs" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_contract_crossrefs.py" \
  --contract "$CONTRACT_FILE" \
  --strict \
  --check-at \
  --include-bare-section-refs

[[ -f "scripts/check_arch_flows.py" ]] || fail "Missing scripts/check_arch_flows.py"
run_logged "arch_flows" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_arch_flows.py" \
  --contract "$CONTRACT_FILE" \
  --flows "$ARCH_FLOWS_FILE" \
  --strict

[[ -f "scripts/check_state_machines.py" ]] || fail "Missing scripts/check_state_machines.py"
run_logged "state_machines" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_state_machines.py" \
  --dir specs/state_machines \
  --strict \
  --contract "$CONTRACT_FILE" \
  --flows "$ARCH_FLOWS_FILE" \
  --invariants "$GLOBAL_INVARIANTS_FILE"

[[ -f "scripts/check_global_invariants.py" ]] || fail "Missing scripts/check_global_invariants.py"
run_logged "global_invariants" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_global_invariants.py" \
  --file "$GLOBAL_INVARIANTS_FILE" \
  --contract "$CONTRACT_FILE"

if [[ -f "scripts/check_time_freshness.py" ]]; then
  [[ -f "specs/flows/TIME_FRESHNESS.yaml" ]] || fail "Missing specs/flows/TIME_FRESHNESS.yaml"
  run_logged "time_freshness" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_time_freshness.py" \
    --contract "$CONTRACT_FILE" \
    --spec specs/flows/TIME_FRESHNESS.yaml \
    --strict
else
  fail "Missing scripts/check_time_freshness.py"
fi

if [[ -f "scripts/check_crash_matrix.py" ]]; then
  [[ -f "specs/flows/CRASH_MATRIX.md" ]] || fail "Missing specs/flows/CRASH_MATRIX.md"
  run_logged "crash_matrix" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_crash_matrix.py" \
    --contract "$CONTRACT_FILE" \
    --matrix specs/flows/CRASH_MATRIX.md
else
  fail "Missing scripts/check_crash_matrix.py"
fi

if [[ -f "scripts/check_crash_replay_idempotency.py" ]]; then
  [[ -f "specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml" ]] || fail "Missing specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml"
  run_logged "crash_replay_idempotency" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_crash_replay_idempotency.py" \
    --contract "$CONTRACT_FILE" \
    --spec specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml \
    --strict
else
  fail "Missing scripts/check_crash_replay_idempotency.py"
fi

if [[ -f "scripts/check_reconciliation_matrix.py" ]]; then
  [[ -f "specs/flows/RECONCILIATION_MATRIX.md" ]] || fail "Missing specs/flows/RECONCILIATION_MATRIX.md"
  run_logged "reconciliation_matrix" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_reconciliation_matrix.py" \
    --matrix specs/flows/RECONCILIATION_MATRIX.md \
    --contract "$CONTRACT_FILE" \
    --strict
else
  fail "Missing scripts/check_reconciliation_matrix.py"
fi

if [[ -f "scripts/check_csp_trace.py" ]]; then
  [[ -f "specs/TRACE.yaml" ]] || fail "Missing specs/TRACE.yaml"
  run_logged "csp_trace" "$SPEC_LINT_TIMEOUT" "$PYTHON_BIN" "scripts/check_csp_trace.py" \
    --contract "$CONTRACT_FILE" \
    --trace specs/TRACE.yaml
else
  fail "Missing scripts/check_csp_trace.py"
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
  fixture_count=0
  for f in "$STATUS_FIXTURES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    fixture_name="$(basename "$f" .json)"
    VALIDATE_STATUS_ARGS=(
      --file "$f"
      --schema "$STATUS_EXACT_SCHEMA"
      --manifest "$STATUS_MANIFEST"
      --strict
    )
    if [[ "$VERIFY_CONSOLE" == "quiet" ]]; then
      VALIDATE_STATUS_ARGS+=(--quiet)
    fi
    run_logged "status_fixture_${fixture_name}" "$STATUS_VALIDATION_TIMEOUT" \
      "$PYTHON_BIN" tools/validate_status.py "${VALIDATE_STATUS_ARGS[@]}"
    fixture_count=$((fixture_count + 1))
  done
  if [[ "$fixture_count" -eq 0 ]]; then
    warn "No status fixtures found in $STATUS_FIXTURES_DIR"
  else
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
# 2) Rust gates (if Rust project present)
# -----------------------------------------------------------------------------
if [[ -f Cargo.toml ]]; then
  if should_run_rust_gates; then
    need cargo

    log "2a) Rust format"
    run_logged "rust_fmt" "$RUST_FMT_TIMEOUT" cargo fmt --all -- --check

    if [[ "$MODE" == "full" ]]; then
      log "2b) Rust clippy"
      run_logged "rust_clippy" "$RUST_CLIPPY_TIMEOUT" cargo clippy --workspace --all-targets --all-features -- -D warnings
    else
      warn "Skipping clippy in quick mode"
    fi

    log "2c) Rust tests"
    if [[ "$MODE" == "full" ]]; then
      run_logged "rust_tests_full" "$RUST_TEST_TIMEOUT" cargo test --workspace --all-features --locked
    else
      run_logged "rust_tests_quick" "$RUST_TEST_TIMEOUT" cargo test --workspace --lib --locked
    fi

    echo "✓ rust gates passed"
  else
    echo "info: rust gates skipped (no rust-affecting changes detected)"
  fi
fi

# -----------------------------------------------------------------------------
# 3) Python gates (if Python project present)
# -----------------------------------------------------------------------------
if [[ -f pyproject.toml || -f requirements.txt ]]; then
  if should_run_python_gates; then
    ensure_python

    # Ruff: required in CI (best ROI for agent-heavy workflows)
    if command -v ruff >/dev/null 2>&1; then
      log "3a) Python ruff lint"
      run_logged "python_ruff_check" "$RUFF_TIMEOUT" ruff check .

      log "3b) Python ruff format"
      run_logged "python_ruff_format" "$RUFF_TIMEOUT" ruff format --check .
    else
      if is_ci; then
        fail "ruff not found in CI (install it or adjust verify.sh)"
      else
        warn "ruff not found (install: pip install ruff) — skipping lint/format"
      fi
    fi

    # Pytest: required in CI if present in toolchain
    if command -v pytest >/dev/null 2>&1; then
      log "3c) Python tests"
      if [[ "$MODE" == "quick" ]]; then
        PYTEST_QUICK_EXPR="${PYTEST_QUICK_EXPR:-not integration and not slow}"
        if ! run_logged "python_pytest_quick" "$PYTEST_TIMEOUT" pytest -q -m "$PYTEST_QUICK_EXPR"; then
          warn "pytest quick selection failed; retrying full pytest -q"
          run_logged "python_pytest_full" "$PYTEST_TIMEOUT" pytest -q
        fi
      else
        run_logged "python_pytest_full" "$PYTEST_TIMEOUT" pytest -q
      fi
    else
      if is_ci; then
        fail "pytest not found in CI (install it or adjust verify.sh)"
      else
        warn "pytest not found — skipping python tests"
      fi
    fi

    # MyPy optional: can be made strict with REQUIRE_MYPY=1
    REQUIRE_MYPY="${REQUIRE_MYPY:-0}"
    if command -v mypy >/dev/null 2>&1; then
      log "3d) Python mypy"
      if [[ "$REQUIRE_MYPY" == "1" ]]; then
        run_logged "python_mypy" "$MYPY_TIMEOUT" mypy .
      else
        run_logged "python_mypy" "$MYPY_TIMEOUT" mypy . --ignore-missing-imports || warn "mypy reported issues"
      fi
    else
      if [[ "$REQUIRE_MYPY" == "1" ]]; then
        fail "REQUIRE_MYPY=1 but mypy is not installed"
      fi
    fi

    echo "✓ python gates passed"
  else
    echo "info: python gates skipped (no python-affecting changes detected)"
  fi
fi

# -----------------------------------------------------------------------------
# 4) Node/TS gates (if package.json present)
# -----------------------------------------------------------------------------
if [[ -f package.json ]]; then
  if should_run_node_gates; then
    log "4) Node/TS gates"

    if [[ -z "$NODE_PM" ]]; then
      warn "No recognized lockfile; skipping node gates"
    else
      need "$NODE_PM"
      node_run_script lint
      node_run_script typecheck
      node_run_script test
      echo "✓ node gates passed ($NODE_PM)"
    fi
  else
    echo "info: node gates skipped (no node-affecting changes detected)"
  fi
fi

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
  run_logged "workflow_acceptance" "$WORKFLOW_ACCEPTANCE_TIMEOUT" ./plans/workflow_acceptance.sh --mode "$WORKFLOW_ACCEPTANCE_MODE"
  echo "✓ workflow acceptance passed (${WORKFLOW_ACCEPTANCE_MODE})"
else
  if [[ "${CI:-}" == "" && "${WORKFLOW_ACCEPTANCE_POLICY}" == "never" ]]; then
    echo "info: workflow acceptance skipped (policy=never)"
  else
    echo "info: workflow acceptance skipped (no workflow file changes detected)"
  fi
fi

log "VERIFY OK (mode=$MODE)"
