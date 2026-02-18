//! Exchange Health Monitor — Maintenance Mode Override
//! Per CONTRACT.md §2.3.1
//!
//! Purpose: Do not trade into a known exchange outage window.
//! Maintenance is a separate risk state from Python liveness.

use crate::risk::{RiskState, TradingMode};

/// Configuration for the Exchange Health Monitor.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ExchangeHealthConfig {
    /// Max staleness before fail-closed (seconds). Default: 180s per Appendix A.
    pub exchange_health_stale_s: u64,
    /// Maintenance window: block opens when maintenance is within this many seconds. Default: 3600 (60m).
    pub maintenance_lookahead_s: u64,
}

impl Default for ExchangeHealthConfig {
    fn default() -> Self {
        Self {
            exchange_health_stale_s: 180,
            maintenance_lookahead_s: 3600,
        }
    }
}

/// An announcement entry from /public/get_announcements.
#[derive(Debug, Clone, Copy)]
pub struct AnnouncementEntry {
    /// Unix timestamp (ms) when maintenance starts. None if not a maintenance announcement.
    pub maintenance_start_ms: Option<u64>,
}

/// Input to the Exchange Health Monitor evaluation.
#[derive(Debug, Clone)]
pub struct ExchangeHealthInput {
    /// Parsed announcements from the last poll. None if the endpoint was unreachable or returned invalid data.
    pub announcements: Option<Vec<AnnouncementEntry>>,
    /// Timestamp (ms) of the last successful poll.
    pub last_successful_poll_ms: Option<u64>,
}

/// Output decision from ExchangeHealthMonitor::evaluate().
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExchangeHealthDecision {
    /// No maintenance imminent and announcements are fresh.
    Normal,
    /// Maintenance within lookahead window → RiskState::Maintenance, TradingMode::ReduceOnly.
    MaintenanceImminent,
    /// Announcements unreachable/invalid for >= exchange_health_stale_s → cortex_override = ForceReduceOnly.
    ForceReduceOnly,
}

impl ExchangeHealthDecision {
    /// Map decision to RiskState per §2.3.1 rules.
    pub fn risk_state(self) -> Option<RiskState> {
        match self {
            ExchangeHealthDecision::Normal => None,
            ExchangeHealthDecision::MaintenanceImminent => Some(RiskState::Maintenance),
            ExchangeHealthDecision::ForceReduceOnly => None, // cortex_override path, not RiskState
        }
    }

    /// Returns true if this decision forces ReduceOnly trading mode.
    pub fn forces_reduce_only(self) -> bool {
        matches!(
            self,
            ExchangeHealthDecision::MaintenanceImminent | ExchangeHealthDecision::ForceReduceOnly
        )
    }

    /// Returns the effective TradingMode.
    pub fn trading_mode(self) -> TradingMode {
        if self.forces_reduce_only() {
            TradingMode::ReduceOnly
        } else {
            TradingMode::Active
        }
    }
}

/// Exchange Health Monitor — stateful evaluator for §2.3.1 rules.
///
/// Call `evaluate()` once per tick with current input and `now_ms`.
#[derive(Debug, Default)]
pub struct ExchangeHealthMonitor {
    /// Monotonic counter for exchange_health_status metric.
    status_count: u64,
}

impl ExchangeHealthMonitor {
    pub fn new() -> Self {
        Self::default()
    }

    /// Evaluate exchange health for the current tick.
    ///
    /// Decision priority per §2.3.1:
    ///   1. Stale/unreachable for >= exchange_health_stale_s → ForceReduceOnly (fail-closed)
    ///   2. Maintenance within lookahead_s → MaintenanceImminent
    ///   3. Otherwise → Normal
    pub fn evaluate(
        &mut self,
        input: &ExchangeHealthInput,
        now_ms: u64,
        config: ExchangeHealthConfig,
    ) -> ExchangeHealthDecision {
        self.status_count += 1;

        // Step 1: Check for stale/unreachable — fail-closed
        let announcements = match &input.announcements {
            Some(list) => list,
            None => {
                // No valid announcements — check staleness
                return self.check_staleness(input, now_ms, config);
            }
        };

        // We have valid announcements — check staleness of last_successful_poll_ms
        // (The announcements slice being Some implies last poll succeeded, but check anyway)
        let stale = is_stale(
            input.last_successful_poll_ms,
            now_ms,
            config.exchange_health_stale_s,
        );
        if stale {
            return ExchangeHealthDecision::ForceReduceOnly;
        }

        // Step 2: Check for imminent maintenance
        for entry in announcements {
            if let Some(start_ms) = entry.maintenance_start_ms {
                // maintenance starts within lookahead window?
                if start_ms > now_ms {
                    let secs_until = (start_ms - now_ms) / 1_000;
                    if secs_until <= config.maintenance_lookahead_s {
                        return ExchangeHealthDecision::MaintenanceImminent;
                    }
                } else {
                    // maintenance start is in the past — we are in maintenance
                    return ExchangeHealthDecision::MaintenanceImminent;
                }
            }
        }

        ExchangeHealthDecision::Normal
    }

    /// Returns the total number of status evaluations (for exchange_health_status metric).
    pub fn status_count(&self) -> u64 {
        self.status_count
    }

    fn check_staleness(
        &self,
        input: &ExchangeHealthInput,
        now_ms: u64,
        config: ExchangeHealthConfig,
    ) -> ExchangeHealthDecision {
        if is_stale(
            input.last_successful_poll_ms,
            now_ms,
            config.exchange_health_stale_s,
        ) {
            ExchangeHealthDecision::ForceReduceOnly
        } else {
            // No announcements but not yet stale — treat as normal (no maintenance announced)
            ExchangeHealthDecision::Normal
        }
    }
}

/// Returns true if `last_poll_ms` is None or is older than `stale_s` seconds ago from `now_ms`.
fn is_stale(last_poll_ms: Option<u64>, now_ms: u64, stale_s: u64) -> bool {
    match last_poll_ms {
        None => true,
        Some(ts) => now_ms.saturating_sub(ts) >= stale_s * 1_000,
    }
}
