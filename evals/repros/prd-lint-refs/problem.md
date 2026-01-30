# Problem: prd-lint-refs

## Error Observed

PRD lint fails due to invalid references or scope path issues:

```bash
$ ./plans/prd_lint.sh plans/prd.json
ERROR: Invalid ref or scope path detected
# Lint failures related to plan_refs or scope.touch paths
```

## Expected Behavior

PRD items should have valid:
- `plan_refs` pointing to real plan sections
- `scope.touch` listing files that exist or will be created
- `scope.create` only for genuinely new files

## Reproduction Steps

1. Run `./plans/prd_lint.sh plans/prd.json`
2. Observe lint errors about refs or scope

## Context

- **Affected file(s):** `plans/prd.json`
- **Root cause hint:** Check plan_refs format and scope.touch vs scope.create classification
