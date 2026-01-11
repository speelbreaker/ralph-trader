#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${PRD_FILE:-plans/prd.json}"
STORY_ID="${1:-}"
ITER_DIR="${2:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for contract check" >&2
  exit 2
fi

if [[ ! -f "$PRD_FILE" ]]; then
  echo "ERROR: missing PRD file: $PRD_FILE" >&2
  exit 3
fi

if ! jq . "$PRD_FILE" >/dev/null 2>&1; then
  echo "ERROR: PRD is not valid JSON: $PRD_FILE" >&2
  exit 4
fi

if [[ -z "$STORY_ID" ]]; then
  echo "ERROR: contract_check requires story id as first arg" >&2
  exit 5
fi

contract_path="$(jq -r '.source.contract_path // empty' "$PRD_FILE")"
if [[ -n "$contract_path" && ! -f "$contract_path" ]]; then
  echo "ERROR: contract_path from PRD is missing: $contract_path" >&2
  contract_path=""
fi
if [[ -z "$contract_path" ]]; then
  if [[ -f "CONTRACT.md" ]]; then
    contract_path="CONTRACT.md"
  elif [[ -f "specs/CONTRACT.md" ]]; then
    contract_path="specs/CONTRACT.md"
  fi
fi

if [[ -z "$contract_path" ]]; then
  echo "ERROR: CONTRACT.md missing (expected CONTRACT.md or specs/CONTRACT.md)" >&2
  exit 6
fi

story_json="$(jq -c --arg id "$STORY_ID" '
  def items: if type=="array" then . else (.items // []) end;
  items[] | select(.id==$id)
' "$PRD_FILE")"

if [[ -z "$story_json" ]]; then
  echo "ERROR: story id not found in PRD: $STORY_ID" >&2
  exit 7
fi

mapfile -t refs < <(jq -r '.contract_refs[]?' <<<"$story_json")
if [[ "${#refs[@]}" -eq 0 ]]; then
  echo "ERROR: contract_refs missing for story: $STORY_ID" >&2
  exit 8
fi

missing_refs=()
for ref in "${refs[@]}"; do
  if ! grep -Fq "$ref" "$contract_path"; then
    missing_refs+=("$ref")
  fi
done

status="PASS"
if [[ "${#missing_refs[@]}" -gt 0 ]]; then
  status="FAIL"
fi

if [[ -n "$ITER_DIR" ]]; then
  mkdir -p "$ITER_DIR"
  jq -n \
    --arg status "$status" \
    --arg story_id "$STORY_ID" \
    --arg contract_path "$contract_path" \
    --argjson checked_refs "$(printf '%s\n' "${refs[@]}" | jq -R . | jq -s .)" \
    --argjson missing_refs "$(printf '%s\n' "${missing_refs[@]}" | jq -R . | jq -s .)" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{status:$status, story_id:$story_id, contract_path:$contract_path, checked_refs:$checked_refs, missing_refs:$missing_refs, timestamp_utc:$ts}' \
    > "$ITER_DIR/contract_review.json"
fi

if [[ "$status" != "PASS" ]]; then
  echo "ERROR: contract_refs not found in contract file: ${missing_refs[*]}" >&2
  exit 9
fi

echo "Contract check OK for $STORY_ID"
