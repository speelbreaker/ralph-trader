# SKILL: /acceptance-test (Generate AT from Contract)

Purpose
- Generate acceptance test skeletons from CONTRACT.md requirements.
- Ensure tests prove causality (dispatch count, reject reason, latch reason).
- Maintain TRIP/NON-TRIP test pairs for guards.

When to use
- After adding a new guard, rule, or gate to CONTRACT.md
- When CONTRACT.md specifies an AT-### that doesn't exist yet
- To verify existing AT coverage for a section

## Workflow

### 1) Identify the Contract Section
```bash
# Look up the section
contract_lookup("2.2.3")  # via MCP

# Or manually
grep -n "§2.2.3\|### 2.2.3" specs/CONTRACT.md
```

### 2) Extract MUST/MUST NOT Requirements
From the section, identify:
- MUST requirements -> positive test cases
- MUST NOT requirements -> negative test cases
- Fail-closed behavior -> edge case tests

### 3) Generate Test Skeleton

For each guard/rule, create a TRIP and NON-TRIP pair:

```rust
/// AT-XXX: [Guard Name] TRIP test
/// Contract: §X.Y.Z - [requirement text]
///
/// Preconditions:
/// - All other gates forced pass (Liquidity, NetEdge, quantization)
/// - Fresh feeds, RiskState normal, no unrelated latches
///
/// Expected: Guard activates, OPEN blocked
#[test]
fn test_guard_name_trip() {
    // Setup: condition that should trigger the guard
    let mut ctx = TestContext::new();
    ctx.set_guard_trigger_condition(true);
    ctx.force_other_gates_pass();

    // Act: attempt OPEN
    let result = ctx.dispatch_open_intent();

    // Assert: blocked with specific reason
    assert_eq!(result.dispatch_count, 0);
    assert_eq!(result.reject_reason, RejectReasonCode::GuardName);
}

/// AT-XXX: [Guard Name] NON-TRIP test
/// Contract: §X.Y.Z - [requirement text]
///
/// Preconditions: Same as TRIP, but guard condition is false
///
/// Expected: Guard does not activate, OPEN proceeds to dispatch
#[test]
fn test_guard_name_non_trip() {
    // Setup: condition that should NOT trigger the guard
    let mut ctx = TestContext::new();
    ctx.set_guard_trigger_condition(false);
    ctx.force_other_gates_pass();

    // Act: attempt OPEN
    let result = ctx.dispatch_open_intent();

    // Assert: dispatched
    assert_eq!(result.dispatch_count, 1);
}
```

### 4) Causality Proof Requirements

Each test MUST prove causality via at least ONE of:
- `dispatch_count` (0 vs 1)
- `reject_reason` (specific RejectReasonCode)
- `latch_reason` (specific LatchReasonCode)
- `cortex_override` value

```rust
// GOOD: Proves causality
assert_eq!(result.reject_reason, RejectReasonCode::PolicyStale);

// BAD: Doesn't prove the guard was the reason
assert!(result.is_err());
```

### 5) Register the AT in CONTRACT.md

Add to the relevant section:
```markdown
**Acceptance Tests:**
- AT-XXX: [Guard] TRIP - guard activates when [condition], blocks OPEN with `RejectReasonCode::X`
- AT-XXY: [Guard] NON-TRIP - guard inactive when [condition], OPEN dispatches
```

### 6) Verify AT Numbering
```bash
# Find next available AT number
rg "AT-\d+" specs/CONTRACT.md | grep -oE "AT-[0-9]+" | sort -t- -k2 -n | tail -5
```

## Checklist
- [ ] TRIP test exists
- [ ] NON-TRIP test exists
- [ ] Both declare "all other gates forced pass"
- [ ] Both prove causality (dispatch count OR reason code)
- [ ] AT-### registered in CONTRACT.md
- [ ] Test file follows naming: `test_<guard>_trip.rs` or in `#[cfg(test)]` module

## Output
- Test skeleton with correct structure
- AT registration text for CONTRACT.md
- Verification that AT number is unique
