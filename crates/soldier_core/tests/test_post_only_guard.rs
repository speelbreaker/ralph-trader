use soldier_core::execution::{
    OrderIntent, OrderType, OrderTypeGuardConfig, PostOnlyIntent, PostOnlyRejectReason,
    PreflightGuardRejectReason, Side, preflight_intent_with_post_only,
};
use soldier_core::venue::InstrumentKind;

fn base_intent(instrument_kind: InstrumentKind) -> OrderIntent {
    OrderIntent {
        instrument_kind,
        order_type: OrderType::Limit,
        trigger: None,
        trigger_price: None,
        linked_order_type: None,
    }
}

#[test]
fn test_post_only_crossing_rejected() {
    let intent = base_intent(InstrumentKind::Perpetual);
    let post_only = PostOnlyIntent {
        post_only: true,
        side: Side::Buy,
        limit_price: 101.0,
        best_bid: Some(100.0),
        best_ask: Some(100.5),
    };

    let err = preflight_intent_with_post_only(&intent, OrderTypeGuardConfig::default(), &post_only)
        .expect_err("expected post-only reject");

    assert_eq!(
        err.reason,
        PreflightGuardRejectReason::PostOnly(PostOnlyRejectReason::PostOnlyWouldCross)
    );
}

#[test]
fn test_post_only_non_crossing_allows() {
    let intent = base_intent(InstrumentKind::LinearFuture);
    let post_only = PostOnlyIntent {
        post_only: true,
        side: Side::Buy,
        limit_price: 99.0,
        best_bid: Some(98.0),
        best_ask: Some(100.0),
    };

    preflight_intent_with_post_only(&intent, OrderTypeGuardConfig::default(), &post_only)
        .expect("expected non-crossing post-only to pass");
}
