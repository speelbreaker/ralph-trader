#!/usr/bin/env python3
"""
Merge slice audit outputs into a single prd_audit.json.

Usage:
    python3 plans/prd_audit_merge.py [--prd PATH] [--output PATH] [--slice-dir PATH]

Environment Variables:
    PRD_FILE: Path to full PRD (default: plans/prd.json)
    AUDIT_OUTPUT_DIR: Directory with slice audits (default: .context/parallel_audits)
    MERGED_AUDIT_FILE: Output path (default: plans/prd_audit.json)
"""

import hashlib
import json
import sys
from pathlib import Path


def sha256_file(path: Path) -> str:
    """Compute SHA256 of file contents."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lookup_slice_prd_sha(audit_file: Path, meta_files: dict[int, Path]) -> str | None:
    """Look up slice PRD SHA from meta file."""
    # Extract slice number from filename: audit_slice_N.json
    name = audit_file.name
    if not name.startswith("audit_slice_") or not name.endswith(".json"):
        return None
    try:
        slice_num = int(name[len("audit_slice_"):-len(".json")])
    except ValueError:
        return None

    meta_path = meta_files.get(slice_num)
    if not meta_path or not meta_path.exists():
        return None

    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        slice_prd_path = meta.get("prd_slice_file")
        if slice_prd_path and Path(slice_prd_path).exists():
            return sha256_file(Path(slice_prd_path))
    except (json.JSONDecodeError, OSError):
        pass

    return None


def merge_slice_audits(
    prd_file: Path,
    slice_audit_files: list[Path],
    slice_meta_files: dict[int, Path] | None = None,
) -> dict:
    """
    Merge slice audits into single audit output.

    Args:
        prd_file: Path to full PRD JSON
        slice_audit_files: List of paths to slice audit JSON files
        slice_meta_files: Optional dict mapping slice number to meta file path

    Returns:
        Merged audit dict

    Raises:
        ValueError: On validation failure (SHA mismatch, missing inputs, etc.)
    """
    if not prd_file.exists():
        raise ValueError(f"PRD file not found: {prd_file}")

    # 1. Load full PRD and compute SHA
    prd_sha256 = sha256_file(prd_file)
    meta_files = slice_meta_files or {}

    # 2. Load all slice audits, validate consistency
    inputs = None
    slices = []

    for f in sorted(slice_audit_files):
        if not f.exists():
            raise ValueError(f"Slice audit file not found: {f}")

        try:
            audit = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON in {f}: {e}")

        # Accept full PRD SHA or slice PRD SHA (when meta provides slice PRD file)
        if audit.get("prd_sha256") != prd_sha256:
            slice_prd_sha = lookup_slice_prd_sha(f, meta_files)
            if audit.get("prd_sha256") != slice_prd_sha:
                raise ValueError(
                    f"prd_sha256 mismatch in {f}: "
                    f"expected {prd_sha256} (full) or {slice_prd_sha} (slice), "
                    f"got {audit.get('prd_sha256')}"
                )

        # Inputs must be present and identical across slices
        if "inputs" not in audit:
            raise ValueError(f"inputs missing in slice audit: {f}")

        if inputs is None:
            inputs = audit["inputs"]
        elif audit["inputs"] != inputs:
            raise ValueError(
                f"inputs mismatch across slices: {f} differs from previous"
            )

        slices.append(audit)

    if not slices:
        raise ValueError("No slice audits to merge")

    # 3. Merge items: concat + sort by (slice, id)
    all_items = []
    for s in slices:
        all_items.extend(s.get("items", []))
    all_items.sort(key=lambda x: (x.get("slice", 0), x.get("id", "")))

    # 4. Recompute summary from merged items (don't sum slice summaries)
    items_total = len(all_items)
    items_pass = sum(1 for x in all_items if x.get("status") == "PASS")
    items_fail = sum(1 for x in all_items if x.get("status") == "FAIL")
    items_blocked = sum(1 for x in all_items if x.get("status") == "BLOCKED")

    # 5. Merge global_findings (concat arrays)
    global_must_fix = []
    global_risk = []
    global_improvements = []
    for s in slices:
        gf = s.get("global_findings", {})
        global_must_fix.extend(gf.get("must_fix", []))
        global_risk.extend(gf.get("risk", []))
        global_improvements.extend(gf.get("improvements", []))

    # must_fix_count = FAIL items + global must_fix entries
    must_fix_count = items_fail + len(global_must_fix)

    # 6. Build merged audit
    merged = {
        "project": slices[0].get("project", "Unknown"),
        "prd_sha256": prd_sha256,  # Full PRD SHA (not slice SHA)
        "inputs": inputs,
        "summary": {
            "items_total": items_total,
            "items_pass": items_pass,
            "items_fail": items_fail,
            "items_blocked": items_blocked,
            "must_fix_count": must_fix_count,
        },
        "global_findings": {
            "must_fix": global_must_fix,
            "risk": global_risk,
            "improvements": global_improvements,
        },
        "items": all_items,
    }

    return merged


def get_expected_slices(prd_file: Path) -> set[int]:
    """Get set of slice numbers from PRD."""
    prd = json.loads(prd_file.read_text(encoding="utf-8"))
    return set(item.get("slice", 0) for item in prd.get("items", []))


def extract_slice_num(filename: str) -> int | None:
    """Extract slice number from audit filename."""
    if not filename.startswith("audit_slice_") or not filename.endswith(".json"):
        return None
    try:
        return int(filename[len("audit_slice_"):-len(".json")])
    except ValueError:
        return None


def main():
    import os

    # Parse arguments and environment
    prd_file = Path(os.environ.get("PRD_FILE", "plans/prd.json"))
    output_dir = Path(os.environ.get("AUDIT_OUTPUT_DIR", ".context/parallel_audits"))
    output_file = Path(os.environ.get("MERGED_AUDIT_FILE", "plans/prd_audit.json"))

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--prd" and i + 1 < len(args):
            prd_file = Path(args[i + 1])
            i += 2
        elif args[i] == "--output" and i + 1 < len(args):
            output_file = Path(args[i + 1])
            i += 2
        elif args[i] == "--slice-dir" and i + 1 < len(args):
            output_dir = Path(args[i + 1])
            i += 2
        else:
            i += 1

    # Find slice audit files
    slice_audit_files = sorted(output_dir.glob("audit_slice_*.json"))
    if not slice_audit_files:
        print(f"ERROR: No slice audit files found in {output_dir}", file=sys.stderr)
        sys.exit(1)

    # Validate completeness: all expected slices must be present
    expected_slices = get_expected_slices(prd_file)
    found_slices = {extract_slice_num(f.name) for f in slice_audit_files}
    found_slices.discard(None)

    missing = expected_slices - found_slices
    if missing:
        print(f"ERROR: Missing slice audit files: {sorted(missing)}", file=sys.stderr)
        sys.exit(1)

    # Find meta files
    meta_files: dict[int, Path] = {}
    for meta_path in output_dir.glob("meta_*.json"):
        name = meta_path.name
        try:
            slice_num = int(name[len("meta_"):-len(".json")])
            meta_files[slice_num] = meta_path
        except ValueError:
            pass

    print(f"Merging {len(slice_audit_files)} slice audits...", file=sys.stderr)

    try:
        merged = merge_slice_audits(prd_file, slice_audit_files, meta_files)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    # Write output
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(
        json.dumps(merged, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Merged audit written to {output_file}", file=sys.stderr)

    # Print summary
    summary = merged["summary"]
    print(
        f"Summary: {summary['items_total']} items, "
        f"{summary['items_pass']} PASS, "
        f"{summary['items_fail']} FAIL, "
        f"{summary['items_blocked']} BLOCKED",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
