//! Basis Monitor — Mark/Index/Last Liquidation Reality Guard
//! Per CONTRACT.md §2.3.3
//!
//! Purpose: Liquidation/margin risk is driven by reference prices (mark), not last trade.
//! Large basis divergence is a microstructure failure mode; fail-closed for new risk.

/// Configuration for the Basis Monitor.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BasisMonitorConfig {
    /// Maximum age of basis prices before considered stale (ms)
    pub basis_price_max_age_ms: u64,
    /// Basis threshold for ReduceOnly trip (bps)
    pub basis_reduceonly_bps: f64,
    /// Window basis must exceed reduceonly threshold to trip (s)
    pub basis_reduceonly_window_s: u64,
    /// Cooldown applied when ForceReduceOnly is emitted (s)
    pub basis_reduceonly_cooldown_s: u64,
    /// Basis threshold for Kill trip (bps)
    pub basis_kill_bps: f64,
    /// Window basis must exceed kill threshold to trip (s)
    pub basis_kill_window_s: u64,
}

impl Default for BasisMonitorConfig {
    fn default() -> Self {
        Self {
            basis_price_max_age_ms: 5_000,
            basis_reduceonly_bps: 50.0,
            basis_reduceonly_window_s: 5,
            basis_reduceonly_cooldown_s: 300,
            basis_kill_bps: 150.0,
            basis_kill_window_s: 5,
        }
    }
}

/// Prices provided to the Basis Monitor for evaluation.
#[derive(Debug, Clone, Copy)]
pub struct BasisPrices {
    /// Mark price (>0) and its timestamp (ms since epoch)
    pub mark_price: Option<f64>,
    pub mark_price_ts_ms: Option<u64>,
    /// Index price (>0) and its timestamp (ms since epoch)
    pub index_price: Option<f64>,
    pub index_price_ts_ms: Option<u64>,
    /// Last/mid price (>0) and its timestamp (ms since epoch)
    pub last_price: Option<f64>,
    pub last_price_ts_ms: Option<u64>,
}

/// Output decision from BasisMonitor::evaluate()
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BasisDecision {
    /// No override — basis within thresholds and data is fresh
    Normal,
    /// Basis diverged >= reduceonly threshold for window, or fail-closed (stale/missing)
    ForceReduceOnly { cooldown_s: u64 },
    /// Basis diverged >= kill threshold for kill_window
    ForceKill,
}

/// Internal windowed-trip state for a single threshold
#[derive(Debug, Clone, Copy)]
struct WindowState {
    /// Timestamp (ms) when the current trip window first started (None = not tripping)
    trip_start_ms: Option<u64>,
}

impl WindowState {
    fn new() -> Self {
        Self {
            trip_start_ms: None,
        }
    }

    /// Update window state given whether basis exceeds threshold at `now_ms`.
    /// Returns `true` if the threshold has been exceeded continuously for >= `window_s`.
    fn update_and_check(&mut self, exceeds: bool, now_ms: u64, window_s: u64) -> bool {
        if exceeds {
            let start = self.trip_start_ms.get_or_insert(now_ms);
            let elapsed_ms = now_ms.saturating_sub(*start);
            elapsed_ms >= window_s * 1_000
        } else {
            self.trip_start_ms = None;
            false
        }
    }
}

/// Basis Monitor — stateful evaluator for §2.3.3 trip rules.
///
/// Call `evaluate()` once per tick with current prices and `now_ms`.
/// The monitor tracks window state internally.
#[derive(Debug)]
pub struct BasisMonitor {
    kill_window: WindowState,
    reduceonly_window: WindowState,
    /// Monotonic counter for basis_trip_total metric
    trip_total: u64,
}

impl BasisMonitor {
    pub fn new() -> Self {
        Self {
            kill_window: WindowState::new(),
            reduceonly_window: WindowState::new(),
            trip_total: 0,
        }
    }

    /// Evaluate basis trip rules for the current tick.
    ///
    /// Returns `BasisDecision` per §2.3.3 priority order:
    ///   1. Missing/stale → ForceReduceOnly (fail-closed)
    ///   2. Kill threshold exceeded for kill_window → ForceKill
    ///   3. ReduceOnly threshold exceeded for reduceonly_window → ForceReduceOnly
    ///   4. Otherwise → Normal
    ///
    /// **`now_ms` must be monotonically non-decreasing across calls.** A non-monotonic
    /// clock (e.g. NTP step-back) will NOT reset `trip_start_ms` and may cause the
    /// window check to stall until the clock catches up. The caller is responsible
    /// for providing a monotonic time source.
    pub fn evaluate(
        &mut self,
        prices: BasisPrices,
        now_ms: u64,
        config: BasisMonitorConfig,
    ) -> BasisDecision {
        // Step 1: Validate all required prices are present and fresh
        let (mark, index, last) = match self.extract_prices(&prices, now_ms, config) {
            Some(v) => v,
            None => {
                // Fail-closed: missing or stale price
                let decision = BasisDecision::ForceReduceOnly {
                    cooldown_s: config.basis_reduceonly_cooldown_s,
                };
                self.trip_total += 1;
                // Reset trip windows — stale data, can't accumulate window
                self.kill_window.trip_start_ms = None;
                self.reduceonly_window.trip_start_ms = None;
                return decision;
            }
        };

        // Step 2: Compute basis metrics (bps)
        let basis_mark_last_bps = compute_basis_bps(mark, last);
        let basis_mark_index_bps = compute_basis_bps(mark, index);
        let max_basis_bps = basis_mark_last_bps.max(basis_mark_index_bps);

        // Step 3: Kill threshold check (highest priority trip)
        let kill_exceeds = max_basis_bps >= config.basis_kill_bps;
        let kill_tripped =
            self.kill_window
                .update_and_check(kill_exceeds, now_ms, config.basis_kill_window_s);

        if kill_tripped {
            // Keep reduceonly window state in sync (also exceeded if kill is exceeded)
            self.reduceonly_window
                .update_and_check(true, now_ms, config.basis_reduceonly_window_s);
            self.trip_total += 1;
            return BasisDecision::ForceKill;
        }

        // Step 4: ReduceOnly threshold check
        let ro_exceeds = max_basis_bps >= config.basis_reduceonly_bps;
        let ro_tripped = self.reduceonly_window.update_and_check(
            ro_exceeds,
            now_ms,
            config.basis_reduceonly_window_s,
        );

        // Clear kill window if basis dropped below kill threshold
        if !kill_exceeds {
            // Already cleared by update_and_check above returning false
        }

        if ro_tripped {
            self.trip_total += 1;
            return BasisDecision::ForceReduceOnly {
                cooldown_s: config.basis_reduceonly_cooldown_s,
            };
        }

        BasisDecision::Normal
    }

