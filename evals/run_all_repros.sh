#!/usr/bin/env bash
set -euo pipefail

# Batch runner for golden repros
# Usage: ./evals/run_all_repros.sh [validate|apply_patch] [patch-dir]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-validate}"
PATCH_DIR="${2:-}"

manifest="evals/repros/manifest.json"
[[ -f "$manifest" ]] || { echo "ERROR: Manifest not found: $manifest" >&2; exit 2; }

# Get all repro names
repros=$(jq -r '.repros[].name' "$manifest")

passed=0
failed=0
skipped=0

echo "=== Running all repros (mode: $MODE) ===" >&2
echo ""

for name in $repros; do
  case "$MODE" in
    validate)
      echo "--- $name ---" >&2
      if ./evals/run_repro.sh validate "$name"; then
        ((passed++))
      else
        ((failed++))
      fi
      echo ""
      ;;

    apply_patch)
      patch_file="$PATCH_DIR/$name.patch"
      echo "--- $name ---" >&2
      if [[ ! -f "$patch_file" ]]; then
        echo "SKIP: No patch file: $patch_file" >&2
        ((skipped++))
      elif ./evals/run_repro.sh apply_patch "$name" "$patch_file"; then
        ((passed++))
      else
        ((failed++))
      fi
      echo ""
      ;;

    *)
      echo "ERROR: Unknown mode: $MODE" >&2
      echo "Usage: $0 [validate|apply_patch] [patch-dir]" >&2
      exit 2
      ;;
  esac
done

echo "=== Summary ===" >&2
echo "Passed:  $passed"
echo "Failed:  $failed"
echo "Skipped: $skipped"
echo "Total:   $(echo "$repros" | wc -w | tr -d ' ')"

[[ "$failed" -eq 0 ]] || exit 1
