use std::sync::atomic::{AtomicU64, Ordering};

use crate::risk::RiskState;
use crate::venue::InstrumentKind;

use super::OrderSize;

const CONTRACTS_AMOUNT_MATCH_TOLERANCE: f64 = 0.001;
const CONTRACTS_AMOUNT_MATCH_EPSILON: f64 = 1e-9;

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
    ContractsAmountMismatch,
    UnitMismatch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DispatchReject {
    pub risk_state: RiskState,
    pub reason: DispatchRejectReason,
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
        return reject_unit_mismatch(metrics, "both_qty");
    }

    let (canonical_amount, derived_qty_coin) = match instrument_kind {
        InstrumentKind::Option | InstrumentKind::LinearFuture => {
            let amount = order_size.qty_coin;
            (amount, amount)
        }
        InstrumentKind::Perpetual | InstrumentKind::InverseFuture => {
            if !index_price.is_finite() || index_price <= 0.0 {
                return reject_unit_mismatch(metrics, "invalid_index_price");
            }
            let amount = order_size.qty_usd;
            let derived_qty_coin = amount.map(|qty_usd| qty_usd / index_price);
            (amount, derived_qty_coin)
        }
    };

    let canonical_amount = match canonical_amount {
        Some(amount) => amount,
        None => return reject_unit_mismatch(metrics, "missing_canonical"),
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
            None => return reject_unit_mismatch(metrics, "missing_multiplier_for_validation"),
        };
        let expected = contracts as f64 * multiplier;
        if !contracts_amount_match(canonical_amount, expected) {
            return reject_contracts_mismatch(metrics, "contracts_mismatch");
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

fn contracts_amount_match(amount: f64, expected: f64) -> bool {
    let denom = amount.abs().max(CONTRACTS_AMOUNT_MATCH_EPSILON);
    (amount - expected).abs() / denom <= CONTRACTS_AMOUNT_MATCH_TOLERANCE
}

fn reject_unit_mismatch(
    metrics: &DispatchMetrics,
    reason: &str,
) -> Result<DeribitOrderAmount, DispatchReject> {
    metrics.unit_mismatch_total.fetch_add(1, Ordering::Relaxed);
    eprintln!("order_intent_reject_unit_mismatch reason={}", reason);
    Err(DispatchReject {
        risk_state: RiskState::Degraded,
        reason: DispatchRejectReason::UnitMismatch,
    })
}

fn reject_contracts_mismatch(
    metrics: &DispatchMetrics,
    reason: &str,
) -> Result<DeribitOrderAmount, DispatchReject> {
    metrics.unit_mismatch_total.fetch_add(1, Ordering::Relaxed);
    eprintln!("order_intent_reject_contracts_mismatch reason={}", reason);
    Err(DispatchReject {
        risk_state: RiskState::Degraded,
        reason: DispatchRejectReason::ContractsAmountMismatch,
    })
}
