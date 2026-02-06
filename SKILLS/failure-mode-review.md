# SKILL: /failure-mode-review

Purpose
- Find how code will fail, not just whether it looks correct
- **Part A**: Adversarial analysis for caching, state, integrations, error paths (implementation-level)
- **Part B**: Architectural analysis for systemic risks, hidden assumptions, compounding failures, maintenance hazards (system-level)
- Complements `/pr-review` for risky code patterns and `/plan-review` for design-level risks

When to use
- New caching/persistence logic
- Cross-script/cross-module integrations
- State machines or lifecycle management
- Code that handles external inputs (files, env vars, JSON)
- Scripts that might run concurrently (CI, multiple terminals)
- Aggregation/merge operations (are all inputs present?)
- Any code where "it looks right" isn't enough
- **Part B additionally**: New subsystems, multi-phase rollouts, infrastructure that adds persistent state or multiple interacting mechanisms

When NOT to use
- Simple single-file changes with no external dependencies
- Documentation-only changes
- Use `/pr-review` for general correctness checks first

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

### 6. Concrete Value Walkthrough

Pick specific concrete values and trace execution:

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

---

## Part B: Architectural Failure Modes

**When to apply Part B**: Plans or PRs that introduce new subsystems, caching layers, multi-phase rollouts, or cross-cutting infrastructure. Part A catches implementation bugs; Part B catches structural problems that survive correct implementations.

### 12. Architectural Purity Check

Ask: "Does the new mechanism fit the existing architecture, or does it introduce a parallel model?"

- [ ] **Flat vs layered**: If the existing system has a flat model (e.g., all gates are independent named entities with `.rc` files), does the change introduce a grouping/hierarchy that violates that model?
- [ ] **Stateless vs stateful**: If the existing system is stateless (computed fresh each run), does the change add persistent state that can drift?
- [ ] **Single vs dual mechanisms**: Does the change create a second way to achieve the same outcome (e.g., a second skip system alongside an existing one)? If so, specify the interaction model:
  - Which runs first?
  - Which is authoritative on conflict?
  - How does the operator debug "why was X skipped?" across both systems?

Example failure:
```
Existing: change_detection says "skip rust gates" (stateless, per-run)
New:      checkpoint says "skip contract_coverage" (stateful, cached)

Operator asks: "Why didn't contract_coverage run?"
Answer requires checking TWO systems with different semantics.
No unified "skip reason" exists.
```

### 13. Complexity-to-Benefit Ratio

Before accepting a design, quantify what it costs vs what it delivers:

- [ ] **Enumerate the machinery**: Count new env vars, new files, new scripts, new acceptance tests, new rollout modes, new maintenance artifacts.
- [ ] **Enumerate the benefit**: What specific operations get faster/safer, by how much, and how often?
- [ ] **Check the ratio**: If the machinery exceeds the benefit, ask whether a simpler alternative achieves 80% of the value at 10% of the cost.
- [ ] **Check expandability claims**: If the plan justifies complexity by "this will expand to more cases later," verify that the plan's own safety constraints actually allow that expansion.

Example failure:
```
Plan: 12 implementation tickets, 8 new env vars, 30+ acceptance tests,
      4 rollout modes, 2 manifest files, 2 lint scripts
Benefit: skip 2 gates (~14 seconds) in manual quick-mode verify runs
Expansion: plan's own safety constraints prevent adding more gates
Result: highway built for two cars
```

### 14. Hidden Assumptions

Explicitly enumerate assumptions the plan takes for granted. For each, ask "what if this assumption is violated?"

Common hidden assumptions:

| Assumption | Violation | Impact |
|------------|-----------|--------|
| Gates are pure functions of fingerprinted inputs | Tool version changes, Python upgrades, transitive deps | False cache hit — gate would fail but is skipped |
| File name list captures all state changes | File CONTENT changes within existing diff set | Name-hash matches but content differs |
| The fast path is safe to weaken | Developers rely on fast path as primary feedback | Trust erosion: "verify is unreliable" → ignored failures |
| Evidence window proves ongoing correctness | Codebase evolves after evidence collection | Evidence is stale; no continuous validation exists |
| TTL prevents stale cache reuse | Continuous runs refresh TTL before expiry | Cache lives forever under active use |
| Atomic writes prevent all corruption | NFS, Docker overlay, disk-full between open and replace | Non-atomic write on non-POSIX filesystem |
| Cache file is not adversarial | Shared dev machine, CI runner reuse, file permissions | No HMAC/signature; anyone with write access can forge cache |
| `is_ci()` catches all CI environments | Custom CI, Docker without CI=true, developer with CI=false in profile | Skip fires in CI or is blocked on developer machine |

Checklist:
- [ ] For each cached/skipped decision: list ALL inputs that affect the outcome, not just the fingerprinted ones
- [ ] For each "never happens" scenario: what if it does?
- [ ] For each environment assumption: does it hold on NFS, Docker, CI, shared machines?

### 15. Systemic Risks and Emergent Behaviors

These are risks that emerge from component interactions, not from any single component.

#### 15a. Complexity Ratchet

Ask: "Does each safety mechanism justify adding the next one?"

```
Skip logic needs safety → add shared helper
Shared helper needs enforcement → add entrypoint guard
Entrypoint guard needs testing → add acceptance tests
Fingerprint needs completeness → add manifest lint
Manifest lint needs maintenance → add manifest files
Skip needs emergency disable → add kill switch
Kill switch needs rotation → add drill procedure
...
```

- [ ] Is the total debuggable by a single developer?
- [ ] How many decision points must be traced to answer "why was this gate skipped?"
- [ ] Could any layer be removed without meaningfully reducing safety?

