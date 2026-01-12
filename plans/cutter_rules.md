# Non-negotiables
- Always read IMPLEMENTATION_PLAN.md, CONTRACT.md (and specs/ equivalents if present), and plans/cutter_rules.md before generating PRD.
- Always run ./plans/prd_lint.sh after writing plans/prd.json and repair failures in the PRD (not the linter) for up to 5 passes.
- If errors remain after 5 passes, set needs_human_decision=true for the affected items and add "BLOCKED: ..." to acceptance and evidence.
- Append-only: never rewrite or delete existing rules.
- New auto-learned rule format (one line per rule):
  - YYYY-MM-DD | CODE | rule: <plain rule> | check: <mechanical check>

# Auto-learned rules
