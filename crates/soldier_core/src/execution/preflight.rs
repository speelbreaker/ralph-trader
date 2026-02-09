use std::sync::atomic::{AtomicU64, Ordering};

use crate::venue::InstrumentKind;

use super::order_type_guard::{
    validate_order_type, LinkedOrderType, OrderType, OrderTypeGuardConfig, OrderTypeRejectReason,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriggerType {
    IndexPrice,
    MarkPrice,
    LastPrice,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OrderIntent {
    pub instrument_kind: InstrumentKind,
    pub order_type: OrderType,
    pub trigger: Option<TriggerType>,
    pub trigger_price: Option<f64>,
    pub linked_order_type: Option<LinkedOrderType>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreflightReject {
    pub reason: OrderTypeRejectReason,
}

pub struct PreflightMetrics {
    market_forbidden_total: AtomicU64,
    stop_forbidden_total: AtomicU64,
    linked_order_forbidden_total: AtomicU64,
}

impl PreflightMetrics {
    pub const fn new() -> Self {
        Self {
            market_forbidden_total: AtomicU64::new(0),
            stop_forbidden_total: AtomicU64::new(0),
            linked_order_forbidden_total: AtomicU64::new(0),
        }
    }

    pub fn reject_total(&self, reason: OrderTypeRejectReason) -> u64 {
        match reason {
            OrderTypeRejectReason::OrderTypeMarketForbidden => {
                self.market_forbidden_total.load(Ordering::Relaxed)
            }
            OrderTypeRejectReason::OrderTypeStopForbidden => {
                self.stop_forbidden_total.load(Ordering::Relaxed)
            }
            OrderTypeRejectReason::LinkedOrderTypeForbidden => {
                self.linked_order_forbidden_total.load(Ordering::Relaxed)
            }
        }
    }

    fn bump(&self, reason: OrderTypeRejectReason) {
        match reason {
            OrderTypeRejectReason::OrderTypeMarketForbidden => {
                self.market_forbidden_total.fetch_add(1, Ordering::Relaxed);
            }
            OrderTypeRejectReason::OrderTypeStopForbidden => {
                self.stop_forbidden_total.fetch_add(1, Ordering::Relaxed);
            }
            OrderTypeRejectReason::LinkedOrderTypeForbidden => {
                self.linked_order_forbidden_total
                    .fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

static PREFLIGHT_METRICS: PreflightMetrics = PreflightMetrics::new();

pub fn preflight_reject_total(reason: OrderTypeRejectReason) -> u64 {
    PREFLIGHT_METRICS.reject_total(reason)
}

pub fn preflight_intent(
    intent: &OrderIntent,
    config: OrderTypeGuardConfig,
) -> Result<(), PreflightReject> {
    let has_trigger_fields = intent.trigger.is_some() || intent.trigger_price.is_some();
    match validate_order_type(
        intent.instrument_kind,
        intent.order_type,
        has_trigger_fields,
        intent.linked_order_type,
        config,
    ) {
        Ok(()) => Ok(()),
        Err(reason) => Err(reject_with_metrics(reason)),
    }
}

pub fn build_order_intent(
    intent: OrderIntent,
    config: OrderTypeGuardConfig,
) -> Result<OrderIntent, PreflightReject> {
    preflight_intent(&intent, config)?;
    Ok(intent)
}

fn reject_with_metrics(reason: OrderTypeRejectReason) -> PreflightReject {
    PREFLIGHT_METRICS.bump(reason);
    eprintln!("preflight_reject_total reason={:?}", reason);
    PreflightReject { reason }
}
