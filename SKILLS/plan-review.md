# SKILL: /plan-review (Implementation Plan Review)

Purpose
- Systematic review of implementation plans before approval
- Catches omissions, not just errors
- Ensures workflow compliance and implementability
- **Identifies failure modes, not just syntax correctness**

When to use
- Before approving any implementation plan
- After automated plan analysis flags issues
- When plan touches workflow/harness files
- Long-running automated processes
- Plans with shell scripts or CLI commands

## Pre-Review: Read First

Before reviewing ANY plan, read these based on scope:

| If plan touches... | Read first... |
|-------------------|---------------|
| `plans/*` | `specs/WORKFLOW_CONTRACT.md` §11, §12; `reviews/REVIEW_CHECKLIST.md` §Workflow |
| `specs/*` | `specs/WORKFLOW_CONTRACT.md` §2.1, §11 |
| Cache/state files | Existing cache schemas in codebase |
| Parallel execution | Race condition patterns in codebase |
| PRD stories | `CLAUDE.md` Ralph-only rule for `passes=false` stories |

---

## Part A: Governance & Implementability

### 1. Governance Compliance (for plans/ or specs/ changes)

**CRITICAL: Verify exact text, not just presence.** Don't check "does verify.sh appear?" — check "does it match the exact governance requirement?"

- [ ] **Acceptance coverage**: Does plan include updates to `plans/workflow_acceptance.sh`?
- [ ] **Verify inclusion**: Does verification section include `./plans/verify.sh full` (not just `verify.sh`) or explicit CI proof? Workflow file changes require `full` mode per REVIEW_CHECKLIST.md line 18.
- [ ] **Change control**: Does plan follow WORKFLOW_CONTRACT.md §11?
- [ ] **Postmortem**: If PR-bound, is postmortem mentioned?
- [ ] **Postmortem template**: Declares "workflow vs bot" governing contract explicitly?
- [ ] **Ralph-only rule**: No manual implementation of `passes=false` PRD stories (including "amend" options)
- [ ] **No time estimates**: Plan avoids duration predictions per CLAUDE.md

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
- [ ] **Plan's self-review accurate**: If plan has its own checklist, verify those boxes are correctly checked

### 7. Cross-Fix Execution Paths (MANDATORY for multi-fix plans)

After reviewing individual fixes, trace how they interact:

- [ ] **Draw the call graph**: Which fix calls into which other fix?
- [ ] **Trace error propagation**: If Fix A exits non-zero, does Fix B's wrapper swallow it?
- [ ] **Check policy consistency**: Are all fixes following the same fail-closed/fail-open policy?

Example failure:
```
Fix 2: stable_digest_hash() → sys.exit(2) on error
Fix 3: audit_parallel.sh calls prd_cache_update.py with `|| { warn; }`
       ↳ sys.exit(2) is swallowed by warning wrapper
       ↳ Inconsistent: "hard fail" in Python, "soft fail" in bash
```

Ask: "If I trace an error from the innermost function to the outermost caller, is the behavior consistent?"

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
6. **Happy-path bias**: Ask "how does this fail?" not "does this work?"
7. **Skipping boilerplate sections**: Rollback, preflight, cleanup hide subtle bugs
8. **Ignoring execution context**: Human terminal vs CI vs background
9. **Trusting plan's patterns**: Cross-reference against codebase source of truth
10. **Surface-level syntax review**: Trace state at each decision point
11. **Presence vs correctness**: Checking "does X appear?" instead of "does X match exact requirement?"
12. **Single-fix review**: Reviewing fixes independently without tracing cross-fix interactions
13. **Single-trigger assumption**: Assuming a conditional has only one trigger condition
14. **Trusting plan's self-review**: Plan checked its own boxes — verify they're accurate
15. **Part A confidence**: Green Part A checkmarks don't mean Part B can be skimmed
16. **Fixing without tracing downstream**: A fix that solves one problem may create another (e.g., tracking a file to fix gitignore issue → dirties worktree → breaks clean-tree gates)

## Quick Reference: Common Omissions by Plan Type

| Plan Type | Commonly Missing |
|-----------|------------------|
| Caching | Race conditions, eviction policy, invalidation rules |
| Parallel execution | Failure handling, partial completion, merge logic |
| Schema changes | Migration, backwards compat, validator updates |
| Workflow changes | Acceptance tests, verify.sh inclusion, §11 compliance |
| New scripts | Allowlist additions, executable permissions, error codes |

