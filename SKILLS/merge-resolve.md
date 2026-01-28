# SKILL: /merge-resolve (Merge Conflict Resolution)

Purpose
- Safely resolve merge conflicts while preserving contract alignment and fail-closed behavior.
- Prevent accidental introduction of safety bugs during conflict resolution.

When to use
- PR has merge conflicts
- Rebasing a branch onto main
- Cherry-picking across branches
- After `git merge` or `git rebase` reports conflicts

## Workflow

### 1) Identify conflicts
```bash
git status --porcelain | grep "^UU\|^AA\|^DD"
git diff --name-only --diff-filter=U
```

### 2) Classify each conflict by risk level

| File Pattern | Risk | Extra Care |
|--------------|------|------------|
| `crates/soldier_core/` | HIGH | Verify fail-closed preserved |
| `crates/soldier_infra/` | HIGH | Check error handling |
| `specs/CONTRACT.md` | HIGH | Check section numbering, AT refs |
| `specs/state_machines/` | HIGH | State transition integrity |
| `plans/*.sh` | MEDIUM | Run verify.sh after |
| `python/schemas/` | MEDIUM | Validate fixtures |
| `prd.json` | MEDIUM | Check task IDs, refs |
| Docs, comments, README | LOW | Standard resolution |

### 3) For each conflict

**a) Understand both sides:**
- Read the PR description / commit message for "ours"
- Read the incoming commit message for "theirs"
- Identify CONTRACT.md sections involved
- Check git log for context:
  ```bash
  git log --oneline -5 HEAD
  git log --oneline -5 MERGE_HEAD
  ```

**b) Resolve with safety bias:**
- If uncertain which behavior is correct -> keep MORE RESTRICTIVE
- If both add code -> check for duplicate functionality
- If both modify same function -> re-read contract requirements
- Default to `ReduceOnly` over `Active` when merging TradingMode logic

**c) Verify patterns preserved after resolution:**
```rust
// Check these patterns are intact:
// - No new unwrap() introduced
// - Fail-closed defaults maintained
// - Error handling not swallowed
// - Latch behavior preserved
```

### 4) Post-resolution verification

```bash
# Must pass before marking resolved
cargo check                    # Compiles
cargo test                     # Tests pass
./plans/verify.sh --quick      # Gates pass (if available)
```

### 5) For CONTRACT.md conflicts specifically

```bash
# After resolution, verify integrity
python3 scripts/check_contract_crossrefs.py --contract specs/CONTRACT.md --strict
python3 scripts/check_arch_flows.py --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml
```

Check:
- Section numbers still sequential
- AT-### references valid
- Cross-references resolve
- No orphaned sections

### 6) For prd.json conflicts

```bash
# Validate JSON structure
python3 -m json.tool plans/prd.json > /dev/null

# Check for duplicate task IDs
jq '.tasks[].id' plans/prd.json | sort | uniq -d
```

## Anti-patterns to Avoid

| Anti-pattern | Why it's dangerous |
|--------------|-------------------|
| Blindly accept "ours" or "theirs" | May lose critical safety logic |
| Resolve safety code without reading both | Could introduce fail-open bugs |
| Skip verification "it's just a merge" | Merges can break invariants |
| Lose AT references during resolution | Breaks contract traceability |
| Add unwrap() to "simplify" resolution | Introduces panic paths |
| Swallow errors to make code compile | Hides contract violations |

## Conflict Resolution Patterns

### Pattern: Both sides add to a list/enum
```rust
// OURS adds:
RejectReasonCode::PolicyStale,
// THEIRS adds:
RejectReasonCode::WatchdogTimeout,

// RESOLUTION: Include both, check for semantic overlap
RejectReasonCode::PolicyStale,
RejectReasonCode::WatchdogTimeout,
```

### Pattern: Both sides modify same match arm
```rust
// Read both implementations
// Keep the MORE RESTRICTIVE behavior
// If unclear, check CONTRACT.md for the requirement
```

### Pattern: Structural changes conflict
```rust
// One side refactors, other adds feature
// Usually: apply refactor first, then re-add feature on new structure
// May need to rebase instead of merge
```

## Output

After resolution, report:
- List of files resolved with risk classification
- Verification commands run + results
- Any CONTRACT.md sections that need human review
- Warnings if fail-closed patterns may have changed

## Quick Reference Commands

```bash
# See what's conflicting
git diff --check

# See conflict markers
grep -rn "<<<<<<" .

# Abort if needed
git merge --abort
git rebase --abort

# After resolving all conflicts
git add <resolved-files>
git rebase --continue   # or git merge --continue
```
