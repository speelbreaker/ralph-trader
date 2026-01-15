#!/usr/bin/env bash
set -euo pipefail

ID="${1:-}"
STATUS="${2:-}"
PRD_FILE="${PRD_FILE:-plans/prd.json}"
STATE_FILE="${RPH_STATE_FILE:-.ralph/state.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git required" >&2; exit 2; }
[[ -n "$ID" && -n "$STATUS" ]] || { echo "Usage: $0 <task_id> <true|false>" >&2; exit 1; }

if [[ "$STATUS" != "true" && "$STATUS" != "false" ]]; then
  echo "ERROR: status must be true or false" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: not inside a git repository" >&2
  exit 2
fi
cd "$REPO_ROOT"

[[ -f "$PRD_FILE" ]] || { echo "ERROR: missing $PRD_FILE" >&2; exit 1; }

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

if [[ "$STATUS" == "true" ]]; then
  if [[ "${RPH_UPDATE_TASK_OK:-}" != "1" ]]; then
    echo "ERROR: refusing to set passes=true without RPH_UPDATE_TASK_OK=1" >&2
    exit 4
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "ERROR: missing state file: $STATE_FILE" >&2
    exit 5
  fi
  jq -e . "$STATE_FILE" >/dev/null 2>&1 || { echo "ERROR: $STATE_FILE invalid JSON" >&2; exit 5; }
  last_rc="$(jq -r '.last_verify_post_rc // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$last_rc" != "0" ]]; then
    echo "ERROR: last_verify_post_rc is not 0 in $STATE_FILE" >&2
    exit 6
  fi
  selected_id="$(jq -r '.selected_id // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$selected_id" ]]; then
    echo "ERROR: state missing selected_id in $STATE_FILE" >&2
    exit 6
  fi
  if [[ "$selected_id" != "$ID" ]]; then
    echo "ERROR: selected_id mismatch (state=$selected_id task=$ID)" >&2
    exit 6
  fi
  verify_post_head="$(jq -r '.last_verify_post_head // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$verify_post_head" ]]; then
    echo "ERROR: state missing last_verify_post_head in $STATE_FILE" >&2
    exit 6
  fi
  current_head="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$current_head" ]]; then
    echo "ERROR: unable to resolve git HEAD" >&2
    exit 6
  fi
  if [[ "$verify_post_head" != "$current_head" ]]; then
    echo "ERROR: verify_post_head does not match current HEAD (verify_post_head=$verify_post_head current=$current_head)" >&2
    exit 6
  fi
  verify_post_log="$(jq -r '.last_verify_post_log // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$verify_post_log" || ! -f "$verify_post_log" ]]; then
    echo "ERROR: verify_post_log missing or not found (state=$verify_post_log)" >&2
    exit 6
  fi
  verify_post_log_sha="$(jq -r '.last_verify_post_log_sha256 // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$verify_post_log_sha" ]]; then
    echo "ERROR: state missing last_verify_post_log_sha256 in $STATE_FILE" >&2
    exit 6
  fi
  actual_log_sha="$(sha256_file "$verify_post_log")"
  if [[ -z "$actual_log_sha" || "$actual_log_sha" != "$verify_post_log_sha" ]]; then
    echo "ERROR: verify_post_log sha mismatch (state=$verify_post_log_sha actual=$actual_log_sha)" >&2
    exit 6
  fi
  last_mode="$(jq -r '.last_verify_post_mode // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$last_mode" ]]; then
    echo "ERROR: state missing last_verify_post_mode in $STATE_FILE" >&2
    exit 6
  fi
  if [[ "$last_mode" != "full" && "$last_mode" != "promotion" && "$last_mode" != "strict" ]]; then
    echo "ERROR: last_verify_post_mode not eligible for pass flip (mode=$last_mode)" >&2
    exit 6
  fi
fi

# Ensure PRD is valid
jq . "$PRD_FILE" >/dev/null 2>&1 || { echo "ERROR: $PRD_FILE invalid JSON" >&2; exit 1; }
if ! jq -e '.items and (.items | type == "array")' "$PRD_FILE" >/dev/null 2>&1; then
  echo "ERROR: PRD must be an object with .items array: $PRD_FILE" >&2
  exit 1
fi

# Ensure task exists
exists="$(jq --arg id "$ID" '
  any(.items[]; .id==$id)
' "$PRD_FILE")"

if [[ "$exists" != "true" ]]; then
  echo "ERROR: task id not found in PRD: $ID" >&2
  exit 3
fi

tmp="$(mktemp)"
jq --arg id "$ID" --argjson status "$STATUS" '
  .items = (.items | map(if .id == $id then .passes = $status else . end))
' "$PRD_FILE" > "$tmp" && mv "$tmp" "$PRD_FILE"

echo "Updated task $ID: passes=$STATUS"