---

## Part B: Failure Mode Analysis

**Key principle**: Ask "how does this fail?" not "does this work?"

**CRITICAL: Part B is where bugs hide.** Part A checks compliance boxes; Part B catches logic errors. Do not treat Part B as optional.

### Conditional Trigger Enumeration (MANDATORY)

For every `if` statement or conditional in the plan, enumerate ALL trigger conditions — not just the intended one:

```bash
# Plan says: "handles bash <4.3"
if ! wait -n 2>/dev/null; then

# Actually triggers when:
# 1. wait -n unavailable (bash <4.3) ← intended
# 2. wait -n returns non-zero (job failed) ← UNINTENDED
# 3. wait -n interrupted by signal ← UNINTENDED
```

**Rule**: List at least 3 trigger conditions for every conditional, even if you think there's only 1. This forces you to consider unintended triggers.

### 7. String Matching Edge Cases

Prefix/pattern bugs are silent and catastrophic.

- [ ] **Prefix over-matching**: `startswith("S1-")` matches `S1-`, `S10-`, `S11-`, `S100-`
  - Fix: Use regex with anchor: `test("^S1-[0-9]+$")` or exact bounds
- [ ] **Regex anchoring**: Missing `^` matches mid-string, missing `$` matches partial
- [ ] **Case sensitivity**: `grep "APPROVE"` misses `Approve`, `approve`
  - Fix: `grep -i` or explicit case handling
- [ ] **Glob vs regex confusion**: `*.md` vs `.*\.md`

### 8. Execution Context

Plans run in different environments.

- [ ] **Interactive prompts**: `read -p` hangs forever in CI/background
  - Fix: Check `[[ -t 0 ]]` for TTY, provide default for non-interactive
  - Or: Add timeout: `read -t 30 -p "Choice: " CHOICE || CHOICE=default`
- [ ] **Partial previous runs**: Branch exists? File exists? State left behind?
  - Fix: Delete-or-ignore before create, or check-and-skip
- [ ] **Long-running concerns**:
  - [ ] Checkpoint/resume mechanism?
  - [ ] Progress tracking?
  - [ ] Disk space bounds?
  - [ ] Rate limit handling with backoff?

### 9. Command Failure Modes

For each command, ask "how does this fail?"

| Command Pattern | Failure Mode | Silent? | Fix |
|-----------------|--------------|---------|-----|
| `cat file \| jq` | Partial JSON during write | Yes | Validate file first |
| `ls -td dir/* \| head -1` | Empty if dir missing | Yes | Check dir exists |
| `git revert --no-edit` | Merge conflict opens editor | Hangs | Wrap with conflict check |
| `git checkout -b X` | Fails if X exists | No | Delete first or `git switch -c` |
| `jq ... > file.tmp && mv` | Interrupt leaves .tmp | Partial | Use trap for cleanup |
| `$(jq -r '.field')` | Returns literal "null" | Yes | Use `// empty` or `-e` |

### 10. Git Operations

- [ ] **git checkout vs git switch**: `git checkout` may violate guardrails; prefer `git switch`
- [ ] **Branch creation**: What if branch already exists from partial run?
- [ ] **git revert with dirty state**: Uncommitted changes cause conflicts
  - Fix: Stash before revert, abort on conflict
- [ ] **Destructive commands**: `reset --hard`, `push --force` documented as human-only?
- [ ] **git add to gitignored paths**: Check `.gitignore` for any paths plan tries to `git add`
- [ ] **Local vs remote branch staleness**: `git diff main` may be stale; prefer `origin/main` with fetch
- [ ] **Tracked files updated in loops**: If a tracked file is updated during iteration (checkpoint, state), it dirties the worktree. If downstream tools require clean trees (Ralph preflight), this blocks subsequent iterations. Keep such files untracked or commit after each update.

### 11. External Tool Dependencies

- [ ] **CLI availability**: All tools validated in preflight? (`codex --version`, etc.)
- [ ] **Model/flag validity**: Model names real? Flags exist in current version?
- [ ] **API failures**: Rate limits, timeouts, network errors → retry logic?
- [ ] **Output variations**: LLM outputs vary in case, spacing, format
  - Fix: `grep -qi "decision.*approve"` not `grep "DECISION: APPROVE"`