    /// Returns the total number of basis trips (for basis_trip_total metric)
    pub fn trip_total(&self) -> u64 {
        self.trip_total
    }

    /// Extract and validate prices, returning None if any are missing/stale.
    fn extract_prices(
        &self,
        prices: &BasisPrices,
        now_ms: u64,
        config: BasisMonitorConfig,
    ) -> Option<(f64, f64, f64)> {
        let mark = prices.mark_price?;
        let mark_ts = prices.mark_price_ts_ms?;
        let index = prices.index_price?;
        let index_ts = prices.index_price_ts_ms?;
        let last = prices.last_price?;
        let last_ts = prices.last_price_ts_ms?;

        // Validate prices are positive
        if mark <= 0.0 || index <= 0.0 || last <= 0.0 {
            return None;
        }

        // Check freshness: max age across all prices must not exceed limit
        let mark_age = now_ms.saturating_sub(mark_ts);
        let index_age = now_ms.saturating_sub(index_ts);
        let last_age = now_ms.saturating_sub(last_ts);
        let max_age = mark_age.max(index_age).max(last_age);

        if max_age > config.basis_price_max_age_ms {
            return None;
        }

        Some((mark, index, last))
    }
}

impl Default for BasisMonitor {
    fn default() -> Self {
        Self::new()
    }
}

/// Compute basis in bps: abs(mark - other) / mark * 10_000
///
/// Returns 0.0 if mark is zero (should not happen with validated inputs).
fn compute_basis_bps(mark: f64, other: f64) -> f64 {
    if mark == 0.0 {
        return 0.0;
    }
    (mark - other).abs() / mark * 10_000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh_prices(mark: f64, index: f64, last: f64, now_ms: u64) -> BasisPrices {
        BasisPrices {
            mark_price: Some(mark),
            mark_price_ts_ms: Some(now_ms - 100), // 100ms ago = fresh
            index_price: Some(index),
            index_price_ts_ms: Some(now_ms - 100),
            last_price: Some(last),
            last_price_ts_ms: Some(now_ms - 100),
        }
    }

    #[test]
    fn test_normal_below_threshold() {
        let mut monitor = BasisMonitor::new();
        let config = BasisMonitorConfig::default();
        let now_ms = 100_000;
        // mark=100, index=100.1, last=100.2 → basis < 50 bps
        let prices = fresh_prices(100.0, 100.1, 100.2, now_ms);
        let decision = monitor.evaluate(prices, now_ms, config);
        assert_eq!(decision, BasisDecision::Normal);
    }

    #[test]
    fn test_compute_basis_bps() {
        // mark=100, other=100.5 → basis = 0.5/100*10000 = 50 bps
        let bps = compute_basis_bps(100.0, 100.5);
        assert!((bps - 50.0).abs() < 0.001, "Expected 50 bps, got {}", bps);
    }

    #[test]
    fn test_missing_price_fail_closed() {
        let mut monitor = BasisMonitor::new();
        let config = BasisMonitorConfig::default();
        let now_ms = 100_000;
        let prices = BasisPrices {
            mark_price: None, // Missing!
            mark_price_ts_ms: None,
            index_price: Some(100.0),
            index_price_ts_ms: Some(now_ms - 100),
            last_price: Some(100.0),
            last_price_ts_ms: Some(now_ms - 100),
        };
        let decision = monitor.evaluate(prices, now_ms, config);
        assert_eq!(
            decision,
            BasisDecision::ForceReduceOnly { cooldown_s: 300 },
            "Missing price must trigger fail-closed ForceReduceOnly"
        );
    }

    #[test]
    fn test_stale_price_fail_closed() {
        let mut monitor = BasisMonitor::new();
        let config = BasisMonitorConfig::default(); // max_age = 5000ms
        let now_ms = 100_000;
        // index price is 6s old → stale
        let prices = BasisPrices {
            mark_price: Some(100.0),
            mark_price_ts_ms: Some(now_ms - 100),
            index_price: Some(100.0),
            index_price_ts_ms: Some(now_ms - 6_000), // stale!
            last_price: Some(100.0),
            last_price_ts_ms: Some(now_ms - 100),
        };
        let decision = monitor.evaluate(prices, now_ms, config);
        assert_eq!(
            decision,
            BasisDecision::ForceReduceOnly { cooldown_s: 300 },
            "Stale price must trigger fail-closed ForceReduceOnly"
        );
    }
}
