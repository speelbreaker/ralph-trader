use soldier_core::execution::{
    IntentClassification, L2BookLevel, L2BookSnapshot, LiquidityGateConfig, LiquidityGateIntent,
    LiquidityGateRejectReason, Side, evaluate_liquidity_gate,
};

fn snapshot(ts_ms: u64, bids: Vec<L2BookLevel>, asks: Vec<L2BookLevel>) -> L2BookSnapshot {
    L2BookSnapshot { bids, asks, ts_ms }
}

fn base_intent<'a>(
    classification: IntentClassification,
    side: Side,
    order_qty: f64,
    l2_snapshot: Option<&'a L2BookSnapshot>,
    now_ms: u64,
) -> LiquidityGateIntent<'a> {
    LiquidityGateIntent {
        classification,
        side,
        order_qty,
        l2_snapshot,
        now_ms,
    }
}

#[test]
fn test_liquidity_gate_rejects_sweep() {
    let asks = vec![
        L2BookLevel {
            price: 100.0,
            qty: 1.0,
        },
        L2BookLevel {
            price: 101.0,
            qty: 1.0,
        },
    ];
    let bids = vec![L2BookLevel {
        price: 99.0,
        qty: 5.0,
    }];
    let book = snapshot(1_000, bids, asks);
    let intent = base_intent(
        IntentClassification::Open,
        Side::Buy,
        2.0,
        Some(&book),
        1_500,
    );

    let err = evaluate_liquidity_gate(&intent, LiquidityGateConfig::default())
        .expect_err("expected slippage rejection");

    assert_eq!(
        err.reason,
        LiquidityGateRejectReason::ExpectedSlippageTooHigh
    );
    let wap = err.wap.expect("wap should be captured on slippage reject");
    let slippage_bps = err
        .slippage_bps
        .expect("slippage should be captured on slippage reject");
    assert!((wap - 100.5).abs() < 1e-9);
    assert!((slippage_bps - 50.0).abs() < 1e-6);
}

#[test]
fn test_liquidity_gate_no_l2_blocks_open() {
    let intent = base_intent(IntentClassification::Open, Side::Buy, 1.0, None, 10_000);

    let err = evaluate_liquidity_gate(&intent, LiquidityGateConfig::default())
        .expect_err("expected no-l2 rejection");

    assert_eq!(err.reason, LiquidityGateRejectReason::LiquidityGateNoL2);
}

#[test]
fn test_liquidity_gate_no_l2_reject_reason() {
    let asks = vec![L2BookLevel {
        price: 100.0,
        qty: 1.0,
    }];
    let bids = vec![L2BookLevel {
        price: 99.0,
        qty: 1.0,
    }];
    let book = snapshot(1_000, bids, asks);
    let intent = base_intent(
        IntentClassification::Open,
        Side::Buy,
        1.0,
        Some(&book),
        5_000,
    );

    let err = evaluate_liquidity_gate(&intent, LiquidityGateConfig::default())
        .expect_err("expected stale L2 rejection");

    assert_eq!(err.reason, LiquidityGateRejectReason::LiquidityGateNoL2);
}

#[test]
fn test_liquidity_gate_no_l2_blocks_close_hedge_allows_cancel() {
    let close_intent = base_intent(IntentClassification::Close, Side::Sell, 1.0, None, 500);
    let hedge_intent = base_intent(IntentClassification::Hedge, Side::Buy, 1.0, None, 500);
    let cancel_intent = base_intent(IntentClassification::Cancel, Side::Buy, 1.0, None, 500);

    let close_err = evaluate_liquidity_gate(&close_intent, LiquidityGateConfig::default())
        .expect_err("expected close to reject without L2");
    assert_eq!(
        close_err.reason,
        LiquidityGateRejectReason::LiquidityGateNoL2
    );

    let hedge_err = evaluate_liquidity_gate(&hedge_intent, LiquidityGateConfig::default())
        .expect_err("expected hedge to reject without L2");
    assert_eq!(
        hedge_err.reason,
        LiquidityGateRejectReason::LiquidityGateNoL2
    );

    evaluate_liquidity_gate(&cancel_intent, LiquidityGateConfig::default())
        .expect("expected cancel to allow without L2");
}
