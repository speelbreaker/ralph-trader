use std::sync::atomic::{AtomicU64, Ordering};

use super::Side;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PostOnlyIntent {
    pub post_only: bool,
    pub side: Side,
    pub limit_price: f64,
    pub best_bid: Option<f64>,
    pub best_ask: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PostOnlyRejectReason {
    PostOnlyWouldCross,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PostOnlyReject {
    pub reason: PostOnlyRejectReason,
}

pub struct PostOnlyMetrics {
    cross_reject_total: AtomicU64,
}

impl Default for PostOnlyMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl PostOnlyMetrics {
    pub const fn new() -> Self {
        Self {
            cross_reject_total: AtomicU64::new(0),
        }
    }

    pub fn cross_reject_total(&self) -> u64 {
        self.cross_reject_total.load(Ordering::Relaxed)
    }

    fn bump_cross_reject(&self) {
        self.cross_reject_total.fetch_add(1, Ordering::Relaxed);
    }
}

static POST_ONLY_METRICS: PostOnlyMetrics = PostOnlyMetrics::new();

pub fn post_only_cross_reject_total() -> u64 {
    POST_ONLY_METRICS.cross_reject_total()
}

pub fn preflight_post_only(intent: &PostOnlyIntent) -> Result<(), PostOnlyReject> {
    if !intent.post_only {
        return Ok(());
    }
    if would_cross(
        intent.side,
        intent.limit_price,
        intent.best_bid,
        intent.best_ask,
    ) {
        return Err(reject_with_metrics());
    }
    Ok(())
}

fn would_cross(side: Side, limit_price: f64, best_bid: Option<f64>, best_ask: Option<f64>) -> bool {
    if !limit_price.is_finite() {
        return false;
    }
    match side {
        Side::Buy => match best_ask {
            Some(ask) if ask.is_finite() => limit_price >= ask,
            _ => false,
        },
        Side::Sell => match best_bid {
            Some(bid) if bid.is_finite() => limit_price <= bid,
            _ => false,
        },
    }
}

fn reject_with_metrics() -> PostOnlyReject {
    POST_ONLY_METRICS.bump_cross_reject();
    let reason = PostOnlyRejectReason::PostOnlyWouldCross;
    eprintln!("post_only_cross_reject_total reason={:?}", reason);
    PostOnlyReject { reason }
}
