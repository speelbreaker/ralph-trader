# SKILL: /plan-review (Implementation Plan Review)

Purpose
- Systematic review of implementation plans before approval
- Catches omissions, not just errors
- Ensures workflow compliance and implementability

When to use
- Before approving any implementation plan
- After automated plan analysis flags issues
- When plan touches workflow/harness files

## Pre-Review: Read First

Before reviewing ANY plan, read these based on scope:

| If plan touches... | Read first... |
|-------------------|---------------|
| `plans/*` | `specs/WORKFLOW_CONTRACT.md` §11, §12; `reviews/REVIEW_CHECKLIST.md` §Workflow |
| `specs/*` | `specs/WORKFLOW_CONTRACT.md` §2.1, §11 |
| Cache/state files | Existing cache schemas in codebase |
| Parallel execution | Race condition patterns in codebase |

## Review Checklist

### 1. Governance Compliance (for plans/ or specs/ changes)

- [ ] **Acceptance coverage**: Does plan include updates to `plans/workflow_acceptance.sh`?
- [ ] **Verify inclusion**: Does verification section include `./plans/verify.sh` or CI proof?
- [ ] **Change control**: Does plan follow WORKFLOW_CONTRACT.md §11?
- [ ] **Postmortem**: If PR-bound, is postmortem mentioned?

Reference: `reviews/REVIEW_CHECKLIST.md` lines 20-24:
> Workflow file changes add acceptance coverage in `plans/workflow_acceptance.sh` or a gate invoked by it.

### 2. Implementability (could someone build this blind?)

- [ ] **All file paths defined**: No "roadmap" without exact path (e.g., `docs/ROADMAP.md`)
- [ ] **All inputs canonicalized**: Hash computation inputs fully specified
- [ ] **All outputs have schemas**: JSON structures have field definitions
- [ ] **Error handling specified**: What happens on invalid input, missing file, timeout?

Ask: "If I implemented this with only the plan as context, where would I get stuck?"

### 3. Source of Truth (no hardcoded enums)

- [ ] **Enums traced to validator**: Status values derived from validation code, not hardcoded
- [ ] **Schemas match validators**: Field names match what validation scripts check
- [ ] **Version/hash sources specified**: "git hash of X" vs "file content hash of X"

Example failure (from curried-enchanting-pond.md):
```python
# Plan hardcodes:
global_findings.should_fix  # WRONG

# prd_audit_check.sh validates:
global_findings.risk        # Actual
global_findings.improvements # Actual
```

Fix: Read `prd_audit_check.sh` and derive field names from validation logic.

### 4. Concurrency & Race Conditions

- [ ] **Parallel writes addressed**: If multiple writers, is there locking or single-writer phase?
- [ ] **Atomic operations specified**: "write temp, rename" vs file locking
- [ ] **Race window identified**: What happens if two processes read-modify-write?

Example failure (from curried-enchanting-pond.md):
> Atomic rename alone won't prevent lost updates when multiple prd_cache_update.py writes race

Fix: Single-writer merge phase OR file locking OR per-slice cache files.

### 5. Omissions Checklist

Check for these commonly missing sections:

- [ ] **Rollback plan**: How to undo if something breaks?
- [ ] **Migration path**: If schema changes, how to handle old data?
- [ ] **Failure modes**: What are the top 3 ways this could fail?
- [ ] **Metrics/observability**: How do we know it's working?
- [ ] **Dependencies**: What must exist before this can run?

### 6. Claims Verification

- [ ] **Counts match reality**: "21 jq-based checks" - actually count them
- [ ] **Schemas match code**: Read the validator, compare field names
- [ ] **Existing code does what plan claims**: Read referenced files

## Output Format

```markdown
## Plan Review: <plan name>

### Pre-Review Docs Read
- [ ] WORKFLOW_CONTRACT.md §11 (if touches plans/)
- [ ] <other relevant docs>

### Governance Compliance
- [x] Acceptance coverage included
- [ ] MISSING: verify.sh in verification section

### Implementability
- [x] File paths defined
- [ ] AMBIGUOUS: "prompt" file location not specified

### Source of Truth
- [ ] WRONG: global_findings.should_fix (actual: risk, improvements)

### Concurrency
- [ ] RACE: parallel cache updates need locking

### Omissions
- [ ] MISSING: rollback plan

### Recommendations
1. Add acceptance test coverage for new scripts
2. Specify exact prompt file path
3. Add file locking for cache updates
4. Fix global_findings field names

### Verdict: APPROVE | NEEDS_CHANGES | BLOCK
```

## Anti-Patterns to Avoid

1. **Reviewing in isolation**: Always read governance docs first
2. **Checking only what's there**: Systematically check for omissions
3. **Trusting claimed counts**: Verify numbers against actual code
4. **Assuming enums are correct**: Trace to validation source of truth
5. **Ignoring concurrency**: Any parallel execution needs race analysis

## Quick Reference: Common Omissions by Plan Type

| Plan Type | Commonly Missing |
|-----------|------------------|
| Caching | Race conditions, eviction policy, invalidation rules |
| Parallel execution | Failure handling, partial completion, merge logic |
| Schema changes | Migration, backwards compat, validator updates |
| Workflow changes | Acceptance tests, verify.sh inclusion, §11 compliance |
| New scripts | Allowlist additions, executable permissions, error codes |
