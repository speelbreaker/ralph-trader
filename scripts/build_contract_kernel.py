#!/usr/bin/env python3
import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from contract_kernel_lib import (
    fail,
    parse_anchors,
    parse_contract_version,
    parse_validation_rules,
)

ROOT = Path(__file__).resolve().parents[1]

ANCHORS_PATH = ROOT / "docs/contract_anchors.md"
RULES_PATH = ROOT / "docs/validation_rules.md"
CONTRACT_PATH = ROOT / "CONTRACT.md"
PLAN_PATH = ROOT / "IMPLEMENTATION_PLAN.md"


def sha256_file(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha256(data).hexdigest()


def build_kernel():
    for required in (ANCHORS_PATH, RULES_PATH, CONTRACT_PATH, PLAN_PATH):
        if not required.exists():
            fail(f"required file missing: {required}")

    contract_text = CONTRACT_PATH.read_text(encoding="utf-8")
    contract_version = parse_contract_version(contract_text)
    contract_lines = contract_text.splitlines()

    anchors_text = ANCHORS_PATH.read_text(encoding="utf-8")
    rules_text = RULES_PATH.read_text(encoding="utf-8")
    anchors = parse_anchors(anchors_text, contract_lines, str(ANCHORS_PATH))
    rules = parse_validation_rules(rules_text, str(RULES_PATH))

    sources = {
        "contract_path": "CONTRACT.md",
        "contract_sha256": sha256_file(CONTRACT_PATH),
        "anchors_path": "docs/contract_anchors.md",
        "anchors_sha256": sha256_file(ANCHORS_PATH),
        "rules_path": "docs/validation_rules.md",
        "rules_sha256": sha256_file(RULES_PATH),
        "plan_path": "IMPLEMENTATION_PLAN.md",
        "plan_sha256": sha256_file(PLAN_PATH),
    }

    return {
        "kernel_version": 3,
        "contract_version": contract_version,
        "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": sources,
        "anchors": anchors,
        "validation_rules": rules,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build contract kernel JSON from anchors and validation rules.")
    parser.add_argument("--out", default=str(ROOT / "docs/contract_kernel.json"))
    args = parser.parse_args()

    kernel = build_kernel()
    output_path = Path(args.out)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(kernel, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
