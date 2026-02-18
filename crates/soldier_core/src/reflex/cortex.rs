//! Reflexive Cortex — Hot-Loop Safety Override
//! Per CONTRACT.md §2.3
//!
//! Purpose: Detects market microstructure stress (DVOL spike, spread blowout, depth depletion)
//! and emits a safety override that PolicyGuard consumes to force ReduceOnly or Kill mode.
//! Also enforces cancel/replace permission when ws_gap_flag is active (AT-119).

/// Configuration for the Reflexive Cortex.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CortexConfig {
    /// Maximum tolerable spread before ReduceOnly (bps). Default: 25.
    pub spread_max_bps: f64,
    /// Hard kill threshold for spread blowout (bps). Default: 75.
    pub spread_kill_bps: f64,
    /// Minimum depth (USD notional, top-5 per side, min-side). Below = ReduceOnly. Default: 300_000.
    pub depth_min: f64,
    /// Hard kill threshold for depth depletion (USD). Default: 100_000.
    pub depth_kill_min: f64,
    /// Continuous breach window to trigger ForceKill (s). Default: 10.
    pub cortex_kill_window_s: u64,
    /// DVOL jump threshold as fraction (0.10 = 10%). Default: 0.10.
    pub dvol_jump_pct: f64,
    /// Rolling window for DVOL jump detection (s). Default: 60.
    pub dvol_jump_window_s: u64,
    /// Cooldown after DVOL jump (s). Default: 300.
    pub dvol_cooldown_s: u64,
    /// Cooldown after spread/depth trip (s). Default: 120.
    pub spread_depth_cooldown_s: u64,
}

impl Default for CortexConfig {
    fn default() -> Self {
        Self {
            spread_max_bps: 25.0,
            spread_kill_bps: 75.0,
            depth_min: 300_000.0,
            depth_kill_min: 100_000.0,
            cortex_kill_window_s: 10,
            dvol_jump_pct: 0.10,
            dvol_jump_window_s: 60,
            dvol_cooldown_s: 300,
            spread_depth_cooldown_s: 120,
        }
    }
}

/// Market data snapshot provided to the Cortex each tick.
#[derive(Debug, Clone, Copy)]
pub struct MarketData {
    /// Current DVOL (implied vol index, as a fraction e.g. 0.80 for 80%)
    pub dvol: Option<f64>,
    /// Current spread in bps
    pub spread_bps: Option<f64>,
    /// Depth: min(sum of top-5 bid notional, sum of top-5 ask notional) in USD
    pub depth_top_n: Option<f64>,
    /// Current wall-clock timestamp in ms since epoch
    pub now_ms: u64,
}

/// Safety override emitted by the Cortex each tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CortexSignal {
    /// No override — market conditions within thresholds.
    None,
    /// Force ReduceOnly for `cooldown_s` seconds.
    ForceReduceOnly { cooldown_s: u64 },
    /// Force Kill — extreme market dislocation.
    ForceKill,
}

impl CortexSignal {
    /// Returns the severity level for aggregation (higher = more severe).
    fn severity(&self) -> u8 {
        match self {
            CortexSignal::None => 0,
            CortexSignal::ForceReduceOnly { .. } => 1,
            CortexSignal::ForceKill => 2,
        }
    }

    /// Returns the more severe of two overrides (ForceKill > ForceReduceOnly > None).
    pub fn max_severity(a: CortexSignal, b: CortexSignal) -> CortexSignal {
        if a.severity() >= b.severity() { a } else { b }
    }
}

/// Result of evaluating a cancel/replace request under ws_gap conditions (AT-119).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CancelReplacePermission {
    /// Cancel/replace is allowed.
    Allowed,
    /// Cancel/replace is blocked (ws_gap active and request is risk-increasing).
    Blocked,
}

/// Internal DVOL sample for rolling window jump detection.
#[derive(Debug, Clone, Copy)]
struct DvolSample {
    dvol: f64,
    ts_ms: u64,
}

