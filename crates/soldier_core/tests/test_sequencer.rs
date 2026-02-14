use soldier_core::execution::sequencer::{
    ExecutionStep, IntentKind, RiskState, SequenceError, Sequencer,
};

#[test]
fn test_sequencer_close_then_hedge_ordering() {
    // GIVEN sequencer ordering
    let seq = Sequencer::new();
    let leg_ids = vec!["btc_put".to_string(), "btc_call".to_string()];

    // WHEN processing close intent
    let steps = seq
        .generate_steps(IntentKind::Close, RiskState::Healthy, &leg_ids)
        .expect("close steps should succeed");

    // THEN close→confirm→hedge order enforced
    assert_eq!(steps.len(), 5);

    // All close steps come first
    assert!(matches!(steps[0], ExecutionStep::PlaceClose { ref leg_id } if leg_id == "btc_put"));
    assert!(matches!(steps[1], ExecutionStep::PlaceClose { ref leg_id } if leg_id == "btc_call"));

    // Then all confirm steps
    assert!(matches!(steps[2], ExecutionStep::ConfirmClose { ref leg_id } if leg_id == "btc_put"));
    assert!(matches!(steps[3], ExecutionStep::ConfirmClose { ref leg_id } if leg_id == "btc_call"));

    // Finally hedge (reduce-only)
    assert!(matches!(
        steps[4],
        ExecutionStep::PlaceHedge {
            reduce_only: true,
            ..
        }
    ));
}

#[test]
fn test_sequencer_blocks_exposure_increase_when_riskstate_not_healthy() {
    // GIVEN RiskState != Healthy
    let seq = Sequencer::new();
    let leg_ids = vec!["btc_call".to_string()];

    // Table-driven test for all non-Healthy states
    let cases = vec![
        ("Degraded", RiskState::Degraded),
        ("Maintenance", RiskState::Maintenance),
        ("Kill", RiskState::Kill),
    ];

    for (name, risk_state) in cases {
        // WHEN evaluating open intent
        let result = seq.generate_steps(IntentKind::Open, risk_state, &leg_ids);

        // THEN never increase exposure
        assert!(
            matches!(result, Err(SequenceError::RiskStateNotHealthy { .. })),
            "Open intent should be rejected when RiskState = {}",
            name
        );
    }

    // Verify counter increments
    assert_eq!(seq.get_counter("sequencer_order_violation_total"), 3);
}

#[test]
fn test_sequencer_repair_flattens_before_hedge() {
    // GIVEN repair path (mixed failed/zombie legs)
    let seq = Sequencer::new();
    let leg_ids = vec!["failed_group_123".to_string()];

    // WHEN processing repair intent
    let steps = seq
        .generate_steps(IntentKind::Repair, RiskState::Degraded, &leg_ids)
        .expect("repair steps should succeed");

    // THEN flatten filled legs first via emergency_close_algorithm
    assert_eq!(steps.len(), 2);
    assert!(matches!(
        steps[0],
        ExecutionStep::FlattenViaEmergencyClose { ref group_id } if group_id == "failed_group_123"
    ));

    // hedge only after retries fail
    assert!(matches!(
        steps[1],
        ExecutionStep::PlaceHedge {
            reduce_only: true,
            ..
        }
    ));
}

#[test]
fn test_open_allowed_when_risk_state_healthy() {
    // GIVEN RiskState::Healthy
    let seq = Sequencer::new();
    let leg_ids = vec!["btc_call".to_string()];

    // WHEN processing open intent
    let steps = seq
        .generate_steps(IntentKind::Open, RiskState::Healthy, &leg_ids)
        .expect("open should succeed when healthy");

    // THEN open→confirm→hedge ordering
    assert_eq!(steps.len(), 3);
    assert!(matches!(steps[0], ExecutionStep::PlaceOpen { ref leg_id } if leg_id == "btc_call"));
    assert!(matches!(steps[1], ExecutionStep::ConfirmOpen { ref leg_id } if leg_id == "btc_call"));
    assert!(matches!(
        steps[2],
        ExecutionStep::PlaceHedge {
            reduce_only: false,
            ..
        }
    ));
}

#[test]
fn test_close_allowed_in_all_risk_states() {
    // GIVEN any RiskState (including non-Healthy)
    let seq = Sequencer::new();
    let leg_ids = vec!["btc_put".to_string()];

    let risk_states = vec![
        RiskState::Healthy,
        RiskState::Degraded,
        RiskState::Maintenance,
        RiskState::Kill,
    ];

    for risk_state in risk_states {
        // WHEN processing close intent
        let steps = seq
            .generate_steps(IntentKind::Close, risk_state, &leg_ids)
            .expect("close should succeed in all risk states");

        // THEN close steps are generated
        assert!(!steps.is_empty());
        assert!(matches!(steps[0], ExecutionStep::PlaceClose { .. }));
    }
}

#[test]
fn test_repair_allowed_in_degraded_risk_state() {
    // GIVEN RiskState::Degraded (repair paths should work in degraded)
    let seq = Sequencer::new();
    let leg_ids = vec!["zombie_group".to_string()];

    // WHEN processing repair intent
    let steps = seq
        .generate_steps(IntentKind::Repair, RiskState::Degraded, &leg_ids)
        .expect("repair should succeed in degraded state");

    // THEN repair steps generated
    assert_eq!(steps.len(), 2);
    assert!(matches!(
        steps[0],
        ExecutionStep::FlattenViaEmergencyClose { .. }
    ));
}

#[test]
fn test_empty_leg_list_rejected() {
    let seq = Sequencer::new();
    let empty_legs: Vec<String> = vec![];

    // All intent kinds should reject empty leg lists
    assert!(matches!(
        seq.generate_steps(IntentKind::Close, RiskState::Healthy, &empty_legs),
        Err(SequenceError::EmptyLegList)
    ));
    assert!(matches!(
        seq.generate_steps(IntentKind::Open, RiskState::Healthy, &empty_legs),
        Err(SequenceError::EmptyLegList)
    ));
    assert!(matches!(
        seq.generate_steps(IntentKind::Repair, RiskState::Healthy, &empty_legs),
        Err(SequenceError::EmptyLegList)
    ));
}

#[test]
fn test_multiple_legs_ordering_preserved() {
    // GIVEN multiple legs
    let seq = Sequencer::new();
    let leg_ids = vec![
        "leg_a".to_string(),
        "leg_b".to_string(),
        "leg_c".to_string(),
    ];

    // WHEN processing close intent
    let steps = seq
        .generate_steps(IntentKind::Close, RiskState::Healthy, &leg_ids)
        .expect("close with multiple legs should succeed");

    // THEN all place_close before any confirm_close
    assert!(matches!(steps[0], ExecutionStep::PlaceClose { ref leg_id } if leg_id == "leg_a"));
    assert!(matches!(steps[1], ExecutionStep::PlaceClose { ref leg_id } if leg_id == "leg_b"));
    assert!(matches!(steps[2], ExecutionStep::PlaceClose { ref leg_id } if leg_id == "leg_c"));
    assert!(matches!(steps[3], ExecutionStep::ConfirmClose { ref leg_id } if leg_id == "leg_a"));
    assert!(matches!(steps[4], ExecutionStep::ConfirmClose { ref leg_id } if leg_id == "leg_b"));
    assert!(matches!(steps[5], ExecutionStep::ConfirmClose { ref leg_id } if leg_id == "leg_c"));
    assert!(matches!(
        steps[6],
        ExecutionStep::PlaceHedge {
            reduce_only: true,
            ..
        }
    ));
}
