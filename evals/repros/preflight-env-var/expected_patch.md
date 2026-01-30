# Expected Patch: preflight-env-var

> **ORACLE ONLY** - This file is for scoring/review. NEVER feed to agent.

## Summary

Add proper argument parsing loop to handle `--strict` flag separately from positional args.

## Key Changes

- **File:** `plans/prd_preflight.sh`
- **Change:** Replace simple `${1:-...}` with a for loop that parses flags and positional args separately

## Diff (Reference)

```diff
-PRD_FILE="${1:-${PRD_FILE:-plans/prd.json}}"
+ARG_PRD_FILE=""
+STRICT=0
+
+for arg in "$@"; do
+  case "$arg" in
+    --strict) STRICT=1 ;;
+    --help|-h) ... ;;
+    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
+    *) ARG_PRD_FILE="$arg" ;;
+  esac
+done
+
+PRD_FILE="${ARG_PRD_FILE:-${PRD_FILE:-plans/prd.json}}"
```

## Scoring Criteria

- [ ] Touched `plans/prd_preflight.sh`
- [ ] Added argument parsing loop
- [ ] Handles --strict flag without breaking positional args
- [ ] No regressions in normal usage (prd_preflight.sh plans/prd.json)
