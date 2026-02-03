#!/usr/bin/env bash
set -euo pipefail

# Parallel slice auditor with incremental caching
# Runs slice audits concurrently with configurable parallelism
# Caches PASS/FAIL results to skip unchanged slices

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRD_FILE="${PRD_FILE:-plans/prd.json}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
AUDIT_OUTPUT_DIR="${AUDIT_OUTPUT_DIR:-.context/parallel_audits}"
# Optional: filter to specific slices (comma-separated, e.g., "0,1,2" or range "0-5")
AUDIT_SLICES="${AUDIT_SLICES:-}"
# Set to 1 to force re-audit all slices (ignore cache)
AUDIT_NO_CACHE="${AUDIT_NO_CACHE:-0}"

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
else
  rm -f ".context/roadmap_digest.json"
  echo "[audit_parallel] No roadmap found, removed stale digest" >&2
fi
echo "[audit_parallel] Digests ready" >&2

# Create work dir for outputs
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$AUDIT_OUTPUT_DIR"

# Build slice list
declare -a slice_list=()
for slice in $slices; do
  slice_list+=("$slice")
done

# Check cache to determine which slices need re-auditing
declare -a valid_slices=()
declare -a invalid_slices=()
declare -a reused_slices=()

if [[ "$AUDIT_NO_CACHE" == "1" ]]; then
  echo "[audit_parallel] Cache disabled (AUDIT_NO_CACHE=1), re-auditing all slices" >&2
  invalid_slices=("${slice_list[@]}")
