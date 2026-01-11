#!/usr/bin/env bash
set -euo pipefail

ID="${1:-}"
STATUS="${2:-}"
PRD_FILE="${PRD_FILE:-plans/prd.json}"
VERIFY_SH="${VERIFY_SH:-./plans/verify.sh}"
SKIP_VERIFY_GATE="${SKIP_VERIFY_GATE:-0}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
[[ -n "$ID" && -n "$STATUS" ]] || { echo "Usage: $0 <task_id> <true|false>" >&2; exit 1; }

if [[ "$STATUS" != "true" && "$STATUS" != "false" ]]; then
  echo "ERROR: status must be true or false" >&2
  exit 1
fi

# If setting passes=true, require verify to be green unless explicitly skipped.
if [[ "$STATUS" == "true" && "$SKIP_VERIFY_GATE" != "1" ]]; then
  if [[ -x "$VERIFY_SH" ]]; then
    if ! "$VERIFY_SH" quick >/dev/null 2>&1; then
      echo "ERROR: cannot set passes=true when verify is red (set SKIP_VERIFY_GATE=1 to override)" >&2
      exit 4
    fi
  fi
fi

[[ -f "$PRD_FILE" ]] || { echo "ERROR: missing $PRD_FILE" >&2; exit 1; }

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
