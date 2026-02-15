# Atomic Group State Machine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the atomic group state machine with the first-fail invariant, MixedFailed open blocking, and the `atomic_group_state_total{state}` counter, plus tests for S7-000.

**Architecture:** Add two execution modules, `group.rs` and `atomic_group_executor.rs`. `group.rs` owns the `GroupState` enum, first-failure latch, and state transition validation with metrics. `atomic_group_executor.rs` evaluates leg snapshots against contract rules and drives transitions while preserving the first-fail invariant and MixedFailed blocking.

**Tech Stack:** Rust (soldier_core), AtomicU64 counters, cargo test.

---

## Architecture

This change introduces a self-contained atomic group state machine aligned with CONTRACT §1.2.1 and `specs/state_machines/group_state.yaml`. The state machine lives in `crates/soldier_core/src/execution/group.rs` and encodes the canonical states (`New`, `Dispatched`, `Complete`, `MixedFailed`, `Flattening`, `Flattened`) plus a first-failure latch. `atomic_group_executor.rs` is a small orchestrator that receives leg snapshots and applies the state machine, ensuring the “first observed failure seeds MixedFailed” rule is enforced regardless of out-of-order updates. The design intentionally avoids cross-module dependencies to keep scope tight and ensure compilation within the story’s allowed files.

We treat the state machine as a fail-closed component: transitions are validated against the spec, and any illegal transition returns an error and leaves the state unchanged. The executor never sets `Complete` unless every leg is terminal and the group passes the “safe complete” checks (no partial fills, no fill mismatch beyond epsilon, and no containment pending). Observability is handled in `group.rs` via `atomic_group_state_total{state}` counters that increment on each state entry. Metric emission uses the existing execution metric sink when compiled in the main crate and falls back to a local stub in tests.

## Components & Data Flow

The core data structure is `AtomicGroup`, containing `group_id`, `state`, and `first_failure`. Each evaluation uses a `LegOutcome` list with `requested_qty`, `filled_qty`, and `LegState` (including `Pending` for non-terminal legs). The evaluator walks the legs to detect failure signals in deterministic order: explicit reject/cancel/unfilled, then partial fills, then fill mismatch beyond `epsilon`. The first observed failure is latched in `first_failure` and the group transitions to `MixedFailed` exactly once. Subsequent evaluations cannot overwrite that failure or advance to `Complete`.

Data flow is straightforward: `on_intent_persisted()` transitions `New -> Dispatched`; `evaluate()` inspects leg snapshots and either keeps `Dispatched`, moves to `Complete` (only if all terminal and safe), or moves to `MixedFailed` (on first failure). `start_containment()` transitions `MixedFailed -> Flattening`; `mark_flattened()` transitions `Flattening -> Flattened`. This is sufficient for S7-000 tests and aligns with the spec’s GS-001..GS-005 transitions. The executor returns a small evaluation outcome containing the current state and open-block status for the caller.

## Error Handling & Fail-Closed Behavior

All state transitions validate against the allowed graph and fail closed. Attempting `Dispatched -> Complete` while any leg is non-terminal or unsafe returns an error and leaves the state unchanged. Attempts to move from `MixedFailed` back to `Complete` are rejected: once MixedFailed is seeded, the only valid path is containment. This guarantees the first-fail invariant and prevents a later “clean” update from masking a prior failure. The failure latch is immutable: `seed_first_failure()` only sets the value once, and future calls are ignored. This behavior is deterministic regardless of the order in which leg updates arrive, which is essential for asynchronous execution correctness.

Containment is represented as explicit transitions (`MixedFailed -> Flattening -> Flattened`) without implementing the emergency close algorithm in this story. The executor exposes methods to enter containment and to mark completion of flattening, allowing tests (and future integration points) to prove that opens remain blocked until neutral. Any illegal transition returns a `GroupTransitionError` with a clear message that can be surfaced in logs later when real execution wiring is added.

## Open Blocking & Safety Gating

MixedFailed is a hard safety boundary. While in `MixedFailed` or `Flattening`, opens must be blocked to avoid increasing exposure during containment. The state machine provides `allows_open()` that returns `false` in these states and `true` once the group reaches `Complete` or `Flattened`. This gives a deterministic, testable rule for “block opens until neutral.” The executor mirrors this with `open_allowed(&AtomicGroup)` so callers can gate new orders on group safety. We intentionally keep the gating logic local to the atomic group state until broader policy/TradingMode integration arrives in later slices.

Safe completion is conservative: all legs must be terminal, no partial fills are allowed, and the maximum fill mismatch must be within `epsilon`. If any mismatch or partial exists, the executor treats it as an atomicity break and enters MixedFailed immediately. This behavior is consistent with contract §1.2.1 and the group state machine spec, and it ensures we never mark `Complete` on potentially naked exposure.

## Observability, Config, and Testing

Observability uses `atomic_group_state_total{state}` counters recorded on every successful state entry. Each counter is stored in a static `AtomicU64`, and a metric line is emitted with `state=<State>` for integration with the existing execution metric sink. This is enough to satisfy the S7-000 observability requirement without adding new global metrics plumbing.

Configuration note: atomic group execution remains behind the feature flag `ENABLE_ATOMIC_GROUPS` (bool, default false; fail-closed if missing). This flag must be enabled before any multi-leg strategy is allowed to trade; until then, the state machine and tests remain isolated and safe. This doc records the flag explicitly to satisfy the story evidence requirement.

Testing focuses on invariants: (1) first failure seeds MixedFailed and is not overwritten, (2) MixedFailed blocks opens until the group is neutral (Flattened), and (3) safe completion requires all legs terminal with no partials/mismatch. The tests are small integration tests in `crates/soldier_core/tests/test_atomic_group.rs` using a fixed epsilon to validate mismatch logic deterministically.

