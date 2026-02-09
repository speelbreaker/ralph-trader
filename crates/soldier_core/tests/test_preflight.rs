use soldier_core::execution::{
    LinkedOrderType, OrderIntent, OrderType, OrderTypeGuardConfig, OrderTypeRejectReason,
    TriggerType, build_order_intent, preflight_intent,
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
fn preflight_rejects_option_market_orders() {
    let intent = OrderIntent {
        order_type: OrderType::Market,
        ..base_intent(InstrumentKind::Option)
    };
    let err = preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect_err("expected market reject");
    assert_eq!(err.reason, OrderTypeRejectReason::OrderTypeMarketForbidden);
}

#[test]
fn preflight_rejects_option_stop_orders() {
    let intent = OrderIntent {
        order_type: OrderType::StopMarket,
        ..base_intent(InstrumentKind::Option)
    };
    let err = preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect_err("expected stop reject");
    assert_eq!(err.reason, OrderTypeRejectReason::OrderTypeStopForbidden);
}

#[test]
fn preflight_rejects_option_trigger_fields() {
    let intent = OrderIntent {
        trigger: Some(TriggerType::IndexPrice),
        ..base_intent(InstrumentKind::Option)
    };
    let err = preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect_err("expected trigger reject");
    assert_eq!(err.reason, OrderTypeRejectReason::OrderTypeStopForbidden);
}

#[test]
fn preflight_rejects_future_market_orders() {
    let intent = OrderIntent {
        order_type: OrderType::Market,
        ..base_intent(InstrumentKind::LinearFuture)
    };
    let err = preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect_err("expected market reject");
    assert_eq!(err.reason, OrderTypeRejectReason::OrderTypeMarketForbidden);
}

#[test]
fn preflight_rejects_perp_stop_orders() {
    let intent = OrderIntent {
        order_type: OrderType::StopLimit,
        ..base_intent(InstrumentKind::Perpetual)
    };
    let err = preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect_err("expected stop reject");
    assert_eq!(err.reason, OrderTypeRejectReason::OrderTypeStopForbidden);
}

#[test]
fn preflight_rejects_linked_orders_by_default() {
    let intent = OrderIntent {
        linked_order_type: Some(LinkedOrderType::Oco),
        ..base_intent(InstrumentKind::LinearFuture)
    };
    let err = preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect_err("expected linked-order reject");
    assert_eq!(err.reason, OrderTypeRejectReason::LinkedOrderTypeForbidden);
}

#[test]
fn build_order_intent_runs_preflight() {
    let intent = OrderIntent {
        order_type: OrderType::Market,
        ..base_intent(InstrumentKind::Option)
    };
    let err = build_order_intent(intent, OrderTypeGuardConfig::default())
        .expect_err("expected preflight reject");
    assert_eq!(err.reason, OrderTypeRejectReason::OrderTypeMarketForbidden);
}

#[test]
fn preflight_allows_limit_orders_without_triggers() {
    let intent = base_intent(InstrumentKind::InverseFuture);
    preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect("limit orders should pass preflight");
}