/// Internal windowed-trip state for spread/depth kill threshold.
#[derive(Debug, Clone, Copy)]
struct KillWindowState {
    /// Timestamp (ms) when the current trip window first started (None = not tripping).
    trip_start_ms: Option<u64>,
}

impl KillWindowState {
    fn new() -> Self {
        Self {
            trip_start_ms: Option::None,
        }
    }

    /// Returns `true` if breach has been continuous for >= `window_s`.
    fn update_and_check(&mut self, exceeds: bool, now_ms: u64, window_s: u64) -> bool {
        if exceeds {
            let start = self.trip_start_ms.get_or_insert(now_ms);
            let elapsed_ms = now_ms.saturating_sub(*start);
            elapsed_ms >= window_s * 1_000
        } else {
            self.trip_start_ms = Option::None;
            false
        }
    }
}

/// Observability counters for `cortex_override_total{kind}`.
#[derive(Debug, Clone, Copy, Default)]
pub struct CortexCounters {
    /// Number of times ForceReduceOnly was emitted (any cause).
    pub force_reduce_only_total: u64,
    /// Number of times ForceKill was emitted.
    pub force_kill_total: u64,
    /// Number of times fail-closed triggered ForceReduceOnly (missing/stale input).
    pub fail_closed_total: u64,
}

/// Reflexive Cortex — stateful evaluator for §2.3 trip rules.
///
/// Call `evaluate()` once per tick with `MarketData` and the config.
/// The monitor tracks DVOL history and kill window state internally.
#[derive(Debug)]
pub struct CortexMonitor {
    /// Ring buffer of recent DVOL samples for jump detection.
    dvol_history: Vec<DvolSample>,
    /// Windowed state for spread kill threshold.
    spread_kill_window: KillWindowState,
    /// Windowed state for depth kill threshold.
    depth_kill_window: KillWindowState,
    /// Observability counters.
    pub counters: CortexCounters,
}

impl CortexMonitor {
    pub fn new() -> Self {
        Self {
            dvol_history: Vec::new(),
            spread_kill_window: KillWindowState::new(),
            depth_kill_window: KillWindowState::new(),
            counters: CortexCounters::default(),
        }
    }

