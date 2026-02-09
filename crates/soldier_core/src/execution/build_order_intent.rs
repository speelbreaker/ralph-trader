use std::cell::RefCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::risk::{FeeModelSnapshot, FeeStalenessConfig, RiskState, evaluate_fee_staleness};

use super::{
    InstrumentQuantization, IntentClassification, L2BookSnapshot, LiquidityGateConfig,
    LiquidityGateIntent, LiquidityGateRejectReason, NetEdgeGateIntent, NetEdgeRejectReason,
    OrderIntent, OrderTypeGuardConfig, OrderTypeRejectReason, PreflightReject, PricerIntent,
    QuantizeRejectReason, RejectReason, Side, evaluate_liquidity_gate, evaluate_net_edge_gate,
    preflight, price_ioc_limit, quantize_steps,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateStep {
    Preflight,
    Quantize,
    FeeCache,
    LiquidityGate,
    NetEdgeGate,
    Pricer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchStep {
    RecordIntent,
    DispatchAttempt,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BuildOrderIntentOutcome {
    Allowed,
    Rejected(BuildOrderIntentRejectReason),
}

#[derive(Debug, Clone, PartialEq)]
pub enum BuildOrderIntentRejectReason {
    Preflight(OrderTypeRejectReason),
    MissingContext,
    Quantize(QuantizeRejectReason),
    DispatchAuth(RiskState),
    LiquidityGate(LiquidityGateRejectReason),
    NetEdge(NetEdgeRejectReason),
    Pricer(RejectReason),
    RecordedBeforeDispatch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateSequenceResult {
    Allowed,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordIntentOutcome {
    Recorded,
    Failed,
}

#[derive(Debug, Clone)]
pub struct BuildOrderIntentObservers {
    pub recorded_total: Arc<AtomicU64>,
    pub dispatch_total: Arc<AtomicU64>,
}

impl BuildOrderIntentObservers {
    pub fn new() -> Self {
        Self {
            recorded_total: Arc::new(AtomicU64::new(0)),
            dispatch_total: Arc::new(AtomicU64::new(0)),
        }
    }

    fn record_intent(&self) {
        self.recorded_total.fetch_add(1, Ordering::Relaxed);
    }

    fn record_dispatch(&self) {
        self.dispatch_total.fetch_add(1, Ordering::Relaxed);
    }
}

impl Default for BuildOrderIntentObservers {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone)]
pub struct BuildOrderIntentContext {
    pub classification: IntentClassification,
    pub side: Side,
    pub raw_qty: f64,
    pub raw_limit_price: f64,
    pub quantization: InstrumentQuantization,
    pub fee_model: FeeModelSnapshot,
    pub fee_staleness_config: FeeStalenessConfig,
    pub is_maker: bool,
    pub l2_snapshot: Option<L2BookSnapshot>,
    pub liquidity_config: LiquidityGateConfig,
    pub now_ms: u64,
    pub gross_edge_usd: f64,
    pub min_edge_usd: f64,
    pub fair_price: f64,
    pub risk_state: RiskState,
    pub record_outcome: RecordIntentOutcome,
    pub observers: Option<BuildOrderIntentObservers>,
}

static GATE_SEQUENCE_ALLOWED_TOTAL: AtomicU64 = AtomicU64::new(0);
static GATE_SEQUENCE_REJECTED_TOTAL: AtomicU64 = AtomicU64::new(0);

thread_local! {
    static BUILD_CONTEXT: RefCell<Option<BuildOrderIntentContext>> = RefCell::new(None);
    static GATE_SEQUENCE_TRACE: RefCell<Vec<GateStep>> = RefCell::new(Vec::new());
    static DISPATCH_TRACE: RefCell<Vec<DispatchStep>> = RefCell::new(Vec::new());
    static LAST_OUTCOME: RefCell<Option<BuildOrderIntentOutcome>> = RefCell::new(None);
}

pub fn with_build_order_intent_context<F, R>(context: BuildOrderIntentContext, f: F) -> R
where
    F: FnOnce() -> R,
{
    BUILD_CONTEXT.with(|cell| {
        let previous = cell.borrow_mut().replace(context);
        let result = f();
        *cell.borrow_mut() = previous;
        result
    })
}

pub fn take_gate_sequence_trace() -> Vec<GateStep> {
    GATE_SEQUENCE_TRACE.with(|trace| trace.borrow_mut().drain(..).collect())
}

pub fn take_dispatch_trace() -> Vec<DispatchStep> {
    DISPATCH_TRACE.with(|trace| trace.borrow_mut().drain(..).collect())
}

pub fn take_build_order_intent_outcome() -> Option<BuildOrderIntentOutcome> {
    LAST_OUTCOME.with(|cell| cell.borrow_mut().take())
}

pub fn gate_sequence_total(result: GateSequenceResult) -> u64 {
    match result {
        GateSequenceResult::Allowed => GATE_SEQUENCE_ALLOWED_TOTAL.load(Ordering::Relaxed),
        GateSequenceResult::Rejected => GATE_SEQUENCE_REJECTED_TOTAL.load(Ordering::Relaxed),
    }
}

fn reset_trace() {
    GATE_SEQUENCE_TRACE.with(|trace| trace.borrow_mut().clear());
    DISPATCH_TRACE.with(|trace| trace.borrow_mut().clear());
    LAST_OUTCOME.with(|cell| cell.borrow_mut().take());
}

fn record_gate_step(step: GateStep) {
    GATE_SEQUENCE_TRACE.with(|trace| trace.borrow_mut().push(step));
}

fn record_dispatch_step(step: DispatchStep) {
    DISPATCH_TRACE.with(|trace| trace.borrow_mut().push(step));
}

fn finish_outcome(outcome: BuildOrderIntentOutcome) {
    match outcome {
        BuildOrderIntentOutcome::Allowed => {
            GATE_SEQUENCE_ALLOWED_TOTAL.fetch_add(1, Ordering::Relaxed);
            eprintln!("gate_sequence_total result=allowed");
        }
        BuildOrderIntentOutcome::Rejected(_) => {
            GATE_SEQUENCE_REJECTED_TOTAL.fetch_add(1, Ordering::Relaxed);
            eprintln!("gate_sequence_total result=rejected");
        }
    }
    LAST_OUTCOME.with(|cell| {
        *cell.borrow_mut() = Some(outcome);
    });
}

fn effective_risk_state(primary: RiskState, fallback: RiskState) -> RiskState {
    if primary != RiskState::Healthy {
        return primary;
    }
    fallback
}

fn fee_rate_for_model(model: &FeeModelSnapshot, is_maker: bool) -> f64 {
    if is_maker {
        model.maker_fee_rate
    } else {
        model.taker_fee_rate
    }
}

fn estimate_notional_usd(fair_price: f64, qty: f64) -> f64 {
    fair_price.abs() * qty.abs()
}

fn estimate_slippage_usd(slippage_bps: Option<f64>, notional_usd: f64) -> f64 {
    match slippage_bps {
        Some(bps) => (bps / 10_000.0) * notional_usd,
        None => 0.0,
    }
}

fn finish_reject(reason: BuildOrderIntentRejectReason) {
    finish_outcome(BuildOrderIntentOutcome::Rejected(reason));
}

fn finish_allowed() {
    finish_outcome(BuildOrderIntentOutcome::Allowed);
}

/// build_order_intent runs the deterministic gate sequence and records the outcome via
/// take_build_order_intent_outcome(). Non-preflight gate failures are surfaced through
/// that outcome channel while the returned Result preserves the preflight signature.
pub fn build_order_intent(
    intent: OrderIntent,
    config: OrderTypeGuardConfig,
) -> Result<OrderIntent, PreflightReject> {
    reset_trace();
    record_gate_step(GateStep::Preflight);
    let intent = match preflight::build_order_intent(intent, config) {
        Ok(intent) => intent,
        Err(err) => {
            finish_reject(BuildOrderIntentRejectReason::Preflight(err.reason));
            return Err(err);
        }
    };

    let context = BUILD_CONTEXT.with(|cell| cell.borrow().clone());
    let context = match context {
        Some(context) => context,
        None => {
            finish_reject(BuildOrderIntentRejectReason::MissingContext);
            return Ok(intent);
        }
    };

    record_gate_step(GateStep::Quantize);
    let quantized = match quantize_steps(
        context.side,
        context.raw_qty,
        context.raw_limit_price,
        &context.quantization,
    ) {
        Ok(quantized) => quantized,
        Err(err) => {
            finish_reject(BuildOrderIntentRejectReason::Quantize(err.reason));
            return Ok(intent);
        }
    };

    record_gate_step(GateStep::FeeCache);
    let fee_rate = fee_rate_for_model(&context.fee_model, context.is_maker);
    let fee_decision = evaluate_fee_staleness(
        fee_rate,
        context.now_ms,
        context.fee_model.fee_model_cached_at_ts_ms,
        context.fee_staleness_config,
    );
    let combined_risk_state = effective_risk_state(context.risk_state, fee_decision.risk_state);
    if context.classification == IntentClassification::Open
        && combined_risk_state != RiskState::Healthy
    {
        finish_reject(BuildOrderIntentRejectReason::DispatchAuth(
            combined_risk_state,
        ));
        return Ok(intent);
    }

    record_gate_step(GateStep::LiquidityGate);
    let liquidity_intent = LiquidityGateIntent {
        classification: context.classification,
        side: context.side,
        order_qty: quantized.qty_q,
        l2_snapshot: context.l2_snapshot.as_ref(),
        now_ms: context.now_ms,
    };
    let liquidity_outcome =
        match evaluate_liquidity_gate(&liquidity_intent, context.liquidity_config) {
            Ok(outcome) => outcome,
            Err(err) => {
                finish_reject(BuildOrderIntentRejectReason::LiquidityGate(err.reason));
                return Ok(intent);
            }
        };

    record_gate_step(GateStep::NetEdgeGate);
    let notional_usd = estimate_notional_usd(context.fair_price, quantized.qty_q);
    let expected_slippage_usd = estimate_slippage_usd(liquidity_outcome.slippage_bps, notional_usd);
    let fee_estimate_usd = fee_decision.fee_rate_effective * notional_usd;
    let net_edge_intent = NetEdgeGateIntent {
        classification: context.classification,
        gross_edge_usd: Some(context.gross_edge_usd),
        fee_usd: Some(fee_estimate_usd),
        expected_slippage_usd: Some(expected_slippage_usd),
        min_edge_usd: Some(context.min_edge_usd),
    };
    if let Err(err) = evaluate_net_edge_gate(&net_edge_intent) {
        finish_reject(BuildOrderIntentRejectReason::NetEdge(err.reason));
        return Ok(intent);
    }

    record_gate_step(GateStep::Pricer);
    let pricer_intent = PricerIntent {
        side: context.side,
        fair_price: context.fair_price,
        gross_edge_usd: context.gross_edge_usd,
        fee_estimate_usd,
        min_edge_usd: context.min_edge_usd,
        qty: quantized.qty_q,
    };
    if let Err(err) = price_ioc_limit(&pricer_intent) {
        finish_reject(BuildOrderIntentRejectReason::Pricer(err.reason));
        return Ok(intent);
    }

    record_dispatch_step(DispatchStep::RecordIntent);
    if let Some(observers) = context.observers.as_ref() {
        observers.record_intent();
    }
    if context.record_outcome == RecordIntentOutcome::Failed {
        finish_reject(BuildOrderIntentRejectReason::RecordedBeforeDispatch);
        return Ok(intent);
    }

    record_dispatch_step(DispatchStep::DispatchAttempt);
    if let Some(observers) = context.observers.as_ref() {
        observers.record_dispatch();
    }

    finish_allowed();
    Ok(intent)
}
