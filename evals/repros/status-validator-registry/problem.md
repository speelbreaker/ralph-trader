# Problem: status-validator-registry

## Error Observed

The status validator fails to parse registry entries correctly when the manifest uses **mixed-format registries** (some entries as plain strings, others as objects with `code` field).

This is a **defensive robustness fix** - the old code would silently drop plain string entries when processing registries, causing validation to fail incorrectly. The new code handles all format variations.

```bash
$ python3 tools/validate_status.py --file tests/fixtures/status/repro-only/mixed_registry_test.json --schema tests/fixtures/schemas/repro_test_schema.json --manifest tests/fixtures/manifests/mixed_format_registry.json --strict
ValidationError: Invalid ReduceOnly mode_reasons (not in manifest): ['REDUCEONLY_PLAIN_STRING']
# Old code only extracted object entries with "code" field, missing plain strings
```

## Expected Behavior

The validator should handle various registry formats robustly:
- Simple list of code strings (e.g., `["CODE_A", "CODE_B"]`)
- List of objects with `code` field (e.g., `[{"code": "CODE_A", "display": "..."}, ...]`)
- Nested `values` wrapper (e.g., `{"values": [...]}`)
- **Mixed formats** (e.g., `["PLAIN_CODE", {"code": "OBJECT_CODE"}]`)

## Reproduction Steps

1. Run `python3 tools/validate_status.py --file tests/fixtures/status/repro-only/mixed_registry_test.json --schema tests/fixtures/schemas/repro_test_schema.json --manifest tests/fixtures/manifests/mixed_format_registry.json --strict`
2. At bad_commit (18ff16b): Validation fails because plain string codes are silently dropped during registry parsing
3. At good_commit (edddce1): Validation passes because `normalize_code_list()` handles all formats

## Context

- **Affected file(s):** `tools/validate_status.py`
- **Root cause:** `normalize_code_list()` function in old code didn't handle plain string entries in registry lists
- **Fix:** Enhanced `normalize_code_list()` to extract codes from both plain strings and objects with `code` field
- **Nature:** Defensive fix to prevent silent data loss during registry parsing (not a current production failure)
