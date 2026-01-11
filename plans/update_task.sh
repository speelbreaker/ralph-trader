#!/usr/bin/env bash
set -euo pipefail

ID="${1:-}"
STATUS="${2:-}"
PRD_FILE="${PRD_FILE:-plans/prd.json}"
STATE_FILE="${RPH_STATE_FILE:-.ralph/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
[[ -n "$ID" && -n "$STATUS" ]] || { echo "Usage: $0 <task_id> <true|false>" >&2; exit 1; }

if [[ "$STATUS" != "true" && "$STATUS" != "false" ]]; then
  echo "ERROR: status must be true or false" >&2
  exit 1
fi

[[ -f "$PRD_FILE" ]] || { echo "ERROR: missing $PRD_FILE" >&2; exit 1; }

if [[ "$STATUS" == "true" ]]; then
  if [[ "${RPH_UPDATE_TASK_OK:-}" != "1" ]]; then
    echo "ERROR: refusing to set passes=true without RPH_UPDATE_TASK_OK=1" >&2
    exit 4
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "ERROR: missing state file: $STATE_FILE" >&2
    exit 5
  fi
  last_rc="$(jq -r '.last_verify_post_rc // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$last_rc" != "0" ]]; then
    echo "ERROR: last_verify_post_rc is not 0 in $STATE_FILE" >&2
    exit 6
  fi
fi

# Ensure PRD is valid
jq . "$PRD_FILE" >/dev/null 2>&1 || { echo "ERROR: $PRD_FILE invalid JSON" >&2; exit 1; }

# Ensure task exists
exists="$(jq --arg id "$ID" '
  if type=="array" then any(.[]; .id==$id)
  else any((.items // [])[]; .id==$id)
  end
' "$PRD_FILE")"

if [[ "$exists" != "true" ]]; then
  echo "ERROR: task id not found in PRD: $ID" >&2
  exit 3
fi

tmp="$(mktemp)"
jq --arg id "$ID" --argjson status "$STATUS" '
  if type=="array" then
    map(if .id == $id then .passes = $status else . end)
  else
    .items = ((.items // []) | map(if .id == $id then .passes = $status else . end))
  end
' "$PRD_FILE" > "$tmp" && mv "$tmp" "$PRD_FILE"

echo "Updated task $ID: passes=$STATUS"
