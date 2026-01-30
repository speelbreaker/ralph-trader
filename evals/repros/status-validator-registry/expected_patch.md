# Expected Patch: status-validator-registry

> **ORACLE ONLY** - This file is for scoring/review. NEVER feed to agent.

## Summary

Add `normalize_code_list()` helper to handle multiple registry formats.

## Key Changes

- **File:** `tools/validate_status.py`
- **Change:** Add normalization function that handles dicts with `values` key, lists of strings, lists of objects with `code` field

## Diff (Reference)

```diff
+def normalize_code_list(value: Any) -> list[str]:
+    if isinstance(value, dict):
+        if "values" in value:
+            return normalize_code_list(value["values"])
+        code = value.get("code")
+        return [code] if isinstance(code, str) else []
+    if isinstance(value, list):
+        out: list[str] = []
+        for item in value:
+            if isinstance(item, str):
+                out.append(item)
+            elif isinstance(item, dict):
+                code = item.get("code")
+                if isinstance(code, str):
+                    out.append(code)
+        return out
+    return []

-reduce_only_reasons: list[str] = [r["code"] for r in mode_regs.get("ReduceOnly", []) if isinstance(r, dict)]
+reduce_only_reasons = normalize_code_list(mode_regs.get("ReduceOnly", []))
```

## Scoring Criteria

- [ ] Touched `tools/validate_status.py`
- [ ] Added normalization for multiple registry formats
- [ ] Handles edge cases (nested values, mixed types)
