use std::sync::atomic::Ordering;

use soldier_core::execution::{
    BuildOrderIntentContext, BuildOrderIntentObservers, BuildOrderIntentOutcome,
    BuildOrderIntentRejectReason, DispatchStep, GateStep, InstrumentQuantization,
    IntentClassification, L2BookLevel, L2BookSnapshot, LiquidityGateConfig,
    LiquidityGateRejectReason, NetEdgeRejectReason, OrderIntent, OrderType, OrderTypeGuardConfig,
    QuantizeRejectReason, RecordIntentOutcome, Side, build_order_intent,
    take_build_order_intent_outcome, take_dispatch_trace, take_gate_sequence_trace,
    with_build_order_intent_context,
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

fn context_for_open(observers: BuildOrderIntentObservers) -> BuildOrderIntentContext {
    let now_ms = 1_000;
    BuildOrderIntentContext {
        classification: IntentClassification::Open,
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
        risk_state: RiskState::Healthy,
        record_outcome: RecordIntentOutcome::Recorded,
        observers: Some(observers),
    }
}

#[test]
fn gate_sequence_is_deterministic_for_open() {
    let observers = BuildOrderIntentObservers::new();
    let intent = base_intent();
    let result = with_build_order_intent_context(context_for_open(observers.clone()), || {
        build_order_intent(intent, OrderTypeGuardConfig::default())
    });
    assert!(result.is_ok());

    let steps = take_gate_sequence_trace();
    assert_eq!(
        steps,
        vec![
            GateStep::Preflight,
            GateStep::Quantize,
            GateStep::FeeCache,
            GateStep::LiquidityGate,
            GateStep::NetEdgeGate,
            GateStep::Pricer,
        ]
    );

    let dispatch_steps = take_dispatch_trace();
    assert_eq!(
        dispatch_steps,
        vec![DispatchStep::RecordIntent, DispatchStep::DispatchAttempt]
    );

    let outcome = take_build_order_intent_outcome().expect("expected outcome");
    assert_eq!(outcome, BuildOrderIntentOutcome::Allowed);
    assert_eq!(observers.recorded_total.load(Ordering::Relaxed), 1);
    assert_eq!(observers.dispatch_total.load(Ordering::Relaxed), 1);
}

#[test]
fn test_gate_ordering_constraints() {
    let observers = BuildOrderIntentObservers::new();
    let mut context = context_for_open(observers.clone());
    context.risk_state = RiskState::Degraded;
    let intent = base_intent();
    let result = with_build_order_intent_context(context, || {
        build_order_intent(intent, OrderTypeGuardConfig::default())
    });
    assert!(result.is_err());

    let outcome = take_build_order_intent_outcome().expect("expected outcome");
    assert_eq!(
        outcome,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::DispatchAuth(
            RiskState::Degraded
        ))
    );
    assert!(take_dispatch_trace().is_empty());
    assert_eq!(observers.recorded_total.load(Ordering::Relaxed), 0);
    assert_eq!(observers.dispatch_total.load(Ordering::Relaxed), 0);

    let observers = BuildOrderIntentObservers::new();
    let intent = base_intent();
    let result = with_build_order_intent_context(context_for_open(observers.clone()), || {
        build_order_intent(intent, OrderTypeGuardConfig::default())
    });
    assert!(result.is_ok());
    assert_eq!(
        take_dispatch_trace(),
        vec![DispatchStep::RecordIntent, DispatchStep::DispatchAttempt]
    );
    let outcome = take_build_order_intent_outcome().expect("expected outcome");
    assert_eq!(outcome, BuildOrderIntentOutcome::Allowed);
    assert_eq!(observers.recorded_total.load(Ordering::Relaxed), 1);
    assert_eq!(observers.dispatch_total.load(Ordering::Relaxed), 1);

    let observers = BuildOrderIntentObservers::new();
    let mut context = context_for_open(observers.clone());
    context.record_outcome = RecordIntentOutcome::Failed;
    let intent = base_intent();
    let result = with_build_order_intent_context(context, || {
        build_order_intent(intent, OrderTypeGuardConfig::default())
    });
    assert!(result.is_err());
    assert_eq!(take_dispatch_trace(), vec![DispatchStep::RecordIntent]);
    let outcome = take_build_order_intent_outcome().expect("expected outcome");
    assert_eq!(
        outcome,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::RecordedBeforeDispatch)
    );
    assert_eq!(observers.recorded_total.load(Ordering::Relaxed), 1);
    assert_eq!(observers.dispatch_total.load(Ordering::Relaxed), 0);
}

