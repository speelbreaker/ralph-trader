#!/usr/bin/env python3
import argparse
import hashlib
import json
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
KERNEL_PATH = ROOT / "docs/contract_kernel.json"


def sha256_file(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha256(data).hexdigest()


def require_fields(obj: dict, required: list, label: str) -> None:
    missing = [key for key in required if key not in obj]
    if missing:
        fail(f"{label} missing fields: {', '.join(missing)}")


def check_kernel(kernel_path: Path) -> None:
    if not kernel_path.exists():
        fail(f"kernel missing: {kernel_path}")
    kernel = json.loads(kernel_path.read_text(encoding="utf-8"))

    allowed_top = {
        "kernel_version",
        "contract_version",
        "generated_at_utc",
        "sources",
        "anchors",
        "validation_rules",
    }
    extra_top = set(kernel.keys()) - allowed_top
    if extra_top:
        fail(f"kernel has unexpected top-level keys: {', '.join(sorted(extra_top))}")

    if kernel.get("kernel_version") != 3:
        fail("kernel_version must be 3")

    contract_text = CONTRACT_PATH.read_text(encoding="utf-8")
    contract_version = parse_contract_version(contract_text)
    contract_lines = contract_text.splitlines()
    if kernel.get("contract_version") != contract_version:
        fail("contract_version does not match CONTRACT.md")

    if not isinstance(kernel.get("generated_at_utc"), str):
        fail("generated_at_utc must be a string")

    sources = kernel.get("sources")
    if not isinstance(sources, dict):
        fail("sources must be an object")

    require_fields(
        sources,
        [
            "contract_path",
            "contract_sha256",
            "anchors_path",
            "anchors_sha256",
            "rules_path",
            "rules_sha256",
            "plan_path",
            "plan_sha256",
        ],
        "sources",
    )

    expected_paths = {
        "contract_path": "CONTRACT.md",
        "anchors_path": "docs/contract_anchors.md",
        "rules_path": "docs/validation_rules.md",
        "plan_path": "IMPLEMENTATION_PLAN.md",
    }
    for key, expected in expected_paths.items():
        if sources.get(key) != expected:
            fail(f"sources.{key} must be {expected}")

    expected_hashes = {
        "contract_sha256": sha256_file(CONTRACT_PATH),
        "anchors_sha256": sha256_file(ANCHORS_PATH),
        "rules_sha256": sha256_file(RULES_PATH),
        "plan_sha256": sha256_file(PLAN_PATH),
    }
    for key, expected in expected_hashes.items():
        if sources.get(key) != expected:
            fail(f"sources.{key} mismatch (expected {expected})")

    anchors_text = ANCHORS_PATH.read_text(encoding="utf-8")
    rules_text = RULES_PATH.read_text(encoding="utf-8")
    expected_anchors = parse_anchors(anchors_text, contract_lines, str(ANCHORS_PATH))
    expected_rules = parse_validation_rules(rules_text, str(RULES_PATH))

    anchors = kernel.get("anchors")
    if not isinstance(anchors, list):
        fail("anchors must be a list")

    rules = kernel.get("validation_rules")
    if not isinstance(rules, list):
        fail("validation_rules must be a list")

    for anchor in anchors:
        if not isinstance(anchor, dict):
            fail("anchors entries must be objects")
        if set(anchor.keys()) != {"id", "title", "contract_ref", "proof"}:
            fail(f"anchor entry has unexpected keys: {anchor}")
        if not isinstance(anchor.get("proof"), dict):
            fail("anchor proof must be an object")
        if set(anchor["proof"].keys()) != {"section", "line"}:
            fail(f"anchor proof has unexpected keys: {anchor}")
        if not isinstance(anchor["proof"].get("section"), str) or not isinstance(anchor["proof"].get("line"), int):
            fail(f"anchor proof must include section (str) and line (int): {anchor}")

    for rule in rules:
        if not isinstance(rule, dict):
            fail("validation_rules entries must be objects")
        if set(rule.keys()) != {
            "id",
            "title",
            "contract_ref",
            "rule",
            "gate_ids",
            "fields",
            "enforcement",
        }:
            fail(f"validation rule entry has unexpected keys: {rule}")
        if not isinstance(rule.get("enforcement"), dict):
            fail("validation_rules enforcement must be an object")
        if set(rule["enforcement"].keys()) != {"rule"}:
            fail(f"validation_rules enforcement has unexpected keys: {rule}")
        if rule["enforcement"].get("rule") != rule.get("rule"):
            fail(f"validation_rules enforcement.rule mismatch: {rule}")
        if not isinstance(rule.get("gate_ids"), list):
            fail("validation_rules gate_ids must be a list")
        if not all(isinstance(item, str) for item in rule.get("gate_ids", [])):
            fail("validation_rules gate_ids entries must be strings")
        if not isinstance(rule.get("fields"), dict):
            fail("validation_rules fields must be an object")
        for key, values in rule.get("fields", {}).items():
            if not isinstance(key, str) or not isinstance(values, list):
                fail("validation_rules fields must map to list values")
            if not all(isinstance(item, str) for item in values):
                fail("validation_rules fields values must be strings")

    anchors_sorted = sorted(anchors, key=lambda item: item["id"])
    rules_sorted = sorted(rules, key=lambda item: item["id"])

    if anchors_sorted != expected_anchors:
        fail("anchors do not match docs/contract_anchors.md")
    if rules_sorted != expected_rules:
        fail("validation_rules do not match docs/validation_rules.md")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate contract kernel JSON against source files.")
    parser.add_argument("--kernel", default=str(KERNEL_PATH))
    args = parser.parse_args()

    check_kernel(Path(args.kernel))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
