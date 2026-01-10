#!/usr/bin/env bash
# =============================================================================
# Stoic Trader / Ralph Verification Script
# -----------------------------------------------------------------------------
# Purpose:
#   One command that tells a coding agent (and CI): "is this repo in a mergeable,
#   green state for the selected verification level?"
#
# Usage:
#   ./plans/verify.sh [quick|full]
#
# Philosophy:
#   - quick: same core gates as full (CI parity), no optional heavy gates.
#   - full: same core gates + optional heavy gates (explicitly enabled).
#   - promotion: optional release gate checks (e.g., F1 cert) ONLY when explicitly enabled.
#
# CI alignment:
#   - If CI runs this script as the sole gate, set CI_GATES_SOURCE=verify.
#   - Otherwise, this script expects .github/workflows to exist so it can mirror CI.
#   - If neither is true, it emits <promise>BLOCKED_CI_COMMANDS</promise> and exits non-zero.
# =============================================================================

set -euo pipefail

VERIFY_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify.sh"
if command -v sha256sum >/dev/null 2>&1; then
  VERIFY_SH_SHA="$(sha256sum "$VERIFY_SCRIPT_PATH" | awk '{print $1}')"
else
  VERIFY_SH_SHA="$(shasum -a 256 "$VERIFY_SCRIPT_PATH" | awk '{print $1}')"
fi
echo "VERIFY_SH_SHA=$VERIFY_SH_SHA"

MODE="${1:-quick}"                 # quick | full | promotion
# Allow "promotion" as a mode alias (full + VERIFY_MODE=promotion)
if [[ "$MODE" == "promotion" ]]; then
  MODE="full"
  export VERIFY_MODE="promotion"
fi
VERIFY_MODE="${VERIFY_MODE:-}"     # set to "promotion" for release-grade gates
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CI_GATES_SOURCE="${CI_GATES_SOURCE:-auto}"
if [[ "$CI_GATES_SOURCE" == "auto" ]]; then
  if [[ -d "$ROOT/.github/workflows" ]]; then
    CI_GATES_SOURCE="github"
  else
    CI_GATES_SOURCE=""
  fi
fi

if [[ "$CI_GATES_SOURCE" != "github" && "$CI_GATES_SOURCE" != "verify" ]]; then
  echo "<promise>BLOCKED_CI_COMMANDS</promise>"
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

need() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
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
    yarn) yarn -s run "$script" --if-present ;;
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
if is_ci; then echo "CI=1"; fi

# Dirty tree warning (never fail; Ralph should keep tree clean via commits)
if command -v git >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    warn "Working tree is dirty"
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
BASE_REF="${BASE_REF:-origin/main}"

if [[ "$ENDPOINT_GATE" == "0" && -z "${CI:-}" ]]; then
  warn "ENDPOINT_GATE=0 (disabled locally)"
else
  if ! command -v git >/dev/null 2>&1; then
    warn "git not found (skipping endpoint gate)"
  else
    # Make BASE_REF available in CI
    if is_ci; then
      git fetch --no-tags --prune origin +refs/heads/main:refs/remotes/origin/main >/dev/null 2>&1 || true
    fi

    if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
      changed_files="$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null || true)"

      # Broad but practical patterns across stacks
      endpoint_changed="$(echo "$changed_files" | grep -E \
        '(^|/)(routes|router|api|endpoints|controllers|handlers)(/|$)|(^|/)(web|http)/|(^|/)(fastapi|django|flask)/' || true)"

      tests_changed="$(echo "$changed_files" | grep -E \
        '(^|/)(tests?|__tests__)/|(\.spec\.|\.test\.)|(^|/)integration_tests/' || true)"

      if [[ -n "$endpoint_changed" && -z "$tests_changed" ]]; then
        fail "Endpoint-ish files changed without corresponding test changes:
$endpoint_changed

Fix: add/update endpoint-level tests for the changed endpoints."
      fi

      echo "✓ endpoint gate passed"
    else
      if is_ci; then
        fail "CI must be able to diff against BASE_REF=$BASE_REF (fetch-depth must be 0 and main must be present)."
      else
        warn "Cannot verify BASE_REF=$BASE_REF (skipping endpoint gate)"
      fi
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 2) Rust gates (if Rust project present)
# -----------------------------------------------------------------------------
if [[ -f Cargo.toml ]]; then
  need cargo

  log "2a) Rust format"
  cargo fmt --all -- --check

  log "2b) Rust clippy"
  cargo clippy --workspace --all-targets --all-features -- -D warnings

  log "2c) Rust tests"
  cargo test --workspace --all-features --locked

  echo "✓ rust gates passed"
fi

# -----------------------------------------------------------------------------
# 3) Python gates (if Python project present)
# -----------------------------------------------------------------------------
if [[ -f pyproject.toml || -f requirements.txt ]]; then
  need python

  # Ruff: required in CI (best ROI for agent-heavy workflows)
  if command -v ruff >/dev/null 2>&1; then
    log "3a) Python ruff lint"
    ruff check .

    log "3b) Python ruff format"
    ruff format --check .
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
    pytest -q
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
      mypy .
    else
      mypy . --ignore-missing-imports || warn "mypy reported issues"
    fi
  else
    if [[ "$REQUIRE_MYPY" == "1" ]]; then
      fail "REQUIRE_MYPY=1 but mypy is not installed"
    fi
  fi

  echo "✓ python gates passed"
fi

# -----------------------------------------------------------------------------
# 4) Node/TS gates (if package.json present)
# -----------------------------------------------------------------------------
if [[ -f package.json ]]; then
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
  need python
  python "$ROOT/scripts/check_vq_evidence.py" || fail "Venue facts evidence check failed"
  echo "✓ venue evidence check passed"
else
  if [[ "$REQUIRE_VQ_EVIDENCE" == "1" ]]; then
    fail "REQUIRE_VQ_EVIDENCE=1 but scripts/check_vq_evidence.py is missing"
  fi
fi

# 5b) Promotion-grade F1 cert gate (explicit only)
REQUIRE_F1_CERT="${REQUIRE_F1_CERT:-0}"
RUN_F1_CERT="${RUN_F1_CERT:-0}"
F1_CERT="$ROOT/artifacts/F1_CERT.json"
F1_TOOL="$ROOT/python/tools/f1_certify.py"

if [[ "$VERIFY_MODE" == "promotion" || "$REQUIRE_F1_CERT" == "1" ]]; then
  need jq

  # Generate cert if requested and tool exists
  if [[ "$RUN_F1_CERT" == "1" && -f "$F1_TOOL" ]]; then
    need python
    mkdir -p "$ROOT/artifacts"
    python "$F1_TOOL" --window=24h --out="$F1_CERT"
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
E2E_ARTIFACTS_DIR="${E2E_ARTIFACTS_DIR:-$ROOT/artifacts/e2e}"

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

log "VERIFY OK (mode=$MODE)"
