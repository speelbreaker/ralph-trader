#!/usr/bin/env python3
"""
Update PRD audit slice cache after a slice audit completes.

Usage:
    python3 plans/prd_cache_update.py <slice_num> <audit_json_path> [--decision PASS|FAIL|BLOCKED]

Environment Variables:
    PRD_FILE: Path to PRD (default: plans/prd.json)
    REPO_ROOT: Repository root (default: .)
"""

import errno
import fcntl
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
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
        for key in ("generated_at", "filtered_from"):
            data.pop(key, None)
        return sha256_bytes(canonical_json(data))
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: digest parse failed for {path}: {e}", file=sys.stderr)
        sys.exit(2)


def compute_global_inputs_sha(repo_root: Path) -> tuple[str, dict]:
    """Compute SHA of global inputs."""
    global_inputs = {
        "prompt_sha256": sha256_file(repo_root / "prompts" / "auditor.md"),
        "workflow_contract_sha256": sha256_file(repo_root / "specs" / "WORKFLOW_CONTRACT.md"),
        "runner_sha256": sha256_file(repo_root / "plans" / "run_prd_auditor.sh"),
        "validator_sha256": sha256_file(repo_root / "plans" / "prd_audit_check.sh"),
        "slice_prep_sha256": sha256_file(repo_root / "plans" / "prd_slice_prepare.sh"),
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
        stable_item.pop("passes", None)
        canonical_items.append(stable_item)
    return sha256_bytes(canonical_json(canonical_items))


def acquire_lock(cache_file: Path) -> tuple[int | None, Path | None]:
    """Acquire exclusive lock on cache file (flock with mkdir fallback).

    Uses flock for proper mutual exclusion. Falls back to mkdir only when
    flock is unavailable (e.g., NFS without lock support). If flock is
    available but lock is held, exits with error (no fallback to mkdir).

    os.open() failures are fatal - if we can't create/open the lock file,
    we likely can't write the cache either. Only flock() failures with
    specific "not supported" errnos trigger the mkdir fallback.
    """
    lock_file = cache_file.with_suffix(".json.lock")
    lock_dir = cache_file.with_suffix(".json.lock.d")

    # Try flock-based locking first
    try:
        fd = os.open(str(lock_file), os.O_CREAT | os.O_RDWR)
    except OSError as e:
        # Can't open lock file - fatal error (can't write to directory)
        print(f"ERROR: cannot create lock file: {e}", file=sys.stderr)
        sys.exit(7)

    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd, None
    except BlockingIOError:
        # Lock is held by another process - flock works, just busy
        os.close(fd)
        print("ERROR: cache locked by another process", file=sys.stderr)
        sys.exit(7)
    except OSError as e:
        os.close(fd)
        # Only fall back to mkdir for specific "flock not supported" errors
        if e.errno not in (errno.ENOSYS, errno.ENOLCK, errno.EOPNOTSUPP):
            print(f"ERROR: flock failed: {e}", file=sys.stderr)
            sys.exit(7)

    # mkdir fallback for filesystems without flock support
    try:
        lock_dir.mkdir(parents=True, exist_ok=False)
        return None, lock_dir
    except FileExistsError:
        print("ERROR: cache locked by another process", file=sys.stderr)
        sys.exit(7)
    except OSError as e:
        print(f"ERROR: cannot acquire cache lock: {e}", file=sys.stderr)
        sys.exit(7)


def release_lock(fd: int | None, lock_dir: Path | None) -> None:
    """Release lock acquired by acquire_lock()."""
    if fd is not None:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    if lock_dir is not None:
        try:
            lock_dir.rmdir()
        except OSError:
            pass  # Already removed or never created


def extract_decision_from_audit(audit_path: Path) -> str:
    """Extract overall decision from audit JSON."""
    try:
        audit = json.loads(audit_path.read_text(encoding="utf-8"))
        summary = audit.get("summary", {})
        def to_int(value):
            if isinstance(value, int):
                return value
            if isinstance(value, float):
                if value.is_integer():
                    return int(value)
                return None
            if isinstance(value, str):
                try:
                    return int(value)
                except ValueError:
                    return None
            return None

        items_fail = to_int(summary.get("items_fail", 0))
        items_blocked = to_int(summary.get("items_blocked", 0))

        if items_fail is None or items_blocked is None:
            return "UNKNOWN"

        if items_fail > 0:
            return "FAIL"
        elif items_blocked > 0:
            return "BLOCKED"
        else:
            return "PASS"
    except (json.JSONDecodeError, OSError):
        return "UNKNOWN"


def main():
    if len(sys.argv) < 3:
        print("Usage: prd_cache_update.py <slice_num> <audit_json_path> [--decision PASS|FAIL|BLOCKED]", file=sys.stderr)
        sys.exit(1)

    slice_num = int(sys.argv[1])
    audit_path = Path(sys.argv[2]).resolve()
    if not audit_path.exists():
        print(f"ERROR: Audit file not found: {audit_path}", file=sys.stderr)
        sys.exit(1)

    # Optional decision override
    decision = None
    args = sys.argv[3:]
    for i, arg in enumerate(args):
        if arg == "--decision" and i + 1 < len(args):
            decision = args[i + 1].upper()

    # Resolve paths
    repo_root = Path(os.environ.get("REPO_ROOT", ".")).resolve()
    prd_file = Path(os.environ.get("PRD_FILE", "plans/prd.json"))
    if not prd_file.is_absolute():
        prd_file = repo_root / prd_file
    cache_file = repo_root / ".context" / "prd_audit_slice_cache.json"

    # Extract decision from audit if not provided
    if decision is None:
        decision = extract_decision_from_audit(audit_path)

    valid_decisions = {"PASS", "FAIL", "BLOCKED"}
    if decision not in valid_decisions:
        print(f"ERROR: Uncacheable decision '{decision}' for slice {slice_num}", file=sys.stderr)
        sys.exit(1)

    # Note: BLOCKED decisions are written to cache to invalidate prior PASS/FAIL entries.
    # prd_cache_check.py treats BLOCKED as a cache miss (dependencies may have resolved).

    # Load PRD and get items for this slice
    try:
        prd = json.loads(prd_file.read_text(encoding="utf-8"))
        slice_items = [item for item in prd.get("items", []) if item.get("slice") == slice_num]
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: Failed to load PRD: {e}", file=sys.stderr)
        sys.exit(1)

    # Compute current hashes (before lock to minimize lock duration)
    global_sha, global_inputs = compute_global_inputs_sha(repo_root)
    slice_inputs_sha = compute_slice_inputs_sha(slice_items)

    # Acquire lock for cache read-modify-write
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    fd, lock_dir = acquire_lock(cache_file)
    try:
        # Load existing cache
        cache: dict = {"version": 1, "slices": {}}
        if cache_file.exists():
            try:
                cache = json.loads(cache_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                pass

        # Update global inputs if changed
        cache["global_inputs_sha"] = global_sha
        cache["global_inputs"] = global_inputs

        # Update slice entry
        if "slices" not in cache:
            cache["slices"] = {}

        cache["slices"][str(slice_num)] = {
            "slice_inputs_sha": slice_inputs_sha,
            "slice_items": [item.get("id", "") for item in slice_items],
            "audit_json": str(audit_path),
            "decision": decision,
            "cached_at": datetime.now(timezone.utc).isoformat(),
        }

        # Atomic write
        with tempfile.NamedTemporaryFile(
            mode="w",
            dir=cache_file.parent,
            suffix=".tmp",
            delete=False,
            encoding="utf-8",
        ) as f:
            json.dump(cache, f, indent=2)
            f.write("\n")
            temp_path = Path(f.name)

        temp_path.rename(cache_file)
    finally:
        release_lock(fd, lock_dir)

    print(f"Cache updated for slice {slice_num}: {decision}", file=sys.stderr)


if __name__ == "__main__":
    main()
