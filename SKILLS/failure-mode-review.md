# SKILL: /failure-mode-review

Purpose
- Find how code will fail, not just whether it looks correct
- Adversarial analysis for caching, state, integrations, error paths (implementation-level)
- Complements `/pr-review` for risky code patterns and `/plan-review` for design-level risks
- For architectural/systemic/operational analysis, use `/strategic-failure-review` after this skill

When to use
- New caching/persistence logic
- Cross-script/cross-module integrations
- State machines or lifecycle management
- Code that handles external inputs (files, env vars, JSON)
- Scripts that might run concurrently (CI, multiple terminals)
- Aggregation/merge operations (are all inputs present?)
- Any code where "it looks right" isn't enough

When NOT to use
- Simple single-file changes with no external dependencies
- Documentation-only changes
- Use `/pr-review` for general correctness checks first

---

## Before You Start (MANDATORY)

### Read the source code, not just the plan/PR description

**Do not reason abstractly.** For each file the plan/PR touches:
1. **Read the actual source file** — at least the functions/sections being modified
2. **Read the callers** — who calls this code? What do they expect?
3. **Read the consumers** — who reads the files/state this code writes?

Minimum: read the top 3 most-modified files before starting any checklist item.

### Triage: which sections apply?

Scan the change and check which sections to apply:

| If the change involves... | Apply sections... |
|--------------------------|-------------------|
| Env vars, JSON fields, cross-file calls | §1 Interface Crossings |
| Caching, state files, checkpoints | §2 State Transitions, §6 Concrete Walkthrough |
| External inputs (files, env, CLI args) | §3 "What If" Analysis |
| Error handling, fallbacks, `|| true` | §4 Error Path Tracing, §9 Downstream Propagation |
| Counters, aggregations, summaries | §5 Summary/Count Verification |
| Shared state, parallel execution | §7 Concurrent Execution |
| Merging multiple sources | §8 Completeness Validation |
| File paths in config/cache | §10 Trusted Files |
| Long-running scripts, growth over time | §11 Operational Concerns |

**Always apply**: §6 Concrete Value Walkthrough — this catches the most bugs. Pick at least one happy path and one failure path and trace them with specific values.

### Verify claims against code

For any quantitative claim in the plan/PR ("saves 14 seconds", "21 jq-based checks", "covers all validators"):
- [ ] Count the actual items in the source code
- [ ] Verify the number matches the claim
- [ ] If an acceptance test/command exists: can it pass WITHOUT the change? If yes, the test is vacuous.

---

## Review Process

### 1. Interface Crossing Verification

For every call that crosses file/module boundaries:

```bash
# Pattern: script A sets env var, script B reads it
# In script A:
AUDIT_SLICE="$slice" ./other_script.sh

# MUST verify: open other_script.sh, grep for the variable name
grep -n 'AUDIT_SLICE\|PRD_SLICE' other_script.sh
```

Checklist:
- [ ] For each env var passed: read consumer, verify expected name matches
- [ ] For each function call across files: verify parameter names and types
- [ ] For each file path: verify producer and consumer agree on location/format
- [ ] For each JSON field: verify writer and reader use same key name and type

### 2. State Transition Enumeration

For any caching, persistence, or stateful logic, explicitly enumerate:

| Question | Answer |
|----------|--------|
| What creates the artifact? | |
| What reads/uses it? | |
| What invalidates/deletes it? | |
| What if source changes but artifact remains? | |
| What if source disappears but artifact remains? | |
| What if artifact is corrupted/partial/empty? | |
| What if artifact has wrong schema version? | |

Write these out before concluding the cache logic is correct.

### 3. "What If" Analysis

For each external input (file read, env var, JSON field, CLI arg):

| Input | Missing? | Malformed? | Wrong type? | Stale? | Empty? |
|-------|----------|------------|-------------|--------|--------|
| `$ENV_VAR` | | | | | |
| `config.json` | | | | | |
| `field.value` | | | | | |

