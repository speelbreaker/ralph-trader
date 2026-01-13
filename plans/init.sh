#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------
# plans/init.sh
# Purpose: deterministic, cheap preflight to reduce uncertainty
# Default: NO heavy tests (verify happens in the main loop)
# Optional: run verify if INIT_RUN_VERIFY=1
# ------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRD_FILE="plans/prd.json"
PROGRESS_FILE="plans/progress.txt"
VERIFY_SH="plans/verify.sh"
PRD_SCHEMA_CHECK_SH="plans/prd_schema_check.sh"
CONTRACT_CHECK_SH="plans/contract_check.sh"

# Controls
FAIL_ON_DIRTY="${INIT_FAIL_ON_DIRTY:-1}"
RUN_VERIFY="${INIT_RUN_VERIFY:-0}"          # 0=skip, 1=run ./plans/verify.sh
VERIFY_MODE="${INIT_VERIFY_MODE:-quick}"    # passed to verify.sh if supported

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[init] ERROR: $ROOT is not a git repository"
  exit 10
fi

echo "[init] repo_root: $ROOT"
echo "[init] branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
echo "[init] commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

# --- directories used by the harness
mkdir -p plans/logs .ralph

# --- tooling checks (fail fast, fail loud)
need() { command -v "$1" >/dev/null 2>&1 || { echo "[init] ERROR: missing required tool: $1"; exit 11; }; }
need git
need jq

# --- progress file: create if missing (do NOT rewrite if exists)
if [[ ! -f "$PROGRESS_FILE" ]]; then
  cat > "$PROGRESS_FILE" <<'TXT'
# progress.txt
# Append-only session log. Do not rewrite.
#
# Format suggestion (1 entry per iteration):
# ts:
# story_id:
# summary:
# commands_run:
# evidence_paths:
# notes_for_next_iteration:
TXT
  echo "[init] created $PROGRESS_FILE"
fi

# --- optional logs (create if missing)
if [[ ! -f "plans/ideas.md" ]]; then
  echo "# Ideas & Deferred Items" > "plans/ideas.md"
  echo "[init] created plans/ideas.md"
fi

if [[ ! -f "plans/pause.md" ]]; then
  echo "# Pause / Handoff Notes" > "plans/pause.md"
  echo "[init] created plans/pause.md"
fi

# --- PRD must exist + be valid JSON (otherwise Ralph is blind)
if [[ ! -f "$PRD_FILE" ]]; then
  echo "[init] ERROR: missing $PRD_FILE"
  echo "[init] Action: run Story Cutter to generate plans/prd.json from IMPLEMENTATION_PLAN.md"
  exit 12
fi

if ! jq . "$PRD_FILE" >/dev/null 2>&1; then
  echo "[init] ERROR: $PRD_FILE is not valid JSON (refusing to proceed)"
  exit 13
fi

# --- required contract + implementation plan inputs
resolve_contract_path() {
  local prd_path="$1"
  if [[ -n "$prd_path" ]]; then
    [[ -f "$prd_path" ]] || return 1
    echo "$prd_path"
    return 0
  fi
  if [[ -f "CONTRACT.md" ]]; then echo "CONTRACT.md"; return 0; fi
  if [[ -f "specs/CONTRACT.md" ]]; then echo "specs/CONTRACT.md"; return 0; fi
  return 1
}

resolve_plan_path() {
  local prd_path="$1"
  if [[ -n "$prd_path" ]]; then
    [[ -f "$prd_path" ]] || return 1
    echo "$prd_path"
    return 0
  fi
  if [[ -f "IMPLEMENTATION_PLAN.md" ]]; then echo "IMPLEMENTATION_PLAN.md"; return 0; fi
  if [[ -f "specs/IMPLEMENTATION_PLAN.md" ]]; then echo "specs/IMPLEMENTATION_PLAN.md"; return 0; fi
  return 1
}

PRD_CONTRACT_PATH="$(jq -r '.source.contract_path // empty' "$PRD_FILE")"
PRD_PLAN_PATH="$(jq -r '.source.implementation_plan_path // empty' "$PRD_FILE")"

resolve_contract_path "$PRD_CONTRACT_PATH" >/dev/null 2>&1 || { echo "[init] ERROR: missing CONTRACT.md (required input)"; exit 17; }
resolve_plan_path "$PRD_PLAN_PATH" >/dev/null 2>&1 || { echo "[init] ERROR: missing IMPLEMENTATION_PLAN.md (required input)"; exit 18; }

# --- PRD schema validation (fail closed)
if [[ ! -x "$PRD_SCHEMA_CHECK_SH" ]]; then
  echo "[init] ERROR: missing $PRD_SCHEMA_CHECK_SH"
  exit 19
fi
"./$PRD_SCHEMA_CHECK_SH" "$PRD_FILE"

# --- verify must exist (single standard gate runner)
if [[ ! -f "$VERIFY_SH" ]]; then
  echo "[init] ERROR: missing $VERIFY_SH"
  echo "[init] Action: implement the workflow story that creates verify.sh (your S1-000)"
  exit 14
fi
if [[ ! -x "$VERIFY_SH" ]]; then
  chmod +x "$VERIFY_SH" || { echo "[init] ERROR: unable to mark $VERIFY_SH executable"; exit 14; }
fi
if [[ ! -x "$VERIFY_SH" ]]; then
  echo "[init] ERROR: $VERIFY_SH is not executable"
  exit 14
fi

if [[ -f "$CONTRACT_CHECK_SH" ]]; then
  chmod +x "$CONTRACT_CHECK_SH" || true
fi

if [[ -f "plans/contract_review_validate.sh" ]]; then
  chmod +x "plans/contract_review_validate.sh" || true
fi

# --- shell sanity (cheap, catches 80% of dumb)
if compgen -G "plans/*.sh" >/dev/null; then
  for f in plans/*.sh; do
    bash -n "$f" || { echo "[init] ERROR: bash syntax check failed: $f"; exit 15; }
  done
fi

# --- git hygiene (optional but recommended)
DIRTY="$(git status --porcelain || true)"
if [[ -n "$DIRTY" ]]; then
  echo "[init] git status: DIRTY"
  echo "$DIRTY"
  if [[ "$FAIL_ON_DIRTY" == "1" ]]; then
    echo "[init] ERROR: working tree dirty (set INIT_FAIL_ON_DIRTY=0 to override)"
    exit 16
  fi
else
  echo "[init] git status: clean"
fi

# --- optional heavy step: run verify (off by default to avoid double runtime)
if [[ "$RUN_VERIFY" == "1" ]]; then
  echo "[init] running verify: ./$VERIFY_SH $VERIFY_MODE"
  "./$VERIFY_SH" "$VERIFY_MODE"
else
  echo "[init] skipping verify (INIT_RUN_VERIFY=0). Ralph will run baseline verify next."
fi

echo "[init] OK"
