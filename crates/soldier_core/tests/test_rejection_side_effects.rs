use std::sync::atomic::Ordering;

use soldier_core::execution::{
    build_order_intent, take_build_order_intent_outcome, take_dispatch_trace,
    with_build_order_intent_context, BuildOrderIntentContext, BuildOrderIntentObservers,
    BuildOrderIntentOutcome, BuildOrderIntentRejectReason, InstrumentQuantization,
    IntentClassification, L2BookLevel, L2BookSnapshot, LinkedOrderType, LiquidityGateConfig,
    OrderIntent, OrderType, OrderTypeGuardConfig, OrderTypeRejectReason, QuantizeRejectReason,
    RecordIntentOutcome, Side,
};
use soldier_core::risk::{FeeModelSnapshot, FeeStalenessConfig, RiskState};
use soldier_core::venue::InstrumentKind;

fn base_intent() -> OrderIntent {
    OrderIntent {
        instrument_kind: InstrumentKind::Perpetual,
        order_type: OrderType::Limit,
        trigger: None,
        trigger_price: None,
        linked_order_type: None,
    }
}

fn sample_book(now_ms: u64) -> L2BookSnapshot {
    L2BookSnapshot {
        bids: vec![L2BookLevel {
            price: 99.5,
            qty: 10.0,
        }],
        asks: vec![L2BookLevel {
            price: 100.0,
            qty: 10.0,
        }],
        ts_ms: now_ms,
    }
}

fn base_context(
    observers: BuildOrderIntentObservers,
    quantization: InstrumentQuantization,
    raw_qty: f64,
    raw_limit_price: f64,
) -> BuildOrderIntentContext {
    let now_ms = 1_000;
    BuildOrderIntentContext {
        classification: IntentClassification::Open,
        side: Side::Buy,
        raw_qty,
        raw_limit_price,
        quantization,
        fee_model: FeeModelSnapshot {
            fee_tier: 1,
            maker_fee_rate: 0.0002,
            taker_fee_rate: 0.0005,
            fee_model_cached_at_ts_ms: Some(now_ms),
        },
        fee_staleness_config: FeeStalenessConfig::default(),
        is_maker: false,
        l2_snapshot: Some(sample_book(now_ms)),
        liquidity_config: LiquidityGateConfig::default(),
        now_ms,
        gross_edge_usd: 10.0,
        min_edge_usd: 1.0,
        fair_price: 100.0,
        risk_state: RiskState::Healthy,
        record_outcome: RecordIntentOutcome::Recorded,
        observers: Some(observers),
    }
}

fn assert_rejects_without_side_effects(
    name: &str,
    intent: OrderIntent,
    config: OrderTypeGuardConfig,
    context: BuildOrderIntentContext,
    expected: BuildOrderIntentOutcome,
    expect_err: bool,
) {
    let observers = context
        .observers
        .as_ref()
        .expect("expected observers")
        .clone();
    let result = with_build_order_intent_context(context, || build_order_intent(intent, config));
    if expect_err {
        assert!(result.is_err(), "{name} expected preflight rejection");
    } else {
        assert!(result.is_ok(), "{name} expected non-preflight rejection");
    }

    let outcome = take_build_order_intent_outcome().expect("expected outcome");
    assert_eq!(outcome, expected, "{name} outcome mismatch");

    assert!(
        take_dispatch_trace().is_empty(),
        "{name} should not record/dispatch"
    );
    assert_eq!(
        observers.recorded_total.load(Ordering::Relaxed),
        0,
        "{name} should not record intent"
    );
    assert_eq!(
        observers.dispatch_total.load(Ordering::Relaxed),
        0,
        "{name} should not dispatch intent"
    );
}

#[test]
fn test_rejected_intent_has_no_side_effects() {
    let mut intent = base_intent();
    intent.linked_order_type = Some(LinkedOrderType::Oco);
    let observers = BuildOrderIntentObservers::new();
    let context = base_context(
        observers,
        InstrumentQuantization {
            tick_size: 0.5,
            amount_step: 0.1,
            min_amount: 0.1,
        },
        1.2,
        100.1,
    );
    assert_rejects_without_side_effects(
        "missing config",
        intent,
        OrderTypeGuardConfig::default(),
        context,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::Preflight(
            OrderTypeRejectReason::LinkedOrderTypeForbidden,
        )),
        true,
    );

    let observers = BuildOrderIntentObservers::new();
    let context = base_context(
        observers,
        InstrumentQuantization {
            tick_size: 0.0,
            amount_step: 0.1,
            min_amount: 0.1,
        },
        1.2,
        100.1,
    );
    assert_rejects_without_side_effects(
        "invalid instrument metadata",
        base_intent(),
        OrderTypeGuardConfig::default(),
        context,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::Quantize(
            QuantizeRejectReason::InstrumentMetadataMissing,
        )),
        false,
    );

    let observers = BuildOrderIntentObservers::new();
    let context = base_context(
        observers,
        InstrumentQuantization {
            tick_size: 0.5,
            amount_step: 0.1,
            min_amount: 1.0,
        },
        0.95,
        100.1,
    );
    assert_rejects_without_side_effects(
        "quantization too small",
        base_intent(),
        OrderTypeGuardConfig::default(),
        context,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::Quantize(
            QuantizeRejectReason::TooSmallAfterQuantization,
        )),
        false,
    );
}