---

### Task 1: Add failing tests for first-fail + open blocking

**Files:**
- Create: `crates/soldier_core/tests/test_atomic_group.rs`

**Step 1: Write the failing tests**

```rust
#[path = "../src/execution/group.rs"]
mod group;
#[path = "../src/execution/atomic_group_executor.rs"]
mod atomic_group_executor;

use atomic_group_executor::AtomicGroupExecutor;
use group::{AtomicGroup, GroupState, LegOutcome, LegState};

#[test]
fn test_atomic_group_mixed_failed_then_flattened() {
    let mut group = AtomicGroup::new("group-1");
    let exec = AtomicGroupExecutor::new(1e-9);

    exec.on_intent_persisted(&mut group).unwrap();
    assert_eq!(group.state(), GroupState::Dispatched);

    let legs = vec![
        LegOutcome::filled(1.0),
        LegOutcome::rejected(1.0),
    ];
    exec.evaluate(&mut group, &legs).unwrap();
    assert_eq!(group.state(), GroupState::MixedFailed);

    exec.start_containment(&mut group).unwrap();
    assert_eq!(group.state(), GroupState::Flattening);

    exec.mark_flattened(&mut group).unwrap();
    assert_eq!(group.state(), GroupState::Flattened);
}

#[test]
fn test_mixed_failed_blocks_opens_until_neutral() {
    let mut group = AtomicGroup::new("group-2");
    let exec = AtomicGroupExecutor::new(1e-9);

    exec.on_intent_persisted(&mut group).unwrap();

    let legs = vec![
        LegOutcome::filled(1.0),
        LegOutcome::rejected(1.0),
    ];
    exec.evaluate(&mut group, &legs).unwrap();
    assert_eq!(group.state(), GroupState::MixedFailed);
    assert!(!exec.open_allowed(&group));

    exec.start_containment(&mut group).unwrap();
    exec.mark_flattened(&mut group).unwrap();
    assert!(exec.open_allowed(&group));
}
```

**Step 2: Run tests to verify they fail**

Run: `cargo test -p soldier_core --test test_atomic_group`
Expected: FAIL (missing modules / unimplemented logic).

### Task 2: Implement group state machine + metrics

**Files:**
- Create: `crates/soldier_core/src/execution/group.rs`

**Step 1: Add `GroupState`, `LegOutcome`, and `AtomicGroup` with first-fail latch**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupState { New, Dispatched, Complete, MixedFailed, Flattening, Flattened }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupFailure { Rejected, Canceled, Unfilled, PartialFill, FillMismatch }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LegState { Pending, Filled, Rejected, Canceled, Unfilled }

#[derive(Debug, Clone, Copy)]
pub struct LegOutcome {
    pub requested_qty: f64,
    pub filled_qty: f64,
    pub state: LegState,
}

impl LegOutcome {
    pub fn filled(requested_qty: f64) -> Self { Self { requested_qty, filled_qty: requested_qty, state: LegState::Filled } }
    pub fn rejected(requested_qty: f64) -> Self { Self { requested_qty, filled_qty: 0.0, state: LegState::Rejected } }
}

pub struct AtomicGroup {
    group_id: String,
    state: GroupState,
    first_failure: Option<GroupFailure>,
}
```

**Step 2: Add transition validation + metrics**

```rust
pub fn atomic_group_state_total(state: GroupState) -> u64 { /* AtomicU64 per state */ }

impl AtomicGroup {
    pub fn new(group_id: impl Into<String>) -> Self { /* state=New */ }
    pub fn state(&self) -> GroupState { self.state }
    pub fn first_failure(&self) -> Option<GroupFailure> { self.first_failure }
    pub fn seed_first_failure(&mut self, failure: GroupFailure) { if self.first_failure.is_none() { self.first_failure = Some(failure); } }
    pub fn transition_to(&mut self, next: GroupState) -> Result<(), GroupTransitionError> { /* validate graph; bump metrics */ }
}
```

### Task 3: Implement executor evaluation logic

**Files:**
- Create: `crates/soldier_core/src/execution/atomic_group_executor.rs`

**Step 1: Add evaluator and open gating**

```rust
use super::group::{AtomicGroup, GroupFailure, GroupState, LegOutcome, LegState};

pub struct AtomicGroupExecutor { epsilon: f64 }

impl AtomicGroupExecutor {
    pub fn new(epsilon: f64) -> Self { Self { epsilon: epsilon.abs() } }
    pub fn on_intent_persisted(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> { group.transition_to(GroupState::Dispatched) }
    pub fn evaluate(&self, group: &mut AtomicGroup, legs: &[LegOutcome]) -> Result<(), GroupTransitionError> { /* detect failure or complete */ }
    pub fn start_containment(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> { group.transition_to(GroupState::Flattening) }
    pub fn mark_flattened(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> { group.transition_to(GroupState::Flattened) }
    pub fn open_allowed(&self, group: &AtomicGroup) -> bool { group.state().allows_open() }
}
```

### Task 4: Run tests + commit

**Step 1: Run tests**

Run: `cargo test -p soldier_core --test test_atomic_group`
Expected: PASS.

**Step 2: Commit**

```bash
git add crates/soldier_core/src/execution/group.rs crates/soldier_core/src/execution/atomic_group_executor.rs crates/soldier_core/tests/test_atomic_group.rs docs/plans/2026-02-14-s7-000-atomic-group-design.md
git commit -m "PRD: S7-000 - atomic group state machine"
```
