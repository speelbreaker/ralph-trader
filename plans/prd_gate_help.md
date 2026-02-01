# PRD Gate Help

## Environment Variables

| Env var | Default | Effect |
|---------|---------|--------|
| `PRD_REF_CHECK_ENABLED` | `1` | Set to `0` to skip ref check locally (CI always blocks; `PRD_GATE_ALLOW_REF_SKIP=1` only applies outside CI) |
| `PRD_GATE_ALLOW_REF_SKIP` | `0` | Allow `PRD_REF_CHECK_ENABLED=0` outside CI |
| `PRD_LINT_STRICT_HEURISTICS` | `0` | Fail on heuristic warnings |
| `PRD_LINT_ALLOW_SCHEMA_BYPASS` | `0` | Skip schema validation inside `prd_lint.sh` (warns only); `prd_gate.sh` still runs `prd_schema_check.sh` |

## Common Lint Failure Codes

These are diagnostic codes printed in `prd_lint.sh` output (not process exit codes):

| Code | Meaning |
|------|---------|
| `CREATE_PATH_EXISTS` | `scope.create` path already exists on disk |
| `CREATE_PARENT_MISSING` | `scope.create` parent directory doesn't exist |
| `SCHEMA_FAIL` | PRD doesn't match JSON schema |
| `MISSING_ANCHOR_REF` | `contract_refs` mentions anchor title but missing `Anchor-###` ID |
| `MISSING_VR_REF` | `contract_refs` mentions validation rule title but missing `VR-###` ID |

## Ref Check Errors

From `prd_ref_check.sh` (separate script):

```
[prd_ref_check] ERROR: unresolved contract_ref ...
[prd_ref_check] ERROR: unresolved plan_ref ...
```

## Quick Fixes

**CREATE_PATH_EXISTS**: The `scope.create` path already exists. Either:
- Remove the path from `scope.create` (it's not a new file)
- Delete the existing file if it was scaffolded incorrectly
- Move to `scope.touch` if editing an existing file

**CREATE_PARENT_MISSING**: The parent directory for a `scope.create` path doesn't exist:
- Create the parent directory first
- Check for typos in the path

**MISSING_ANCHOR_REF / MISSING_VR_REF**: Contract references need explicit IDs:
- Find the anchor/VR in `specs/CONTRACT.md`
- Add the ID in format: `"Anchor-001: Title"` or `"VR-001: Title"`

## See Also

- `plans/prd_lint.sh` - PRD linting rules
- `plans/prd_schema_check.sh` - Schema validation
- `plans/prd_ref_check.sh` - Reference resolution