Ask each question explicitly. Don't assume inputs are valid.

**Exhaustive Type Coverage**: For type-checking code, enumerate ALL types the source can produce:

```python
# JSON can produce: int, float, str, bool, None, list, dict
def to_int(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value)
    return None  # What about float? bool? None?

# BAD: 1.0 (float) → None → UNKNOWN → cache disabled
# FIX: Handle all JSON numeric types
def to_int(value):
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        return int(value)
    return None
```

Checklist for type handling:
- [ ] JSON fields: handled `int`, `float`, `str`, `bool`, `None`, `list`, `dict`?
- [ ] Python numbers: handled both `int` and `float`?
- [ ] Empty values: handled `""`, `[]`, `{}`, `None`, `0`?

### 4. Error Path Tracing

For each error handling pattern:

```bash
# Pattern: silent failure
command || true
# ASK: Is silent failure safe here? What state is left behind?

# Pattern: fallback default
value="${VAR:-default}"
# ASK: Is this fail-closed (safe default) or fail-open (dangerous default)?

# Pattern: error return
if error:
    return "UNKNOWN"
# ASK: What does the caller do with "UNKNOWN"? Trace it.
```

Checklist:
- [ ] For each error return: trace what caller does with it
- [ ] For each fallback/default: is it fail-closed or fail-open?
- [ ] For each `|| true`, `except: pass`, `.ok()`: is silent failure safe?
- [ ] For each early return: what cleanup is skipped?

**Persistent Error States**: When error handling returns a sentinel value, ask "what if the error persists across runs?"

```python
def stable_digest_hash(path: Path) -> str:
    if not path.exists():
        return "ABSENT"
    try:
        data = json.loads(path.read_text())
        return sha256(data)
    except (json.JSONDecodeError, OSError):
        return "ERROR"  # Sentinel on parse failure

# Problem: if digest file stays corrupt across runs:
# Run 1: corrupt → "ERROR" → cache key includes "ERROR"
# Run 2: still corrupt → "ERROR" → same cache key → FALSE CACHE HIT!
#
# The sentinel is STABLE, so cache thinks inputs haven't changed
```

Checklist for sentinel values:
- [ ] If error returns sentinel (e.g., "ERROR", "UNKNOWN", -1): what if condition persists?
- [ ] Does stable sentinel cause false cache hits?
- [ ] Should persistent errors FAIL LOUDLY instead of returning sentinel?

### 5. Summary/Count Verification

For any counters, lists, or aggregations:

- [ ] Trace all increments AND decrements
- [ ] Trace all additions AND removals
- [ ] Run the math with concrete example values
- [ ] Check: can the count go negative? Exceed expected max?

Example trace:
```
valid_slices starts at [0, 1, 2]
- slice 1 fails validation → added to invalid_slices
- BUT: slice 1 NOT removed from valid_slices
- Summary: total_passed = len(valid_slices) + fresh_passed
- Bug: slice 1 counted twice
```

### 6. Concrete Value Walkthrough (HIGHEST SIGNAL — always do this)

Pick specific concrete values and trace execution step by step. This catches more bugs than any other technique.

```
Scenario: slice 2, items A and B, roadmap exists then deleted

1. First run: roadmap exists
   - roadmap_digest.json created with hash X
   - cache entry: {slice_2: {global_sha: includes X}}

2. User deletes ROADMAP.md

3. Second run: roadmap missing
   - roadmap_digest.json still exists (never deleted)
   - global_sha still includes hash X
   - Cache hit! But audit referenced roadmap that no longer exists
   - BUG: stale cache reuse
```

### 7. Concurrent Execution Analysis

Ask: "What if two instances of this script run simultaneously?"

For any shared state (files, cache, database):
- [ ] Is there file locking or atomic operations?
- [ ] Can read-modify-write cause corruption?
- [ ] What if process A reads, process B writes, process A writes?