    /// Evaluate Cortex safety rules for the current tick.
    ///
    /// Priority order (per §2.3):
    ///   1. Missing/stale inputs → ForceReduceOnly (fail-closed)
    ///   2. spread_kill or depth_kill window tripped → ForceKill
    ///   3. DVOL jump >= dvol_jump_pct within dvol_jump_window_s → ForceReduceOnly
    ///   4. spread > spread_max_bps OR depth < depth_min → ForceReduceOnly
    ///   5. Otherwise → None
    pub fn evaluate(&mut self, data: MarketData, config: &CortexConfig) -> CortexSignal {
        // Step 1: Fail-closed on missing inputs
        let dvol = match data.dvol {
            Some(v) => v,
            None => {
                self.counters.force_reduce_only_total += 1;
                self.counters.fail_closed_total += 1;
                // Reset windows — can't track state with missing data
                self.spread_kill_window.trip_start_ms = Option::None;
                self.depth_kill_window.trip_start_ms = Option::None;
                self.dvol_history.clear();
                return CortexSignal::ForceReduceOnly {
                    cooldown_s: config.spread_depth_cooldown_s,
                };
            }
        };
        let spread_bps = match data.spread_bps {
            Some(v) => v,
            None => {
                self.counters.force_reduce_only_total += 1;
                self.counters.fail_closed_total += 1;
                self.spread_kill_window.trip_start_ms = Option::None;
                self.depth_kill_window.trip_start_ms = Option::None;
                self.dvol_history.clear();
                return CortexSignal::ForceReduceOnly {
                    cooldown_s: config.spread_depth_cooldown_s,
                };
            }
        };
        let depth_top_n = match data.depth_top_n {
            Some(v) => v,
            None => {
                self.counters.force_reduce_only_total += 1;
                self.counters.fail_closed_total += 1;
                self.spread_kill_window.trip_start_ms = Option::None;
                self.depth_kill_window.trip_start_ms = Option::None;
                self.dvol_history.clear();
                return CortexSignal::ForceReduceOnly {
                    cooldown_s: config.spread_depth_cooldown_s,
                };
            }
        };

        let now_ms = data.now_ms;

        // Step 2: Update DVOL history, prune samples outside the window.
        // Hard cap prevents unbounded growth if `now_ms` doesn't advance between ticks
        // (same-millisecond calls or a stale monotonic source).
        self.dvol_history.push(DvolSample {
            dvol,
            ts_ms: now_ms,
        });
        let window_ms = config.dvol_jump_window_s * 1_000;
        self.dvol_history
            .retain(|s| now_ms.saturating_sub(s.ts_ms) <= window_ms);
        // Safety cap: at most 10 samples/s × window_s. Removes oldest if still over limit.
        let max_samples = (config.dvol_jump_window_s as usize).saturating_mul(10).max(128);
        if self.dvol_history.len() > max_samples {
            let drain = self.dvol_history.len() - max_samples;
            self.dvol_history.drain(..drain);
        }

        // Step 3: Check kill window for spread and depth
        let spread_kill_exceeds = spread_bps >= config.spread_kill_bps;
        let depth_kill_exceeds = depth_top_n <= config.depth_kill_min;

        let spread_kill_tripped = self.spread_kill_window.update_and_check(
            spread_kill_exceeds,
            now_ms,
            config.cortex_kill_window_s,
        );
        let depth_kill_tripped = self.depth_kill_window.update_and_check(
            depth_kill_exceeds,
            now_ms,
            config.cortex_kill_window_s,
        );

        if spread_kill_tripped || depth_kill_tripped {
            self.counters.force_kill_total += 1;
            return CortexSignal::ForceKill;
        }

        // Step 4: Check DVOL jump within window
        if self.check_dvol_jump(dvol, now_ms, config) {
            self.counters.force_reduce_only_total += 1;
            return CortexSignal::ForceReduceOnly {
                cooldown_s: config.dvol_cooldown_s,
            };
        }

        // Step 5: Check spread/depth ReduceOnly thresholds
        let spread_ro_exceeds = spread_bps > config.spread_max_bps;
        let depth_ro_exceeds = depth_top_n < config.depth_min;

        if spread_ro_exceeds || depth_ro_exceeds {
            self.counters.force_reduce_only_total += 1;
            return CortexSignal::ForceReduceOnly {
                cooldown_s: config.spread_depth_cooldown_s,
            };
        }

        CortexSignal::None
    }

    /// Check if DVOL has jumped >= dvol_jump_pct within dvol_jump_window_s ending at now_ms.
    ///
    /// Looks for the minimum DVOL value in the window and checks if current dvol
    /// represents >= dvol_jump_pct increase over that minimum.
    fn check_dvol_jump(&self, current_dvol: f64, now_ms: u64, config: &CortexConfig) -> bool {
        if self.dvol_history.len() < 2 {
            return false;
        }
        let window_ms = config.dvol_jump_window_s * 1_000;
        // Find minimum DVOL in the window (excluding the current sample, which is the last)
        let min_dvol_in_window = self
            .dvol_history
            .iter()
            .filter(|s| now_ms.saturating_sub(s.ts_ms) <= window_ms)
            .map(|s| s.dvol)
            .fold(f64::INFINITY, f64::min);

        if min_dvol_in_window == f64::INFINITY || min_dvol_in_window <= 0.0 {
            return false;
        }

        let jump_fraction = (current_dvol - min_dvol_in_window) / min_dvol_in_window;
        jump_fraction >= config.dvol_jump_pct
    }

