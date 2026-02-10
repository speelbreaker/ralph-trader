use std::sync::atomic::{AtomicU64, Ordering};

use super::{IntentClassification, Side};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct L2BookLevel {
    pub price: f64,
    pub qty: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct L2BookSnapshot {
    pub bids: Vec<L2BookLevel>,
    pub asks: Vec<L2BookLevel>,
    pub ts_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiquidityGateConfig {
    pub max_slippage_bps: f64,
    pub l2_book_snapshot_max_age_ms: u64,
}

impl Default for LiquidityGateConfig {
    fn default() -> Self {
        Self {
            max_slippage_bps: 10.0,
            l2_book_snapshot_max_age_ms: 1000,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LiquidityGateRejectReason {
    ExpectedSlippageTooHigh,
    LiquidityGateNoL2,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiquidityGateReject {
    pub reason: LiquidityGateRejectReason,
    pub wap: Option<f64>,
    pub slippage_bps: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiquidityGateOutcome {
    pub wap: Option<f64>,
    pub slippage_bps: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiquidityGateIntent<'a> {
    pub classification: IntentClassification,
    pub side: Side,
    pub order_qty: f64,
    pub l2_snapshot: Option<&'a L2BookSnapshot>,
    pub now_ms: u64,
}

pub struct LiquidityGateMetrics {
    expected_slippage_samples: AtomicU64,
    reject_expected_slippage_total: AtomicU64,
    reject_no_l2_total: AtomicU64,
}

impl Default for LiquidityGateMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl LiquidityGateMetrics {
    pub const fn new() -> Self {
        Self {
            expected_slippage_samples: AtomicU64::new(0),
            reject_expected_slippage_total: AtomicU64::new(0),
            reject_no_l2_total: AtomicU64::new(0),
        }
    }

    pub fn reject_total(&self, reason: LiquidityGateRejectReason) -> u64 {
        match reason {
            LiquidityGateRejectReason::ExpectedSlippageTooHigh => {
                self.reject_expected_slippage_total.load(Ordering::Relaxed)
            }
            LiquidityGateRejectReason::LiquidityGateNoL2 => {
                self.reject_no_l2_total.load(Ordering::Relaxed)
            }
        }
    }

    pub fn expected_slippage_samples(&self) -> u64 {
        self.expected_slippage_samples.load(Ordering::Relaxed)
    }

    fn bump_reject(&self, reason: LiquidityGateRejectReason) {
        match reason {
            LiquidityGateRejectReason::ExpectedSlippageTooHigh => {
                self.reject_expected_slippage_total
                    .fetch_add(1, Ordering::Relaxed);
            }
            LiquidityGateRejectReason::LiquidityGateNoL2 => {
                self.reject_no_l2_total.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    fn record_expected_slippage(&self) {
        self.expected_slippage_samples
            .fetch_add(1, Ordering::Relaxed);
    }
}

static LIQUIDITY_GATE_METRICS: LiquidityGateMetrics = LiquidityGateMetrics::new();

pub fn liquidity_gate_reject_total(reason: LiquidityGateRejectReason) -> u64 {
    LIQUIDITY_GATE_METRICS.reject_total(reason)
}

pub fn expected_slippage_bps_samples() -> u64 {
    LIQUIDITY_GATE_METRICS.expected_slippage_samples()
}

pub fn evaluate_liquidity_gate(
    intent: &LiquidityGateIntent<'_>,
    config: LiquidityGateConfig,
) -> Result<LiquidityGateOutcome, LiquidityGateReject> {
    if intent.classification == IntentClassification::Cancel {
        return Ok(LiquidityGateOutcome {
            wap: None,
            slippage_bps: None,
        });
    }

    let snapshot = match intent.l2_snapshot {
        Some(snapshot) => snapshot,
        None => return Err(reject_no_l2(None, None)),
    };

    if !is_fresh(
        intent.now_ms,
        snapshot.ts_ms,
        config.l2_book_snapshot_max_age_ms,
    ) {
        return Err(reject_no_l2(None, None));
    }

    let levels = match validated_levels(snapshot, intent.side) {
        Some(levels) => levels,
        None => return Err(reject_no_l2(None, None)),
    };

    if intent.classification != IntentClassification::Open {
        return Ok(LiquidityGateOutcome {
            wap: None,
            slippage_bps: None,
        });
    }

    let stats = match compute_wap_and_slippage(intent.order_qty, intent.side, &levels) {
        Some(stats) => stats,
        None => return Err(reject_no_l2(None, None)),
    };

    record_expected_slippage(stats.slippage_bps);

    if stats.slippage_bps > config.max_slippage_bps {
        return Err(reject_slippage(stats));
    }

    Ok(LiquidityGateOutcome {
        wap: Some(stats.wap),
        slippage_bps: Some(stats.slippage_bps),
    })
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct LiquidityGateStats {
    wap: f64,
    slippage_bps: f64,
}

fn reject_slippage(stats: LiquidityGateStats) -> LiquidityGateReject {
    reject_with_metrics(
        LiquidityGateRejectReason::ExpectedSlippageTooHigh,
        Some(stats.wap),
        Some(stats.slippage_bps),
    )
}

fn reject_no_l2(wap: Option<f64>, slippage_bps: Option<f64>) -> LiquidityGateReject {
    reject_with_metrics(
        LiquidityGateRejectReason::LiquidityGateNoL2,
        wap,
        slippage_bps,
    )
}

fn reject_with_metrics(
    reason: LiquidityGateRejectReason,
    wap: Option<f64>,
    slippage_bps: Option<f64>,
) -> LiquidityGateReject {
    LIQUIDITY_GATE_METRICS.bump_reject(reason);
    eprintln!("liquidity_gate_reject_total reason={:?}", reason);
    eprintln!(
        "LiquidityGateReject reason={:?} wap={:?} slippage_bps={:?}",
        reason, wap, slippage_bps
    );
    LiquidityGateReject {
        reason,
        wap,
        slippage_bps,
    }
}

fn record_expected_slippage(slippage_bps: f64) {
    LIQUIDITY_GATE_METRICS.record_expected_slippage();
    eprintln!("expected_slippage_bps value={}", slippage_bps);
}

fn is_fresh(now_ms: u64, ts_ms: u64, max_age_ms: u64) -> bool {
    if now_ms < ts_ms {
        return false;
    }
    now_ms - ts_ms <= max_age_ms
}

fn validated_levels(snapshot: &L2BookSnapshot, side: Side) -> Option<Vec<L2BookLevel>> {
    let levels = match side {
        Side::Buy => &snapshot.asks,
        Side::Sell => &snapshot.bids,
    };
    if levels.is_empty() {
        return None;
    }

    let mut cleaned = Vec::with_capacity(levels.len());
    for level in levels {
        if !level.price.is_finite()
            || !level.qty.is_finite()
            || level.price <= 0.0
            || level.qty <= 0.0
        {
            return None;
        }
        cleaned.push(*level);
    }

    if cleaned.is_empty() {
        return None;
    }

    cleaned.sort_by(|a, b| {
        a.price
            .partial_cmp(&b.price)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if side == Side::Sell {
        cleaned.reverse();
    }

    Some(cleaned)
}

fn compute_wap_and_slippage(
    order_qty: f64,
    side: Side,
    levels: &[L2BookLevel],
) -> Option<LiquidityGateStats> {
    if !order_qty.is_finite() || order_qty <= 0.0 {
        return None;
    }

    let best_price = levels.first()?.price;
    if !best_price.is_finite() || best_price <= 0.0 {
        return None;
    }

    let mut remaining = order_qty;
    let mut cost = 0.0;
    for level in levels {
        let take_qty = remaining.min(level.qty);
        cost += take_qty * level.price;
        remaining -= take_qty;
        if remaining <= 0.0 {
            break;
        }
    }

    if remaining > 0.0 {
        return None;
    }

    let wap = cost / order_qty;
    if !wap.is_finite() || wap <= 0.0 {
        return None;
    }

    let slippage_bps = match side {
        Side::Buy => (wap - best_price) / best_price * 10_000.0,
        Side::Sell => (best_price - wap) / best_price * 10_000.0,
    };

    if !slippage_bps.is_finite() {
        return None;
    }

    Some(LiquidityGateStats { wap, slippage_bps })
}
