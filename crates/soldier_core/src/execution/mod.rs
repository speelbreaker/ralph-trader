mod build_order_intent;
pub mod dispatch_map;
pub mod gate;
pub mod gates;
pub mod label;
pub mod order_size;
pub mod order_type_guard;
pub mod post_only_guard;
mod preflight;
pub mod pricer;
pub mod quantize;
pub mod state;
pub mod tlsm;

pub use build_order_intent::{
    BuildOrderIntentContext, BuildOrderIntentError, BuildOrderIntentObservers,
    BuildOrderIntentOutcome, BuildOrderIntentRejectReason, DispatchStep, GateSequenceResult,
    GateStep, RecordIntentOutcome, build_order_intent, gate_sequence_total,
    take_build_order_intent_outcome, take_dispatch_trace, take_gate_sequence_trace,
    with_build_order_intent_context,
};
pub use dispatch_map::{
    DeribitOrderAmount, DispatchMetrics, DispatchReject, DispatchRejectReason,
    IntentClassification, map_order_size_to_deribit_amount,
    map_order_size_to_deribit_amount_with_metrics, order_intent_reject_unit_mismatch_total,
    reduce_only_from_intent_classification,
};
pub use gate::{
    L2BookLevel, L2BookSnapshot, LiquidityGateConfig, LiquidityGateIntent, LiquidityGateOutcome,
    LiquidityGateReject, LiquidityGateRejectReason, evaluate_liquidity_gate,
    expected_slippage_bps_samples, liquidity_gate_reject_total,
};
pub use gates::{
    NetEdgeGateIntent, NetEdgeGateOutcome, NetEdgeReject, NetEdgeRejectReason,
    evaluate_net_edge_gate, net_edge_reject_total,
};
pub use label::{
    CompactLabelParts, LabelDecodeError, LabelEncodeReject, LabelRejectReason,
    decode_compact_label, encode_compact_label, encode_compact_label_with_hashes,
};
pub use order_size::{
    CONTRACTS_AMOUNT_MATCH_EPSILON, CONTRACTS_AMOUNT_MATCH_TOLERANCE, OrderSize, OrderSizeError,
    contracts_amount_matches,
};
pub use order_type_guard::{
    LinkedOrderType, OrderType, OrderTypeGuardConfig, OrderTypeRejectReason,
};
pub use post_only_guard::{
    PostOnlyIntent, PostOnlyReject, PostOnlyRejectReason, post_only_cross_reject_total,
    preflight_post_only,
};
pub use preflight::{
    OrderIntent, PreflightReject, TriggerType, preflight_intent, preflight_reject_total,
};
pub use pricer::{PricerIntent, PricerOutcome, PricerReject, price_ioc_limit};
pub use quantize::{
    InstrumentQuantization, QuantizeReject, QuantizeRejectReason, QuantizedFields, QuantizedSteps,
    Side, quantization_reject_too_small_total, quantize, quantize_from_metadata, quantize_steps,
};
pub use state::{TlsmEvent, TlsmIntent, TlsmLedgerEntry, TlsmSide, TlsmState};
pub use tlsm::{
    Tlsm, TlsmError, TlsmLedger, TlsmLedgerError, TlsmTransition, tlsm_out_of_order_total,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    UnitMismatch,
    NetEdgeTooLow,
}

impl From<DispatchRejectReason> for RejectReason {
    fn from(reason: DispatchRejectReason) -> Self {
        match reason {
            DispatchRejectReason::UnitMismatch => RejectReason::UnitMismatch,
        }
    }
}

impl PartialEq<RejectReason> for DispatchRejectReason {
    fn eq(&self, other: &RejectReason) -> bool {
        matches!(
            (self, other),
            (
                DispatchRejectReason::UnitMismatch,
                RejectReason::UnitMismatch
            )
        )
    }
}

impl PartialEq<DispatchRejectReason> for RejectReason {
    fn eq(&self, other: &DispatchRejectReason) -> bool {
        other == self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreflightGuardRejectReason {
    OrderType(OrderTypeRejectReason),
    PostOnly(PostOnlyRejectReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreflightGuardReject {
    pub reason: PreflightGuardRejectReason,
}

pub fn preflight_intent_with_post_only(
    intent: &OrderIntent,
    config: OrderTypeGuardConfig,
    post_only_intent: &PostOnlyIntent,
) -> Result<(), PreflightGuardReject> {
    preflight::preflight_intent(intent, config).map_err(|err| PreflightGuardReject {
        reason: PreflightGuardRejectReason::OrderType(err.reason),
    })?;
    post_only_guard::preflight_post_only(post_only_intent).map_err(|err| PreflightGuardReject {
        reason: PreflightGuardRejectReason::PostOnly(err.reason),
    })?;
    Ok(())
}
