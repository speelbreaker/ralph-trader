#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TELEMETRY_DIR="${VERIFY_CHECKPOINT_TELEMETRY_DIR:-$ROOT/.ralph/verify_telemetry}"
MIN_RUNS="${MIN_RUNS:-50}"
MIN_DAYS="${MIN_DAYS:-3}"
STRICT=0

show_help() {
  cat <<'EOF'
Usage: ./plans/check_sample_mix.sh [options]

Options:
  --dir <path>       Telemetry directory (default: .ralph/verify_telemetry)
  --min-runs <n>     Minimum run count target (default: 50)
  --min-days <n>     Minimum distinct day/session target (default: 3)
  --strict           Exit non-zero when targets are not met
  --help             Show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      TELEMETRY_DIR="${2:?missing value for --dir}"
      shift 2
      ;;
    --min-runs)
      MIN_RUNS="${2:?missing value for --min-runs}"
      shift 2
      ;;
    --min-days)
      MIN_DAYS="${2:?missing value for --min-days}"
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "FAIL: unknown argument: $1" >&2
      show_help >&2
      exit 2
      ;;
  esac
done

if ! [[ "$MIN_RUNS" =~ ^[0-9]+$ ]]; then
  echo "FAIL: --min-runs must be an integer" >&2
  exit 2
fi
if ! [[ "$MIN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "FAIL: --min-days must be an integer" >&2
  exit 2
fi

if command -v python3 >/dev/null 2>&1; then
  pybin="python3"
elif command -v python >/dev/null 2>&1; then
  pybin="python"
else
  echo "FAIL: python is required for telemetry parsing" >&2
  exit 2
fi

set +e
analysis="$("$pybin" - "$TELEMETRY_DIR" "$MIN_RUNS" "$MIN_DAYS" <<'PY'
import datetime as dt
import glob
import json
import os
import sys

telemetry_dir = sys.argv[1]
min_runs = int(sys.argv[2])
min_days = int(sys.argv[3])

files = sorted(glob.glob(os.path.join(telemetry_dir, "skip_telemetry_*.jsonl")))
if not files:
    print("status=no_data")
    print("total_runs=0")
    print("distinct_days=0")
    print("target_runs=%d" % min_runs)
    print("target_days=%d" % min_days)
    raise SystemExit(0)

total_runs = 0
distinct_days = set()
head_unchanged_true = 0
would_skip_contract = 0
would_skip_spec = 0
rollout_counts = {"off": 0, "dry_run": 0, "enforce": 0, "other": 0}

for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                total_runs += 1
                ts = row.get("ts")
                if isinstance(ts, int) and ts >= 0:
                    day = dt.datetime.fromtimestamp(ts, tz=dt.timezone.utc).strftime("%Y-%m-%d")
                    distinct_days.add(day)
                if row.get("head_unchanged_since_last_run") is True:
                    head_unchanged_true += 1
                would = row.get("would_skip", {})
                if isinstance(would, dict):
                    if would.get("contract_coverage") is True:
                        would_skip_contract += 1
                    if would.get("spec_validators_group") is True:
                        would_skip_spec += 1
                mode = str(row.get("rollout_mode", "other"))
                if mode in rollout_counts:
                    rollout_counts[mode] += 1
                else:
                    rollout_counts["other"] += 1
    except Exception:
        # Ignore malformed files/rows; keep helper diagnostic-only.
        continue

days_count = len(distinct_days)
status = "ok" if total_runs >= min_runs and days_count >= min_days else "insufficient_sample"
print(f"status={status}")
print(f"total_runs={total_runs}")
print(f"distinct_days={days_count}")
print(f"target_runs={min_runs}")
print(f"target_days={min_days}")
print(f"head_unchanged_true={head_unchanged_true}")
print(f"would_skip_contract_coverage={would_skip_contract}")
print(f"would_skip_spec_validators_group={would_skip_spec}")
print(f"rollout_off={rollout_counts['off']}")
print(f"rollout_dry_run={rollout_counts['dry_run']}")
print(f"rollout_enforce={rollout_counts['enforce']}")
print(f"rollout_other={rollout_counts['other']}")
PY
)"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: sample-mix analysis failed" >&2
  exit "$rc"
fi

echo "$analysis"
status="$(echo "$analysis" | awk -F= '$1=="status"{print $2}')"
if [[ "$STRICT" == "1" && "$status" != "ok" ]]; then
  exit 1
fi
exit 0
