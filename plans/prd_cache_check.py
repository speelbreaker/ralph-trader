#!/usr/bin/env python3
"""
Check PRD audit slice cache and determine which slices need re-auditing.

Returns JSON with valid_slices (can reuse) and invalid_slices (must re-audit).

Usage:
    python3 plans/prd_cache_check.py [--slices N,N,...] [--output-dir PATH]

Environment Variables:
    AUDIT_OUTPUT_DIR: Directory for slice outputs (default: .context/parallel_audits)
    PRD_FILE: Path to PRD (default: plans/prd.json)
"""

import hashlib
import json
import os
import sys
from pathlib import Path


def sha256_file(path: Path) -> str:
    """Compute SHA256 of file contents."""
    if not path.exists():
        return "ABSENT"
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha256_bytes(data: bytes) -> str:
    """Compute SHA256 of bytes."""
    return hashlib.sha256(data).hexdigest()


def canonical_json(obj: dict | list) -> bytes:
    """Produce canonical JSON bytes for hashing."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def stable_digest_hash(path: Path) -> str:
    """Hash digest JSON, excluding volatile fields.

    Returns "ABSENT" for missing files (valid state).
    Exits non-zero for corrupt files (requires human attention).
    """
    if not path.exists():
        return "ABSENT"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        # Remove volatile fields
        for key in ("generated_at", "filtered_from"):
            data.pop(key, None)
        return sha256_bytes(canonical_json(data))
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: digest parse failed for {path}: {e}", file=sys.stderr)
        sys.exit(2)


def compute_global_inputs_sha(repo_root: Path) -> tuple[str, dict]:
    """Compute SHA of global inputs that invalidate all slices if changed."""
    global_inputs = {
        "prompt_sha256": sha256_file(repo_root / "prompts" / "auditor.md"),
        "workflow_contract_sha256": sha256_file(repo_root / "specs" / "WORKFLOW_CONTRACT.md"),
        "runner_sha256": sha256_file(repo_root / "plans" / "run_prd_auditor.sh"),
        "validator_sha256": sha256_file(repo_root / "plans" / "prd_audit_check.sh"),
        "slice_prep_sha256": sha256_file(repo_root / "plans" / "prd_slice_prepare.sh"),
        # Digest content hashes (stable fields only)
        "contract_digest_sha256": stable_digest_hash(repo_root / ".context" / "contract_digest.json"),
        "plan_digest_sha256": stable_digest_hash(repo_root / ".context" / "plan_digest.json"),
        "roadmap_digest_sha256": stable_digest_hash(repo_root / ".context" / "roadmap_digest.json"),
    }
    global_sha = sha256_bytes(canonical_json(global_inputs))
    return global_sha, global_inputs


def compute_slice_inputs_sha(prd_items: list[dict]) -> str:
    """Compute SHA of slice inputs (PRD items sans volatile 'passes' field)."""
    canonical_items = []
    for item in sorted(prd_items, key=lambda x: x.get("id", "")):
        stable_item = dict(item)
        stable_item.pop("passes", None)  # Exclude volatile field
        canonical_items.append(stable_item)
    return sha256_bytes(canonical_json(canonical_items))


def load_prd_items_by_slice(prd_path: Path) -> dict[int, list[dict]]:
    """Load PRD and group items by slice number."""
    if not prd_path.exists():
        return {}
    try:
        prd = json.loads(prd_path.read_text(encoding="utf-8"))
        items_by_slice: dict[int, list[dict]] = {}
        for item in prd.get("items", []):
            slice_num = item.get("slice", 0)
            if slice_num not in items_by_slice:
                items_by_slice[slice_num] = []
            items_by_slice[slice_num].append(item)
        return items_by_slice
    except (json.JSONDecodeError, OSError):
        return {}


def main():
    # Parse environment and arguments
    repo_root = Path(os.environ.get("REPO_ROOT", ".")).resolve()
    prd_file = Path(os.environ.get("PRD_FILE", "plans/prd.json"))
    if not prd_file.is_absolute():
        prd_file = repo_root / prd_file
    output_dir = Path(os.environ.get("AUDIT_OUTPUT_DIR", ".context/parallel_audits"))
    if not output_dir.is_absolute():
        output_dir = repo_root / output_dir
    cache_file = repo_root / ".context" / "prd_audit_slice_cache.json"

    # Parse --slices argument
    target_slices: list[int] | None = None
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == "--slices" and i + 1 < len(args):
            target_slices = [int(s) for s in args[i + 1].split(",")]
        elif arg == "--output-dir" and i + 1 < len(args):
            output_dir = Path(args[i + 1])
            if not output_dir.is_absolute():
                output_dir = repo_root / output_dir

    # Load PRD items by slice
    items_by_slice = load_prd_items_by_slice(prd_file)
    if not items_by_slice:
        print(json.dumps({"error": "Failed to load PRD", "valid_slices": [], "invalid_slices": []}))
        sys.exit(1)

    all_slices = sorted(items_by_slice.keys())
    if target_slices is not None:
        all_slices = [s for s in all_slices if s in target_slices]

    # Compute current global inputs SHA
    current_global_sha, current_global_inputs = compute_global_inputs_sha(repo_root)

    # Load cache
    cache: dict = {}
    if cache_file.exists():
        try:
            cache = json.loads(cache_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            cache = {}

    valid_slices: list[int] = []
    invalid_slices: list[int] = []
    reasons: dict[int, str] = {}

    # Check global invalidation
    cached_global_sha = cache.get("global_inputs_sha", "")
    global_invalid = cached_global_sha != current_global_sha

    if global_invalid:
        # All slices invalid due to global change
        invalid_slices = all_slices
        for s in all_slices:
            reasons[s] = "global_inputs_changed"
    else:
        # Check per-slice validity
        cached_slices = cache.get("slices", {})

        for slice_num in all_slices:
            slice_key = str(slice_num)
            cached_slice = cached_slices.get(slice_key, {})

            # Compute current slice inputs SHA
            current_slice_sha = compute_slice_inputs_sha(items_by_slice.get(slice_num, []))

            # Check cache validity
            cached_slice_sha = cached_slice.get("slice_inputs_sha", "")
            cached_decision = cached_slice.get("decision", "")
            cached_audit_path = cached_slice.get("audit_json", "")

            # Validation conditions
            if cached_slice_sha != current_slice_sha:
                invalid_slices.append(slice_num)
                reasons[slice_num] = "slice_inputs_changed"
            elif cached_decision == "BLOCKED":
                # BLOCKED is always a cache miss (dependencies may have resolved)
                invalid_slices.append(slice_num)
                reasons[slice_num] = "blocked_not_cacheable"
            elif not cached_audit_path or not Path(cached_audit_path).exists():
                invalid_slices.append(slice_num)
                reasons[slice_num] = "cached_audit_file_missing"
            else:
                valid_slices.append(slice_num)

    # Output result
    result = {
        "global_inputs_sha": current_global_sha,
        "global_inputs_changed": global_invalid,
        "valid_slices": valid_slices,
        "invalid_slices": invalid_slices,
        "reasons": {str(k): v for k, v in reasons.items()},
    }

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
