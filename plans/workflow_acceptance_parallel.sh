#!/usr/bin/env bash
set -euo pipefail

# Parallel workflow acceptance test runner
# Usage: ./plans/workflow_acceptance_parallel.sh [jobs] [extra_args...]
#        ./plans/workflow_acceptance_parallel.sh --jobs N [extra_args...]
#
# Runs workflow_acceptance.sh tests in parallel by sharding test IDs across
# multiple workers. Each worker runs a subset of tests in a single invocation
# to amortize the worktree setup cost.
#
# Requirements:
#   - Each worker uses unique --state-file/--status-file (defaults are shared /tmp)
#   - WORKFLOW_ACCEPTANCE_SETUP_MODE=clone or archive (avoids git worktree lock contention)
#   - Chunks are partitioned (no duplicate IDs)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

normalize_cache_dir() {
  local path="$1"
  if [[ -z "$path" ]]; then
    echo ""
    return 0
  fi
  if [[ "$path" != /* ]]; then
    echo "$ROOT/$path"
  else
    echo "$path"
  fi
}

# Default cache location unless explicitly set (empty disables cache).
if [[ -z "${WORKFLOW_ACCEPTANCE_CACHE_DIR+x}" ]]; then
  WORKFLOW_ACCEPTANCE_CACHE_DIR="$ROOT/.ralph/workflow_acceptance_cache"
fi
WORKFLOW_ACCEPTANCE_CACHE_DIR="$(normalize_cache_dir "${WORKFLOW_ACCEPTANCE_CACHE_DIR:-}")"
export WORKFLOW_ACCEPTANCE_CACHE_DIR

usage() {
  cat <<'EOF'
Usage: ./plans/workflow_acceptance_parallel.sh [jobs] [extra_args...]
       ./plans/workflow_acceptance_parallel.sh --jobs N [extra_args...]

Options:
  --jobs N   Number of parallel workers (default: 4)
  --help     Show this help
EOF
}

prepare_cache_repo() {
  local cache_dir="$1"
  local err_file
  if [[ -z "$cache_dir" ]]; then
    return 0
  fi
  err_file="$(mktemp)"
  mkdir -p "$(dirname "$cache_dir")"
  if [[ -d "$cache_dir" ]]; then
    if [[ ! -d "$cache_dir/objects" ]]; then
      echo "FAIL: cache dir exists but is not a git repo: $cache_dir" >&2
      rm -f "$err_file"
      return 1
    fi
    git -C "$cache_dir" remote set-url origin "$ROOT" >/dev/null 2>&1 || true
    if ! git -C "$cache_dir" fetch --prune origin >/dev/null 2>"$err_file"; then
      echo "FAIL: cache fetch failed: $(cat "$err_file" 2>/dev/null || true)" >&2
      rm -f "$err_file"
      return 1
    fi
  else
    if ! git clone --mirror "$ROOT" "$cache_dir" >/dev/null 2>"$err_file"; then
      echo "FAIL: cache clone failed: $(cat "$err_file" 2>/dev/null || true)" >&2
      rm -f "$err_file"
      return 1
    fi
  fi
  rm -f "$err_file"
  return 0
}

JOBS=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      JOBS="${2:-}"
      if [[ -z "$JOBS" ]]; then
        echo "FAIL: --jobs requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      if [[ -z "$JOBS" && "$1" =~ ^[0-9]+$ ]]; then
        JOBS="$1"
      else
        EXTRA_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ -z "$JOBS" ]]; then
  JOBS=4
fi

if ! [[ "$JOBS" =~ ^[0-9]+$ ]]; then
  echo "FAIL: jobs must be a positive integer (got: $JOBS)" >&2
  exit 2
fi
if (( JOBS < 1 )); then
  echo "FAIL: jobs must be >= 1 (got: $JOBS)" >&2
  exit 2
fi

if [[ -n "$WORKFLOW_ACCEPTANCE_CACHE_DIR" ]]; then
  if ! prepare_cache_repo "$WORKFLOW_ACCEPTANCE_CACHE_DIR"; then
    exit 1
  fi
  export WORKFLOW_ACCEPTANCE_CACHE_READY=1
fi

# Get unique test IDs from --list output (dedupe duplicates if present)
ALL_IDS=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  ALL_IDS+=("$id")
done < <("$ROOT/plans/workflow_acceptance.sh" --list 2>/dev/null | awk '{print $1}' | sort -u)

if [[ ${#ALL_IDS[@]} -eq 0 ]]; then
  echo "FAIL: no test IDs found from --list" >&2
  exit 1
fi

total=${#ALL_IDS[@]}
echo "Found $total unique test IDs, sharding across $JOBS workers..."

# Calculate chunk size (ceiling division)
chunk_size=$(( (total + JOBS - 1) / JOBS ))

run_chunk() {
  local chunk_id=$1
  local start=$2
  local end=$3
  shift 3

  # Slice array
  local -a chunk_ids
  chunk_ids=("${ALL_IDS[@]:start:end-start}")
  if [[ ${#chunk_ids[@]} -eq 0 ]]; then
    echo "Chunk $chunk_id: empty (skipped)"
    return 0
  fi

  # Join with commas
  local csv
  csv=$(IFS=','; echo "${chunk_ids[*]}")

  local state_file="/tmp/wa_state_${chunk_id}_$$"
  local status_file="/tmp/wa_status_${chunk_id}_$$"

  local last_idx=$(( ${#chunk_ids[@]} - 1 ))
  local last_id="${chunk_ids[$last_idx]}"
  echo "Chunk $chunk_id: ${#chunk_ids[@]} tests (${chunk_ids[0]}..${last_id})"

  # Use clone mode to avoid git worktree lock contention
  WORKFLOW_ACCEPTANCE_SETUP_MODE=clone \
    "$ROOT/plans/workflow_acceptance.sh" \
    "$@" \
    --only-set "$csv" \
    --state-file "$state_file" \
    --status-file "$status_file" || return $?
}

main() {
  local pids=()
  local exit_status=0
  local chunk_id=0
  
  # Launch workers with contiguous chunks
  for ((start=0; start<total; start+=chunk_size)); do
    local end=$((start + chunk_size))
    if ((end > total)); then end=$total; fi
    
    run_chunk "$chunk_id" "$start" "$end" "$@" &
    pids+=($!)
    ((chunk_id++))
  done
  
  echo "Launched ${#pids[@]} workers, waiting for completion..."
  
  # Collect and propagate failures
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      exit_status=1
    fi
  done
  
  if [[ $exit_status -eq 0 ]]; then
    echo "All workers completed successfully"
  else
    echo "FAIL: one or more workers failed" >&2
  fi
  
  exit $exit_status
}

main "${EXTRA_ARGS[@]}"
