use std::sync::atomic::Ordering;

use soldier_core::execution::{
    BuildOrderIntentContext, BuildOrderIntentObservers, BuildOrderIntentOutcome,
    BuildOrderIntentRejectReason, InstrumentQuantization, IntentClassification, L2BookLevel,
    L2BookSnapshot, LiquidityGateConfig, OrderIntent, OrderType, OrderTypeGuardConfig,
    RecordIntentOutcome, Side, build_order_intent, take_build_order_intent_outcome,
    take_dispatch_trace, with_build_order_intent_context,
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

fn context_for(
    classification: IntentClassification,
    risk_state: RiskState,
    observers: BuildOrderIntentObservers,
) -> BuildOrderIntentContext {
    let now_ms = 1_000;
    BuildOrderIntentContext {
        classification,
        side: Side::Buy,
        raw_qty: 1.2,
        raw_limit_price: 100.1,
        quantization: InstrumentQuantization {
            tick_size: 0.5,
            amount_step: 0.1,
            min_amount: 0.1,
        },
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
        risk_state,
        record_outcome: RecordIntentOutcome::Recorded,
        observers: Some(observers),
    }
}

#[test]
fn open_rejected_when_risk_state_degraded() {
    let observers = BuildOrderIntentObservers::new();
    let intent = base_intent();
    let result = with_build_order_intent_context(
        context_for(
            IntentClassification::Open,
            RiskState::Degraded,
            observers.clone(),
        ),
        || build_order_intent(intent, OrderTypeGuardConfig::default()),
    );
    assert!(result.is_err());

    let outcome = take_build_order_intent_outcome().expect("expected outcome");
    assert_eq!(
        outcome,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::DispatchAuth(
            RiskState::Degraded
        ))
    );
    assert_eq!(observers.dispatch_total.load(Ordering::Relaxed), 0);
    assert!(take_dispatch_trace().is_empty());
}

#[test]
fn close_hedge_cancel_allowed_when_risk_state_degraded() {
    let intent = base_intent();
    let classifications = [
        IntentClassification::Close,
        IntentClassification::Hedge,
        IntentClassification::Cancel,
    ];
    for classification in classifications {
        let observers = BuildOrderIntentObservers::new();
        let result = with_build_order_intent_context(
            context_for(classification, RiskState::Degraded, observers.clone()),
            || build_order_intent(intent, OrderTypeGuardConfig::default()),
        );
        assert!(result.is_ok());
        let outcome = take_build_order_intent_outcome().expect("expected outcome");
        assert_eq!(outcome, BuildOrderIntentOutcome::Allowed);
        assert_eq!(observers.dispatch_total.load(Ordering::Relaxed), 1);
    }
}
