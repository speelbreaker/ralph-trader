#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CUTTER_PROMPT="${CUTTER_PROMPT:-plans/prompts/cutter.md}"
PRD_LINT_SH="${PRD_LINT_SH:-./plans/prd_lint.sh}"
MAX_REPAIR_PASSES="${MAX_REPAIR_PASSES:-5}"

CUTTER_AGENT_CMD="${CUTTER_AGENT_CMD:-claude}"
CUTTER_AGENT_ARGS="${CUTTER_AGENT_ARGS:-}"
CUTTER_PROMPT_FLAG="${CUTTER_PROMPT_FLAG:--p}"

if ! [[ "$MAX_REPAIR_PASSES" =~ ^[0-9]+$ ]] || [[ "$MAX_REPAIR_PASSES" -lt 1 ]]; then
  echo "[cut_prd] ERROR: MAX_REPAIR_PASSES must be a positive integer" >&2
  exit 2
fi

if [[ ! -f "$CUTTER_PROMPT" ]]; then
  echo "[cut_prd] ERROR: missing prompt file: $CUTTER_PROMPT" >&2
  exit 2
fi

if [[ ! -f "$PRD_LINT_SH" ]]; then
  echo "[cut_prd] ERROR: missing lint script: $PRD_LINT_SH" >&2
  exit 2
fi

if [[ -z "${CUTTER_AGENT_CMD:-}" ]]; then
  echo "[cut_prd] ERROR: CUTTER_AGENT_CMD is empty" >&2
  exit 2
fi

if ! command -v "$CUTTER_AGENT_CMD" >/dev/null 2>&1; then
  echo "[cut_prd] ERROR: CUTTER_AGENT_CMD not found: $CUTTER_AGENT_CMD" >&2
  exit 2
fi

CUTTER_AGENT_ARGS_ARR=()
if [[ -n "$CUTTER_AGENT_ARGS" ]]; then
  _old_ifs="$IFS"; IFS=$' \t\n'
  read -r -a CUTTER_AGENT_ARGS_ARR <<<"$CUTTER_AGENT_ARGS"
  IFS="$_old_ifs"
fi

run_cutter() {
  local prompt
  prompt="$(cat "$CUTTER_PROMPT")"
  if [[ -n "${CUTTER_PROMPT_FLAG:-}" ]]; then
    "$CUTTER_AGENT_CMD" "${CUTTER_AGENT_ARGS_ARR[@]}" "$CUTTER_PROMPT_FLAG" "$prompt"
  else
    "$CUTTER_AGENT_CMD" "${CUTTER_AGENT_ARGS_ARR[@]}" "$prompt"
  fi
}

run_lint() {
  if [[ -x "$PRD_LINT_SH" ]]; then
    "$PRD_LINT_SH"
  else
    bash "$PRD_LINT_SH"
  fi
}

pass=1
while [[ "$pass" -le "$MAX_REPAIR_PASSES" ]]; do
  echo "[cut_prd] Story Cutter pass $pass/$MAX_REPAIR_PASSES"
  run_cutter
  echo "[cut_prd] Linting PRD..."
  if run_lint; then
    echo "[cut_prd] Lint clean."
    exit 0
  fi
  echo "[cut_prd] Lint failed; retrying." >&2
  pass=$((pass + 1))
done

echo "[cut_prd] ERROR: lint failed after $MAX_REPAIR_PASSES passes" >&2
exit 1
