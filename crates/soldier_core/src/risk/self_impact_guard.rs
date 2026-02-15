use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::RiskState;

/// Self-Impact Feedback Loop Guard per CONTRACT.md §1.2.3
/// Prevents the bot from reacting to its own impact (echo chamber)
///
/// Rule: Stale trade feed => Degraded + latch blocks opens
/// Rule: self_fraction/notional trip => reject with cooldown

const FLOAT_EPSILON: f64 = 1e-9;
const MIN_PUBLIC_VOLUME_USD: f64 = 1000.0; // Minimum public volume for fraction calculation

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SelfImpactKey {
    pub strategy_id: String,
    pub structure_fingerprint: String,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SelfImpactConfig {
    pub public_trade_feed_max_age_ms: u64,
    pub feedback_loop_window_s: u64,
    pub self_trade_fraction_trip: f64,
    pub self_trade_min_self_notional_usd: f64,
    pub self_trade_notional_trip_usd: f64,
    pub feedback_loop_cooldown_s: u64,
}

impl Default for SelfImpactConfig {
    fn default() -> Self {
        Self {
            public_trade_feed_max_age_ms: 5000,
            feedback_loop_window_s: 10,
            self_trade_fraction_trip: 0.25,
            self_trade_min_self_notional_usd: 10_000.0,
            self_trade_notional_trip_usd: 150_000.0,
            feedback_loop_cooldown_s: 60,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TradeAggregates {
    pub public_notional_usd: f64,
    pub self_notional_usd: f64,
    pub public_trades_last_update_ts_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LatchReason {
    WsTradesGapReconcileRequired,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SelfImpactEvaluation {
    pub allowed: bool,
    pub latch_reason: Option<LatchReason>,
    pub reject_reason: Option<String>,
    pub risk_state: RiskState,
}

#[derive(Debug, Clone)]
struct CooldownEntry {
    blocked_until: Instant,
}

struct SelfImpactGuardState {
    cooldown_map: HashMap<SelfImpactKey, CooldownEntry>,
    trip_counter: u64, // For self_impact_trip_total metric
}

/// Thread-safety: All methods use interior mutability (Mutex) for safe concurrent access
pub struct SelfImpactGuard {
    state: Mutex<SelfImpactGuardState>,
}

impl SelfImpactGuard {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(SelfImpactGuardState {
                cooldown_map: HashMap::new(),
                trip_counter: 0,
            }),
        }
    }

    /// Evaluate an OPEN intent against self-impact rules.
    /// Returns evaluation with allowed/latch/reject/risk_state fields.
    /// Thread-safe: uses interior mutability
    pub fn evaluate_open(
        &self,
        key: &SelfImpactKey,
        aggregates: TradeAggregates,
        now_ms: u64,
        now_instant: Instant,
        config: SelfImpactConfig,
    ) -> SelfImpactEvaluation {
        let mut state = match self.state.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                eprintln!("self_impact_guard lock poisoned, recovering");
                poisoned.into_inner()
            }
        };

        // Prune expired cooldowns
        state
            .cooldown_map
            .retain(|_k, entry| now_instant < entry.blocked_until);

        // Step 1: Check trade feed freshness (CONTRACT.md §1.2.3 freshness precondition)
        match aggregates.public_trades_last_update_ts_ms {
            None => {
                // Missing trade feed => Degraded + latch
                return SelfImpactEvaluation {
                    allowed: false,
                    latch_reason: Some(LatchReason::WsTradesGapReconcileRequired),
                    reject_reason: None,
                    risk_state: RiskState::Degraded,
                };
            }
            Some(last_update_ts_ms) => {
                if now_ms.saturating_sub(last_update_ts_ms) > config.public_trade_feed_max_age_ms {
                    // Stale trade feed => Degraded + latch
                    return SelfImpactEvaluation {
                        allowed: false,
                        latch_reason: Some(LatchReason::WsTradesGapReconcileRequired),
                        reject_reason: None,
                        risk_state: RiskState::Degraded,
                    };
                }
            }
        }

        // Step 2: Feed is fresh, check if key is in cooldown
        if let Some(entry) = state.cooldown_map.get(key) {
            let remaining_secs = entry
                .blocked_until
                .saturating_duration_since(now_instant)
                .as_secs();
            return SelfImpactEvaluation {
                allowed: false,
                latch_reason: None,
                reject_reason: Some(format!(
                    "FeedbackLoopGuardActive: cooldown active, {}s remaining",
                    remaining_secs
                )),
                risk_state: RiskState::Healthy,
            };
        }

        // Step 3: Compute self_fraction and check trip conditions
        // Only compute fraction if public volume is meaningful
        let fraction_trip = if aggregates.public_notional_usd >= MIN_PUBLIC_VOLUME_USD {
            let self_fraction = aggregates.self_notional_usd / aggregates.public_notional_usd;

            // Trip condition A: self_fraction >= threshold (with epsilon tolerance) AND self_notional >= min
            (self_fraction + FLOAT_EPSILON >= config.self_trade_fraction_trip)
                && aggregates.self_notional_usd >= config.self_trade_min_self_notional_usd
        } else {
            // Public volume too small to compute meaningful fraction - skip fraction check
            false
        };

        // Trip condition B: self_notional >= absolute trip threshold (with epsilon tolerance)
        let notional_trip =
            aggregates.self_notional_usd + FLOAT_EPSILON >= config.self_trade_notional_trip_usd;

        if fraction_trip || notional_trip {
            // Trip: reject and apply cooldown
            state.cooldown_map.insert(
                key.clone(),
                CooldownEntry {
                    blocked_until: now_instant
                        + Duration::from_secs(config.feedback_loop_cooldown_s),
                },
            );
            state.trip_counter += 1;

            SelfImpactEvaluation {
                allowed: false,
                latch_reason: None,
                reject_reason: Some("FeedbackLoopGuardActive".to_string()),
                risk_state: RiskState::Healthy,
            }
        } else {
            // Below threshold: allow
            SelfImpactEvaluation {
                allowed: true,
                latch_reason: None,
                reject_reason: None,
                risk_state: RiskState::Healthy,
            }
        }
    }

    /// Get total trip count (for self_impact_trip_total metric)
    /// Thread-safe: uses interior mutability
    pub fn trip_count(&self) -> u64 {
        let state = match self.state.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                eprintln!("self_impact_guard lock poisoned, recovering");
                poisoned.into_inner()
            }
        };
        state.trip_counter
    }
}

impl Default for SelfImpactGuard {
    fn default() -> Self {
        Self::new()
    }
}
