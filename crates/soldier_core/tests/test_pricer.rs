use soldier_core::execution::{PricerIntent, RejectReason, Side, price_ioc_limit};

fn intent(
    side: Side,
    fair_price: f64,
    gross_edge_usd: f64,
    fee_estimate_usd: f64,
    min_edge_usd: f64,
    qty: f64,
) -> PricerIntent {
    PricerIntent {
        side,
        fair_price,
        gross_edge_usd,
        fee_estimate_usd,
        min_edge_usd,
        qty,
    }
}

fn realized_net_edge_usd(
    side: Side,
    fair_price: f64,
    limit_price: f64,
    fee_estimate_usd: f64,
    qty: f64,
) -> f64 {
    let fee_per_unit = fee_estimate_usd / qty;
    let per_unit_edge = match side {
        Side::Buy => fair_price - limit_price - fee_per_unit,
        Side::Sell => limit_price - fair_price - fee_per_unit,
    };
    per_unit_edge * qty
}

#[test]
fn test_pricer_rejects_low_edge() {
    let low_edge = intent(Side::Buy, 100.0, 1.0, 0.6, 0.8, 2.0);

    let err = price_ioc_limit(&low_edge).expect_err("expected low-edge rejection");

    assert_eq!(err.reason, RejectReason::NetEdgeTooLow);
    let net_edge = err.net_edge_usd.expect("net edge should be captured");
    assert!((net_edge - 0.4).abs() < 1e-9);
}

#[test]
fn test_pricer_clamps_limit_for_min_edge_buy() {
    let open = intent(Side::Buy, 100.0, 4.0, 1.0, 2.0, 1.0);

    let outcome = price_ioc_limit(&open).expect("expected limit price");

    let expected_max = 97.0;
    assert!((outcome.max_price_for_min_edge - expected_max).abs() < 1e-9);
    assert!((outcome.limit_price - expected_max).abs() < 1e-9);
    assert!(outcome.limit_price <= outcome.max_price_for_min_edge + 1e-9);

    let realized_edge = realized_net_edge_usd(
        open.side,
        open.fair_price,
        outcome.limit_price,
        open.fee_estimate_usd,
        open.qty,
    );
    assert!(realized_edge + 1e-9 >= open.min_edge_usd);
}

#[test]
fn test_pricer_clamps_limit_for_min_edge_sell() {
    let open = intent(Side::Sell, 200.0, 10.0, 2.0, 4.0, 2.0);

    let outcome = price_ioc_limit(&open).expect("expected limit price");

    let expected_max = 203.0;
    assert!((outcome.max_price_for_min_edge - expected_max).abs() < 1e-9);
    assert!((outcome.limit_price - expected_max).abs() < 1e-9);
    assert!(outcome.limit_price + 1e-9 >= outcome.max_price_for_min_edge);

    let realized_edge = realized_net_edge_usd(
        open.side,
        open.fair_price,
        outcome.limit_price,
        open.fee_estimate_usd,
        open.qty,
    );
    assert!(realized_edge + 1e-9 >= open.min_edge_usd);
}
