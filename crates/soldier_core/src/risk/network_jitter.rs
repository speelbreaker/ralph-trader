//! Network Jitter Monitor — Bunker Mode Override
//! Per CONTRACT.md §2.3.2
//!
//! Purpose: VPS tail latency is a first-class risk driver. If network jitter spikes,
//! cancel/replace/repair becomes unreliable. Bunker Mode blocks new opens until stable.
//!
//! Self-contained: no dependency on crate module tree; safe to include via #[path] in tests.

// NOTE: items not yet wired into the integration produce dead_code warnings intentionally.

/// Configuration for the Network Jitter Monitor.
///
/// Defaults per CONTRACT.md Appendix A:
/// - `bunker_jitter_threshold_ms` = 2000
/// - `bunker_exit_stable_s` = 120
/// - `http_p95_threshold_ms` = 750
/// - `http_p95_consecutive_windows` = 3
/// - `timeout_rate_threshold` = 0.02
pub struct NetworkJitterConfig {
    /// ws_event_lag_ms threshold for bunker entry (default 2000 ms)
    pub bunker_jitter_threshold_ms: u64,
    /// Stable period required before bunker exit (default 120 s)
    pub bunker_exit_stable_s: u64,
    /// deribit_http_p95_ms threshold for bunker entry (default 750 ms)
    pub http_p95_threshold_ms: u64,
    /// Number of consecutive http_p95 windows above threshold to trigger (default 3)
    pub http_p95_consecutive_windows: u32,
    /// request_timeout_rate threshold for bunker entry (default 0.02 = 2%)
    pub timeout_rate_threshold: f64,
}

impl Default for NetworkJitterConfig {
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

/// Inputs provided to the Network Jitter Monitor each evaluation tick.
#[derive(Debug, Clone, Copy)]
pub struct JitterInputs {
    /// ws_event_lag_ms: now - last_ws_msg_ts (None if no WS message received yet)
    pub ws_event_lag_ms: Option<u64>,
    /// deribit_http_p95_ms: p95 HTTP latency over last 30s (None if uncomputable)
    pub http_p95_ms: Option<u64>,
    /// request_timeout_rate: fraction of requests that timed out over last 60s (None if uncomputable)
    pub request_timeout_rate: Option<f64>,
}

/// Network Jitter Monitor — stateful evaluator for §2.3.2 bunker mode rules.
///
/// Call `evaluate()` once per tick with current jitter metrics and `now_ms`.
/// The monitor tracks consecutive windows and stable-exit state internally.
pub struct NetworkJitterMonitor {
    /// Whether bunker mode is currently active
    bunker_mode_active: bool,
    /// Timestamp when all metrics first dropped below thresholds (None = not stable yet)
    stable_start_ms: Option<u64>,
    /// Count of consecutive http_p95 windows above threshold
    http_p95_consecutive: u32,
    /// Monotonic counter for bunker_mode_trip_total metric
    trip_total: u64,
}

impl NetworkJitterMonitor {
    pub fn new() -> Self {
        Self {
            bunker_mode_active: false,
            stable_start_ms: None,
            http_p95_consecutive: 0,
            trip_total: 0,
        }
    }

    /// Evaluate bunker mode rules for the current tick.
    ///
    /// Returns `true` if bunker mode is (or remains) active.
    ///
    /// **`now_ms` must be monotonically non-decreasing** across calls. If `now_ms`
    /// decreases (e.g. after a system restart with a non-monotonic clock), the stable-exit
    /// timer (`saturating_sub`) silently resets to zero, keeping the monitor in bunker mode
    /// indefinitely. Callers should use a monotonic clock source (e.g. `Instant`) and
    /// convert to milliseconds rather than using wall-clock `SystemTime`.
    ///
    /// Rules per §2.3.2:
    /// 1. Any missing/uncomputable metric → bunker entry (fail-closed)
    /// 2. ws_event_lag_ms > threshold → bunker entry
    /// 3. http_p95_ms > threshold for N consecutive windows → bunker entry
    /// 4. request_timeout_rate > threshold → bunker entry
    /// 5. Exit only after all metrics below thresholds for bunker_exit_stable_s
    pub fn evaluate(
        &mut self,
        inputs: JitterInputs,
        now_ms: u64,
        config: &NetworkJitterConfig,
    ) -> bool {
        // Step 1: Fail-closed — missing metrics force bunker entry
        let (ws_lag, http_p95, timeout_rate) = match (
            inputs.ws_event_lag_ms,
            inputs.http_p95_ms,
            inputs.request_timeout_rate,
        ) {
            (Some(w), Some(h), Some(t)) => (w, h, t),
            _ => {
                // Any missing metric → bunker active
                let was_active = self.bunker_mode_active;
                self.bunker_mode_active = true;
                self.stable_start_ms = None;
                if !was_active {
                    self.trip_total += 1;
                }
                return true;
            }
        };

        // Step 2: Check trip conditions
        let ws_trip = ws_lag > config.bunker_jitter_threshold_ms;
        let timeout_trip = timeout_rate > config.timeout_rate_threshold;

        // Step 3: Update http_p95 consecutive window counter
        if http_p95 > config.http_p95_threshold_ms {
            self.http_p95_consecutive = self.http_p95_consecutive.saturating_add(1);
        } else {
            self.http_p95_consecutive = 0;
        }
        let http_trip = self.http_p95_consecutive >= config.http_p95_consecutive_windows;

        let any_trip = ws_trip || http_trip || timeout_trip;

        if any_trip {
            // Enter or remain in bunker mode
            let was_active = self.bunker_mode_active;
            self.bunker_mode_active = true;
            self.stable_start_ms = None; // reset stable timer
            if !was_active {
                self.trip_total += 1;
            }
            return true;
        }

        // Step 4: No trip conditions — check for stable exit
        if self.bunker_mode_active {
            // Start or continue stable timer
            let start = self.stable_start_ms.get_or_insert(now_ms);
            let stable_ms = now_ms.saturating_sub(*start);
            let required_ms = config.bunker_exit_stable_s * 1_000;
            if stable_ms >= required_ms {
                // Full stable period elapsed — exit bunker mode
                self.bunker_mode_active = false;
                self.stable_start_ms = None;
            }
        }

        self.bunker_mode_active
    }

    /// Returns true if bunker mode is currently active.
    pub fn is_active(&self) -> bool {
        self.bunker_mode_active
    }

    /// Returns the total number of bunker mode trips (for bunker_mode_trip_total metric).
    pub fn trip_total(&self) -> u64 {
        self.trip_total
    }
}

impl Default for NetworkJitterMonitor {
    fn default() -> Self {
        Self::new()
    }
}

/// Metric gauges (exported values)
pub struct JitterMetrics {
    pub ws_event_lag_ms: Option<u64>,
    pub deribit_http_p95_ms: Option<u64>,
    pub bunker_mode_trip_total: u64,
}
