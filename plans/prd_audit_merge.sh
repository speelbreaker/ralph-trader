#!/usr/bin/env bash
#
# Merge slice audit outputs into single prd_audit.json
#
# Usage:
#   ./plans/prd_audit_merge.sh [slice_audit_dir]
#
# Environment:
#   PRD_FILE: Path to full PRD (default: plans/prd.json)
#   MERGED_AUDIT_FILE: Output path (default: plans/prd_audit.json)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
PRD_FILE="${PRD_FILE:-$REPO_ROOT/plans/prd.json}"
MERGED_AUDIT_FILE="${MERGED_AUDIT_FILE:-$REPO_ROOT/plans/prd_audit.json}"
AUDIT_OUTPUT_DIR="${1:-$REPO_ROOT/.context/parallel_audits}"

if [[ ! -d "$AUDIT_OUTPUT_DIR" ]]; then
  echo "ERROR: Slice audit directory not found: $AUDIT_OUTPUT_DIR" >&2
  exit 1
fi

# Run merge
PRD_FILE="$PRD_FILE" \
AUDIT_OUTPUT_DIR="$AUDIT_OUTPUT_DIR" \
MERGED_AUDIT_FILE="$MERGED_AUDIT_FILE" \
python3 "$SCRIPT_DIR/prd_audit_merge.py"

# Validate merged output (no promise required for merged audits)
echo "Validating merged audit..." >&2
AUDIT_PROMISE_REQUIRED=0 \
PRD_FILE="$PRD_FILE" \
AUDIT_FILE="$MERGED_AUDIT_FILE" \
"$SCRIPT_DIR/prd_audit_check.sh"

echo "Merge complete: $MERGED_AUDIT_FILE" >&2