#### 15b. Point-in-Time vs Continuous Correctness

- [ ] Does the plan prove correctness once (evidence window) or continuously (ongoing monitoring)?
- [ ] After rollout promotion, is there any mechanism to detect regression?
- [ ] What is the mean time to detect a false skip after it starts occurring?

#### 15c. Dual-Mechanism Interaction

When two independent mechanisms can both skip/route the same gate:

- [ ] Can they disagree? (Mechanism A says run, mechanism B says skip)
- [ ] If they disagree, which wins?
- [ ] Can the disagreement itself be detected and logged?
- [ ] Trace a concrete scenario where they disagree and identify the outcome.

### 16. Compounding Failure Scenarios

Trace multi-step failure chains where failure A enables failure B:

Template:
```
1. [Root cause]: <what goes wrong first>
2. [Propagation]: <how it enables the next failure>
3. [Amplification]: <why it gets worse over time>
4. [Detection gap]: <why nobody notices>
5. [Impact]: <what finally breaks>
```

Common compounding patterns:

| Chain | Example |
|-------|---------|
| Manifest drift + evidence staleness | New validator added → manifest not updated → shadow evidence is stale → enforce promoted → validator never runs |
| Kill switch neglect + TTL refresh loop | Token never rotated → TTL refreshed each run → cache never expires → gate never re-validated |
| Lint bypass + transitive dependency | Lint checks direct env reads → transitive import reads unlinted env var → fingerprint incomplete |
| Safety guard + bash dynamism | Guard uses static `rg` patterns → developer adds dynamic call path → guard passes but invariant is violated |

Checklist:
- [ ] For each safety mechanism: what if it fails silently?
- [ ] For each "manual maintenance" artifact (manifests, allowlists): what if it becomes stale?
- [ ] For each evidence gate: does the evidence remain valid as the codebase evolves?
- [ ] For each cache/TTL: can continuous use prevent the TTL from ever expiring?

### 17. Long-Term Maintenance Hazards

Ask: "What happens in 6 months when the original author is unavailable?"

#### 17a. Configuration Explosion

- [ ] How many env vars does the system have before and after the change?
- [ ] Is the interaction between env vars documented?
- [ ] Can a new developer understand the configuration without reading the source?
- [ ] Are any env var combinations dangerous or contradictory?

Rule of thumb: >50 env vars for a single script is a maintenance hazard. Each new var adds a dimension to the configuration space that can't be fully tested.

#### 17b. Manifest and Lint Staleness

For any manually-maintained artifact (manifests, allowlists, lint patterns):

- [ ] What is the forcing function to keep it updated? (CI failure? Lint? Nothing?)
- [ ] What happens if it becomes stale? (Silent false-positive? Noisy false-negative? Undetected drift?)
- [ ] Does the lint/guard itself need maintenance when coding patterns evolve?
- [ ] Can escape hatches (ignore annotations, allowlist entries) accumulate over time?

#### 17c. Debugging Archaeology

- [ ] How many steps does it take to debug "why did this gate not run?"
- [ ] Does each step require knowledge of a different subsystem?
- [ ] Is there a unified "skip reason" log entry, or must the operator check multiple systems?
- [ ] Compare: how many steps does the current (pre-change) debugging path require?

#### 17d. Zombie Features

- [ ] If the feature is never fully enabled (rollout stalls at shadow), does the scaffolding stay forever?
- [ ] Does the scaffolding add overhead to every run even when disabled?
- [ ] Is there a sunset clause or removal criteria?

#### 17e. "Expand Later" Debt

- [ ] If the plan justifies complexity by future expansion, are those expansion paths actually viable?
- [ ] Do the plan's own safety constraints prevent the expansion it claims to enable?
- [ ] What is the concrete list of future skip candidates, and how many are actually eligible?

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

### Part B: Architectural (if applicable)

### Hidden Assumptions
- [ ] <assumption>: violated when <scenario>

### Systemic Risks
- [ ] Complexity ratio: <N env vars, M scripts> for <benefit>
- [ ] Dual-mechanism interaction: <system A> vs <system B> on conflict

### Compounding Failures
- [ ] Chain: <A> → <B> → <C> with detection gap at <step>

### Maintenance Hazards
- [ ] Debug path: <N steps> to answer "why was X skipped?"
- [ ] Zombie risk: if rollout stalls, scaffolding remains with <overhead>

### Open Questions
- <question needing clarification>
```

## Common Failure Patterns to Check

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
| Dual skip mechanisms | Two systems disagree on skip/run | Specify ordering, authority, unified logging |
| Complexity ratchet | Each safety layer justifies the next | Count total machinery vs actual benefit |
| Point-in-time evidence | Evidence window proves nothing about future | Ask "is correctness proved once or continuously?" |
| TTL refresh loop | Continuous use prevents TTL expiry | Ask "can cache live forever under active use?" |
| Manifest staleness | Manual artifact drifts from reality | Ask "what forces this to stay updated?" |
| Impure function caching | Tool version / env changes invisible to fingerprint | List ALL inputs, not just fingerprinted ones |
| Zombie scaffolding | Feature never fully enabled but code stays | Ask "what if rollout stalls at shadow forever?" |
| Expand-later debt | Complexity justified by future expansion that can't happen | Verify expansion is viable under plan's own constraints |
| Config explosion | >50 env vars, untestable combinations | Count before/after; flag contradictory combos |
| Debug archaeology | N-step trace across M subsystems to find root cause | Compare pre-change vs post-change debug path length |

## Integration with Other Skills

- Run `/pr-review` first for general correctness
- Use `/failure-mode-review` for risky sections identified
- For safety-critical Rust code, also use `/contract-review`
