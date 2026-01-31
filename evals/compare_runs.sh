#!/usr/bin/env bash
# Compare results across two eval runs
# Compatible with bash 3.2+ (macOS default)

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <run_id_1> <run_id_2>

Compare golden repro eval results across two runs.

Example:
  $0 20260130-102345 20260130-103000

Output: Table showing status changes per repro
Exit codes:
  0 = No regressions (run2 >= run1 pass count)
  1 = Regressions detected (run2 < run1 pass count)
  2 = Usage error or missing data
EOF
  exit 1
}

[[ $# -eq 2 ]] || usage
RUN1="$1"
RUN2="$2"

RESULTS_DIR="evals/results"
[[ -d "$RESULTS_DIR/$RUN1" ]] || { echo "ERROR: Run not found: $RUN1" >&2; exit 2; }
[[ -d "$RESULTS_DIR/$RUN2" ]] || { echo "ERROR: Run not found: $RUN2" >&2; exit 2; }

# Collect all unique repro names using temporary files (bash 3.2 compatible)
tmp_repros=$(mktemp)
trap "rm -f $tmp_repros" EXIT

# Gather repro names from both runs
(cd "$RESULTS_DIR/$RUN1" && ls *.json 2>/dev/null | sed 's/\.json$//' || true) > "$tmp_repros"
(cd "$RESULTS_DIR/$RUN2" && ls *.json 2>/dev/null | sed 's/\.json$//' || true) >> "$tmp_repros"
sort -u "$tmp_repros" -o "$tmp_repros"

# Print header
printf "%-30s %-12s %-12s %s\n" "Repro" "$RUN1" "$RUN2" "Delta"
printf "%-30s %-12s %-12s %s\n" "$(printf '%0.s-' {1..30})" "$(printf '%0.s-' {1..12})" "$(printf '%0.s-' {1..12})" "-----"

count_improved=0
count_regressed=0
count_same=0

while read -r repro; do
  [[ -n "$repro" ]] || continue

  # Get status from each run (with fallback for validate-only results)
  s1="missing"
  s2="missing"

  if [[ -f "$RESULTS_DIR/$RUN1/${repro}.json" ]]; then
    s1=$(jq -r '.status // .phases.verify_after_patch.status // .phases.validate_after_patch.status // "unknown"' \
      "$RESULTS_DIR/$RUN1/${repro}.json" 2>/dev/null || echo "error")
  fi

  if [[ -f "$RESULTS_DIR/$RUN2/${repro}.json" ]]; then
    s2=$(jq -r '.status // .phases.verify_after_patch.status // .phases.validate_after_patch.status // "unknown"' \
      "$RESULTS_DIR/$RUN2/${repro}.json" 2>/dev/null || echo "error")
  fi

  # Determine delta (ASCII markers: OK=improved, REG=regressed, --=same)
  delta="--"
  if [[ "$s1" != "pass" && "$s2" == "pass" ]]; then
    delta="OK"
    ((count_improved++))
  elif [[ "$s1" == "pass" && "$s2" != "pass" ]]; then
    delta="REG"
    ((count_regressed++))
  else
    ((count_same++))
  fi

  printf "%-30s %-12s %-12s %s\n" "$repro" "$s1" "$s2" "$delta"
done < "$tmp_repros"

echo ""
echo "Summary: $count_improved improved, $count_regressed regressed, $count_same unchanged"

# Exit 0 if no regressions, else 1
[[ $count_regressed -eq 0 ]]
