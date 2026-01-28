#!/usr/bin/env bash
set -euo pipefail

# Parallel slice auditor
# Runs slice audits concurrently with configurable parallelism

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRD_FILE="${PRD_FILE:-plans/prd.json}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
AUDIT_OUTPUT_DIR="${AUDIT_OUTPUT_DIR:-.context/parallel_audits}"
# Optional: filter to specific slices (comma-separated, e.g., "0,1,2" or range "0-5")
AUDIT_SLICES="${AUDIT_SLICES:-}"

if [[ ! -f "$PRD_FILE" ]]; then
  echo "[audit_parallel] ERROR: PRD file not found: $PRD_FILE" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[audit_parallel] ERROR: jq required" >&2
  exit 2
fi

# Get unique slices from PRD
all_slices=$(jq -r '[.items[].slice] | unique | .[]' "$PRD_FILE")

if [[ -z "$all_slices" ]]; then
  echo "[audit_parallel] ERROR: No slices found in PRD" >&2
  exit 2
fi

# Filter slices if AUDIT_SLICES is set
if [[ -n "$AUDIT_SLICES" ]]; then
  # Parse slice filter: supports "0,1,2" or "0-5" or "0-5,7"
  filter_set=""
  IFS=',' read -ra parts <<< "$AUDIT_SLICES"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      # Range: expand "0-5" to "0 1 2 3 4 5"
      for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
        filter_set="$filter_set $i"
      done
    else
      # Single number
      filter_set="$filter_set $part"
    fi
  done
  # Filter all_slices to only include those in filter_set
  slices=""
  for s in $all_slices; do
    if [[ " $filter_set " == *" $s "* ]]; then
      slices="$slices $s"
    fi
  done
  slices=$(echo $slices | tr ' ' '\n' | grep -v '^$' | sort -n | uniq)
  if [[ -z "$slices" ]]; then
    echo "[audit_parallel] ERROR: No matching slices for filter '$AUDIT_SLICES'" >&2
    exit 2
  fi
  echo "[audit_parallel] Filtered to slices: $(echo $slices | tr '\n' ' ')" >&2
else
  slices="$all_slices"
  echo "[audit_parallel] Found slices: $(echo $slices | tr '\n' ' ')" >&2
fi
echo "[audit_parallel] Max parallel: $MAX_PARALLEL" >&2

# Pre-build shared digests ONCE before parallel launch (avoids redundant work)
echo "[audit_parallel] Pre-building shared digests..." >&2
./plans/build_contract_digest.sh
./plans/build_plan_digest.sh
if [[ -f "docs/ROADMAP.md" ]]; then
  SOURCE_FILE="docs/ROADMAP.md" OUTPUT_FILE=".context/roadmap_digest.json" DIGEST_MODE="slim" ./plans/build_markdown_digest.sh
elif [[ -f "ROADMAP.md" ]]; then
  SOURCE_FILE="ROADMAP.md" OUTPUT_FILE=".context/roadmap_digest.json" DIGEST_MODE="slim" ./plans/build_markdown_digest.sh
fi
echo "[audit_parallel] Digests ready" >&2

# Create work dir for outputs
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$AUDIT_OUTPUT_DIR"

# Track pids for parallel execution
declare -a pids=()
declare -a slice_list=()

for slice in $slices; do
  slice_list+=("$slice")
done

running=0
idx=0

while [[ $idx -lt ${#slice_list[@]} ]] || [[ $running -gt 0 ]]; do
  # Launch new jobs if under limit and jobs remain
  while [[ $running -lt $MAX_PARALLEL ]] && [[ $idx -lt ${#slice_list[@]} ]]; do
    slice="${slice_list[$idx]}"
    (
      AUDIT_SCOPE=slice \
      AUDIT_SLICE="$slice" \
      AUDIT_LOCK_FILE="$WORK_DIR/lock_$slice" \
      AUDIT_OUTPUT_JSON="$AUDIT_OUTPUT_DIR/audit_slice_$slice.json" \
      AUDIT_STDOUT_LOG="$WORK_DIR/stdout_$slice.log" \
      AUDIT_CACHE_FILE="$WORK_DIR/cache_$slice.json" \
      AUDIT_META_FILE="$AUDIT_OUTPUT_DIR/meta_$slice.json" \
      AUDIT_PRD_SLICE_FILE="$AUDIT_OUTPUT_DIR/prd_slice_$slice.json" \
      AUDIT_CONTRACT_SLICE_DIGEST_FILE="$AUDIT_OUTPUT_DIR/contract_digest_$slice.json" \
      AUDIT_PLAN_SLICE_DIGEST_FILE="$AUDIT_OUTPUT_DIR/plan_digest_$slice.json" \
      AUDIT_ROADMAP_SLICE_DIGEST_FILE="$AUDIT_OUTPUT_DIR/roadmap_digest_$slice.json" \
      AUDIT_PROGRESS=1 \
      bash plans/run_prd_auditor.sh 2>&1 | sed "s/^/[slice $slice] /"
      echo $? > "$WORK_DIR/rc_$slice"
    ) &
    pids[$slice]=$!
    echo "[audit_parallel] Started slice $slice (pid ${pids[$slice]})" >&2
    ((running++)) || true
    ((idx++)) || true
  done

  # Wait for at least one job to finish
  if [[ $running -gt 0 ]]; then
    wait -n 2>/dev/null || true
    # Count still running
    running=0
    for slice in "${slice_list[@]}"; do
      if [[ -n "${pids[$slice]:-}" ]] && kill -0 "${pids[$slice]}" 2>/dev/null; then
        ((running++)) || true
      fi
    done
  fi
done

# Wait for all remaining jobs
wait

# Collect results
failed=0
passed=0
for slice in "${slice_list[@]}"; do
  rc_file="$WORK_DIR/rc_$slice"
  if [[ -f "$rc_file" ]]; then
    rc=$(cat "$rc_file")
  else
    rc=1
  fi

  if [[ "$rc" != "0" ]]; then
    echo "[audit_parallel] Slice $slice FAILED (rc=$rc)" >&2
    failed=1
  else
    echo "[audit_parallel] Slice $slice PASS" >&2
    ((passed++)) || true
  fi
done

echo "[audit_parallel] Summary: ${passed}/${#slice_list[@]} slices passed" >&2

if [[ $failed -ne 0 ]]; then
  echo "[audit_parallel] FAILED: Some slices failed" >&2
  exit 1
fi

echo "[audit_parallel] PASS: All slices passed" >&2
exit 0
