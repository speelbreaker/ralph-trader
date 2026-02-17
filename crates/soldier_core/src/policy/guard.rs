//! PolicyGuard bunker mode wrapper.
//! Per CONTRACT.md §2.3.2 and §2.2.3.
//!
//! When `bunker_mode_active == true`, PolicyGuard returns TradingMode::ReduceOnly
//! and OPEN intents are blocked. CLOSE/HEDGE/CANCEL remain allowed (§2.2.5).
//!
//! Self-contained: no dependency on crate module tree; safe to include via #[path] in tests.

#![allow(dead_code)]

/// Configuration for the BunkerModeGuard.
pub struct BunkerModeGuardConfig {
    /// ws_event_lag_ms threshold for bunker entry (default 2000 ms)
    pub bunker_jitter_threshold_ms: u64,
    /// Stable period required before bunker exit (default 120 s)
    pub bunker_exit_stable_s: u64,
    /// deribit_http_p95_ms threshold (default 750 ms)
    pub http_p95_threshold_ms: u64,
    /// Consecutive http_p95 windows above threshold to trigger (default 3)
    pub http_p95_consecutive_windows: u32,
    /// request_timeout_rate threshold (default 0.02 = 2%)
    pub timeout_rate_threshold: f64,
}

impl Default for BunkerModeGuardConfig {
    fn default() -> Self {
        Self {
            bunker_jitter_threshold_ms: 2_000,
            bunker_exit_stable_s: 120,
            http_p95_threshold_ms: 750,
            http_p95_consecutive_windows: 3,
            timeout_rate_threshold: 0.02,
        }
    }
}

/// Jitter inputs for the BunkerModeGuard.
pub struct BunkerJitterInputs {
    pub ws_event_lag_ms: Option<u64>,
    pub http_p95_ms: Option<u64>,
    pub request_timeout_rate: Option<f64>,
}

/// BunkerModeGuard — PolicyGuard-compatible bunker mode evaluator (§2.3.2).
///
/// When `evaluate()` returns `true`:
///   - PolicyGuard computes TradingMode::ReduceOnly (§2.2.3)
///   - OPEN intents are blocked
///   - CLOSE/HEDGE/CANCEL remain allowed (per §2.2.5)
pub struct BunkerModeGuard {
    bunker_mode_active: bool,
    stable_start_ms: Option<u64>,
    http_p95_consecutive: u32,
    trip_total: u64,
}

impl BunkerModeGuard {
    pub fn new() -> Self {
        Self {
            bunker_mode_active: false,
            stable_start_ms: None,
            http_p95_consecutive: 0,
            trip_total: 0,
        }
    }

    /// Evaluate bunker mode for the current tick. Returns true if bunker_mode_active.
    pub fn evaluate(
        &mut self,
        inputs: BunkerJitterInputs,
        now_ms: u64,
        config: &BunkerModeGuardConfig,
    ) -> bool {
        let (ws_lag, http_p95, timeout_rate) = match (
            inputs.ws_event_lag_ms,
            inputs.http_p95_ms,
            inputs.request_timeout_rate,
        ) {
            (Some(w), Some(h), Some(t)) => (w, h, t),
            _ => {
                let was_active = self.bunker_mode_active;
                self.bunker_mode_active = true;
                self.stable_start_ms = None;
                if !was_active {
                    self.trip_total += 1;
                }
                return true;
            }
        };

        let ws_trip = ws_lag > config.bunker_jitter_threshold_ms;
        let timeout_trip = timeout_rate > config.timeout_rate_threshold;

        if http_p95 > config.http_p95_threshold_ms {
            self.http_p95_consecutive = self.http_p95_consecutive.saturating_add(1);
        } else {
            self.http_p95_consecutive = 0;
        }
        let http_trip = self.http_p95_consecutive >= config.http_p95_consecutive_windows;

        let any_trip = ws_trip || http_trip || timeout_trip;

        if any_trip {
            let was_active = self.bunker_mode_active;
            self.bunker_mode_active = true;
            self.stable_start_ms = None;
            if !was_active {
                self.trip_total += 1;
            }
            return true;
        }

        if self.bunker_mode_active {
            let start = self.stable_start_ms.get_or_insert(now_ms);
            let stable_ms = now_ms.saturating_sub(*start);
            let required_ms = config.bunker_exit_stable_s * 1_000;
            if stable_ms >= required_ms {
                self.bunker_mode_active = false;
                self.stable_start_ms = None;
            }
        }

        self.bunker_mode_active
    }

    pub fn is_active(&self) -> bool {
        self.bunker_mode_active
    }

    pub fn trip_total(&self) -> u64 {
        self.trip_total
    }
}

impl Default for BunkerModeGuard {
    fn default() -> Self {
        Self::new()
    }
}
