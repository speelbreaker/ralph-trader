#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AUDITOR_PROMPT="${AUDITOR_PROMPT:-prompts/auditor.md}"
AUDITOR_AGENT_CMD="${AUDITOR_AGENT_CMD:-codex}"
AUDITOR_AGENT_ARGS="${AUDITOR_AGENT_ARGS:-}"
AUDITOR_PROMPT_FLAG="${AUDITOR_PROMPT_FLAG:-}"
AUDIT_OUTPUT_JSON="${AUDIT_OUTPUT_JSON:-plans/prd_audit.json}"
AUDIT_PRD_FILE="${AUDIT_PRD_FILE:-plans/prd.json}"
AUDIT_CACHE_FILE="${AUDIT_CACHE_FILE:-.context/prd_audit_cache.json}"
AUDIT_STDOUT_LOG="${AUDIT_STDOUT_LOG:-.context/prd_auditor_stdout.log}"
AUDIT_CONTRACT_FILE="${AUDIT_CONTRACT_FILE:-}"
AUDIT_PLAN_FILE="${AUDIT_PLAN_FILE:-}"
AUDIT_WORKFLOW_CONTRACT_FILE="${AUDIT_WORKFLOW_CONTRACT_FILE:-}"
AUDIT_SCOPE="${AUDIT_SCOPE:-${PRD_AUDIT_SCOPE:-full}}"
AUDIT_SLICE="${AUDIT_SLICE:-${PRD_AUDIT_SLICE:-}}"
AUDIT_META_FILE="${AUDIT_META_FILE:-.context/prd_audit_meta.json}"
AUDIT_CONTRACT_DIGEST_FILE="${AUDIT_CONTRACT_DIGEST_FILE:-.context/contract_digest.json}"
AUDIT_PLAN_DIGEST_FILE="${AUDIT_PLAN_DIGEST_FILE:-.context/plan_digest.json}"
AUDIT_CONTRACT_SLICE_DIGEST_FILE="${AUDIT_CONTRACT_SLICE_DIGEST_FILE:-.context/contract_digest_slice.json}"
AUDIT_PLAN_SLICE_DIGEST_FILE="${AUDIT_PLAN_SLICE_DIGEST_FILE:-.context/plan_digest_slice.json}"
AUDIT_PRD_SLICE_FILE="${AUDIT_PRD_SLICE_FILE:-.context/prd_slice.json}"

if [[ ! -f "$AUDITOR_PROMPT" ]]; then
  echo "[prd_auditor] ERROR: missing prompt file: $AUDITOR_PROMPT" >&2
  exit 2
fi

if [[ -z "${AUDITOR_AGENT_CMD:-}" ]]; then
  echo "[prd_auditor] ERROR: AUDITOR_AGENT_CMD is empty" >&2
  exit 2
fi

if ! command -v "$AUDITOR_AGENT_CMD" >/dev/null 2>&1; then
  echo "[prd_auditor] ERROR: AUDITOR_AGENT_CMD not found: $AUDITOR_AGENT_CMD" >&2
  exit 2
fi

if [[ "$AUDITOR_AGENT_CMD" == "codex" && -z "$AUDITOR_AGENT_ARGS" ]]; then
  AUDITOR_AGENT_ARGS="exec"
fi

sha256_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

