#!/usr/bin/env bash
set -euo pipefail

# Golden Repro Harness
# Modes:
#   validate     - Prove repro is real (bad_commit fails, good_commit passes)
#   apply_patch  - Test a fix against a repro

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Timeout command detection (like plans/verify.sh)
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
else
  TIMEOUT_CMD=""
fi

# Worktree cleanup (MUST use git worktree remove, not rm -rf alone)
WORKTREES_TO_CLEAN=()
cleanup() {
  for wt in "${WORKTREES_TO_CLEAN[@]}"; do
    git worktree remove -f "$wt" 2>/dev/null || true
    rm -rf "$wt" 2>/dev/null || true
  done
}
trap cleanup EXIT

die() {
  echo "ERROR: $*" >&2
  exit 2
}

usage() {
  cat <<EOF
Usage: $0 <mode> <repro-name> [options]

Modes:
  validate                     Prove repro is real (bad fails, good passes)
  apply_patch <patch-file>     Apply patch and verify fix

Examples:
  $0 validate preflight-env-var
  $0 apply_patch preflight-env-var fix.patch

Environment:
  RUN_ID     Override run ID (default: timestamp)
EOF
  exit 2
}

# Timeout exit codes (GNU timeout=124, killed=137, SIGTERM=143)
is_timeout() { [[ "$1" -eq 124 || "$1" -eq 137 || "$1" -eq 143 ]]; }

# Run command with timeout
run_with_timeout() {
  local cmd="$1"
  local timeout="$2"
  if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD "$timeout" bash -c "$cmd"
  else
    bash -c "$cmd"
  fi
}

MODE="${1:-}"
REPRO_NAME="${2:-}"

[[ -n "$MODE" ]] || usage
[[ -n "$REPRO_NAME" ]] || usage

# Load manifest
manifest="evals/repros/manifest.json"
[[ -f "$manifest" ]] || die "Manifest not found: $manifest"

# Extract repro config (use --arg for safe escaping)
repro=$(jq -c --arg name "$REPRO_NAME" '.repros[] | select(.name == $name)' "$manifest")

if [[ -z "$repro" || "$repro" == "null" ]]; then
  echo "ERROR: Unknown repro: $REPRO_NAME" >&2
  echo "Available repros:" >&2
  jq -r '.repros[].name' "$manifest" | sed 's/^/  /' >&2
  exit 2
fi

# Parse repro fields
bad_commit=$(echo "$repro" | jq -r '.bad_commit')
good_commit=$(echo "$repro" | jq -r '.good_commit')
validate_cmd=$(echo "$repro" | jq -r '.validate_cmd')
verify_cmd=$(echo "$repro" | jq -r '.verify_cmd')
validate_timeout=$(echo "$repro" | jq -r '.validate_timeout_secs // 30')
verify_timeout=$(echo "$repro" | jq -r '.verify_timeout_secs // 300')
bad_output_regex=$(echo "$repro" | jq -r '.bad_output_regex // ""')
branch=$(echo "$repro" | jq -r '.branch')

# Assert branch exists and matches expected SHA (prevents drift)
if ! actual_sha=$(git rev-parse "$branch" 2>/dev/null); then
  echo "ERROR: Branch not found: $branch" >&2
  echo "Create it with: git branch $branch $bad_commit" >&2
  exit 2
fi

if [[ "$actual_sha" != "$bad_commit" ]]; then
  echo "ERROR: Branch $branch has drifted" >&2
  echo "  expected: $bad_commit" >&2
  echo "  actual:   $actual_sha" >&2
  echo "Fix with: git branch -f $branch $bad_commit" >&2
  exit 2
fi

