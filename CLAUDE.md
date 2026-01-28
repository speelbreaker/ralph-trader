# Claude Code Instructions

> This file is read automatically by Claude Code. It defines code quality standards and codebase patterns.

## Model Selection

| Task Type | Model | Why |
|-----------|-------|-----|
| Quick fixes, typos, simple edits | `sonnet` (default) | Fast, sufficient |
| Contract changes (specs/CONTRACT.md) | `opus` | Safety-critical, needs deep reasoning |
| Architecture decisions | `opus` | Complex tradeoffs |
| State machine changes | `opus` | Correctness-critical |
| Debugging complex issues | `opus` | Needs careful analysis |
| PRD implementation (ralph loop) | `sonnet` | Balanced speed/quality |

**Switch models:**
```bash
claude --model opus   # For critical work
claude --model sonnet # Default
```

## Code Quality Standards

### Rust Code

**Error Handling (Non-Negotiable)**
```rust
// NEVER use unwrap() in production code
let value = map.get(&key).unwrap();           // BAD
let value = map.get(&key)?;                    // GOOD
let value = map.get(&key).ok_or(MyError)?;    // GOOD

// NEVER use expect() without a reason that helps debugging
let x = foo.expect("failed");                  // BAD
let x = foo.expect("config missing: DB_URL"); // GOOD (but still prefer ?)

// NEVER silently ignore errors
let _ = dangerous_operation();                 // BAD
dangerous_operation().ok();                    // BAD
if let Err(e) = dangerous_operation() {        // GOOD
    tracing::warn!(?e, "operation failed");
}
```

**Fail-Closed Pattern (Required for Safety-Critical Code)**
```rust
// Default to the SAFE state when uncertain
fn resolve_trading_mode(&self) -> TradingMode {
    // If ANY check fails or is uncertain, restrict trading
    if self.policy_stale() || self.watchdog_stale() || self.f1_cert_invalid() {
        return TradingMode::ReduceOnly;
    }
    // Only return Active when ALL checks pass
    TradingMode::Active
}
```

**Type Safety**
- Use newtypes for domain concepts: `struct InstrumentId(String);`
- Prefer enums over strings for fixed sets: `enum Side { Buy, Sell }`
- Use `NonZeroU64` when zero is invalid
- Mark fields `#[serde(deny_unknown_fields)]` on config structs

**Logging**
```rust
// Use structured logging with tracing
tracing::info!(instrument_id = %id, side = ?side, "submitting order");

// Include context that helps debugging
tracing::error!(
    error = ?e,
    intent_id = %intent.id,
    trading_mode = ?mode,
    "dispatch rejected"
);
```

### Python Code

**Type Hints (Required)**
```python
# Always annotate function signatures
def validate_status(data: dict[str, Any], schema_path: Path) -> list[str]:
    ...

# Use Optional explicitly, not implicit None
def get_value(key: str) -> Optional[str]:  # GOOD
def get_value(key: str) -> str:            # BAD if can return None
```

**Error Handling**
```python
# Never bare except
try:
    result = risky_operation()
except:  # BAD
    pass

# Catch specific exceptions
try:
    result = risky_operation()
except ValueError as e:  # GOOD
    logger.warning(f"Invalid value: {e}")
    return None
```

### Testing

**Every New Function Needs Tests**
- Unit test the happy path
- Unit test at least one error path
- For safety-critical code: test the fail-closed behavior

**Table-Driven Tests (Preferred)**
```rust
#[test]
fn test_trading_mode_resolution() {
    let cases = vec![
        // (policy_stale, watchdog_stale, expected_mode)
        (false, false, TradingMode::Active),
        (true, false, TradingMode::ReduceOnly),
        (false, true, TradingMode::ReduceOnly),
        (true, true, TradingMode::ReduceOnly),
    ];
    for (policy_stale, watchdog_stale, expected) in cases {
        // ...
    }
}
```

**Acceptance Tests Must Prove Causality**
From CONTRACT.md: Tests must prove the guard is the *sole* reason for the outcome via:
- Dispatch count (0 vs 1)
- Specific reject reason code
- Specific latch reason code

## This Codebase

