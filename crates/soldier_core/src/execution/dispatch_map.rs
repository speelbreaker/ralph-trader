use std::sync::atomic::{AtomicU64, Ordering};

use crate::risk::RiskState;
use crate::venue::InstrumentKind;

use super::OrderSize;

const UNIT_MISMATCH_EPSILON: f64 = 1e-9;

static ORDER_INTENT_REJECT_UNIT_MISMATCH_TOTAL: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeribitOrderAmount {
    pub amount: f64,
    pub derived_qty_coin: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchRejectReason {
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
    if order_size.qty_coin.is_some() && order_size.qty_usd.is_some() {
        return reject_unit_mismatch("both_qty");
    }

    let (canonical_amount, derived_qty_coin) = match instrument_kind {
        InstrumentKind::Option | InstrumentKind::LinearFuture => {
            let amount = order_size.qty_coin;
            (amount, amount)
        }
        InstrumentKind::Perpetual | InstrumentKind::InverseFuture => {
            if index_price <= 0.0 {
                return reject_unit_mismatch("invalid_index_price");
            }
            let amount = order_size.qty_usd;
            let derived_qty_coin = amount.map(|qty_usd| qty_usd / index_price);
            (amount, derived_qty_coin)
        }
    };

    let canonical_amount = match canonical_amount {
        Some(amount) => amount,
        None => return reject_unit_mismatch("missing_canonical"),
    };

    if let Some(contracts) = order_size.contracts {
        let multiplier = match contract_multiplier {
            Some(value) => value,
            None => return reject_unit_mismatch("missing_multiplier"),
        };
        let expected = contracts as f64 * multiplier;
        if !approx_eq(canonical_amount, expected, UNIT_MISMATCH_EPSILON) {
            return reject_unit_mismatch("contracts_mismatch");
        }
    }

    Ok(DeribitOrderAmount {
        amount: canonical_amount,
        derived_qty_coin,
    })
}

pub fn order_intent_reject_unit_mismatch_total() -> u64 {
    ORDER_INTENT_REJECT_UNIT_MISMATCH_TOTAL.load(Ordering::Relaxed)
}

fn approx_eq(lhs: f64, rhs: f64, epsilon: f64) -> bool {
    (lhs - rhs).abs() <= epsilon
}

fn reject_unit_mismatch(reason: &str) -> Result<DeribitOrderAmount, DispatchReject> {
    ORDER_INTENT_REJECT_UNIT_MISMATCH_TOTAL.fetch_add(1, Ordering::Relaxed);
    eprintln!("order_intent_reject_unit_mismatch reason={}", reason);
    Err(DispatchReject {
        risk_state: RiskState::Degraded,
        reason: DispatchRejectReason::UnitMismatch,
    })
}