case "$MODE" in
  validate)
    echo "=== Validating repro: $REPRO_NAME ===" >&2

    # Test 1: bad_commit must fail
    echo "[1/2] Testing bad_commit (should fail)..." >&2
    worktree=$(mktemp -d)
    WORKTREES_TO_CLEAN+=("$worktree")
    git worktree add -f "$worktree" "$bad_commit" >/dev/null 2>&1

    bad_out=""
    bad_rc=0
    set +e
    bad_out="$(cd "$worktree" && run_with_timeout "$validate_cmd" "$validate_timeout" 2>&1)"
    bad_rc=$?
    set -e

    if [[ "$bad_rc" -eq 0 ]]; then
      echo "INVALID: bad_commit passes (should fail)" >&2
      echo "Command: $validate_cmd" >&2
      echo "Output:" >&2
      echo "$bad_out" | head -20 >&2
      exit 1
    fi

    if is_timeout "$bad_rc"; then
      echo "INVALID: bad_commit timed out (not a real failure)" >&2
      exit 1
    fi

    # Assert failure reason (not just "python missing")
    if [[ -n "$bad_output_regex" ]]; then
      if ! echo "$bad_out" | grep -qiE "$bad_output_regex"; then
        echo "INVALID: bad_commit failed but for wrong reason" >&2
        echo "Expected regex: $bad_output_regex" >&2
        echo "Actual output:" >&2
        echo "$bad_out" | head -20 >&2
        exit 1
      fi
    fi

    echo "  PASS: bad_commit fails as expected (exit $bad_rc)" >&2

    # Test 2: good_commit must pass
    echo "[2/2] Testing good_commit (should pass)..." >&2
    worktree2=$(mktemp -d)
    WORKTREES_TO_CLEAN+=("$worktree2")
    git worktree add -f "$worktree2" "$good_commit" >/dev/null 2>&1

    good_out=""
    good_rc=0
    set +e
    good_out="$(cd "$worktree2" && run_with_timeout "$validate_cmd" "$validate_timeout" 2>&1)"
    good_rc=$?
    set -e

    if [[ "$good_rc" -ne 0 ]]; then
      echo "INVALID: good_commit fails (should pass)" >&2
      echo "Command: $validate_cmd" >&2
      echo "Exit code: $good_rc" >&2
      echo "Output:" >&2
      echo "$good_out" | head -20 >&2
      exit 1
    fi

    echo "  PASS: good_commit passes (exit 0)" >&2
    echo ""
    echo "VALID: repro '$REPRO_NAME' validated successfully"
    ;;

  apply_patch)
    patch_file="${3:-}"
    run_id="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
    results_dir="evals/results/$run_id"
    mkdir -p "$results_dir"

    # Validate patch file
    [[ -n "$patch_file" ]] || die "Missing patch file argument"
    # Normalize to absolute path
    [[ "$patch_file" = /* ]] || patch_file="$ROOT/$patch_file"
    [[ -f "$patch_file" ]] || die "Patch file not found: $patch_file"

    echo "=== Applying patch to repro: $REPRO_NAME ===" >&2

    worktree=$(mktemp -d)
    WORKTREES_TO_CLEAN+=("$worktree")
    git worktree add -f "$worktree" "$bad_commit" >/dev/null 2>&1

    # Apply patch
    echo "[1/3] Applying patch..." >&2
    if ! (cd "$worktree" && git apply "$patch_file" 2>&1); then
      echo "ERROR: Failed to apply patch" >&2
      exit 2
    fi

    (cd "$worktree" && git add -A)

    # Guard: empty patch produces no changes
    if (cd "$worktree" && git diff --cached --quiet); then
      echo "ERROR: Patch produced no changes" >&2
      exit 2
    fi

    # Commit with inline config (no identity required)
    (cd "$worktree" && \
      git -c user.name="repro-bot" -c user.email="repro-bot@local" \
        commit -m "Apply patch" --no-gpg-sign) >/dev/null 2>&1

    # Run validate_cmd to prove the fix works
    echo "[2/3] Running validate_cmd (proving fix)..." >&2
    start_time=$(date +%s)
    set +e
    validate_out="$(cd "$worktree" && run_with_timeout "$validate_cmd" "$validate_timeout" 2>&1)"
    validate_rc=$?
    set -e

    if [[ "$validate_rc" -ne 0 ]]; then
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      status="fail"
      is_timeout "$validate_rc" && status="timeout"

      echo "FAIL: Patch did not fix the repro" >&2
      echo "validate_cmd exit: $validate_rc" >&2
      echo "Output:" >&2
      echo "$validate_out" | head -20 >&2

      jq -n \
        --arg repro "$REPRO_NAME" \
        --arg bad_commit "$bad_commit" \
        --arg good_commit "$good_commit" \
        --arg validate_cmd "$validate_cmd" \
        --arg status "$status" \
        --arg rc "$validate_rc" \
        --arg duration "$duration" \
        --arg validate_timeout "$validate_timeout" \
        --arg timestamp "$(date -Iseconds)" \
        --arg output_head "$(printf '%s\n' "$validate_out" | head -50)" \
        '{
          repro: $repro,
          bad_commit: $bad_commit,
          good_commit: $good_commit,
          validate_cmd: $validate_cmd,
          status: $status,
          exit_code: ($rc | tonumber),
          duration_secs: ($duration | tonumber),
          validate_timeout_secs: ($validate_timeout | tonumber),
          timestamp: $timestamp,
          output_head: $output_head,
          phase: "validate_after_patch"
        }' > "$results_dir/${REPRO_NAME}.json"
      exit 1
    fi

    echo "  PASS: validate_cmd passes" >&2

    # Run verify_cmd for regression coverage
    echo "[3/3] Running verify_cmd (regression check)..." >&2
    set +e
    verify_out="$(cd "$worktree" && BASE_REF="$bad_commit" run_with_timeout "$verify_cmd" "$verify_timeout" 2>&1)"
    verify_rc=$?
    set -e
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine status
    status="fail"
    [[ "$verify_rc" -eq 0 ]] && status="pass"
    is_timeout "$verify_rc" && status="timeout"

    # Record result
    jq -n \
      --arg repro "$REPRO_NAME" \
      --arg bad_commit "$bad_commit" \
      --arg good_commit "$good_commit" \
      --arg verify_cmd "$verify_cmd" \
      --arg status "$status" \
      --arg rc "$verify_rc" \
      --arg duration "$duration" \
      --arg verify_timeout "$verify_timeout" \
      --arg timestamp "$(date -Iseconds)" \
      --arg output_head "$(printf '%s\n' "$verify_out" | head -50)" \
      '{
        repro: $repro,
        bad_commit: $bad_commit,
        good_commit: $good_commit,
        verify_cmd: $verify_cmd,
        status: $status,
        exit_code: ($rc | tonumber),
        duration_secs: ($duration | tonumber),
        verify_timeout_secs: ($verify_timeout | tonumber),
        timestamp: $timestamp,
        output_head: $output_head,
        phase: "verify_after_patch"
      }' > "$results_dir/${REPRO_NAME}.json"

    if [[ "$verify_rc" -eq 0 ]]; then
      echo ""
      echo "PASS: Patch fixes repro '$REPRO_NAME'"
      echo "Result: $results_dir/${REPRO_NAME}.json"
    else
      echo ""
      echo "FAIL: Patch fixes validate but fails verify"
      echo "Result: $results_dir/${REPRO_NAME}.json"
    fi
    exit $verify_rc
    ;;

  *)
    echo "ERROR: Unknown mode: $MODE" >&2
    usage
    ;;
esac