### 12. Platform Compatibility

- [ ] **macOS vs Linux**:
  - `seq` syntax differs → use `for ((i=1; i<=N; i++))`
  - `find -printf` unavailable on macOS
  - `date` flags differ
- [ ] **Path handling**: Spaces in paths require quoting
- [ ] **Temp files**: Use `mktemp` not hardcoded names

### 13. State-Dependent Branches (Revisited)

For each decision branch:
- [ ] What is the exact state when this branch executes?
- [ ] Trace: "Option B is offered after Codex review → story just completed → is `passes` true or false?"
- [ ] Does this branch violate any rule given that state?

---

## Part C: Cross-Reference Verification

### 14. Pattern Verification

Do not trust plan's patterns. Verify against codebase.

- [ ] **Workflow-file detection**: Plan's grep matches `plans/verify.sh:is_workflow_file`?
- [ ] **Allowlists**: Plan's list matches canonical allowlist in codebase?
- [ ] **Templates**: Plan's template meets what verifier enforces?
- [ ] **Gitignore vs git operations**: Any `git add` path in plan → check against `.gitignore`

### 15. Claims Verification

- [ ] **Counts match reality**: "11 stories" - actually count them
- [ ] **Schemas match code**: Read the validator, compare field names
- [ ] **CLI syntax correct**: Verify actual tool invocation, not assumed

---

## Quick Reference: Common Plan Bugs

| Pattern | Bug | Fix |
|---------|-----|-----|
| `startswith("S1-")` | Matches S10-, S11- | `test("^S1-[0-9]+$")` |
| `git checkout -b X` | Fails if X exists | Delete first or `git switch -c` |
| `read -p "..."` | Hangs in CI | Check `[[ -t 0 ]]` |
| `cat \| jq` | Race condition | Validate file first |
| `ls -t \| head -1` | Empty on missing dir | Check dir exists |
| `grep "EXACT"` | Case mismatch | `grep -i` |
| No checkpoint | Progress lost on interrupt | Write state file |
| Hardcoded model | Model may not exist | Validate in preflight |
| `jq -r '.field'` | Returns "null" string | Use `// empty` |
| Workflow grep | Narrower than `is_workflow_file` | Reference actual function |
| "Amend" option | May violate Ralph-only | Check `passes` state |
| `if ! cmd` | Triggers on cmd failure, not just unavailability | Check capability first |
| `verify.sh` | Missing `full` mode for workflow changes | Use `verify.sh full` |
| Cross-fix calls | Inner exit swallowed by outer wrapper | Trace error propagation |
| `git add .ralph/` | Path is gitignored | Check `.gitignore` first |
| `git diff main` | Local main may be stale | Use `origin/main` with fetch |
| Tracked checkpoint in loop | Dirties worktree, blocks clean-tree gates | Keep untracked or commit each update |

---

## Output Format (Updated)

```markdown
## Plan Review: <plan name>

### Pre-Review Docs Read
- [ ] WORKFLOW_CONTRACT.md §11 (if touches plans/)
- [ ] CLAUDE.md (Ralph-only, time estimates)
- [ ] <other relevant docs>

### Part A: Governance & Implementability
- [x] Acceptance coverage included
- [ ] BLOCKER: Option B violates Ralph-only (passes=false when offered)
- [ ] BLOCKER: verify.sh missing `full` mode (workflow change requires it)

### Part A.5: Cross-Fix Interactions
- [ ] HIGH: Fix 2 exits non-zero but Fix 3 swallows with warning wrapper

### Part B: Failure Modes
- [ ] CRITICAL: startswith("S1-") matches S10+
- [ ] CRITICAL: read -p hangs in CI
- [ ] HIGH: No checkpoint/resume for long process
- [ ] MEDIUM: `if ! wait -n` triggers on job failure, not just bash version

### Part C: Cross-Reference
- [ ] MEDIUM: Workflow grep narrower than is_workflow_file
- [ ] LOW: Plan's self-review checkbox unchecked despite being verified

### Recommendations
1. ...

### Verdict: APPROVE | NEEDS_CHANGES | BLOCK
```
