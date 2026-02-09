use soldier_core::execution::{encode_compact_label_with_hashes, Side};
use soldier_core::recovery::label_match::{
    match_label_with_metrics, LabelMatchCandidate, LabelMatchMetrics, LabelMatchOrder,
};
use soldier_core::risk::RiskState;

fn ih16(value: u64) -> String {
    format!("{:016x}", value)
}

fn make_label(gid12: &str, leg_idx: u8, ih: &str) -> String {
    encode_compact_label_with_hashes("sid8", gid12, leg_idx, ih).expect("label")
}

fn candidate<'a>(
    group_id: &'a str,
    leg_idx: u8,
    intent_hash: u64,
    instrument_id: &'a str,
    side: Side,
    qty_q: f64,
) -> LabelMatchCandidate<'a> {
    LabelMatchCandidate {
        group_id,
        leg_idx,
        intent_hash,
        instrument_id,
        side,
        qty_q,
    }
}

#[test]
fn test_label_match_tie_breakers_in_order() {
    let gid12 = "gid123456789";
    let leg_idx = 0u8;

    // ih16 match must take precedence over instrument match.
    let label = make_label(gid12, leg_idx, &ih16(1));
    let candidates = vec![
        candidate(gid12, leg_idx, 1, "ETH-PERP", Side::Sell, 2.0),
        candidate(gid12, leg_idx, 2, "BTC-PERP", Side::Buy, 1.0),
    ];
    let order = LabelMatchOrder {
        label: &label,
        instrument_id: "BTC-PERP",
        side: Side::Buy,
        qty_q: 1.0,
    };
    let metrics = LabelMatchMetrics::new();
    let decision = match_label_with_metrics(&metrics, &order, &candidates).expect("match");
    assert_eq!(decision.risk_state, RiskState::Healthy);
    assert_eq!(decision.matched.expect("matched").intent_hash, 1);

    // instrument match must take precedence over side/qty.
    let label = make_label(gid12, leg_idx, &ih16(3));
    let candidates = vec![
        candidate(gid12, leg_idx, 3, "BTC-PERP", Side::Sell, 2.0),
        candidate(gid12, leg_idx, 3, "ETH-PERP", Side::Buy, 1.0),
    ];
    let order = LabelMatchOrder {
        label: &label,
        instrument_id: "BTC-PERP",
        side: Side::Buy,
        qty_q: 1.0,
    };
    let metrics = LabelMatchMetrics::new();
    let decision = match_label_with_metrics(&metrics, &order, &candidates).expect("match");
    assert_eq!(decision.matched.expect("matched").instrument_id, "BTC-PERP");

    // side match must take precedence over qty.
    let label = make_label(gid12, leg_idx, &ih16(4));
    let candidates = vec![
        candidate(gid12, leg_idx, 4, "BTC-PERP", Side::Sell, 2.0),
        candidate(gid12, leg_idx, 4, "BTC-PERP", Side::Buy, 1.0),
    ];
    let order = LabelMatchOrder {
        label: &label,
        instrument_id: "BTC-PERP",
        side: Side::Sell,
        qty_q: 1.0,
    };
    let metrics = LabelMatchMetrics::new();
    let decision = match_label_with_metrics(&metrics, &order, &candidates).expect("match");
    assert_eq!(decision.matched.expect("matched").side, Side::Sell);
}

#[test]
fn test_label_match_ambiguity_degrades_and_increments_metric() {
    let gid12 = "gid123456789";
    let leg_idx = 0u8;
    let label = make_label(gid12, leg_idx, &ih16(9));

    let candidates = vec![
        candidate(gid12, leg_idx, 9, "BTC-PERP", Side::Buy, 1.0),
        candidate(gid12, leg_idx, 9, "BTC-PERP", Side::Buy, 1.0),
    ];
    let order = LabelMatchOrder {
        label: &label,
        instrument_id: "BTC-PERP",
        side: Side::Buy,
        qty_q: 1.0,
    };
    let metrics = LabelMatchMetrics::new();
    let decision = match_label_with_metrics(&metrics, &order, &candidates).expect("match");

    assert!(decision.matched.is_none());
    assert_eq!(decision.risk_state, RiskState::Degraded);
    assert_eq!(metrics.label_match_ambiguity_total(), 1);
}

#[test]
fn test_label_match_single_candidate_is_deterministic() {
    let gid12 = "gid123456789";
    let leg_idx = 0u8;
    let label = make_label(gid12, leg_idx, &ih16(7));

    let candidates = vec![
        candidate(gid12, leg_idx, 7, "BTC-PERP", Side::Sell, 2.0),
        candidate("othergroup000", leg_idx, 7, "BTC-PERP", Side::Sell, 2.0),
    ];
    let order = LabelMatchOrder {
        label: &label,
        instrument_id: "BTC-PERP",
        side: Side::Sell,
        qty_q: 2.0,
    };
    let metrics = LabelMatchMetrics::new();
    let decision = match_label_with_metrics(&metrics, &order, &candidates).expect("match");

    assert_eq!(decision.risk_state, RiskState::Healthy);
    assert_eq!(decision.matched.expect("matched").intent_hash, 7);
}
