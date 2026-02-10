#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Tuple

ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = ROOT / "specs" / "CONTRACT.md"
CONTRACT_VERSION_RE = re.compile(r"^#\s+\*\*Version:\s*([0-9]+(?:\.[0-9]+)*)")

REQUIRED_METRICS = (
    "fee_drag_ratio",
    "replay_coverage_pct",
    "atomic_naked_events_24h",
)
FEE_DRAG_RATIO_MAX = 0.35
REPLAY_COVERAGE_MIN = 95.0
ATOMIC_NAKED_EVENTS_MAX = 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate F1 certification artifacts (F1_CERT.json + F1_CERT.md)."
    )
    parser.add_argument("--window", required=True, help="Window like 24h, 30m, 7d")
    parser.add_argument("--out", required=True, help="Output path for F1_CERT.json")
    parser.add_argument(
        "--metrics",
        help="Path to JSON metrics input (release gate metrics)",
        default=None,
    )
    parser.add_argument(
        "--runtime-config",
        dest="runtime_config_path",
        help="Path to runtime config JSON (optional)",
        default=None,
    )
    parser.add_argument(
        "--now-ms",
        type=int,
        default=None,
        help="Override generated_ts_ms for deterministic output",
    )
    return parser.parse_args()


def parse_window_seconds(window: str) -> int:
    text = window.strip().lower()
    match = re.match(r"^([0-9]+)([smhd])$", text)
    if not match:
        raise ValueError(
            f"Invalid window '{window}'. Expected number + unit (s|m|h|d)."
        )
    value = int(match.group(1))
    unit = match.group(2)
    multipliers = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    return value * multipliers[unit]


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def compute_runtime_config_hash(config: Any) -> str:
    return hashlib.sha256(canonical_json_bytes(config)).hexdigest()


def parse_contract_version(contract_path: Path) -> str:
    text = contract_path.read_text(encoding="utf-8")
    for line in text.splitlines():
        match = CONTRACT_VERSION_RE.match(line.strip())
        if match:
            return match.group(1)
    raise RuntimeError("contract version not found in CONTRACT.md")


def read_json_file(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def coerce_metric_value(key: str, value: Any) -> Any:
    if value is None:
        return None
    try:
        if key == "atomic_naked_events_24h":
            return int(value)
        return float(value)
    except (TypeError, ValueError):
        return None


def extract_metrics(raw: Any) -> Dict[str, Any]:
    if isinstance(raw, dict) and isinstance(raw.get("release_gate_metrics"), dict):
        raw = raw["release_gate_metrics"]
    metrics = {}
    if isinstance(raw, dict):
        for key in REQUIRED_METRICS:
            metrics[key] = coerce_metric_value(key, raw.get(key))
    else:
        for key in REQUIRED_METRICS:
            metrics[key] = None
    return metrics


def evaluate_metrics(metrics: Dict[str, Any]) -> Tuple[str, List[str]]:
    reasons: List[str] = []
    missing = [key for key, value in metrics.items() if value is None]
    if missing:
        reasons.append("missing_metrics: " + ", ".join(missing))
        return "FAIL", reasons

    if metrics["atomic_naked_events_24h"] > ATOMIC_NAKED_EVENTS_MAX:
        reasons.append("atomic_naked_events_24h>0")
    if metrics["fee_drag_ratio"] >= FEE_DRAG_RATIO_MAX:
        reasons.append("fee_drag_ratio>=0.35")
    if metrics["replay_coverage_pct"] < REPLAY_COVERAGE_MIN:
        reasons.append("replay_coverage_pct<95")

    status = "PASS" if not reasons else "FAIL"
    return status, reasons


def resolve_build_id(root: Path) -> str:
    for key in (
        "BUILD_ID",
        "GIT_SHA",
        "GITHUB_SHA",
        "CI_COMMIT_SHA",
        "SOURCE_VERSION",
    ):
        value = os.getenv(key)
        if value:
            return value
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def load_runtime_config(args: argparse.Namespace) -> Tuple[Any, bool]:
    if args.runtime_config_path:
        path = Path(args.runtime_config_path)
        return read_json_file(path), True

    env_path = os.getenv("RUNTIME_CONFIG_PATH")
    if env_path:
        return read_json_file(Path(env_path)), True

    env_json = os.getenv("RUNTIME_CONFIG_JSON")
    if env_json:
        return json.loads(env_json), True

    return {}, False


def render_summary(
    status: str,
    generated_ts_ms: int,
    window: str,
    expires_at_ts_ms: int,
    build_id: str,
    runtime_config_hash: str,
    contract_version: str,
    metrics: Dict[str, Any],
    reasons: List[str],
) -> str:
    lines = [
        "# F1 Certification Summary",
        "",
        f"- Status: {status}",
        f"- Generated (ms): {generated_ts_ms}",
        f"- Window: {window}",
        f"- Expires at (ms): {expires_at_ts_ms}",
        f"- Build ID: {build_id}",
        f"- Contract Version: {contract_version}",
        f"- Runtime Config Hash: {runtime_config_hash}",
        "",
        "## Release Gate Metrics",
    ]
    for key in REQUIRED_METRICS:
        value = metrics.get(key)
        label = "MISSING" if value is None else value
        lines.append(f"- {key}: {label}")

    if reasons:
        lines.append("")
        lines.append("## Status Reasons")
        for reason in reasons:
            lines.append(f"- {reason}")

    return "\n".join(str(line) for line in lines) + "\n"


def main() -> int:
    args = parse_args()
    try:
        window_seconds = parse_window_seconds(args.window)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    metrics_raw = {}
    if args.metrics:
        metrics_raw = read_json_file(Path(args.metrics))
    elif os.getenv("F1_CERT_METRICS_PATH"):
        metrics_raw = read_json_file(Path(os.getenv("F1_CERT_METRICS_PATH")))
    elif os.getenv("F1_CERT_METRICS_JSON"):
        metrics_raw = json.loads(os.getenv("F1_CERT_METRICS_JSON"))

    metrics = extract_metrics(metrics_raw)
    status, reasons = evaluate_metrics(metrics)

    generated_ts_ms = args.now_ms if args.now_ms is not None else int(time.time() * 1000)
    expires_at_ts_ms = generated_ts_ms + (window_seconds * 1000)

    build_id = resolve_build_id(ROOT)
    runtime_config, _ = load_runtime_config(args)
    runtime_config_hash = compute_runtime_config_hash(runtime_config)
    contract_version = parse_contract_version(CONTRACT_PATH)

    cert: Dict[str, Any] = {
        "status": status,
        "generated_ts_ms": generated_ts_ms,
        "build_id": build_id,
        "runtime_config_hash": runtime_config_hash,
        "contract_version": contract_version,
        "expires_at_ts_ms": expires_at_ts_ms,
        "release_gate_metrics": {
            key: metrics.get(key) for key in REQUIRED_METRICS
        },
    }

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as handle:
        json.dump(cert, handle, indent=2, sort_keys=True)
        handle.write("\n")

    if out_path.suffix == ".json":
        md_path = out_path.with_suffix(".md")
    else:
        md_path = out_path.parent / (out_path.name + ".md")

    summary = render_summary(
        status,
        generated_ts_ms,
        args.window,
        expires_at_ts_ms,
        build_id,
        runtime_config_hash,
        contract_version,
        cert["release_gate_metrics"],
        reasons,
    )
    md_path.write_text(summary, encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
