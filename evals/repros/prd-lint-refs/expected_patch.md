# Expected Patch: prd-lint-refs

> **ORACLE ONLY** - This file is for scoring/review. NEVER feed to agent.

## Summary

Fix plan_refs to use valid section names and move files from scope.create to scope.touch.

## Key Changes

- **File:** `plans/prd.json`
- **Change:** Update `plan_refs` from short codes like "P0-A" to actual section names, move evidence files from `create` to `touch`

## Diff (Reference)

```diff
 "plan_refs": [
-  "P0-A"
+  "Global Non-Negotiables (apply to ALL stories)"
 ],
 "scope": {
   "touch": [
-    "docs/launch_policy.md"
-  ],
-  "create": [
+    "docs/launch_policy.md",
     "evidence/phase0/policy/launch_policy_snapshot.md"
   ],
+  "create": [],
```

## Scoring Criteria

- [ ] Touched `plans/prd.json`
- [ ] Fixed plan_refs to valid section names
- [ ] Moved files from create to touch appropriately
- [ ] No structural changes to PRD schema
