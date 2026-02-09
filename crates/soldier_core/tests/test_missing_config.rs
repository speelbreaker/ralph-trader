use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::Ordering;

use soldier_core::execution::{
    BuildOrderIntentContext, BuildOrderIntentObservers, BuildOrderIntentOutcome,
    BuildOrderIntentRejectReason, InstrumentQuantization, IntentClassification, L2BookLevel,
    L2BookSnapshot, LiquidityGateConfig, LiquidityGateRejectReason, NetEdgeRejectReason,
    OrderIntent, OrderType, OrderTypeGuardConfig, QuantizeRejectReason, RecordIntentOutcome, Side,
    build_order_intent, take_build_order_intent_outcome, take_dispatch_trace,
    with_build_order_intent_context,
};
use soldier_core::risk::{FeeModelSnapshot, FeeStalenessConfig, RiskState};
use soldier_core::venue::InstrumentKind;

const CONFIG_MISSING_REASON: &str = "CONFIG_MISSING";

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum CriticalKey {
    InstrumentTickSize,
    InstrumentAmountStep,
    InstrumentMinAmount,
    L2BookSnapshot,
    FeeModelCachedAtTsMs,
    NetEdgeMinUsd,
}

impl CriticalKey {
    fn as_str(self) -> &'static str {
        match self {
            CriticalKey::InstrumentTickSize => "INSTRUMENT_TICK_SIZE",
            CriticalKey::InstrumentAmountStep => "INSTRUMENT_AMOUNT_STEP",
            CriticalKey::InstrumentMinAmount => "INSTRUMENT_MIN_AMOUNT",
            CriticalKey::L2BookSnapshot => "L2_BOOK_SNAPSHOT",
            CriticalKey::FeeModelCachedAtTsMs => "FEE_MODEL_CACHED_AT_TS_MS",
            CriticalKey::NetEdgeMinUsd => "NET_EDGE_MIN_USD",
        }
    }
}

struct MissingCase {
    key: CriticalKey,
    apply: fn(BuildOrderIntentContext) -> BuildOrderIntentContext,
    expected: BuildOrderIntentRejectReason,
}

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

fn base_context(observers: BuildOrderIntentObservers) -> BuildOrderIntentContext {
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

fn missing_tick_size(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.quantization.tick_size = 0.0;
    context
}

fn missing_amount_step(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.quantization.amount_step = 0.0;
    context
}

fn missing_min_amount(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.quantization.min_amount = -1.0;
    context
}

fn missing_l2_snapshot(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.l2_snapshot = None;
    context
}

fn missing_fee_model_cached_at(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.fee_model.fee_model_cached_at_ts_ms = None;
    context
}

fn missing_net_edge_min(mut context: BuildOrderIntentContext) -> BuildOrderIntentContext {
    context.min_edge_usd = f64::NAN;
    context
}

fn assert_rejects_without_side_effects(
    name: &str,
    context: BuildOrderIntentContext,
    expected: BuildOrderIntentRejectReason,
) {
    let observers = context
        .observers
        .as_ref()
        .expect("expected observers")
        .clone();
    let result = with_build_order_intent_context(context, || {
        build_order_intent(base_intent(), OrderTypeGuardConfig::default())
    });
    assert!(result.is_ok(), "{name} expected non-preflight rejection");

    let outcome = take_build_order_intent_outcome().expect("expected outcome");
    assert_eq!(
        outcome,
        BuildOrderIntentOutcome::Rejected(expected),
        "{name} outcome mismatch"
    );

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

fn repo_root() -> PathBuf {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .and_then(|path| path.parent())
        .map(|path| path.to_path_buf())
        .expect("repo root")
}

fn python_exe() -> String {
    std::env::var("PYTHON").unwrap_or_else(|_| "python3".to_string())
}

fn write_config_matrix(results: &BTreeMap<CriticalKey, &'static str>) {
    let mut entries = Vec::with_capacity(results.len());
    for (key, status) in results {
        entries.push(format!(
            "\"{}\": {{\"status\": \"{}\", \"reason\": \"{}\"}}",
            key.as_str(),
            status,
            CONFIG_MISSING_REASON
        ));
    }
    let payload = format!("{{{}}}", entries.join(", "));
    let python = python_exe();
    let status = Command::new(&python)
        .current_dir(repo_root())
        .arg("tools/phase1_evidence.py")
        .arg("config-matrix")
        .arg(payload)
        .status()
        .expect("run config-matrix evidence writer");
    assert!(status.success(), "config-matrix writer failed");
}

#[test]
fn test_missing_config_fails_closed() {
    let cases = [
        MissingCase {
            key: CriticalKey::InstrumentTickSize,
            apply: missing_tick_size,
            expected: BuildOrderIntentRejectReason::Quantize(
                QuantizeRejectReason::InstrumentMetadataMissing,
            ),
        },
        MissingCase {
            key: CriticalKey::InstrumentAmountStep,
            apply: missing_amount_step,
            expected: BuildOrderIntentRejectReason::Quantize(
                QuantizeRejectReason::InstrumentMetadataMissing,
            ),
        },
        MissingCase {
            key: CriticalKey::InstrumentMinAmount,
            apply: missing_min_amount,
            expected: BuildOrderIntentRejectReason::Quantize(
                QuantizeRejectReason::InstrumentMetadataMissing,
            ),
        },
        MissingCase {
            key: CriticalKey::L2BookSnapshot,
            apply: missing_l2_snapshot,
            expected: BuildOrderIntentRejectReason::LiquidityGate(
                LiquidityGateRejectReason::LiquidityGateNoL2,
            ),
        },
        MissingCase {
            key: CriticalKey::FeeModelCachedAtTsMs,
            apply: missing_fee_model_cached_at,
            expected: BuildOrderIntentRejectReason::DispatchAuth(RiskState::Degraded),
        },
        MissingCase {
            key: CriticalKey::NetEdgeMinUsd,
            apply: missing_net_edge_min,
            expected: BuildOrderIntentRejectReason::NetEdge(
                NetEdgeRejectReason::NetEdgeInputMissing,
            ),
        },
    ];

    let mut results: BTreeMap<CriticalKey, &'static str> = BTreeMap::new();
    for case in cases {
        let observers = BuildOrderIntentObservers::new();
        let context = (case.apply)(base_context(observers));
        assert_rejects_without_side_effects(case.key.as_str(), context, case.expected);
        results.insert(case.key, "PASS");
    }

    write_config_matrix(&results);
}