### Architecture
- **Rust** (`crates/soldier_core/`, `crates/soldier_infra/`): Execution and risk
- **Python** (`python/`): Policy, schemas, validation tools
- **Specs** (`specs/`): Contract, state machines, flows
- **Plans** (`plans/`): Ralph harness, PRD, verification

### Key Concepts
- **TradingMode**: `Active | ReduceOnly | Kill` - resolved by PolicyGuard each tick
- **RiskState**: `Healthy | Degraded | Maintenance | Kill` - health layer
- **Fail-closed**: If uncertain, choose the safe/restrictive option
- **Contract alignment**: Code must implement what CONTRACT.md specifies

### Files You Must Read Before Editing
| If editing... | Read first... |
|---------------|---------------|
| PolicyGuard / TradingMode logic | `specs/CONTRACT.md` §2.2 |
| State machines | `specs/state_machines/` |
| /status endpoint | `specs/status/README.md`, schemas in `python/schemas/` |
| Verification gates | `plans/verify.sh`, `specs/WORKFLOW_CONTRACT.md` |

### Patterns to Follow
```rust
// Intent classification: if uncertain, treat as OPEN (most restrictive)
fn classify_intent(intent: &Intent) -> IntentClass {
    if intent.reduce_only == Some(true) {
        IntentClass::Close  // Risk-reducing
    } else {
        IntentClass::Open   // Fail-closed: unknown = OPEN
    }
}

// Latch pattern: set on bad event, clear only on explicit reconciliation
fn handle_ws_gap(&mut self) {
    self.open_permission_latch = true;
    self.latch_reason = LatchReason::WsBookGap;
    // Latch stays set until reconcile() is called
}
```

### Anti-Patterns to Avoid
```rust
// DON'T: Optimistic defaults
let mode = config.trading_mode.unwrap_or(TradingMode::Active);  // BAD

// DO: Pessimistic defaults
let mode = config.trading_mode.unwrap_or(TradingMode::ReduceOnly);  // GOOD
```

```python
# DON'T: Swallow errors
try:
    validate(data)
except Exception:
    pass  # BAD - hides contract violations

# DO: Fail loudly
try:
    validate(data)
except ValidationError as e:
    raise ContractViolation(f"Status validation failed: {e}") from e
```

## Recommended Workflows

### Interview-Driven Specs (for new features)
Before implementing complex features, build detailed specs through Q&A:

```
Read this feature idea and interview me in detail using AskUserQuestionTool:
- Technical implementation details
- Edge cases and error handling
- Contract alignment (which sections apply?)
- Tradeoffs and alternatives

Continue until complete, then write to specs/features/FEATURE_NAME.md
```

This creates **auditable, versioned context** instead of relying on model memory.

See: `SKILLS/interview.md`

## MCP Tools

### Context7 (Documentation Lookup)
Add "use context7" to fetch up-to-date library documentation:
```
use context7 to look up tokio::sync::mpsc channel API
use context7 for serde_json error handling patterns
```

Use before implementing with any external crate to avoid hallucinated APIs.

### Ralph Contract Tools (Auto-Use)
The `ralph` MCP server provides contract validation tools. **Use automatically** during PRD work:

| When | Use This Tool |
|------|---------------|
| Before editing CONTRACT.md | `contract_lookup("section")` to read current state |
| After editing CONTRACT.md | `check_contract_crossrefs()` to validate |
| Checking acceptance tests | `list_acceptance_tests()` |
| Verifying flows | `check_arch_flows()` |
| Before committing | `run_all_checks()` |
| Starting a PRD task | `get_prd_tasks("pending")` then `get_prd_task("T-xxx")` |

### GitHub Tools (Auto-Use for PR Work)
The `github` MCP server provides authenticated GitHub access. **Use automatically** for:

- Fetching PR details and comments
- Reading issue context
- Checking CI/workflow status
- Creating/updating PRs and issues

Prefer MCP tools over `gh` CLI when available for richer context.

## Commit Messages

Format: `<area>: <what changed>`

```
PolicyGuard: add F1 cert staleness check
status: validate fixtures against exact schema
verify: add --strict flag to status validation
```

Keep the first line under 72 characters. Reference CONTRACT.md sections when implementing contract requirements.
