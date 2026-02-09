use soldier_core::execution::{
    evaluate_net_edge_gate, IntentClassification, NetEdgeGateIntent, NetEdgeRejectReason,
};

fn intent(
    classification: IntentClassification,
    gross_edge_usd: Option<f64>,
    fee_usd: Option<f64>,
    expected_slippage_usd: Option<f64>,
    min_edge_usd: Option<f64>,
) -> NetEdgeGateIntent {
    NetEdgeGateIntent {
        classification,
        gross_edge_usd,
        fee_usd,
        expected_slippage_usd,
        min_edge_usd,
    }
}

#[test]
fn test_net_edge_gate_blocks_when_fees_plus_slippage() {
    let open_intent = intent(
        IntentClassification::Open,
        Some(2.0),
        Some(1.0),
        Some(1.2),
        Some(0.5),
    );

    let err = evaluate_net_edge_gate(&open_intent).expect_err("expected net edge rejection");

    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeTooLow);
    let net_edge = err.net_edge_usd.expect("net edge should be captured");
    assert!((net_edge - (-0.2)).abs() < 1e-9);
}

#[test]
fn test_net_edge_gate_rejects_low_edge() {
    let open_intent = intent(
        IntentClassification::Open,
        Some(1.0),
        Some(0.3),
        Some(0.3),
        Some(0.5),
    );

    let err = evaluate_net_edge_gate(&open_intent).expect_err("expected low-edge rejection");

    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeTooLow);
    let net_edge = err.net_edge_usd.expect("net edge should be captured");
    assert!((net_edge - 0.4).abs() < 1e-9);
}

#[test]
fn test_net_edge_gate_rejects_missing_inputs() {
    let missing_fee = intent(
        IntentClassification::Open,
        Some(1.0),
        None,
        Some(0.1),
        Some(0.2),
    );
    let err = evaluate_net_edge_gate(&missing_fee).expect_err("expected missing fee rejection");
    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeInputMissing);

    let missing_slippage = intent(
        IntentClassification::Open,
        Some(1.0),
        Some(0.1),
        None,
        Some(0.2),
    );
    let err =
        evaluate_net_edge_gate(&missing_slippage).expect_err("expected missing slippage rejection");
    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeInputMissing);

    let missing_gross = intent(
        IntentClassification::Open,
        None,
        Some(0.1),
        Some(0.1),
        Some(0.2),
    );
    let err = evaluate_net_edge_gate(&missing_gross).expect_err("expected missing gross rejection");
    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeInputMissing);

    let missing_min_edge = intent(
        IntentClassification::Open,
        Some(1.0),
        Some(0.1),
        Some(0.1),
        None,
    );
    let err =
        evaluate_net_edge_gate(&missing_min_edge).expect_err("expected missing min edge rejection");
    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeInputMissing);

    let unparseable = intent(
        IntentClassification::Open,
        Some(1.0),
        Some(f64::NAN),
        Some(0.1),
        Some(0.2),
    );
    let err = evaluate_net_edge_gate(&unparseable).expect_err("expected unparseable rejection");
    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeInputMissing);
}

#[test]
fn test_net_edge_gate_rejects_when_fees_exceed_gross_edge() {
    let open_intent = intent(
        IntentClassification::Open,
        Some(1.0),
        Some(1.1),
        Some(0.1),
        Some(0.0),
    );

    let err =
        evaluate_net_edge_gate(&open_intent).expect_err("expected fee-exceeds-gross rejection");

    assert_eq!(err.reason, NetEdgeRejectReason::NetEdgeTooLow);
    let net_edge = err.net_edge_usd.expect("net edge should be captured");
    assert!((net_edge - (-0.2)).abs() < 1e-9);
}
