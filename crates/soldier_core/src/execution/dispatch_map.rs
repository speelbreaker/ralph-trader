use std::sync::atomic::{AtomicU64, Ordering};

use crate::risk::RiskState;
use crate::venue::InstrumentKind;

use super::{OrderSize, contracts_amount_matches};

pub struct DispatchMetrics {
    unit_mismatch_total: AtomicU64,
}

impl DispatchMetrics {
    pub const fn new() -> Self {
        Self {
            unit_mismatch_total: AtomicU64::new(0),
        }
    }

    pub fn unit_mismatch_total(&self) -> u64 {
        self.unit_mismatch_total.load(Ordering::Relaxed)
    }
}

impl Default for DispatchMetrics {
    fn default() -> Self {
        Self::new()
    }
}

static DISPATCH_METRICS: DispatchMetrics = DispatchMetrics::new();

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeribitOrderAmount {
    pub amount: f64,
    pub contracts: Option<i64>,
    pub derived_qty_coin: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchRejectReason {
    UnitMismatch,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DispatchReject {
    pub risk_state: RiskState,
    pub reason: DispatchRejectReason,
    pub mismatch_delta: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntentClassification {
    Open,
    Close,
    Hedge,
    Cancel,
}

pub fn reduce_only_from_intent_classification(
    classification: IntentClassification,
) -> Option<bool> {
    match classification {
        IntentClassification::Close | IntentClassification::Hedge => Some(true),
        IntentClassification::Open | IntentClassification::Cancel => None,
    }
}

pub fn map_order_size_to_deribit_amount(
    instrument_kind: InstrumentKind,
    order_size: &OrderSize,
    contract_multiplier: Option<f64>,
    index_price: f64,
) -> Result<DeribitOrderAmount, DispatchReject> {
    map_order_size_to_deribit_amount_with_metrics(
        &DISPATCH_METRICS,
        instrument_kind,
        order_size,
        contract_multiplier,
        index_price,
    )
}

pub fn map_order_size_to_deribit_amount_with_metrics(
    metrics: &DispatchMetrics,
    instrument_kind: InstrumentKind,
    order_size: &OrderSize,
    contract_multiplier: Option<f64>,
    index_price: f64,
) -> Result<DeribitOrderAmount, DispatchReject> {
    if order_size.qty_coin.is_some() && order_size.qty_usd.is_some() {
        return reject_unit_mismatch(metrics, "both_qty", None);
    }

    let (canonical_amount, derived_qty_coin) = match instrument_kind {
        InstrumentKind::Option | InstrumentKind::LinearFuture => {
            let amount = order_size.qty_coin;
            (amount, amount)
        }
        InstrumentKind::Perpetual | InstrumentKind::InverseFuture => {
            if index_price <= 0.0 {
                return reject_unit_mismatch(metrics, "invalid_index_price", None);
            }
            let amount = order_size.qty_usd;
            let derived_qty_coin = amount.map(|qty_usd| qty_usd / index_price);
            (amount, derived_qty_coin)
        }
    };

    let canonical_amount = match canonical_amount {
        Some(amount) => amount,
        None => return reject_unit_mismatch(metrics, "missing_canonical", None),
    };

    // Derive or Validate contracts
    let derived_contracts = if let Some(multiplier) = contract_multiplier {
        if multiplier > 0.0 {
            Some((canonical_amount / multiplier).round() as i64)
        } else {
            None
        }
    } else {
        None
    };

    if let Some(contracts) = order_size.contracts {
        let multiplier = match contract_multiplier {
            Some(value) => value,
            None => {
                return reject_unit_mismatch(metrics, "missing_multiplier_for_validation", None);
            }
        };
        if !contracts_amount_matches(canonical_amount, contracts, multiplier) {
            let expected = contracts as f64 * multiplier;
            let delta = (canonical_amount - expected).abs();
            return reject_unit_mismatch(metrics, "contracts_mismatch", Some(delta));
        }
    }

    Ok(DeribitOrderAmount {
        amount: canonical_amount,
        contracts: derived_contracts,
        derived_qty_coin,
    })
}

pub fn order_intent_reject_unit_mismatch_total() -> u64 {
    DISPATCH_METRICS.unit_mismatch_total()
}

fn reject_unit_mismatch(
    metrics: &DispatchMetrics,
    reason: &str,
    mismatch_delta: Option<f64>,
) -> Result<DeribitOrderAmount, DispatchReject> {
    metrics.unit_mismatch_total.fetch_add(1, Ordering::Relaxed);
    eprintln!(
        "order_intent_reject_unit_mismatch reason={} mismatch_delta={:?}",
        reason, mismatch_delta
    );
    Err(DispatchReject {
        risk_state: RiskState::Degraded,
        reason: DispatchRejectReason::UnitMismatch,
        mismatch_delta,
    })
}
