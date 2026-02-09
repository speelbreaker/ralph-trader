pub mod dispatch_map;
pub mod label;
pub mod order_size;
pub mod order_type_guard;
pub mod post_only_guard;
pub mod preflight;
pub mod quantize;
pub mod state;
pub mod tlsm;

pub use dispatch_map::{
    map_order_size_to_deribit_amount, map_order_size_to_deribit_amount_with_metrics,
    order_intent_reject_unit_mismatch_total, reduce_only_from_intent_classification,
    DeribitOrderAmount, DispatchMetrics, DispatchReject, DispatchRejectReason,
    IntentClassification,
};
pub type RejectReason = DispatchRejectReason;
pub use label::{
    decode_compact_label, encode_compact_label, encode_compact_label_with_hashes,
    CompactLabelParts, LabelDecodeError, LabelEncodeReject, LabelRejectReason,
};
pub use order_size::{
    contracts_amount_matches, OrderSize, OrderSizeError, CONTRACTS_AMOUNT_MATCH_EPSILON,
    CONTRACTS_AMOUNT_MATCH_TOLERANCE,
};
pub use order_type_guard::{
    LinkedOrderType, OrderType, OrderTypeGuardConfig, OrderTypeRejectReason,
};
pub use post_only_guard::{
    post_only_cross_reject_total, preflight_post_only, PostOnlyIntent, PostOnlyReject,
    PostOnlyRejectReason,
};
pub use preflight::{
    build_order_intent, preflight_intent, preflight_reject_total, OrderIntent, PreflightReject,
    TriggerType,
};
pub use quantize::{
    quantization_reject_too_small_total, quantize, quantize_from_metadata, quantize_steps,
    InstrumentQuantization, QuantizeReject, QuantizeRejectReason, QuantizedFields, QuantizedSteps,
    Side,
};
pub use state::{TlsmEvent, TlsmIntent, TlsmLedgerEntry, TlsmSide, TlsmState};
pub use tlsm::{
    tlsm_out_of_order_total, Tlsm, TlsmError, TlsmLedger, TlsmLedgerError, TlsmTransition,
};

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
