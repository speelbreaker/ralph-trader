#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

sentinel="${CONTRACT_COVERAGE_CI_SENTINEL:-plans/contract_coverage_ci_strict}"

if [[ -f "$sentinel" ]]; then
  echo "Contract coverage strict already enabled via $sentinel"
  exit 0
fi

mkdir -p "$(dirname "$sentinel")"
cat > "$sentinel" <<EOF
# Enables strict contract coverage in CI.
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "Contract coverage strict enabled in CI via $sentinel"
