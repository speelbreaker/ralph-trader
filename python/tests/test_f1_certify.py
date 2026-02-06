import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "python" / "tools" / "f1_certify.py"
WRAPPER = ROOT / "scripts" / "f1_certify.py"


def write_metrics(path: Path) -> dict:
    metrics = {
        "fee_drag_ratio": 0.1,
        "replay_coverage_pct": 99.0,
        "atomic_naked_events_24h": 0,
    }
    path.write_text(json.dumps(metrics), encoding="utf-8")
    return metrics


def run_cert(cmd: list, env: dict) -> None:
    subprocess.run(cmd, check=True, env=env, cwd=str(ROOT))


def test_f1_certify_outputs_required_fields(tmp_path: Path) -> None:
    metrics_path = tmp_path / "metrics.json"
    metrics = write_metrics(metrics_path)

    out_path = tmp_path / "F1_CERT.json"
    out_wrapper = tmp_path / "F1_CERT_wrapper.json"
    now_ms = 1700000000000

    env = os.environ.copy()
    env["BUILD_ID"] = "test-build-id"
    env["RUNTIME_CONFIG_JSON"] = json.dumps({"enforced_profile": "CSP"})

    run_cert(
        [
            sys.executable,
            str(TOOL),
            "--window=24h",
            f"--out={out_path}",
            f"--metrics={metrics_path}",
            f"--now-ms={now_ms}",
        ],
        env,
    )

    data = json.loads(out_path.read_text(encoding="utf-8"))
    required = [
        "status",
        "generated_ts_ms",
        "build_id",
        "runtime_config_hash",
        "contract_version",
        "expires_at_ts_ms",
        "release_gate_metrics",
    ]
    for key in required:
        assert key in data

    assert data["generated_ts_ms"] == now_ms
    assert data["expires_at_ts_ms"] == now_ms + 24 * 60 * 60 * 1000
    assert data["release_gate_metrics"] == metrics

    run_cert(
        [
            sys.executable,
            str(WRAPPER),
            "--window=24h",
            f"--out={out_wrapper}",
            f"--metrics={metrics_path}",
            f"--now-ms={now_ms}",
        ],
        env,
    )

    wrapper_data = json.loads(out_wrapper.read_text(encoding="utf-8"))
    assert wrapper_data == data
    assert out_wrapper.with_suffix(".md").read_text(encoding="utf-8") == out_path.with_suffix(
        ".md"
    ).read_text(encoding="utf-8")


def test_f1_certify_emits_md_summary(tmp_path: Path) -> None:
    metrics_path = tmp_path / "metrics.json"
    write_metrics(metrics_path)

    out_path = tmp_path / "F1_CERT.json"
    now_ms = 1700000000000

    env = os.environ.copy()
    env["BUILD_ID"] = "test-build-id"
    env["RUNTIME_CONFIG_JSON"] = json.dumps({"enforced_profile": "CSP"})

    run_cert(
        [
            sys.executable,
            str(TOOL),
            "--window=24h",
            f"--out={out_path}",
            f"--metrics={metrics_path}",
            f"--now-ms={now_ms}",
        ],
        env,
    )

    md_path = out_path.with_suffix(".md")
    assert md_path.exists()
    summary = md_path.read_text(encoding="utf-8")
    assert "F1 Certification Summary" in summary
    assert "Status: PASS" in summary
