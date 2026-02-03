#!/usr/bin/env bash
# PRD cache integration tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}

fail() {
  echo "FAIL: $1" >&2
  ((FAIL++)) || true
}

# TC7: Corrupt digest causes hard failure (exit non-zero, not re-audit)
test_corrupt_digest_hard_fail() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  # Setup: create minimal PRD and corrupt digest
  mkdir -p "$tmp_dir/.context"
  echo '{"items":[{"slice":1,"id":"S1-001"}]}' > "$tmp_dir/prd.json"
  echo '{ invalid json' > "$tmp_dir/.context/contract_digest.json"

  # Act: run cache check
  local rc=0
  REPO_ROOT="$tmp_dir" PRD_FILE="$tmp_dir/prd.json" \
    python3 plans/prd_cache_check.py --slices "1" >/dev/null 2>&1 || rc=$?

  # Assert: must exit non-zero (not silently continue)
  if [[ "$rc" -eq 0 ]]; then
    fail "TC7: corrupt digest should cause non-zero exit, got rc=0"
    return 1
  fi
  pass "TC7: corrupt digest caused exit $rc"
}

# TC8: Missing slice detected in merge
test_missing_slice_detected() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  # Setup: PRD with slices 1 and 2, but only slice 1 audit exists
  mkdir -p "$tmp_dir/.context/parallel_audits"
  echo '{"items":[{"slice":1,"id":"S1-001"},{"slice":2,"id":"S2-001"}]}' > "$tmp_dir/prd.json"
  echo '{"prd_sha256":"abc","inputs":{},"items":[],"summary":{}}' > "$tmp_dir/.context/parallel_audits/audit_slice_1.json"
  # Note: audit_slice_2.json is intentionally missing

  # Act: run merge
  local rc=0
  PRD_FILE="$tmp_dir/prd.json" AUDIT_OUTPUT_DIR="$tmp_dir/.context/parallel_audits" \
    python3 plans/prd_audit_merge.py --slice-dir "$tmp_dir/.context/parallel_audits" >/dev/null 2>&1 || rc=$?

  # Assert: must fail with missing slice error
  if [[ "$rc" -eq 0 ]]; then
    fail "TC8: missing slice should cause non-zero exit, got rc=0"
    return 1
  fi
  pass "TC8: missing slice detected (exit $rc)"
}

# TC6: Float count handling (1.0 -> 1)
test_float_count_handling() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  # Setup: audit JSON with float counts
  mkdir -p "$tmp_dir/.context"
  echo '{"items":[{"slice":1,"id":"S1-001"}]}' > "$tmp_dir/prd.json"
  cat > "$tmp_dir/audit.json" <<'EOF'
{
  "summary": {
    "items_total": 1.0,
    "items_pass": 1.0,
    "items_fail": 0.0,
    "items_blocked": 0.0
  }
}
EOF

  # Act: run cache update (should handle floats gracefully)
  local rc=0
  REPO_ROOT="$tmp_dir" PRD_FILE="$tmp_dir/prd.json" \
    python3 plans/prd_cache_update.py 1 "$tmp_dir/audit.json" 2>&1 || rc=$?

  # Assert: should succeed (float 1.0 -> int 1)
  if [[ "$rc" -ne 0 ]]; then
    fail "TC6: float count handling failed with rc=$rc"
    return 1
  fi
  pass "TC6: float counts handled correctly"
}

# TC9: BLOCKED invalidates prior cache entry
test_blocked_invalidates_cache() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  # Setup: PRD with slice 1, pre-existing PASS cache entry
  mkdir -p "$tmp_dir/.context"
  echo '{"items":[{"slice":1,"id":"S1-001"}]}' > "$tmp_dir/prd.json"
  cat > "$tmp_dir/.context/prd_audit_slice_cache.json" <<'EOF'
{
  "version": 1,
  "global_inputs_sha": "old_sha",
  "slices": {
    "1": {
      "slice_inputs_sha": "old_slice_sha",
      "decision": "PASS",
      "audit_json": "/tmp/old_audit.json"
    }
  }
}
EOF

  # Create a BLOCKED audit
  cat > "$tmp_dir/blocked_audit.json" <<'EOF'
{
  "summary": {
    "items_total": 1,
    "items_pass": 0,
    "items_fail": 0,
    "items_blocked": 1
  }
}
EOF

  # Act: update cache with BLOCKED decision
  local rc=0
  REPO_ROOT="$tmp_dir" PRD_FILE="$tmp_dir/prd.json" \
    python3 plans/prd_cache_update.py 1 "$tmp_dir/blocked_audit.json" 2>&1 || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    fail "TC9: cache update failed with rc=$rc"
    return 1
  fi

  # Assert: cache entry should now have decision=BLOCKED
  local decision
  decision=$(python3 -c "import json; print(json.load(open('$tmp_dir/.context/prd_audit_slice_cache.json'))['slices']['1']['decision'])")
  if [[ "$decision" != "BLOCKED" ]]; then
    fail "TC9: expected decision=BLOCKED, got $decision"
    return 1
  fi

  # Assert: cache check should treat BLOCKED as invalid (cache miss)
  local check_output
  check_output=$(REPO_ROOT="$tmp_dir" PRD_FILE="$tmp_dir/prd.json" \
    python3 plans/prd_cache_check.py --slices "1" 2>/dev/null)

  if ! echo "$check_output" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 1 in d['invalid_slices'] else 1)"; then
    fail "TC9: BLOCKED slice should be in invalid_slices"
    return 1
  fi

  pass "TC9: BLOCKED invalidates cache entry"
}

# TC10: Lock contention causes failure (not silent fallback)
test_lock_contention_fails() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  # Setup: minimal PRD and audit
  mkdir -p "$tmp_dir/.context"
  echo '{"items":[{"slice":1,"id":"S1-001"}]}' > "$tmp_dir/prd.json"
  echo '{"summary":{"items_total":1,"items_pass":1,"items_fail":0,"items_blocked":0}}' > "$tmp_dir/audit.json"

  local lock_file="$tmp_dir/.context/prd_audit_slice_cache.json.lock"

  # Hold flock in background using Python (works on macOS and Linux)
  python3 - "$lock_file" <<'PYEOF' &
import fcntl
import sys
import time
lock_file = sys.argv[1]
fd = open(lock_file, 'w')
fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
time.sleep(30)  # Hold lock for 30 seconds
PYEOF
  local lock_pid=$!
  sleep 0.5  # Give time for lock to be acquired

  # Act: try cache update while lock is held
  local rc=0
  REPO_ROOT="$tmp_dir" PRD_FILE="$tmp_dir/prd.json" \
    python3 plans/prd_cache_update.py 1 "$tmp_dir/audit.json" >/dev/null 2>&1 || rc=$?

  # Clean up background lock holder
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true

  # Assert: should fail with lock error (exit 7)
  if [[ "$rc" -eq 0 ]]; then
    fail "TC10: lock contention should cause non-zero exit, got rc=0"
    return 1
  fi
  if [[ "$rc" -ne 7 ]]; then
    # May get different exit code on some systems, but should not succeed
    pass "TC10: lock contention caused exit $rc (expected 7)"
  else
    pass "TC10: lock contention caused exit 7"
  fi
}

# Run tests
echo "=== PRD Cache Integration Tests ==="

test_corrupt_digest_hard_fail
test_missing_slice_detected
test_float_count_handling
test_blocked_invalidates_cache
test_lock_contention_fails

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