Example:
```
Process A: read cache → {slice_1: PASS}
Process B: read cache → {slice_1: PASS}
Process A: write cache → {slice_1: PASS, slice_2: PASS}
Process B: write cache → {slice_1: PASS, slice_3: PASS}  # OVERWRITES slice_2!
```

Fix patterns:
- File locking (`flock`)
- Atomic rename (write to temp, rename)
- Process-specific files with merge step

### 8. Completeness Validation

Ask: "Are all expected inputs present, or could some be silently missing?"

For any aggregation or merge operation:
- [ ] What validates that ALL expected items are present?
- [ ] What if one file in a set is missing?
- [ ] Does the code detect gaps or silently omit?

Example:
```python
# BAD: Silently processes whatever exists
for f in glob("audit_slice_*.json"):
    merge(f)

# GOOD: Validates completeness
expected = {0, 1, 2, 3}
found = {extract_slice_num(f) for f in glob("audit_slice_*.json")}
if found != expected:
    raise ValueError(f"Missing slices: {expected - found}")
```

### 9. Downstream Error Propagation

For each `|| true` or error suppression, trace the FULL downstream path:

```bash
# Line 154: slice_prepare fails silently
./plans/prd_slice_prepare.sh || true

# Immediate effect: meta file not created
# Downstream effect (line 267): merge needs meta file for SHA validation
# Final impact: merge fails with cryptic "SHA mismatch" error
```

Checklist:
- [ ] For each suppressed error: what files/state are NOT created?
- [ ] What later code assumes those files exist?
- [ ] Will the error manifest immediately or much later?

### 10. Trusted Files as Adversarial Input

Files written by your code can still be corrupted, edited, or malicious:

- [ ] Cache files: what if paths inside are outside repo?
- [ ] Config files: what if values are malicious?
- [ ] State files: what if schema is from old version?

Example:
```python
# Cache stores a path
cached_path = cache["audit_json"]  # Could be "/etc/passwd"

# Later used in copy
cp "$cached_path" "$output_dir/"  # PATH TRAVERSAL!

# Fix: validate path is within expected directory
if not cached_path.startswith(expected_dir):
    raise ValueError("Invalid cached path")
```

### 11. Operational Concerns

Issues that don't break correctness but cause problems over time:

**Unbounded growth:**
- [ ] Does cache/log/state grow forever?
- [ ] Is there eviction or rotation?
- [ ] What's the growth rate? (O(n) per run? per day?)

**Cross-platform compatibility:**
- [ ] bash version (macOS ships 3.2, `wait -n` needs 4.3+)
- [ ] GNU vs BSD commands (`sed -i`, `grep -P`)
- [ ] Python version assumptions

**Performance degradation:**
- [ ] Does file size grow unbounded?
- [ ] Are there O(n²) patterns that will slow down?

### 12. Bash/Shell-Specific Traps

For shell scripts, check these common silent failures:

- [ ] **Exit code masking**: `result=$(failing_command)` — `$?` reflects the assignment, not the command. Use `set -o pipefail` or check explicitly.
- [ ] **Unquoted variables**: `[ $var = "value" ]` breaks when `$var` is empty or contains spaces. Use `[[ "$var" == "value" ]]`.
- [ ] **Subshell variable scope**: Variables set inside `( ... )`, `|` pipes, or `while read` loops don't propagate to the parent. Use `< <(command)` or temp files.
- [ ] **Regex/glob over-matching**: `startswith("S1-")` matches `S10-`, `S11-`, `S100-`. Use anchored regex: `^S1-[0-9]+$`.
- [ ] **`jq -r` returns literal "null"**: `jq -r '.missing_field'` outputs the string `"null"`, not empty. Use `// empty` or check with `-e`.
- [ ] **Heredoc quoting**: `<<EOF` expands variables, `<<'EOF'` does not. Mixing them up injects unexpected values.

---

## Reviewer Anti-Patterns (Mistakes to Avoid)

