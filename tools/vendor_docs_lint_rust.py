#!/usr/bin/env python3
"""
Fail-closed linter:
- If Cargo.lock changes for any crate in CRATES_OF_INTEREST.yaml,
  require a matching specs/vendor_docs/rust/crates/<crate>/<version>/metadata.json
  whose cargo_lock_sha256 matches the current Cargo.lock.

This parser is intentionally minimal and expects a simple YAML layout.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CARGO_LOCK = ROOT / "Cargo.lock"
CRATES_YAML = ROOT / "specs" / "vendor_docs" / "rust" / "CRATES_OF_INTEREST.yaml"
SNAP_ROOT = ROOT / "specs" / "vendor_docs" / "rust" / "crates"


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git_available() -> bool:
    return shutil.which("git") is not None


def run_git(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT)] + args,
        text=True,
        capture_output=True,
        check=False,
    )


def git_has_ref(ref: str) -> bool:
    return run_git(["rev-parse", "--verify", ref]).returncode == 0


def load_crates_of_interest(path: Path) -> list[str]:
    if not path.exists():
        raise FileNotFoundError(str(path))

    crates: list[str] = []
    in_crates = False
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if not line.startswith(" "):
            in_crates = line.strip() == "crates:"
            continue
        if not in_crates:
            continue

        list_match = re.match(r"^\s{2}-\s*([A-Za-z0-9_.-]+)\s*$", line)
        if list_match:
            crates.append(list_match.group(1))
            continue

        map_match = re.match(r"^\s{2}([A-Za-z0-9_.-]+)\s*:\s*$", line)
        if map_match:
            crates.append(map_match.group(1))

    seen: set[str] = set()
    ordered: list[str] = []
    for crate in crates:
        if crate not in seen:
            ordered.append(crate)
            seen.add(crate)
    return ordered


def parse_lock_packages(lock_text: str) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for block in lock_text.split("[[package]]")[1:]:
        name_m = re.search(r'^\s*name\s*=\s*"([^"]+)"', block, re.M)
        ver_m = re.search(r'^\s*version\s*=\s*"([^"]+)"', block, re.M)
        if name_m and ver_m:
            name = name_m.group(1)
            ver = ver_m.group(1)
            out.setdefault(name, set()).add(ver)
    return out


def read_metadata_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    is_ci = bool(os.environ.get("CI"))
    base_ref = os.environ.get("BASE_REF", "origin/main")
    require_features = os.environ.get("REQUIRE_FEATURES_TXT", "0") == "1"

    if not CARGO_LOCK.exists():
        eprint("FAIL: Cargo.lock not found at repo root.")
        return 2

    if not CRATES_YAML.exists():
        eprint(f"FAIL: missing CRATES_OF_INTEREST.yaml at {CRATES_YAML}")
        return 2

    if not git_available():
        msg = "WARN: git not found; skipping vendor docs lint"
        if is_ci:
            eprint(f"FAIL: {msg}")
            return 2
        eprint(msg)
        return 0

    if not git_has_ref(base_ref):
        msg = f"WARN: cannot resolve BASE_REF={base_ref}; skipping vendor docs lint"
        if is_ci:
            eprint(f"FAIL: {msg}")
            return 2
        eprint(msg)
        return 0

    diff = run_git(["diff", "--name-only", f"{base_ref}...HEAD", "--", "Cargo.lock"])
    if diff.returncode != 0:
        eprint(f"FAIL: git diff failed: {diff.stderr.strip()}")
        return 2
    if not diff.stdout.strip():
        print("OK: Cargo.lock unchanged; skipping vendor docs lint.")
        return 0

    old_lock = run_git(["show", f"{base_ref}:Cargo.lock"])
    if old_lock.returncode != 0:
        eprint(f"FAIL: unable to read base Cargo.lock: {old_lock.stderr.strip()}")
        return 2

    crates = load_crates_of_interest(CRATES_YAML)
    if not crates:
        eprint("FAIL: no crates listed in CRATES_OF_INTEREST.yaml")
        return 2

    cargo_lock_hash = sha256_file(CARGO_LOCK)
    old_pkgs = parse_lock_packages(old_lock.stdout)
    new_pkgs = parse_lock_packages(CARGO_LOCK.read_text(encoding="utf-8", errors="replace"))

    failures: list[str] = []
    warnings: list[str] = []
    checked = 0

    for crate in crates:
        new_versions = new_pkgs.get(crate, set())
        if not new_versions:
            continue
        old_versions = old_pkgs.get(crate, set())
        new_only = sorted(new_versions - old_versions)
        if not new_only:
            continue

        for version in new_only:
            checked += 1
            md_path = SNAP_ROOT / crate / version / "metadata.json"
            if not md_path.exists():
                failures.append(
                    f"Missing snapshot: specs/vendor_docs/rust/crates/{crate}/{version}/metadata.json"
                )
                continue

            try:
                md = read_metadata_json(md_path)
            except json.JSONDecodeError as exc:
                failures.append(f"Invalid JSON in {md_path}: {exc}")
                continue

            if md.get("crate") != crate or md.get("version") != version:
                failures.append(f"Snapshot metadata crate/version mismatch for {crate} {version}")

            if md.get("cargo_lock_sha256") != cargo_lock_hash:
                failures.append(
                    f"Snapshot lock hash mismatch for {crate} {version}: "
                    f"metadata has {md.get('cargo_lock_sha256')}, expected {cargo_lock_hash}"
                )

            features_path = SNAP_ROOT / crate / version / "features.txt"
            if not features_path.exists():
                msg = f"Missing features.txt for {crate} {version}"
                if require_features:
                    failures.append(msg)
                else:
                    warnings.append(msg)
            else:
                contents = features_path.read_text(encoding="utf-8", errors="replace").strip()
                if not contents:
                    msg = f"Empty features.txt for {crate} {version}"
                    if require_features:
                        failures.append(msg)
                    else:
                        warnings.append(msg)

    if checked == 0:
        print("OK: Cargo.lock changed, but no crates of interest changed.")
        return 0

    if warnings:
        for warning in warnings:
            eprint(f"WARN: {warning}")

    if failures:
        eprint("FAIL: Rust vendor docs lint failed.")
        for failure in failures:
            eprint(f"- {failure}")
        return 1

    print("OK: Rust vendor docs lint passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
