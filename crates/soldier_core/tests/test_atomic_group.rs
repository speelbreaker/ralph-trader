#[allow(dead_code)]
fn emit_execution_metric_line(_metric_name: &str, _tail_fields: &str) {}

#[path = "../src/execution/atomic_group_executor.rs"]
mod atomic_group_executor;
#[path = "../src/execution/group.rs"]
mod group;

use atomic_group_executor::{AtomicGroupExecutor, RescueAction};
use group::{AtomicGroup, GroupFailure, GroupState, LegOutcome, LegState};

#[test]
fn test_atomic_group_mixed_failed_then_flattened() {
    let mut group = AtomicGroup::new("group-1");
    let exec = AtomicGroupExecutor::new(1e-9);

    exec.on_intent_persisted(&mut group).unwrap();
    assert_eq!(group.state(), GroupState::Dispatched);

    let legs = vec![LegOutcome::filled(1.0), LegOutcome::rejected(1.0)];
    exec.evaluate(&mut group, &legs).unwrap();
    assert_eq!(group.state(), GroupState::MixedFailed);
    assert_eq!(group.first_failure(), Some(GroupFailure::Rejected));

    let safe_legs = vec![LegOutcome::filled(1.0), LegOutcome::filled(1.0)];
    exec.evaluate(&mut group, &safe_legs).unwrap();
    assert_eq!(group.state(), GroupState::MixedFailed);
    assert_eq!(group.first_failure(), Some(GroupFailure::Rejected));

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

    let legs = vec![LegOutcome::filled(1.0), LegOutcome::rejected(1.0)];
    exec.evaluate(&mut group, &legs).unwrap();
    assert_eq!(group.state(), GroupState::MixedFailed);
    assert!(!exec.open_allowed(&group));

    exec.start_containment(&mut group).unwrap();
    exec.mark_flattened(&mut group).unwrap();
    assert!(exec.open_allowed(&group));
}

#[test]
fn test_atomic_rescue_attempts_limited_to_two() {
    let mut group = AtomicGroup::new("group-3");
    let exec = AtomicGroupExecutor::new(1e-9);

    exec.on_intent_persisted(&mut group).unwrap();

    let legs = vec![
        LegOutcome::new(1.0, 0.6, LegState::Filled),
        LegOutcome::new(1.0, 0.0, LegState::Filled),
    ];
    exec.evaluate(&mut group, &legs).unwrap();
    assert_eq!(group.state(), GroupState::MixedFailed);
    assert_eq!(exec.rescue_attempts(&group), 0);

    let outcome = exec.record_rescue_failure(&mut group).unwrap();
    assert_eq!(outcome, RescueAction::Retry);
    assert_eq!(exec.rescue_attempts(&group), 1);
    assert_eq!(group.state(), GroupState::MixedFailed);

    let outcome = exec.record_rescue_failure(&mut group).unwrap();
    assert_eq!(outcome, RescueAction::Flatten);
    assert_eq!(exec.rescue_attempts(&group), 2);
    assert_eq!(group.state(), GroupState::Flattening);

    let outcome = exec.record_rescue_failure(&mut group).unwrap();
    assert_eq!(outcome, RescueAction::Noop);
    assert_eq!(exec.rescue_attempts(&group), 2);
    assert_eq!(group.state(), GroupState::Flattening);
}
