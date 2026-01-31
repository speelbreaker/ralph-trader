#!/usr/bin/env python3
"""
tools/validate_status.py (v3)

Contract-enforced /status validator for CSP.

Validates:
  - JSONSchema (Draft 2020-12)
  - CSP minimum keys presence
  - Manifest registry membership (tier purity, enum membership)
  - Latch invariants + Decision A (latch ⇒ ¬Active + REDUCEONLY_OPEN_PERMISSION_LATCHED)
  - Mode reason ordering (subsequence of manifest tier list)
  - owner_view schema lock

Usage:
  # Validate live /status (runtime, allows extra keys)
  python tools/validate_status.py --url http://localhost:8080/api/v1/status

  # Validate fixture (strict, no extra keys)
  python tools/validate_status.py --file tests/fixtures/status/foo.json --strict

  # CI mode (quiet, exit code only)
  python tools/validate_status.py --file foo.json --quiet

Exit codes:
  0 = OK
  1 = Validation failed
  2 = Setup error (missing files, bad args, missing dependency)
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path
from typing import Any

# CSP Minimum Keys (contract-mandated, must always exist)
CSP_MINIMUM_KEYS = frozenset([
    "status_schema_version",
    "contract_version",
    "build_id",
    "runtime_config_hash",
    "supported_profiles",
    "enforced_profile",
    "trading_mode",
    "risk_state",
    "bunker_mode_active",
    "connectivity_degraded",
    "mode_reasons",
    "open_permission_blocked_latch",
    "open_permission_reason_codes",
    "open_permission_requires_reconcile",
    "policy_age_sec",
    "last_policy_update_ts",
    "f1_cert_state",
    "f1_cert_expires_at",
    "disk_used_pct",
    "disk_used_last_update_ts_ms",
    "disk_used_pct_secondary",
    "disk_used_secondary_last_update_ts_ms",
    "mm_util",
    "mm_util_last_update_ts_ms",
    "loop_tick_last_ts_ms",
    "wal_queue_depth",
    "wal_queue_capacity",
    "wal_queue_enqueue_failures",
    "atomic_naked_events_24h",
    "429_count_5m",
    "10028_count_5m",
    "deribit_http_p95_ms",
    "ws_event_lag_ms",
])


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def load_json_file(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def fetch_json_url(url: str, timeout_s: float) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        data = resp.read()
    return json.loads(data.decode("utf-8"))


def validate_schema(instance: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    """Validate against JSONSchema. Returns list of errors (empty = OK)."""
    try:
        from jsonschema import Draft202012Validator
    except ImportError as ex:
        return [
            "SETUP ERROR: Missing dependency 'jsonschema'",
            "Fix: pip install jsonschema",
            f"Import error: {ex}",
        ]

    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: e.path)

    out: list[str] = []
    for err in errors:
        path = "$" + ("." + ".".join(str(p) for p in err.path) if err.path else "")
        out.append(f"[SCHEMA] {path}: {err.message}")
    return out


def check_minimum_keys(status: dict[str, Any]) -> list[str]:
    """Ensure all CSP minimum keys are present."""
    missing = CSP_MINIMUM_KEYS - set(status.keys())
    if missing:
        return [f"[CSP-MIN] Missing required key: {k}" for k in sorted(missing)]
    return []


def normalize_code_list(value: Any) -> list[str]:
    if isinstance(value, dict):
        if "values" in value:
            return normalize_code_list(value["values"])
        code = value.get("code")
        return [code] if isinstance(code, str) else []
    if isinstance(value, list):
        out: list[str] = []
        for item in value:
            if isinstance(item, str):
                out.append(item)
            elif isinstance(item, dict):
                code = item.get("code")
                if isinstance(code, str):
                    out.append(code)
        return out
    return []


def is_subsequence_in_order(seq: list[str], ordered_universe: list[str]) -> bool:
    """True iff seq preserves relative order of ordered_universe."""
    if not all(isinstance(v, str) for v in seq):
        return False
    if not all(isinstance(v, str) for v in ordered_universe):
        return False
    index = {v: i for i, v in enumerate(ordered_universe)}
    try:
        idxs = [index[v] for v in seq]
    except KeyError:
        return False
    return idxs == sorted(idxs)


def check_contract_invariants(status: dict[str, Any], manifest: dict[str, Any]) -> list[str]:
    """
    Check contract invariants that JSONSchema cannot express:
    - Contract version binding
    - Active ⇒ mode_reasons == []
    - ReduceOnly/Kill ⇒ mode_reasons non-empty
    - Tier purity and ordering
    - Latch invariants + Decision A
    - Enum membership
    """
    errs: list[str] = []

    regs = manifest.get("registries", {})
    mode_regs = regs.get("ModeReasonCode", {})
    reduce_only_reasons = normalize_code_list(mode_regs.get("ReduceOnly", []))
    kill_reasons = normalize_code_list(mode_regs.get("Kill", []))
    open_perm_reasons = normalize_code_list(regs.get("OpenPermissionReasonCode", []))
    manifest_contract_version = manifest.get("contract_version", "5.2")

    trading_mode = status.get("trading_mode")
    mode_reasons = status.get("mode_reasons", [])
    latch = status.get("open_permission_blocked_latch")
    latch_reasons = status.get("open_permission_reason_codes", [])
    requires_reconcile = status.get("open_permission_requires_reconcile")

    # 1. Contract version binding
    if status.get("contract_version") != manifest_contract_version:
        errs.append(
            f"[CONTRACT] Version mismatch: status has '{status.get('contract_version')}', "
            f"manifest requires '{manifest_contract_version}'"
        )

    # 2. Active ⇒ mode_reasons == []
    if trading_mode == "Active" and mode_reasons != []:
        errs.append(
            "[INVARIANT] trading_mode='Active' requires mode_reasons=[] "
            f"(got {mode_reasons})"
        )

    # 3. ReduceOnly/Kill ⇒ mode_reasons non-empty
    if trading_mode in ("ReduceOnly", "Kill"):
        if not isinstance(mode_reasons, list) or len(mode_reasons) == 0:
            errs.append(
                f"[INVARIANT] trading_mode='{trading_mode}' requires at least one mode_reason"
            )

    # 4. Tier purity + ordering
    if isinstance(mode_reasons, list):
        if trading_mode == "ReduceOnly":
            bad = [r for r in mode_reasons if r not in reduce_only_reasons]
            if bad:
                errs.append(
                    f"[TIER] Invalid ReduceOnly mode_reasons (not in manifest): {bad}"
                )
            if mode_reasons and not is_subsequence_in_order(mode_reasons, reduce_only_reasons):
                errs.append(
                    "[ORDER] mode_reasons violates manifest ReduceOnly tier ordering"
                )
        elif trading_mode == "Kill":
            bad = [r for r in mode_reasons if r not in kill_reasons]
            if bad:
                errs.append(
                    f"[TIER] Invalid Kill mode_reasons (not in manifest): {bad}"
                )
            if mode_reasons and not is_subsequence_in_order(mode_reasons, kill_reasons):
                errs.append(
                    "[ORDER] mode_reasons violates manifest Kill tier ordering"
                )
        elif trading_mode not in ("Active", None):
            errs.append(f"[ENUM] Unknown trading_mode: '{trading_mode}'")

    # 5. Latch invariants + Decision A
    if latch is True:
        # Basic latch invariants
        if requires_reconcile is not True:
            errs.append(
                "[LATCH] latch=true requires open_permission_requires_reconcile=true"
            )
        if not isinstance(latch_reasons, list) or len(latch_reasons) == 0:
            errs.append(
                "[LATCH] latch=true requires non-empty open_permission_reason_codes"
            )

        # Decision A: latch=true ⇒ ¬Active (ReduceOnly or Kill allowed)
        if trading_mode == "Active":
            errs.append(
                "[DECISION-A] latch=true prohibits trading_mode='Active' "
                "(must be 'ReduceOnly' or 'Kill')"
            )

        # Decision A: latch=true ⇒ REDUCEONLY_OPEN_PERMISSION_LATCHED in mode_reasons
        # (unless already in Kill mode, which is more severe)
        if trading_mode == "ReduceOnly":
            if not isinstance(mode_reasons, list) or "REDUCEONLY_OPEN_PERMISSION_LATCHED" not in mode_reasons:
                errs.append(
                    "[DECISION-A] latch=true with trading_mode='ReduceOnly' requires "
                    "'REDUCEONLY_OPEN_PERMISSION_LATCHED' in mode_reasons"
                )

    elif latch is False:
        if requires_reconcile is not False:
            errs.append(
                "[LATCH] latch=false requires open_permission_requires_reconcile=false"
            )
        if latch_reasons != []:
            errs.append(
                "[LATCH] latch=false requires open_permission_reason_codes=[]"
            )
    else:
        errs.append(
            f"[LATCH] open_permission_blocked_latch must be boolean (got {type(latch).__name__})"
        )

    # 6. Latch reason membership
    if isinstance(latch_reasons, list):
        bad = [c for c in latch_reasons if c not in open_perm_reasons]
        if bad:
            errs.append(
                f"[ENUM] Unknown open_permission_reason_codes (not in manifest): {bad}"
            )

    # 7. owner_view type check
    if "owner_view" in status and not isinstance(status["owner_view"], dict):
        errs.append(
            f"[SCHEMA] owner_view must be object (got {type(status['owner_view']).__name__})"
        )

    return errs


def check_no_extra_keys(status: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    """For strict mode: ensure no keys beyond what schema defines."""
    # Get allowed keys from schema properties
    allowed = set(schema.get("properties", {}).keys())
    actual = set(status.keys())
    extra = actual - allowed

    if extra:
        return [f"[STRICT] Extra key not in schema: '{k}'" for k in sorted(extra)]
    return []


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Validate /status JSON against CSP contract",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Validate live endpoint
  %(prog)s --url http://localhost:8080/api/v1/status

  # Validate fixture (strict mode)
  %(prog)s --file tests/fixtures/status/market_data_stale.json --strict

  # CI mode (quiet output)
  %(prog)s --file foo.json --quiet
""",
    )
    ap.add_argument("--url", help="Fetch status from URL")
    ap.add_argument("--file", help="Read status from file")
    ap.add_argument(
        "--schema",
        default="python/schemas/status_csp_min.schema.json",
        help="Path to JSONSchema (default: %(default)s)",
    )
    ap.add_argument(
        "--manifest",
        default="specs/status/status_reason_registries_manifest.json",
        help="Path to reason codes manifest (default: %(default)s)",
    )
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Strict mode: fail on extra keys (use for fixtures)",
    )
    ap.add_argument(
        "--quiet",
        action="store_true",
        help="Quiet mode: no output, exit code only",
    )
    ap.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="URL fetch timeout in seconds (default: %(default)s)",
    )
    args = ap.parse_args()

    # Exactly one input source
    if bool(args.url) == bool(args.file):
        if not args.quiet:
            eprint("Error: provide exactly one of --url or --file")
        return 2

    # Check required files exist
    schema_path = Path(args.schema)
    manifest_path = Path(args.manifest)

    if not schema_path.exists():
        if not args.quiet:
            eprint(f"Error: schema not found: {schema_path}")
        return 2
    if not manifest_path.exists():
        if not args.quiet:
            eprint(f"Error: manifest not found: {manifest_path}")
        return 2

    # Load schema and manifest
    try:
        schema = load_json_file(schema_path)
        manifest = load_json_file(manifest_path)
    except Exception as ex:
        if not args.quiet:
            eprint(f"Error loading schema/manifest: {ex}")
        return 2

    # Load status
    try:
        if args.url:
            status = fetch_json_url(args.url, args.timeout)
        else:
            status = load_json_file(Path(args.file))
    except Exception as ex:
        if not args.quiet:
            eprint(f"Error loading status: {ex}")
        return 2

    # Run all checks
    errors: list[str] = []

    # 1. Schema validation
    schema_errors = validate_schema(status, schema)
    if schema_errors and schema_errors[0].startswith("SETUP ERROR"):
        # Missing jsonschema dependency
        if not args.quiet:
            for line in schema_errors:
                eprint(line)
        return 2
    errors.extend(schema_errors)

    # 2. CSP minimum keys
    errors.extend(check_minimum_keys(status))

    # 3. Contract invariants
    errors.extend(check_contract_invariants(status, manifest))

    # 4. Strict mode: no extra keys
    if args.strict:
        errors.extend(check_no_extra_keys(status, schema))

    # Report results
    if errors:
        if not args.quiet:
            source = args.url or args.file
            eprint(f"VALIDATION FAILED: {source}")
            eprint(f"  {len(errors)} error(s):")
            for msg in errors:
                eprint(f"  - {msg}")
        return 1

    if not args.quiet:
        source = args.url or args.file
        print(f"VALIDATION OK: {source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
