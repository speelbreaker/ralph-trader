use std::sync::atomic::{AtomicU64, Ordering};

use super::IntentClassification;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetEdgeRejectReason {
    NetEdgeTooLow,
    NetEdgeInputMissing,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetEdgeReject {
    pub reason: NetEdgeRejectReason,
    pub net_edge_usd: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetEdgeGateOutcome {
    pub net_edge_usd: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetEdgeGateIntent {
    pub classification: IntentClassification,
    pub gross_edge_usd: Option<f64>,
    pub fee_usd: Option<f64>,
    pub expected_slippage_usd: Option<f64>,
    pub min_edge_usd: Option<f64>,
}

pub struct NetEdgeGateMetrics {
    reject_too_low_total: AtomicU64,
    reject_input_missing_total: AtomicU64,
}

impl Default for NetEdgeGateMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl NetEdgeGateMetrics {
    pub const fn new() -> Self {
        Self {
            reject_too_low_total: AtomicU64::new(0),
            reject_input_missing_total: AtomicU64::new(0),
        }
    }

    pub fn reject_total(&self, reason: NetEdgeRejectReason) -> u64 {
        match reason {
            NetEdgeRejectReason::NetEdgeTooLow => self.reject_too_low_total.load(Ordering::Relaxed),
            NetEdgeRejectReason::NetEdgeInputMissing => {
                self.reject_input_missing_total.load(Ordering::Relaxed)
            }
        }
    }

    fn bump_reject(&self, reason: NetEdgeRejectReason) {
        match reason {
            NetEdgeRejectReason::NetEdgeTooLow => {
                self.reject_too_low_total.fetch_add(1, Ordering::Relaxed);
            }
            NetEdgeRejectReason::NetEdgeInputMissing => {
                self.reject_input_missing_total
                    .fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

static NET_EDGE_GATE_METRICS: NetEdgeGateMetrics = NetEdgeGateMetrics::new();

pub fn net_edge_reject_total(reason: NetEdgeRejectReason) -> u64 {
    NET_EDGE_GATE_METRICS.reject_total(reason)
}

pub fn evaluate_net_edge_gate(
    intent: &NetEdgeGateIntent,
) -> Result<NetEdgeGateOutcome, NetEdgeReject> {
    if intent.classification != IntentClassification::Open {
        return Ok(NetEdgeGateOutcome { net_edge_usd: None });
    }

    let gross = parse_input(intent.gross_edge_usd)?;
    let fee = parse_input(intent.fee_usd)?;
    let slippage = parse_input(intent.expected_slippage_usd)?;
    let min_edge = parse_input(intent.min_edge_usd)?;

    let net_edge_usd = gross - fee - slippage;
    if !net_edge_usd.is_finite() {
        return Err(reject_missing());
    }

    if net_edge_usd < min_edge {
        return Err(reject_with_metrics(
            NetEdgeRejectReason::NetEdgeTooLow,
            Some(net_edge_usd),
        ));
    }

    Ok(NetEdgeGateOutcome {
        net_edge_usd: Some(net_edge_usd),
    })
}

fn parse_input(value: Option<f64>) -> Result<f64, NetEdgeReject> {
    match value {
        Some(value) if value.is_finite() => Ok(value),
        _ => Err(reject_missing()),
    }
}

fn reject_missing() -> NetEdgeReject {
    reject_with_metrics(NetEdgeRejectReason::NetEdgeInputMissing, None)
}

fn reject_with_metrics(reason: NetEdgeRejectReason, net_edge_usd: Option<f64>) -> NetEdgeReject {
    NET_EDGE_GATE_METRICS.bump_reject(reason);
    eprintln!("net_edge_reject_total reason={:?}", reason);
    eprintln!(
        "NetEdgeReject reason={:?} net_edge_usd={:?}",
        reason, net_edge_usd
    );
    NetEdgeReject {
        reason,
        net_edge_usd,
    }
}