fn with_invalid_quantization(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.quantization.tick_size = 0.0;
    context
}

fn with_missing_l2(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.l2_snapshot = None;
    context
}

fn with_missing_net_edge_input(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.min_edge_usd = f64::NAN;
    context
}

#[test]
fn test_gate_reject_matrix_stops_before_dispatch() {
    struct Case {
        name: &'static str,
        mutate: fn(BuildOrderIntentContext) -> BuildOrderIntentContext,
        expected_outcome: BuildOrderIntentOutcome,
        expected_trace: Vec<GateStep>,
    }

    let cases = [
        Case {
            name: "quantize_missing_metadata",
            mutate: with_invalid_quantization,
            expected_outcome: BuildOrderIntentOutcome::Rejected(
                BuildOrderIntentRejectReason::Quantize(
                    QuantizeRejectReason::InstrumentMetadataMissing,
                ),
            ),
            expected_trace: vec![GateStep::Preflight, GateStep::Quantize],
        },
        Case {
            name: "liquidity_no_l2",
            mutate: with_missing_l2,
            expected_outcome: BuildOrderIntentOutcome::Rejected(
                BuildOrderIntentRejectReason::LiquidityGate(
                    LiquidityGateRejectReason::LiquidityGateNoL2,
                ),
            ),
            expected_trace: vec![
                GateStep::Preflight,
                GateStep::Quantize,
                GateStep::FeeCache,
                GateStep::LiquidityGate,
            ],
        },
        Case {
            name: "net_edge_input_missing",
            mutate: with_missing_net_edge_input,
            expected_outcome: BuildOrderIntentOutcome::Rejected(
                BuildOrderIntentRejectReason::NetEdge(NetEdgeRejectReason::NetEdgeInputMissing),
            ),
            expected_trace: vec![
                GateStep::Preflight,
                GateStep::Quantize,
                GateStep::FeeCache,
                GateStep::LiquidityGate,
                GateStep::NetEdgeGate,
            ],
        },
    ];

    for case in cases {
        let observers = BuildOrderIntentObservers::new();
        let context = (case.mutate)(context_for_open(observers.clone()));
        let result = with_build_order_intent_context(context, || {
            build_order_intent(base_intent(), OrderTypeGuardConfig::default())
        });
        assert!(result.is_err(), "{} should reject", case.name);

        let outcome = take_build_order_intent_outcome().expect("expected outcome");
        assert_eq!(outcome, case.expected_outcome, "{}", case.name);
        assert_eq!(
            take_gate_sequence_trace(),
            case.expected_trace,
            "{} trace mismatch",
            case.name
        );
        assert!(
            take_dispatch_trace().is_empty(),
            "{} should not record/dispatch",
            case.name
        );
        assert_eq!(
            observers.recorded_total.load(Ordering::Relaxed),
            0,
            "{} should not record intent",
            case.name
        );
        assert_eq!(
            observers.dispatch_total.load(Ordering::Relaxed),
            0,
            "{} should not dispatch intent",
            case.name
        );
    }
}

#[test]
fn test_missing_context_rejects_after_preflight_only() {
    let result = build_order_intent(base_intent(), OrderTypeGuardConfig::default());
    assert!(result.is_err(), "missing context should reject");
    let outcome = take_build_order_intent_outcome().expect("expected missing-context outcome");
    assert_eq!(
        outcome,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::MissingContext)
    );
    assert_eq!(take_gate_sequence_trace(), vec![GateStep::Preflight]);
    assert!(take_dispatch_trace().is_empty());
}
