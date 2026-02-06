#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SH="$ROOT/plans/verify.sh"
CHECKPOINT_LIB="$ROOT/plans/lib/verify_checkpoint.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$VERIFY_SH" ]] || fail "missing plans/verify.sh"
[[ -f "$CHECKPOINT_LIB" ]] || fail "missing plans/lib/verify_checkpoint.sh"

if ! rg -q '^[[:space:]]*decide_skip_gate\(\)' "$VERIFY_SH"; then
  fail "verify.sh must define decide_skip_gate entrypoint"
fi

if rg -n '\bis_cache_eligible\b' "$VERIFY_SH" >/dev/null; then
  fail "verify.sh must not call is_cache_eligible directly"
fi

if ! rg -q '^[[:space:]]*is_cache_eligible\(\)' "$CHECKPOINT_LIB"; then
  fail "verify_checkpoint.sh must define is_cache_eligible()"
fi

if ! rg -q '^[[:space:]]*checkpoint_decide_skip_gate\(\)' "$CHECKPOINT_LIB"; then
  fail "verify_checkpoint.sh must define checkpoint_decide_skip_gate()"
fi

# Allow exactly one call site for is_cache_eligible outside its own definition:
# checkpoint_decide_skip_gate() is the only permitted caller.
total_refs="$(rg -n '\bis_cache_eligible\b' "$CHECKPOINT_LIB" | wc -l | tr -d ' ')"
if [[ "$total_refs" -ne 3 ]]; then
  fail "expected exactly three is_cache_eligible references (definition + wrapper + entrypoint call), found $total_refs"
fi

decide_body="$(awk '
  /^[[:space:]]*checkpoint_decide_skip_gate\(\)/ { in_fn=1 }
  in_fn { print }
  in_fn && /^[[:space:]]*}/ { exit }
' "$CHECKPOINT_LIB")"
if [[ -z "$decide_body" ]]; then
  fail "unable to locate checkpoint_decide_skip_gate() body"
fi
if ! printf '%s\n' "$decide_body" | rg -q '\bis_cache_eligible\b'; then
  fail "is_cache_eligible must be called inside checkpoint_decide_skip_gate()"
fi

echo "PASS: skip entrypoint guard"