else
  # Convert slice list to comma-separated for cache check
  slice_csv=$(IFS=','; echo "${slice_list[*]}")

  echo "[audit_parallel] Checking cache..." >&2
  if ! cache_result=$(REPO_ROOT="$ROOT" PRD_FILE="$PRD_FILE" AUDIT_OUTPUT_DIR="$AUDIT_OUTPUT_DIR" \
      python3 plans/prd_cache_check.py --slices "$slice_csv" 2>&1); then
    echo "[audit_parallel] ERROR: cache check failed: $cache_result" >&2
    exit 2
  fi

  # Parse cache result
  for s in $(echo "$cache_result" | jq -r '.valid_slices[]' 2>/dev/null); do
    valid_slices+=("$s")
  done
  for s in $(echo "$cache_result" | jq -r '.invalid_slices[]' 2>/dev/null); do
    invalid_slices+=("$s")
  done

  # If cache check failed, treat all as invalid
  if [[ ${#valid_slices[@]} -eq 0 ]] && [[ ${#invalid_slices[@]} -eq 0 ]]; then
    echo "[audit_parallel] Cache check failed, re-auditing all slices" >&2
    invalid_slices=("${slice_list[@]}")
  fi

  if [[ ${#valid_slices[@]} -gt 0 ]]; then
    echo "[audit_parallel] Cache hits: ${valid_slices[*]}" >&2
  fi
  if [[ ${#invalid_slices[@]} -gt 0 ]]; then
    echo "[audit_parallel] Cache misses: ${invalid_slices[*]}" >&2
  fi
fi

# Process cached slices: copy from cache and validate
for slice in "${valid_slices[@]}"; do
  cached_audit=$(jq -r ".slices[\"$slice\"].audit_json // empty" .context/prd_audit_slice_cache.json 2>/dev/null || true)

  if [[ -n "$cached_audit" ]] && [[ -f "$cached_audit" ]]; then
    # Validate cached path is under repo root (trust boundary)
    cached_audit_real=$(python3 - "$cached_audit" "$ROOT" <<'PY'
import os, sys
path = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])
print(path)
sys.exit(0 if path.startswith(root + os.sep) else 1)
PY
    ) || {
      echo "[audit_parallel] Slice $slice: cached path outside repo, re-audit" >&2
      invalid_slices+=("$slice")
      continue
    }

    # Copy cached audit to output directory
    cp "$cached_audit_real" "$AUDIT_OUTPUT_DIR/audit_slice_$slice.json"

    # Prepare slice PRD and digests for merge (run slice_prepare in prep-only mode)
    # If prep fails, treat as cache miss and re-audit
    if ! PRD_FILE="$PRD_FILE" \
         PRD_SLICE="$slice" \
         CONTRACT_DIGEST=".context/contract_digest.json" \
         PLAN_DIGEST=".context/plan_digest.json" \
         ROADMAP_DIGEST=".context/roadmap_digest.json" \
         OUT_PRD_SLICE="$AUDIT_OUTPUT_DIR/prd_slice_$slice.json" \
         OUT_CONTRACT_DIGEST="$AUDIT_OUTPUT_DIR/contract_digest_$slice.json" \
         OUT_PLAN_DIGEST="$AUDIT_OUTPUT_DIR/plan_digest_$slice.json" \
         OUT_ROADMAP_DIGEST="$AUDIT_OUTPUT_DIR/roadmap_digest_$slice.json" \
         OUT_AUDIT_FILE="$AUDIT_OUTPUT_DIR/audit_slice_$slice.json" \
         OUT_META="$AUDIT_OUTPUT_DIR/meta_$slice.json" \
         ./plans/prd_slice_prepare.sh >/dev/null 2>&1; then
      echo "[audit_parallel] Slice $slice: cache prep failed, re-audit" >&2
      invalid_slices+=("$slice")
      continue
    fi

    # Validate cached audit
    if AUDIT_PROMISE_REQUIRED=0 \
       PRD_FILE="$AUDIT_OUTPUT_DIR/prd_slice_$slice.json" \
       AUDIT_FILE="$AUDIT_OUTPUT_DIR/audit_slice_$slice.json" \
       AUDIT_META_FILE="$AUDIT_OUTPUT_DIR/meta_$slice.json" \
       ./plans/prd_audit_check.sh >/dev/null 2>&1; then
      echo "[audit_parallel] Slice $slice: CACHE HIT (reused)" >&2
      reused_slices+=("$slice")
    else
      echo "[audit_parallel] Slice $slice: CACHE HIT but validation failed, will re-audit" >&2
      # Add to invalid list for re-audit
      invalid_slices+=("$slice")
    fi
  else
    echo "[audit_parallel] Slice $slice: CACHE HIT but file missing, will re-audit" >&2
    invalid_slices+=("$slice")
  fi
done

# Run parallel audits for invalid slices
declare -a pids=()
declare -a audited_slices=()

# Check wait -n support (bash 4.3+; macOS ships bash 3.2 by default)
_wait_n_supported=0
if [[ ${BASH_VERSINFO[0]} -gt 4 ]] || \
   [[ ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 3 ]]; then
  _wait_n_supported=1
fi

running=0
idx=0

while [[ $idx -lt ${#invalid_slices[@]} ]] || [[ $running -gt 0 ]]; do
  # Launch new jobs if under limit and jobs remain
  while [[ $running -lt $MAX_PARALLEL ]] && [[ $idx -lt ${#invalid_slices[@]} ]]; do
    slice="${invalid_slices[$idx]}"
    audited_slices+=("$slice")
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
    if [[ "$_wait_n_supported" == "1" ]]; then
      # bash 4.3+: use wait -n (ignore exit code, we check job status separately)
      wait -n 2>/dev/null || true
    else
      # bash <4.3: poll for any PID to finish
      while :; do
        for slice in "${invalid_slices[@]}"; do
          if [[ -n "${pids[$slice]:-}" ]] && ! kill -0 "${pids[$slice]}" 2>/dev/null; then
            break 2
          fi
        done
        sleep 0.2
      done
    fi
    # Count still running
    running=0
    for slice in "${invalid_slices[@]}"; do
      if [[ -n "${pids[$slice]:-}" ]] && kill -0 "${pids[$slice]}" 2>/dev/null; then
        ((running++)) || true
      fi
    done
  fi
done

# Wait for all remaining jobs
wait

# Collect results for audited slices
failed=0
passed=0
for slice in "${audited_slices[@]}"; do
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
    echo "[audit_parallel] Slice $slice PASS (fresh audit)" >&2
    ((passed++)) || true
  fi
done

# Update cache for all freshly audited slices (sequential to avoid race)
# Note: cache update errors are non-fatal (audit already succeeded, we just can't cache it)
echo "[audit_parallel] Updating cache for ${#audited_slices[@]} audited slices..." >&2
for slice in "${audited_slices[@]}"; do
  audit_file="$AUDIT_OUTPUT_DIR/audit_slice_$slice.json"
  if [[ -f "$audit_file" ]]; then
    cache_err=$(REPO_ROOT="$ROOT" PRD_FILE="$PRD_FILE" \
      python3 plans/prd_cache_update.py "$slice" "$audit_file" 2>&1) || {
      echo "[audit_parallel] WARNING: cache update failed for slice $slice: $cache_err" >&2
    }
  fi
done

# Count total passed (cached + fresh)
total_passed=$((${#reused_slices[@]} + passed))
echo "[audit_parallel] Summary: $total_passed/${#slice_list[@]} slices passed (${#reused_slices[@]} cached, $passed fresh)" >&2

if [[ $failed -ne 0 ]]; then
  echo "[audit_parallel] FAILED: Some slices failed" >&2
  exit 1
fi

echo "[audit_parallel] All slices passed, merging..." >&2

# Merge slice audits into single prd_audit.json
if ! ./plans/prd_audit_merge.sh "$AUDIT_OUTPUT_DIR"; then
  echo "[audit_parallel] ERROR: Merge failed" >&2
  exit 1
fi

echo "[audit_parallel] PASS: Merged audit written to plans/prd_audit.json" >&2
exit 0
