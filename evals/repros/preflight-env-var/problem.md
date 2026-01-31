# Problem: preflight-env-var

## Error Observed

When running PRD preflight with the `--strict` flag, the script fails because it doesn't recognize the flag:

```bash
$ ./plans/prd_preflight.sh --strict plans/prd.json
[preflight] ERROR: PRD file not found: --strict
```

The script treats `--strict` as the PRD filename instead of as a flag.

## Expected Behavior

The script should support a `--strict` flag that enables strict validation mode. The flag should be parsed separately from positional arguments.

## Reproduction Steps

1. Run `./plans/prd_preflight.sh --strict plans/prd.json`
2. Observe the script fails with "PRD file not found: --strict"

## Context

- **Affected file(s):** `plans/prd_preflight.sh`
- **Root cause hint:** Argument parsing doesn't handle flags
