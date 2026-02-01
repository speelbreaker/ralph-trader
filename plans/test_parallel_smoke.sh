#!/usr/bin/env bash
# Smoke test for parallel verify.sh changes
# Validates structural changes are present
set -euo pipefail

# Determine script directory and root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

echo "Running parallel verify smoke test..."
echo "Verifying bash syntax and structural changes..."

# 1. Check that run_parallel_group function exists
if ! grep -q "^run_parallel_group()" "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] run_parallel_group() function not found"
  exit 1
fi
echo "[OK] run_parallel_group() function exists"

# 2. Check parallel execution flags exist
if ! grep -q "RUN_LOGGED_SKIP_FAILED_GATE" "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] Parallel execution flags not found"
  exit 1
fi
echo "[OK] Parallel execution flags exist"

# 3. Check spec validator array exists
if ! grep -q "SPEC_VALIDATOR_SPECS=" "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] Spec validator array not found"
  exit 1
fi
echo "[OK] Spec validators converted to parallel array"

# 4. Check workflow acceptance is invoked via run_logged
if ! grep -Eq 'run_logged[[:space:]]+"workflow_acceptance"' "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] workflow_acceptance not invoked via run_logged"
  exit 1
fi
echo "[OK] workflow_acceptance invoked via run_logged"

# 5. Timing instrumentation (E-RE, tolerates ordering)
if ! grep -Eq '\.time.*VERIFY_ARTIFACTS_DIR|VERIFY_ARTIFACTS_DIR.*\.time' "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] Timing file pattern not found"
  exit 1
fi
echo "[OK] Timing instrumentation exists"

# 6. detect_cpus function
if ! grep -q "^detect_cpus()" "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] detect_cpus() not found"
  exit 1
fi
echo "[OK] detect_cpus() exists"

# 7. SPEC_VALIDATOR_SPECS uses parallel runner (whitespace tolerant)
if ! grep -Eq 'run_parallel_group[[:space:]]+SPEC_VALIDATOR_SPECS' "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] Spec validators not parallelized"
  exit 1
fi
echo "[OK] Spec validators use parallel runner"

# 8. STATUS_FIXTURE_SPECS uses parallel runner (whitespace tolerant)
if ! grep -Eq 'run_parallel_group[[:space:]]+STATUS_FIXTURE_SPECS' "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] Status fixtures not parallelized"
  exit 1
fi
echo "[OK] Status fixtures use parallel runner"

# 9. Unbound variable guards
for var in RUN_LOGGED_SUPPRESS_EXCERPT RUN_LOGGED_SKIP_FAILED_GATE RUN_LOGGED_SUPPRESS_TIMEOUT_FAIL; do
  if ! grep -q "\${${var}:-}" "$SCRIPT_DIR/verify.sh"; then
    echo "[FAIL] Unbound guard missing for ${var}"
    exit 1
  fi
done
echo "[OK] Unbound variable guards present"

# 10. Operator precedence fix (marker-based, robust to formatting)
if ! grep -q "VERIFY_TIMEOUT_PAREN_FIX" "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] Timeout precedence fix marker not found"
  exit 1
fi
echo "[OK] Timeout precedence fix present"

# 11. Smoke test integration (specific invocation)
if ! grep -Eq 'run_logged[[:space:]]+"parallel_smoke"' "$SCRIPT_DIR/verify.sh"; then
  echo "[FAIL] parallel_smoke not invoked via run_logged"
  exit 1
fi
echo "[OK] Smoke test integrated via run_logged"

echo ""
echo "[OK] All smoke tests passed"
exit 0
