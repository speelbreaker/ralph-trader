use std::sync::atomic::{AtomicU64, Ordering};

use super::RiskState;

pub const FEE_CACHE_SOFT_S_DEFAULT: u64 = 300;
pub const FEE_CACHE_HARD_S_DEFAULT: u64 = 900;
pub const FEE_STALE_BUFFER_DEFAULT: f64 = 0.20;
pub const FEE_MODEL_POLL_INTERVAL_S: u64 = 60;
pub const FEE_MODEL_POLL_INTERVAL_MS: u64 = FEE_MODEL_POLL_INTERVAL_S * 1000;

static FEE_MODEL_CACHE_AGE_MS: AtomicU64 = AtomicU64::new(0);
static FEE_MODEL_REFRESH_FAIL_TOTAL: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FeeStalenessConfig {
    pub fee_cache_soft_s: u64,
    pub fee_cache_hard_s: u64,
    pub fee_stale_buffer: f64,
}

impl Default for FeeStalenessConfig {
    fn default() -> Self {
        Self {
            fee_cache_soft_s: FEE_CACHE_SOFT_S_DEFAULT,
            fee_cache_hard_s: FEE_CACHE_HARD_S_DEFAULT,
            fee_stale_buffer: FEE_STALE_BUFFER_DEFAULT,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FeeModelSnapshot {
    pub fee_tier: u64,
    pub maker_fee_rate: f64,
    pub taker_fee_rate: f64,
    pub fee_model_cached_at_ts_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FeeStalenessDecision {
    pub cache_age_s: f64,
    pub fee_rate_effective: f64,
    pub risk_state: RiskState,
    soft_stale: bool,
    hard_stale: bool,
}

impl FeeStalenessDecision {
    pub fn is_soft_stale(self) -> bool {
        self.soft_stale
    }

    pub fn is_hard_stale(self) -> bool {
        self.hard_stale
    }
}

pub fn fee_model_cache_age_s() -> f64 {
    FEE_MODEL_CACHE_AGE_MS.load(Ordering::Relaxed) as f64 / 1000.0
}

pub fn fee_model_refresh_fail_total() -> u64 {
    FEE_MODEL_REFRESH_FAIL_TOTAL.load(Ordering::Relaxed)
}

pub fn record_fee_model_refresh_fail() {
    FEE_MODEL_REFRESH_FAIL_TOTAL.fetch_add(1, Ordering::Relaxed);
}

pub fn evaluate_fee_staleness(
    fee_rate: f64,
    now_ms: u64,
    cached_at_ms: Option<u64>,
    config: FeeStalenessConfig,
) -> FeeStalenessDecision {
    let hard_s = config.fee_cache_hard_s as f64;
    let age_s = match cached_at_ms {
        Some(cached_at) if now_ms >= cached_at => (now_ms - cached_at) as f64 / 1000.0,
        _ => hard_s + 1.0,
    };

    record_fee_model_cache_age_s(age_s);

    let hard_stale = age_s > hard_s;
    let soft_stale = !hard_stale && age_s > config.fee_cache_soft_s as f64;
    let fee_rate_effective = if soft_stale {
        fee_rate * (1.0 + config.fee_stale_buffer)
    } else {
        fee_rate
    };

    let risk_state = if hard_stale {
        RiskState::Degraded
    } else {
        RiskState::Healthy
    };

    FeeStalenessDecision {
        cache_age_s: age_s,
        fee_rate_effective,
        risk_state,
        soft_stale,
        hard_stale,
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FeeModelCache {
    fee_tier: u64,
    maker_fee_rate: f64,
    taker_fee_rate: f64,
    fee_model_cached_at_ts_ms: Option<u64>,
    last_poll_ms: Option<u64>,
    poll_interval_ms: u64,
}

impl FeeModelCache {
    pub fn new() -> Self {
        Self::with_poll_interval_ms(FEE_MODEL_POLL_INTERVAL_MS)
    }

    pub fn with_poll_interval_ms(poll_interval_ms: u64) -> Self {
        Self {
            fee_tier: 0,
            maker_fee_rate: 0.0,
            taker_fee_rate: 0.0,
            fee_model_cached_at_ts_ms: None,
            last_poll_ms: None,
            poll_interval_ms,
        }
    }

    pub fn poll_interval_ms(&self) -> u64 {
        self.poll_interval_ms
    }

    pub fn should_poll(&self, now_ms: u64) -> bool {
        match self.last_poll_ms {
            None => true,
            Some(last_poll) if now_ms >= last_poll => now_ms - last_poll >= self.poll_interval_ms,
            Some(_) => true,
        }
    }

    pub fn apply_snapshot(self: &mut Self, snapshot: FeeModelSnapshot, now_ms: u64) {
        self.fee_tier = snapshot.fee_tier;
        self.maker_fee_rate = snapshot.maker_fee_rate;
        self.taker_fee_rate = snapshot.taker_fee_rate;
        self.fee_model_cached_at_ts_ms = snapshot.fee_model_cached_at_ts_ms;
        self.last_poll_ms = Some(now_ms);
    }

    pub fn fee_tier(&self) -> u64 {
        self.fee_tier
    }

    pub fn maker_fee_rate(&self) -> f64 {
        self.maker_fee_rate
    }

    pub fn taker_fee_rate(&self) -> f64 {
        self.taker_fee_rate
    }

    pub fn fee_model_cached_at_ts_ms(&self) -> Option<u64> {
        self.fee_model_cached_at_ts_ms
    }

    pub fn effective_fee_rate(
        &self,
        now_ms: u64,
        config: FeeStalenessConfig,
        is_maker: bool,
    ) -> FeeStalenessDecision {
        let fee_rate = if is_maker {
            self.maker_fee_rate
        } else {
            self.taker_fee_rate
        };
        evaluate_fee_staleness(fee_rate, now_ms, self.fee_model_cached_at_ts_ms, config)
    }
}

fn record_fee_model_cache_age_s(age_s: f64) {
    let age_ms = if !age_s.is_finite() || age_s < 0.0 {
        0
    } else {
        (age_s * 1000.0).round() as u64
    };
    FEE_MODEL_CACHE_AGE_MS.store(age_ms, Ordering::Relaxed);
}
