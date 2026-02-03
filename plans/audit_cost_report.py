#!/usr/bin/env python3
"""
Parse .context/audit_costs.jsonl and print performance metrics.

Usage:
    python3 plans/audit_cost_report.py [--jsonl PATH]
"""

import json
import sys
from collections import defaultdict
from pathlib import Path


def percentile(sorted_values: list[float], p: float) -> float:
    """Calculate percentile from sorted list."""
    if not sorted_values:
        return 0.0
    k = (len(sorted_values) - 1) * p
    f = int(k)
    c = f + 1 if f + 1 < len(sorted_values) else f
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)


def main():
    # Parse arguments
    jsonl_path = Path(".context/audit_costs.jsonl")
    args = sys.argv[1:]
    if "--jsonl" in args:
        idx = args.index("--jsonl")
        if idx + 1 < len(args):
            jsonl_path = Path(args[idx + 1])

    if not jsonl_path.exists():
        print(f"ERROR: {jsonl_path} not found", file=sys.stderr)
        sys.exit(1)

    # Parse JSONL
    records = []
    with open(jsonl_path, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"WARNING: Line {line_num}: invalid JSON: {e}", file=sys.stderr)

    if not records:
        print("No records found in audit_costs.jsonl")
        sys.exit(0)

    # Group by stage
    stage_durations: dict[str, list[float]] = defaultdict(list)
    stage_cache_hits: dict[str, int] = defaultdict(int)
    stage_cache_total: dict[str, int] = defaultdict(int)

    # Track runs
    runs: dict[str, dict] = defaultdict(dict)

    for rec in records:
        run_id = rec.get("run_id", "unknown")
        stage = rec.get("stage", "unknown")

        if stage == "complete":
            # Final record for run
            runs[run_id]["decision"] = rec.get("decision")
            runs[run_id]["total_duration_s"] = rec.get("total_duration_s", 0)
        else:
            duration = rec.get("duration_s", 0)
            stage_durations[stage].append(duration)

            cache_hit = rec.get("cache_hit", False)
            stage_cache_total[stage] += 1
            if cache_hit:
                stage_cache_hits[stage] += 1

            # Track stage in run
            if "stages" not in runs[run_id]:
                runs[run_id]["stages"] = {}
            runs[run_id]["stages"][stage] = duration

    # Calculate total durations for runs without "complete" record
    for run_id, run_data in runs.items():
        if "total_duration_s" not in run_data and "stages" in run_data:
            run_data["total_duration_s"] = sum(run_data["stages"].values())

    # Print stage performance
    print("Stage Performance (all runs):")
    stage_order = ["contract_digest", "plan_digest", "roadmap_digest", "slice_prepare", "auditor"]
    for stage in stage_order:
        durations = stage_durations.get(stage, [])
        if not durations:
            continue
        durations_sorted = sorted(durations)
        min_v = durations_sorted[0]
        max_v = durations_sorted[-1]
        median = percentile(durations_sorted, 0.5)
        p90 = percentile(durations_sorted, 0.9)
        p95 = percentile(durations_sorted, 0.95)
        print(f"  {stage}: min={min_v:.0f}s, median={median:.0f}s, p90={p90:.0f}s, p95={p95:.0f}s, max={max_v:.0f}s")

    # Print total duration stats
    total_durations = [r.get("total_duration_s", 0) for r in runs.values() if r.get("total_duration_s")]
    if total_durations:
        total_sorted = sorted(total_durations)
        print(f"\nTotal Duration: min={total_sorted[0]:.0f}s, median={percentile(total_sorted, 0.5):.0f}s, p90={percentile(total_sorted, 0.9):.0f}s")

    # Print run summary
    completed_runs = sum(1 for r in runs.values() if r.get("decision"))
    decisions = defaultdict(int)
    for r in runs.values():
        if r.get("decision"):
            decisions[r["decision"]] += 1

    print(f"\nRun Summary: Total runs={len(runs)}, Completed={completed_runs}")
    if decisions:
        decision_str = ", ".join(f"{k}={v}" for k, v in sorted(decisions.items()))
        print(f"  Decisions: {decision_str}")

    # Print cache performance
    print("\nCache Performance:")
    for stage in stage_order:
        total = stage_cache_total.get(stage, 0)
        hits = stage_cache_hits.get(stage, 0)
        if total > 0:
            hit_rate = (hits / total) * 100
            print(f"  {stage}: hit_rate={hit_rate:.0f}% ({hits}/{total})")


if __name__ == "__main__":
    main()
