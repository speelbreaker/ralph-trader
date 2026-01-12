# Non-negotiables
- Always read IMPLEMENTATION_PLAN.md, CONTRACT.md (and specs/ equivalents if present), and plans/cutter_rules.md before generating PRD.
- Always run ./plans/prd_lint.sh after writing plans/prd.json and repair failures in the PRD (not the linter) for up to 5 passes.
- If errors remain after 5 passes, set needs_human_decision=true for the affected items and add a human_blocker (do not add non-testable acceptance bullets).
- Append-only: never rewrite or delete existing rules.
- New auto-learned rule format (one line per rule):
  - YYYY-MM-DD | CODE | rule: <plain rule> | check: <mechanical check>

# Auto-learned rules
- 2026-01-12 | GLOB_TOO_BROAD | rule: Avoid broad globs in scope.touch; keep matches below the hard threshold. | check: plans/prd_lint.sh flags GLOB_TOO_BROAD when glob matches > PRD_LINT_GLOB_FAIL.
- 2026-01-12 | GLOB_BROAD | rule: Prefer explicit paths; if globs are necessary, keep matches below the warning threshold. | check: plans/prd_lint.sh flags GLOB_BROAD when glob matches > PRD_LINT_GLOB_WARN.
- 2026-01-12 | JUNK_PATH | rule: Never include OS artifacts like .DS_Store in scope.touch. | check: plans/prd_lint.sh flags JUNK_PATH for .DS_Store in scope.touch.
- 2026-01-12 | MISSING_PATH | rule: Non-glob scope.touch paths must exist; use existing parent dirs if files are created later. | check: plans/prd_lint.sh flags MISSING_PATH when a path does not exist.
- 2026-01-12 | CONTRACT_ACCEPTANCE_MISMATCH | rule: Contract refs mentioning reject/degraded/fail-closed/must stop must be enforced in acceptance. | check: plans/prd_lint.sh flags CONTRACT_ACCEPTANCE_MISMATCH when acceptance lacks required terms.
- 2026-01-12 | FORWARD_KEYWORD | rule: Do not reference later-slice components (PolicyGuard/EvidenceGuard/F1/WAL/Replay) without dependencies. | check: plans/prd_lint.sh flags FORWARD_KEYWORD when acceptance mentions forward keywords.
- 2026-01-12 | DEPENDENCY_MISSING | rule: All dependencies must reference existing PRD item IDs. | check: plans/prd_lint.sh flags DEPENDENCY_MISSING for unresolved IDs.
- 2026-01-12 | DEPENDENCY_SLICE | rule: Dependencies must not point to higher slices. | check: plans/prd_lint.sh flags DEPENDENCY_SLICE when dep slice > item slice.
- 2026-01-12 | WORKFLOW_TOUCHES_CRATES | rule: category=workflow MUST NOT touch crates/. | check: plans/prd_lint.sh flags WORKFLOW_TOUCHES_CRATES for crates/ in scope.touch.
- 2026-01-12 | EXECUTION_TOUCHES_PLANS | rule: category=execution or risk MUST NOT touch plans/. | check: plans/prd_lint.sh flags EXECUTION_TOUCHES_PLANS for plans/ in scope.touch.
