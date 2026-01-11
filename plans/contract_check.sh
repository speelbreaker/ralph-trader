#!/usr/bin/env bash
set -euo pipefail

OUT_PATH="${CONTRACT_REVIEW_OUT:-${1:-}}"
CONTRACT_FILE="${CONTRACT_FILE:-CONTRACT.md}"
PRD_FILE="${PRD_FILE:-plans/prd.json}"

if [[ -z "$OUT_PATH" ]]; then
  echo "ERROR: missing output path (CONTRACT_REVIEW_OUT or arg1)" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

iter_dir="$(cd "$(dirname "$OUT_PATH")" && pwd)"

status="pass"
notes=()

note() { notes+=("$1"); }
fail_note() { status="fail"; notes+=("$1"); }

if [[ ! -f "$CONTRACT_FILE" ]]; then
  fail_note "CONTRACT_FILE missing: $CONTRACT_FILE"
fi

if [[ ! -f "$PRD_FILE" ]]; then
  fail_note "PRD_FILE missing: $PRD_FILE"
fi

selected_id=""
if [[ -f "$iter_dir/selected.json" ]]; then
  selected_id="$(jq -r '.selected_id // empty' "$iter_dir/selected.json")"
else
  fail_note "selected.json missing in $iter_dir"
fi

if [[ -z "$selected_id" ]]; then
  fail_note "selected_id not found"
fi

contract_refs=()
if [[ -n "$selected_id" && -f "$PRD_FILE" ]]; then
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    contract_refs+=("$ref")
  done < <(jq -r --arg id "$selected_id" '.items[] | select(.id==$id) | .contract_refs[]?' "$PRD_FILE")
  if (( ${#contract_refs[@]} == 0 )); then
    fail_note "no contract_refs found for $selected_id"
  fi
fi

if [[ -f "$CONTRACT_FILE" ]]; then
  for ref in "${contract_refs[@]}"; do
    if ! grep -Fq -- "$ref" "$CONTRACT_FILE"; then
      fail_note "contract ref not found in CONTRACT.md: $ref"
    fi
  done
fi

head_before=""
head_after=""
if [[ -f "$iter_dir/head_before.txt" ]]; then
  head_before="$(cat "$iter_dir/head_before.txt" || true)"
fi
if [[ -f "$iter_dir/head_after.txt" ]]; then
  head_after="$(cat "$iter_dir/head_after.txt" || true)"
fi

if [[ -z "$head_before" || -z "$head_after" ]]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  state_file="${RPH_STATE_FILE:-${repo_root}/.ralph/state.json}"
  if [[ -f "$state_file" ]]; then
    head_before="$(jq -r '.head_before // empty' "$state_file")"
    head_after="$(jq -r '.head_after // empty' "$state_file")"
  fi
fi

if [[ -n "$head_before" && -n "$head_after" ]]; then
  if git diff --name-only "$head_before" "$head_after" | grep -qx "plans/verify.sh"; then
    fail_note "plans/verify.sh modified in iteration"
  fi
else
  fail_note "missing head_before/head_after; cannot verify verify.sh diff"
fi

notes_text="$(printf '%s; ' "${notes[@]}" | sed 's/[; ]*$//')"
if [[ -z "$notes_text" ]]; then
  notes_text="ok"
fi

jq -n \
  --arg status "$status" \
  --arg contract_path "$CONTRACT_FILE" \
  --arg notes "$notes_text" \
  '{status: $status, contract_path: $contract_path, notes: $notes}' \
  > "$OUT_PATH"

if [[ "$status" != "pass" ]]; then
  exit 1
fi