resolve_input_file() {
  local preferred="$1"
  local fallback="$2"
  if [[ -n "$preferred" && -f "$preferred" ]]; then
    echo "$preferred"
    return 0
  fi
  if [[ -n "$fallback" && -f "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi
  echo ""
}

if [[ ! -f "$AUDIT_PRD_FILE" ]]; then
  echo "[prd_auditor] ERROR: missing PRD file: $AUDIT_PRD_FILE" >&2
  exit 2
fi

expected_sha="$(sha256_file "$AUDIT_PRD_FILE")"
if [[ -z "$expected_sha" ]]; then
  echo "[prd_auditor] ERROR: unable to compute sha256 for $AUDIT_PRD_FILE" >&2
  exit 2
fi

if [[ -z "$AUDIT_CONTRACT_FILE" ]]; then
  AUDIT_CONTRACT_FILE="$(resolve_input_file "specs/CONTRACT.md" "CONTRACT.md")"
fi
if [[ -z "$AUDIT_PLAN_FILE" ]]; then
  AUDIT_PLAN_FILE="$(resolve_input_file "specs/IMPLEMENTATION_PLAN.md" "IMPLEMENTATION_PLAN.md")"
fi
if [[ -z "$AUDIT_WORKFLOW_CONTRACT_FILE" ]]; then
  AUDIT_WORKFLOW_CONTRACT_FILE="$(resolve_input_file "specs/WORKFLOW_CONTRACT.md" "WORKFLOW_CONTRACT.md")"
fi

if [[ -z "$AUDIT_CONTRACT_FILE" || -z "$AUDIT_PLAN_FILE" || -z "$AUDIT_WORKFLOW_CONTRACT_FILE" ]]; then
  echo "[prd_auditor] ERROR: missing contract/plan/workflow contract file (contract=$AUDIT_CONTRACT_FILE plan=$AUDIT_PLAN_FILE workflow=$AUDIT_WORKFLOW_CONTRACT_FILE)" >&2
  exit 2
fi

contract_sha="$(sha256_file "$AUDIT_CONTRACT_FILE")"
plan_sha="$(sha256_file "$AUDIT_PLAN_FILE")"
workflow_sha="$(sha256_file "$AUDIT_WORKFLOW_CONTRACT_FILE")"
prompt_sha="$(sha256_file "$AUDITOR_PROMPT")"

audit_cache_matches() {
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  if [[ ! -f "$AUDIT_CACHE_FILE" || ! -f "$AUDIT_OUTPUT_JSON" ]]; then
    return 1
  fi
  if ! jq -e \
    --arg prd_sha "$expected_sha" \
    --arg contract_sha "$contract_sha" \
    --arg plan_sha "$plan_sha" \
    --arg workflow_sha "$workflow_sha" \
    --arg prompt_sha "$prompt_sha" \
    '
      .prd_sha256 == $prd_sha and
      .contract_sha256 == $contract_sha and
      .impl_plan_sha256 == $plan_sha and
      .workflow_contract_sha256 == $workflow_sha and
      .auditor_prompt_sha256 == $prompt_sha and
      .audited_scope == "full" and
      .decision == "PASS"
    ' "$AUDIT_CACHE_FILE" >/dev/null 2>&1; then
    return 1
  fi
  if ! jq -e \
    --arg prd_sha "$expected_sha" \
    '
      .prd_sha256 == $prd_sha and
      ((.summary.items_fail | tonumber? // 1) == 0) and
      ((.summary.items_blocked | tonumber? // 1) == 0)
    ' "$AUDIT_OUTPUT_JSON" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

if audit_cache_matches; then
  audit_check_prd_file="$AUDIT_PRD_FILE"
  if [[ "$AUDIT_SCOPE" == "slice" ]]; then
    audit_check_prd_file="$AUDIT_PRD_SLICE_FILE"
  fi
  if [[ ! -x "./plans/prd_audit_check.sh" ]]; then
    echo "[prd_auditor] ERROR: missing audit check script: ./plans/prd_audit_check.sh" >&2
    exit 2
  fi
  AUDIT_PROMISE_REQUIRED=0 \
    PRD_FILE="$audit_check_prd_file" \
    AUDIT_FILE="$AUDIT_OUTPUT_JSON" \
    AUDIT_STDOUT="$AUDIT_STDOUT_LOG" \
    ./plans/prd_audit_check.sh
  echo "[prd_auditor] SKIP: audit cache matches inputs and last decision PASS" >&2
  exit 0
fi

mkdir -p ".context"

CONTRACT_SOURCE_FILE="$AUDIT_CONTRACT_FILE" CONTRACT_DIGEST_FILE="$AUDIT_CONTRACT_DIGEST_FILE" ./plans/build_contract_digest.sh
PLAN_SOURCE_FILE="$AUDIT_PLAN_FILE" PLAN_DIGEST_FILE="$AUDIT_PLAN_DIGEST_FILE" ./plans/build_plan_digest.sh

if [[ "$AUDIT_SCOPE" == "slice" ]]; then
  if [[ -z "$AUDIT_SLICE" ]]; then
    echo "[prd_auditor] ERROR: AUDIT_SLICE required when AUDIT_SCOPE=slice" >&2
    exit 2
  fi
  PRD_FILE="$AUDIT_PRD_FILE" \
    PRD_SLICE="$AUDIT_SLICE" \
    CONTRACT_DIGEST="$AUDIT_CONTRACT_DIGEST_FILE" \
    PLAN_DIGEST="$AUDIT_PLAN_DIGEST_FILE" \
    OUT_PRD_SLICE="$AUDIT_PRD_SLICE_FILE" \
    OUT_CONTRACT_DIGEST="$AUDIT_CONTRACT_SLICE_DIGEST_FILE" \
    OUT_PLAN_DIGEST="$AUDIT_PLAN_SLICE_DIGEST_FILE" \
    OUT_META="$AUDIT_META_FILE" \
    ./plans/prd_slice_prepare.sh
else
  if ! command -v jq >/dev/null 2>&1; then
    echo "[prd_auditor] ERROR: jq required to write audit meta" >&2
    exit 2
  fi
  jq -n \
    --arg audit_scope "full" \
    --arg prd_sha "$expected_sha" \
    --arg prd_file "$AUDIT_PRD_FILE" \
    --arg contract_digest "$AUDIT_CONTRACT_DIGEST_FILE" \
    --arg plan_digest "$AUDIT_PLAN_DIGEST_FILE" \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{audit_scope:$audit_scope, prd_sha256:$prd_sha, prd_file:$prd_file, contract_digest:$contract_digest, plan_digest:$plan_digest, generated_at:$generated_at}' \
    > "$AUDIT_META_FILE"
fi

AUDITOR_AGENT_ARGS_ARR=()
if [[ -n "$AUDITOR_AGENT_ARGS" ]]; then
  _old_ifs="$IFS"; IFS=$' \t\n'
  read -r -a AUDITOR_AGENT_ARGS_ARR <<<"$AUDITOR_AGENT_ARGS"
  IFS="$_old_ifs"
fi

run_auditor() {
  local prompt
  prompt="$(cat "$AUDITOR_PROMPT")"
  if [[ -n "$AUDITOR_AGENT_ARGS" ]]; then
    if [[ -n "${AUDITOR_PROMPT_FLAG:-}" ]]; then
      "$AUDITOR_AGENT_CMD" "${AUDITOR_AGENT_ARGS_ARR[@]}" "$AUDITOR_PROMPT_FLAG" "$prompt"
    else
      "$AUDITOR_AGENT_CMD" "${AUDITOR_AGENT_ARGS_ARR[@]}" "$prompt"
    fi
  else
    if [[ -n "${AUDITOR_PROMPT_FLAG:-}" ]]; then
      "$AUDITOR_AGENT_CMD" "$AUDITOR_PROMPT_FLAG" "$prompt"
    else
      "$AUDITOR_AGENT_CMD" "$prompt"
    fi
  fi
}

mkdir -p "$(dirname "$AUDIT_STDOUT_LOG")"
run_auditor > "$AUDIT_STDOUT_LOG" 2>&1

if [[ ! -f "$AUDIT_OUTPUT_JSON" ]]; then
  echo "[prd_auditor] ERROR: auditor did not produce $AUDIT_OUTPUT_JSON" >&2
  exit 3
fi

if command -v jq >/dev/null 2>&1; then
  if ! jq -e . "$AUDIT_OUTPUT_JSON" >/dev/null 2>&1; then
    echo "[prd_auditor] ERROR: $AUDIT_OUTPUT_JSON is not valid JSON" >&2
    exit 4
  fi
  audit_sha="$(jq -r '.prd_sha256 // empty' "$AUDIT_OUTPUT_JSON")"
  if [[ -z "$audit_sha" ]]; then
    echo "[prd_auditor] ERROR: $AUDIT_OUTPUT_JSON missing prd_sha256" >&2
    exit 4
  fi
  if [[ "$audit_sha" != "$expected_sha" ]]; then
    echo "[prd_auditor] ERROR: prd_sha256 mismatch (expected $expected_sha, got $audit_sha)" >&2
    exit 4
  fi
fi

if [[ ! -x "./plans/prd_audit_check.sh" ]]; then
  echo "[prd_auditor] ERROR: missing audit check script: ./plans/prd_audit_check.sh" >&2
  exit 2
fi
audit_check_prd_file="$AUDIT_PRD_FILE"
if [[ "$AUDIT_SCOPE" == "slice" ]]; then
  audit_check_prd_file="$AUDIT_PRD_SLICE_FILE"
fi
AUDIT_PROMISE_REQUIRED=1 \
  PRD_FILE="$audit_check_prd_file" \
  AUDIT_FILE="$AUDIT_OUTPUT_JSON" \
  AUDIT_STDOUT="$AUDIT_STDOUT_LOG" \
  ./plans/prd_audit_check.sh

write_audit_cache() {
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  local decision="BLOCKED"
  local items_fail
  local items_blocked
  items_fail="$(jq -r '.summary.items_fail // empty' "$AUDIT_OUTPUT_JSON" 2>/dev/null || true)"
  items_blocked="$(jq -r '.summary.items_blocked // empty' "$AUDIT_OUTPUT_JSON" 2>/dev/null || true)"
  if [[ "$items_fail" =~ ^[0-9]+$ && "$items_blocked" =~ ^[0-9]+$ ]]; then
    if (( items_fail > 0 )); then
      decision="FAIL"
    elif (( items_blocked > 0 )); then
      decision="BLOCKED"
    else
      decision="PASS"
    fi
  fi
  mkdir -p "$(dirname "$AUDIT_CACHE_FILE")"
  jq -n \
    --arg prd_sha "$expected_sha" \
    --arg contract_sha "$contract_sha" \
    --arg plan_sha "$plan_sha" \
    --arg workflow_sha "$workflow_sha" \
    --arg prompt_sha "$prompt_sha" \
    --arg decision "$decision" \
    --arg audited_scope "$AUDIT_SCOPE" \
    --arg slice "${AUDIT_SLICE:-}" \
    --arg audit_json "$AUDIT_OUTPUT_JSON" \
    --arg contract_file "$AUDIT_CONTRACT_FILE" \
    --arg plan_file "$AUDIT_PLAN_FILE" \
    --arg workflow_file "$AUDIT_WORKFLOW_CONTRACT_FILE" \
    --arg prompt_file "$AUDITOR_PROMPT" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
      prd_sha256: $prd_sha,
      contract_sha256: $contract_sha,
      impl_plan_sha256: $plan_sha,
      workflow_contract_sha256: $workflow_sha,
      auditor_prompt_sha256: $prompt_sha,
      audited_scope: $audited_scope,
      slice: $slice,
      decision: $decision,
      audit_json: $audit_json,
      contract_file: $contract_file,
      plan_file: $plan_file,
      workflow_contract_file: $workflow_file,
      auditor_prompt: $prompt_file,
      timestamp: $timestamp
    }' > "$AUDIT_CACHE_FILE"
}

write_audit_cache
