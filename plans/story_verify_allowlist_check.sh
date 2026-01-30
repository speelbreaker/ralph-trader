#!/usr/bin/env bash
set -euo pipefail

# Compare PRD verify[] vs plans/story_verify_allowlist.txt
# Output missing + orphaned entries; exit 1 on missing allowlist entries
# Read-only; no gate weakening

ALLOWLIST="${RPH_STORY_VERIFY_ALLOWLIST_FILE:-plans/story_verify_allowlist.txt}"
ARG_PRD_FILE=""
FORMAT="text"  # text or json

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="${2:-text}"
      shift 2
      ;;
    --format=*)
      FORMAT="${1#*=}"
      shift
      ;;
    --allowlist)
      ALLOWLIST="${2:-$ALLOWLIST}"
      shift 2
      ;;
    --allowlist=*)
      ALLOWLIST="${1#*=}"
      shift
      ;;
    -*)
      echo "[allowlist_check] ERROR: Unknown option: $1" >&2
      exit 2
      ;;
    *)
      ARG_PRD_FILE="$1"
      shift
      ;;
  esac
done

PRD_FILE="${ARG_PRD_FILE:-${PRD_FILE:-plans/prd.json}}"

if ! command -v jq >/dev/null 2>&1; then
  if [[ "$FORMAT" == "json" ]]; then
    echo '{"status":"error","code":"JQ_NOT_FOUND","message":"jq required"}'
  else
    echo "[allowlist_check] ERROR: jq required" >&2
  fi
  exit 2
fi

if [[ ! -f "$ALLOWLIST" ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    jq -n --arg path "$ALLOWLIST" '{status:"error",code:"ALLOWLIST_NOT_FOUND",message:("Allowlist not found: " + $path)}'
  else
    echo "[allowlist_check] ERROR: Allowlist not found: $ALLOWLIST" >&2
  fi
  exit 2
fi

if [[ ! -f "$PRD_FILE" ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    jq -n --arg path "$PRD_FILE" '{status:"error",code:"PRD_NOT_FOUND",message:("PRD file not found: " + $path)}'
  else
    echo "[allowlist_check] ERROR: PRD file not found: $PRD_FILE" >&2
  fi
  exit 2
fi

# Extract all verify commands from PRD (exclude ./plans/verify.sh)
prd_commands=$(jq -r '.items[].verify[]' "$PRD_FILE" 2>/dev/null | \
  grep -Fxv "./plans/verify.sh" | sort -u || true)

# Load allowlist (strip empty lines and comments)
allowlist_commands=$(grep -v '^[[:space:]]*#' "$ALLOWLIST" 2>/dev/null | grep -v '^[[:space:]]*$' | sort -u || true)

# Find missing (in PRD but not in allowlist)
missing_arr=()
if [[ -n "$prd_commands" ]]; then
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    if ! echo "$allowlist_commands" | grep -Fxq "$cmd"; then
      missing_arr+=("$cmd")
    fi
  done <<< "$prd_commands"
fi

# Find orphaned (in allowlist but not in PRD)
orphaned_arr=()
if [[ -n "$allowlist_commands" ]]; then
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    if [[ -z "$prd_commands" ]] || ! echo "$prd_commands" | grep -Fxq "$cmd"; then
      orphaned_arr+=("$cmd")
    fi
  done <<< "$allowlist_commands"
fi

exit_code=0

if [[ "$FORMAT" == "json" ]]; then
  # JSON output
  if [[ ${#missing_arr[@]} -gt 0 ]]; then
    missing_json=$(printf '%s\n' "${missing_arr[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  else
    missing_json="[]"
  fi

  if [[ ${#orphaned_arr[@]} -gt 0 ]]; then
    orphaned_json=$(printf '%s\n' "${orphaned_arr[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  else
    orphaned_json="[]"
  fi

  if [[ ${#missing_arr[@]} -gt 0 ]]; then
    exit_code=1
    status="fail"
  else
    status="pass"
  fi

  jq -n \
    --arg status "$status" \
    --argjson missing "$missing_json" \
    --argjson orphaned "$orphaned_json" \
    --arg prd_file "$PRD_FILE" \
    --arg allowlist_file "$ALLOWLIST" \
    '{status: $status, missing: $missing, orphaned: $orphaned, prd_file: $prd_file, allowlist_file: $allowlist_file}'
else
  # Text output
  if [[ ${#missing_arr[@]} -gt 0 ]]; then
    echo "[allowlist_check] ERROR: Missing allowlist entries (in PRD but not allowlisted):" >&2
    printf '  %s\n' "${missing_arr[@]}" >&2
    echo "" >&2
    echo "Add to $ALLOWLIST:" >&2
    printf '%s\n' "${missing_arr[@]}" >&2
    exit_code=1
  fi

  if [[ ${#orphaned_arr[@]} -gt 0 ]]; then
    echo "[allowlist_check] WARN: Orphaned allowlist entries (in allowlist but not in PRD):" >&2
    printf '  %s\n' "${orphaned_arr[@]}" >&2
    # Orphans are warnings, not failures
  fi

  if [[ $exit_code -eq 0 ]]; then
    echo "[allowlist_check] PASS: All PRD verify commands are allowlisted" >&2
  fi
fi

exit $exit_code
