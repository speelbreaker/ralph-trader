use soldier_core::execution::{
    BuildOrderIntentError, LinkedOrderType, OrderIntent, OrderType, OrderTypeGuardConfig,
    OrderTypeRejectReason, TriggerType, build_order_intent, preflight_intent,
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
    match err {
        BuildOrderIntentError::Preflight(reject) => {
            assert_eq!(
                reject.reason,
                OrderTypeRejectReason::OrderTypeMarketForbidden
            );
        }
        other => panic!("expected preflight error, got {other:?}"),
    }
}

#[test]
fn preflight_allows_limit_orders_without_triggers() {
    let intent = base_intent(InstrumentKind::InverseFuture);
    preflight_intent(&intent, OrderTypeGuardConfig::default())
        .expect("limit orders should pass preflight");
}

#[test]
fn preflight_linked_order_matrix() {
    struct Case {
        name: &'static str,
        instrument_kind: InstrumentKind,
        linked_supported: bool,
        linked_enabled: bool,
        expect_allowed: bool,
    }

    let cases = [
        Case {
            name: "option_always_forbidden_even_with_both_flags",
            instrument_kind: InstrumentKind::Option,
            linked_supported: true,
            linked_enabled: true,
            expect_allowed: false,
        },
        Case {
            name: "perp_allowed_with_both_flags",
            instrument_kind: InstrumentKind::Perpetual,
            linked_supported: true,
            linked_enabled: true,
            expect_allowed: true,
        },
        Case {
            name: "perp_forbidden_missing_enable",
            instrument_kind: InstrumentKind::Perpetual,
            linked_supported: true,
            linked_enabled: false,
            expect_allowed: false,
        },
        Case {
            name: "inverse_forbidden_missing_support",
            instrument_kind: InstrumentKind::InverseFuture,
            linked_supported: false,
            linked_enabled: true,
            expect_allowed: false,
        },
        Case {
            name: "linear_allowed_with_both_flags",
            instrument_kind: InstrumentKind::LinearFuture,
            linked_supported: true,
            linked_enabled: true,
            expect_allowed: true,
        },
    ];

    for case in cases {
        let intent = OrderIntent {
            linked_order_type: Some(LinkedOrderType::Oco),
            ..base_intent(case.instrument_kind)
        };
        let config = OrderTypeGuardConfig {
            linked_orders_supported: case.linked_supported,
            enable_linked_orders_for_bot: case.linked_enabled,
        };
        let result = preflight_intent(&intent, config);
        if case.expect_allowed {
            assert!(result.is_ok(), "{} should allow linked order", case.name);
        } else {
            let err = result.expect_err("expected linked-order rejection");
            assert_eq!(
                err.reason,
                OrderTypeRejectReason::LinkedOrderTypeForbidden,
                "{} expected linked-order forbidden",
                case.name
            );
        }
    }
}

#[test]
fn preflight_stop_order_matrix_all_instrument_kinds() {
    let kinds = [
        InstrumentKind::Option,
        InstrumentKind::Perpetual,
        InstrumentKind::LinearFuture,
        InstrumentKind::InverseFuture,
    ];

    for instrument_kind in kinds {
        for order_type in [OrderType::StopMarket, OrderType::StopLimit] {
            let intent = OrderIntent {
                order_type,
                ..base_intent(instrument_kind)
            };
            let err = preflight_intent(&intent, OrderTypeGuardConfig::default())
                .expect_err("stop order should reject");
            assert_eq!(
                err.reason,
                OrderTypeRejectReason::OrderTypeStopForbidden,
                "kind={instrument_kind:?} type={order_type:?} should be stop-forbidden"
            );
        }
    }
}

#[test]
fn preflight_trigger_field_matrix() {
    let option_trigger = OrderIntent {
        trigger: Some(TriggerType::IndexPrice),
        ..base_intent(InstrumentKind::Option)
    };
    let option_err = preflight_intent(&option_trigger, OrderTypeGuardConfig::default())
        .expect_err("option trigger field should reject");
    assert_eq!(option_err.reason, OrderTypeRejectReason::OrderTypeStopForbidden);

    let non_option_kinds = [
        InstrumentKind::Perpetual,
        InstrumentKind::LinearFuture,
        InstrumentKind::InverseFuture,
    ];
    for instrument_kind in non_option_kinds {
        let intent = OrderIntent {
            trigger: Some(TriggerType::MarkPrice),
            trigger_price: Some(100.0),
            ..base_intent(instrument_kind)
        };
        preflight_intent(&intent, OrderTypeGuardConfig::default())
            .expect("non-option trigger fields are allowed by current guard");
    }
}