    /// Evaluate cancel/replace permission given ws_gap_flag state (AT-119).
    ///
    /// When ws_gap_flag is true (open_permission_blocked_latch active with WS gap reason),
    /// risk-increasing cancel/replace MUST be blocked.
    ///
    /// **Definition of `is_risk_increasing` per AT-119 (caller contract):**
    /// A cancel/replace is "risk-increasing" if the replacement order results in larger
    /// net exposure than the cancelled order — i.e., a larger quantity, a tighter limit
    /// that is more likely to fill, or a switch from reduce-only to open. Specifically:
    /// - Cancel + replace with larger qty on the OPEN side → risk-increasing.
    /// - Cancel + replace with same or smaller qty → NOT risk-increasing.
    /// - Cancel with no replacement → NOT risk-increasing (pure risk reduction).
    /// - Cancel + replace a hedge (reduce_only=true) → NOT risk-increasing.
    /// Callers must evaluate the net change in open interest commitment, not just
    /// the absolute order size.
    ///
    /// **Supervision note (operational):** If kill mode is triggered by watchdog staleness,
    /// recovery requires the watchdog process to restart and emit fresh heartbeats.
    /// PolicyGuard has no automatic recovery mechanism — ensure the outermost system layer
    /// runs a supervision tree (e.g. systemd restart policy) that restarts a crashed watchdog
    /// rather than requiring manual operator intervention.
    pub fn evaluate_cancel_replace(
        ws_gap_flag: bool,
        is_risk_increasing: bool,
    ) -> CancelReplacePermission {
        if ws_gap_flag && is_risk_increasing {
            CancelReplacePermission::Blocked
        } else {
            CancelReplacePermission::Allowed
        }
    }
}

impl Default for CortexMonitor {
    fn default() -> Self {
        Self::new()
    }
}

/// Compute depth_topN from raw bid/ask level data (AT-420).
///
/// depth_topN = min(sum of top-5 bid price*qty, sum of top-5 ask price*qty).
/// N is capped at 5 per side.
pub fn compute_depth_top_n(bids: &[(f64, f64)], asks: &[(f64, f64)]) -> f64 {
    let bid_usd: f64 = bids.iter().take(5).map(|(price, qty)| price * qty).sum();
    let ask_usd: f64 = asks.iter().take(5).map(|(price, qty)| price * qty).sum();
    bid_usd.min(ask_usd)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_data(dvol: f64, spread_bps: f64, depth_top_n: f64, now_ms: u64) -> MarketData {
        MarketData {
            dvol: Some(dvol),
            spread_bps: Some(spread_bps),
            depth_top_n: Some(depth_top_n),
            now_ms,
        }
    }

    #[test]
    fn test_normal_below_all_thresholds() {
        let mut monitor = CortexMonitor::new();
        let config = CortexConfig::default();
        let data = make_data(0.80, 10.0, 500_000.0, 100_000);
        assert_eq!(monitor.evaluate(data, &config), CortexSignal::None);
    }

    #[test]
    fn test_missing_dvol_fail_closed() {
        let mut monitor = CortexMonitor::new();
        let config = CortexConfig::default();
        let data = MarketData {
            dvol: None,
            spread_bps: Some(10.0),
            depth_top_n: Some(500_000.0),
            now_ms: 100_000,
        };
        let result = monitor.evaluate(data, &config);
        assert!(
            matches!(result, CortexSignal::ForceReduceOnly { .. }),
            "Missing dvol must trigger fail-closed ForceReduceOnly"
        );
        assert_eq!(monitor.counters.fail_closed_total, 1);
    }

    #[test]
    fn test_missing_spread_fail_closed() {
        let mut monitor = CortexMonitor::new();
        let config = CortexConfig::default();
        let data = MarketData {
            dvol: Some(0.80),
            spread_bps: None,
            depth_top_n: Some(500_000.0),
            now_ms: 100_000,
        };
        let result = monitor.evaluate(data, &config);
        assert!(
            matches!(result, CortexSignal::ForceReduceOnly { .. }),
            "Missing spread must trigger fail-closed ForceReduceOnly"
        );
    }

    #[test]
    fn test_missing_depth_fail_closed() {
        let mut monitor = CortexMonitor::new();
        let config = CortexConfig::default();
        let data = MarketData {
            dvol: Some(0.80),
            spread_bps: Some(10.0),
            depth_top_n: None,
            now_ms: 100_000,
        };
        let result = monitor.evaluate(data, &config);
        assert!(
            matches!(result, CortexSignal::ForceReduceOnly { .. }),
            "Missing depth must trigger fail-closed ForceReduceOnly"
        );
    }
}