1. **Abstract reasoning without reading code**: "This should work because..." — STOP. Open the file, read the function, trace the value. The #1 source of missed bugs is reviewing from description alone.
2. **Happy-path bias**: Checking "does this work?" instead of "how does this fail?" Force yourself to trace at least one failure path per section.
3. **Trusting acceptance tests**: Check if the test can pass WITHOUT the change (vacuous test). If `rg -n "pattern" file` is the acceptance command and the pattern already exists, the test proves nothing.
4. **Reviewing sections in isolation**: A bug in §1 (interface crossing) may compound with a gap in §7 (concurrency). After individual sections, ask "do any findings interact?"
5. **Stopping at the first bug**: Finding one issue creates satisfaction bias. The second and third bugs are often worse. Complete all applicable sections.
6. **Checking presence, not behavior**: "Does the code mention X?" is not "Does X actually work?" Trace the execution path, not just grep for keywords.

---

## Output Format

```markdown
## Failure Mode Review: <component/PR>

### Findings

#### High
- **<title>** — `file:line`
  - Failure scenario: <how it fails>
  - Impact: <what goes wrong>
  - Fix: <recommendation>

#### Medium
- **<title>** — `file:line`
  - ...

#### Low
- **<title>** — `file:line`
  - ...

### Interface Crossings Verified
- [ ] `script_a.sh` → `script_b.sh`: ENV_VAR verified
- [ ] `module.py` → `other.py`: function signature verified

### State Transitions Enumerated
- [ ] Cache lifecycle: create/invalidate/stale scenarios checked

### Concurrency Checked
- [ ] Concurrent execution: safe or needs locking?

### Completeness Validated
- [ ] All expected inputs verified present before aggregation

### Downstream Errors Traced
- [ ] Each `|| true` traced to final impact

### Open Questions
- <question needing clarification>

### Next Step
> If findings include architectural, systemic, or operational concerns,
> follow up with `/strategic-failure-review`.
```

---

## Common Failure Patterns (Implementation)

| Pattern | Failure Mode | Check |
|---------|--------------|-------|
| Env var passing | Name mismatch between setter/getter | Grep both files |
| File caching | Stale artifact after source deletion | Trace cleanup path |
| JSON parsing | Type coercion (`"0"` vs `0`) | Check comparison operators |
| Error returns | Caller ignores/mishandles error value | Trace return usage |
| List/set tracking | Add without remove on failure | Trace both paths |
| Summary counts | Double-counting or missed items | Walk through with values |
| Default values | Fail-open instead of fail-closed | Check if default is safe |
| `|| true` / `except: pass` | Silent failure hides bugs | Ask if silence is safe |
| Concurrent execution | Read-modify-write corruption | Check for file locking |
| Aggregation/merge | Missing items silently omitted | Validate expected vs found |
| Suppressed errors | Downstream failure with cryptic message | Trace full error path |
| Trusted files | Path traversal, schema mismatch | Validate paths and schema |
| Unbounded growth | Performance degradation over time | Check for eviction/rotation |
| Cross-platform | bash 3.2, GNU vs BSD, Python version | Test on target platforms |
| Incomplete type handling | Float `1.0` treated as invalid | Check all JSON types: int, float, str, bool, None |
| Persistent error sentinel | Stable "ERROR" key → false cache hits | Ask "what if error persists across runs?" |
| Exit code masking | `$()` hides command failure | Check `$?` source; use `set -o pipefail` |
| Subshell variable scope | Var set in pipe/subshell lost | Use `< <(cmd)` not `cmd | while` |
| Regex over-matching | `startswith("S1-")` matches `S10-` | Use anchored regex with `$` |
| `jq -r` null string | `.missing` returns literal `"null"` | Use `// empty` or `-e` flag |
| Vacuous acceptance test | Test passes without the change | Run test BEFORE implementing; if it passes, test is broken |

## Integration with Other Skills

- Run `/pr-review` first for general correctness
- Use `/failure-mode-review` (this skill) for implementation-level failure analysis
- Use `/strategic-failure-review` for architectural, systemic, and operational analysis
- For safety-critical Rust code, also use `/contract-review`
