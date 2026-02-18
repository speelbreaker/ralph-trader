//! EvidenceGuard — No Evidence → No Opens.
//! Per CONTRACT.md §2.2.2.
//!
//! EvidenceChainState = GREEN iff ALL are true over the rolling window:
//!   - All required counters present and fresh (fail-closed if missing/stale).
//!   - No required counter increased within the last `evidenceguard_window_s` seconds.
//!   - parquet_queue_depth_pct NOT > parquet_queue_trip_pct for >= trip_window_s (strict >).
//!   - Clear: depth_pct < clear_pct for >= queue_clear_window_s (AND cooldown elapsed).
//!
//! Profile gating: only enforced when `enforced_profile != CSP`.
//!
//! Self-contained: safe to include via #[path] in tests.

// NOTE: items not yet wired into the integration produce dead_code warnings intentionally.

/// Enforcement profile — determines whether EvidenceGuard is active.
/// Using an enum prevents typo-based bypasses (e.g. "csp" vs "CSP").
///
/// **Note:** `guard.rs` has a parallel `EnforcedProfile` enum with identical variants.
/// They exist separately because `guard.rs` is `#[path]`-included directly by tests
/// (no crate module system), preventing a shared import. They must be kept in sync.
/// Unification is deferred to Slice 9+ when integration wiring is added.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvidenceEnforcedProfile {
    /// Contract Safety Profile only — EvidenceGuard is NOT enforced.
    Csp,
    /// General Operational Profile — EvidenceGuard IS enforced.
    Gop,
    /// Full profile — EvidenceGuard IS enforced (same semantics as Gop for guard purposes).
    Full,
}

impl EvidenceEnforcedProfile {
    pub fn is_csp(&self) -> bool {
        matches!(self, EvidenceEnforcedProfile::Csp)
    }
}

/// EvidenceChainState as evaluated per tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvidenceChainState {
    Green,
    NotGreen,
}

/// Decision returned by EvidenceGuard per evaluation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvidenceGuardDecision {
    /// enforced_profile == CSP: guard is not enforced.
    NotEnforced,
    /// enforced_profile != CSP and chain is GREEN.
    Green,
    /// enforced_profile != CSP and chain is NOT GREEN — block OPEN intents.
    NotGreen,
}

/// Inputs consumed by EvidenceGuard each evaluation tick.
pub struct EvidenceGuardInputs {
    /// Current timestamp in milliseconds.
    pub now_ms: u64,
    /// Cumulative truth_capsule_write_errors counter (fail-closed if None).
    pub truth_capsule_write_errors: Option<u64>,
    /// Cumulative decision_snapshot_write_errors counter (fail-closed if None).
    pub decision_snapshot_write_errors: Option<u64>,
    /// Cumulative wal_write_errors counter (fail-closed if None).
    pub wal_write_errors: Option<u64>,
    /// Cumulative parquet_queue_overflow_count counter (fail-closed if None).
    pub parquet_queue_overflow_count: Option<u64>,
    /// Raw parquet queue depth (items) for depth_pct computation.
    pub parquet_queue_depth: Option<u64>,
    /// Raw parquet queue capacity for depth_pct computation.
    pub parquet_queue_capacity: Option<u64>,
    /// Timestamp of last counter update (ms) for freshness check.
    pub counters_last_update_ts_ms: Option<u64>,
    /// Enforcement profile. Csp → guard not enforced; Gop/Full → enforced.
    pub enforced_profile: EvidenceEnforcedProfile,
}

/// Configuration for EvidenceGuard.
pub struct EvidenceGuardConfig {
    /// Rolling window for counter-increase detection (seconds). Default 60.
    pub evidenceguard_window_s: u64,
    /// Max staleness of counter update before fail-closed (ms). Default 60000.
    pub evidenceguard_counters_max_age_ms: u64,
    /// Queue depth trip threshold — strict > (default 0.90 per PL-1).
    pub parquet_queue_trip_pct: f64,
    /// Minimum seconds depth must exceed trip_pct to trigger. Default 5.
    pub parquet_queue_trip_window_s: u64,
    /// Queue depth clear threshold — strict < (default 0.70).
    pub parquet_queue_clear_pct: f64,
    /// Seconds below clear_pct before allowing GREEN recovery. Default 120.
    pub queue_clear_window_s: u64,
    /// Global cooldown after recovery (seconds). Default 0.
    pub evidenceguard_global_cooldown: u64,
}

impl Default for EvidenceGuardConfig {
    fn default() -> Self {
        Self {
            evidenceguard_window_s: 60,
            evidenceguard_counters_max_age_ms: 60_000,
            parquet_queue_trip_pct: 0.90,
            parquet_queue_trip_window_s: 5,
            parquet_queue_clear_pct: 0.70,
            queue_clear_window_s: 120,
            evidenceguard_global_cooldown: 0,
        }
    }
}

/// Tracks a cumulative counter: records the last known value and the timestamp
/// when that value was last seen to *increase*. Used for rolling-window checks.
#[derive(Debug, Clone, Copy)]
struct CounterTracker {
    /// The last observed cumulative value.
    last_value: u64,
    /// Timestamp (ms) at which the counter last *increased*.
    /// None if the counter has never been seen to increase.
    last_increase_ts_ms: Option<u64>,
}

impl CounterTracker {
    fn new(initial_value: u64) -> Self {
        Self {
            last_value: initial_value,
            last_increase_ts_ms: None,
        }
    }

    /// Update with a new observation. Returns true if the counter increased
    /// within the rolling `window_ms`.
    fn update_and_check(&mut self, new_value: u64, now_ms: u64, window_ms: u64) -> bool {
        if new_value > self.last_value {
            self.last_increase_ts_ms = Some(now_ms);
            self.last_value = new_value;
        } else {
            self.last_value = new_value;
        }
        // Increased within window?
        match self.last_increase_ts_ms {
            None => false,
            Some(ts) => now_ms.saturating_sub(ts) < window_ms,
        }
    }
}

/// EvidenceGuard stateful evaluator.
pub struct EvidenceGuard {
    truth_capsule_tracker: Option<CounterTracker>,
    snapshot_tracker: Option<CounterTracker>,
    wal_tracker: Option<CounterTracker>,
    parquet_overflow_tracker: Option<CounterTracker>,

    /// Timestamp when depth first exceeded trip_pct (None = not accumulating).
    queue_trip_start_ms: Option<u64>,
    /// Whether the queue depth trip is currently active.
    queue_tripped: bool,
    /// Timestamp when depth first dropped below clear_pct during recovery.
    queue_clear_start_ms: Option<u64>,
    /// Timestamp of last successful recovery (for cooldown).
    recovery_cleared_ms: Option<u64>,

    /// Observability: counter of blocked OPEN intents.
    pub evidence_guard_blocked_opens_count: u64,
    /// Observability gauge: 1 = green, 0 = not green.
    pub evidence_chain_state_gauge: u64,
}

impl EvidenceGuard {
    pub fn new() -> Self {
        Self {
            truth_capsule_tracker: None,
            snapshot_tracker: None,
            wal_tracker: None,
            parquet_overflow_tracker: None,
            queue_trip_start_ms: None,
            queue_tripped: false,
            queue_clear_start_ms: None,
            recovery_cleared_ms: None,
            evidence_guard_blocked_opens_count: 0,
            evidence_chain_state_gauge: 0,
        }
    }

    /// Evaluate EvidenceChainState for the current tick.
    pub fn evaluate(
        &mut self,
        inputs: &EvidenceGuardInputs,
        config: &EvidenceGuardConfig,
    ) -> EvidenceGuardDecision {
        if inputs.enforced_profile.is_csp() {
            return EvidenceGuardDecision::NotEnforced;
        }

        let state = self.compute_state(inputs, config);
        self.evidence_chain_state_gauge = if state == EvidenceChainState::Green {
            1
        } else {
            0
        };

        match state {
            EvidenceChainState::Green => EvidenceGuardDecision::Green,
            EvidenceChainState::NotGreen => EvidenceGuardDecision::NotGreen,
        }
    }

    /// Returns true if the decision blocks OPEN intents.
    pub fn blocks_open(decision: EvidenceGuardDecision) -> bool {
        decision == EvidenceGuardDecision::NotGreen
    }

    /// Increment blocked_opens_count when an OPEN is rejected.
    pub fn record_blocked_open(&mut self) {
        self.evidence_guard_blocked_opens_count += 1;
    }

    fn compute_state(
        &mut self,
        inputs: &EvidenceGuardInputs,
        config: &EvidenceGuardConfig,
    ) -> EvidenceChainState {
        let now_ms = inputs.now_ms;
        let window_ms = config.evidenceguard_window_s * 1_000;

        // 1. Freshness gate: if counters_last_update_ts_ms is present and stale → fail-closed.
        if inputs
            .counters_last_update_ts_ms
            .is_some_and(|ts| now_ms.saturating_sub(ts) > config.evidenceguard_counters_max_age_ms)
        {
            return EvidenceChainState::NotGreen;
        }

        // 2. Required counter presence check (fail-closed on None).
        let tc = match inputs.truth_capsule_write_errors {
            Some(v) => v,
            None => return EvidenceChainState::NotGreen,
        };
        let ds = match inputs.decision_snapshot_write_errors {
            Some(v) => v,
            None => return EvidenceChainState::NotGreen,
        };
        let wal = match inputs.wal_write_errors {
            Some(v) => v,
            None => return EvidenceChainState::NotGreen,
        };
        let pq = match inputs.parquet_queue_overflow_count {
            Some(v) => v,
            None => return EvidenceChainState::NotGreen,
        };

        // 3. Counter rolling-window increase checks.
        let tc_increased = {
            let tracker = self
                .truth_capsule_tracker
                .get_or_insert_with(|| CounterTracker::new(tc));
            tracker.update_and_check(tc, now_ms, window_ms)
        };
        if tc_increased {
            return EvidenceChainState::NotGreen;
        }

        let ds_increased = {
            let tracker = self
                .snapshot_tracker
                .get_or_insert_with(|| CounterTracker::new(ds));
            tracker.update_and_check(ds, now_ms, window_ms)
        };
        if ds_increased {
            return EvidenceChainState::NotGreen;
        }

        let wal_increased = {
            let tracker = self
                .wal_tracker
                .get_or_insert_with(|| CounterTracker::new(wal));
            tracker.update_and_check(wal, now_ms, window_ms)
        };
        if wal_increased {
            return EvidenceChainState::NotGreen;
        }

        let pq_increased = {
            let tracker = self
                .parquet_overflow_tracker
                .get_or_insert_with(|| CounterTracker::new(pq));
            tracker.update_and_check(pq, now_ms, window_ms)
        };
        if pq_increased {
            return EvidenceChainState::NotGreen;
        }

        // 4. Parquet queue depth threshold (fail-closed if metrics missing).
        let depth_pct = match self.compute_queue_depth_pct(inputs) {
            Some(p) => p,
            None => return EvidenceChainState::NotGreen,
        };

        self.update_queue_trip_state(depth_pct, now_ms, config);

        if self.queue_tripped {
            return EvidenceChainState::NotGreen;
        }

        EvidenceChainState::Green
    }

    fn compute_queue_depth_pct(&self, inputs: &EvidenceGuardInputs) -> Option<f64> {
        let depth = inputs.parquet_queue_depth?;
        let capacity = inputs.parquet_queue_capacity?;
        let denom = (capacity as f64).max(1.0);
        Some(depth as f64 / denom)
    }

    fn update_queue_trip_state(
        &mut self,
        depth_pct: f64,
        now_ms: u64,
        config: &EvidenceGuardConfig,
    ) {
        let trip_threshold = config.parquet_queue_trip_pct;
        let clear_threshold = config.parquet_queue_clear_pct;
        let trip_window_ms = config.parquet_queue_trip_window_s * 1_000;
        let clear_window_ms = config.queue_clear_window_s * 1_000;
        let cooldown_ms = config.evidenceguard_global_cooldown * 1_000;

        if !self.queue_tripped {
            if depth_pct > trip_threshold {
                // Accumulate trip window.
                let trip_start = self.queue_trip_start_ms.get_or_insert(now_ms);
                let elapsed = now_ms.saturating_sub(*trip_start);
                if elapsed >= trip_window_ms {
                    self.queue_tripped = true;
                    self.queue_clear_start_ms = None;
                }
            } else {
                // Below trip threshold — reset trip accumulation.
                self.queue_trip_start_ms = None;
            }
        } else {
            // Currently tripped: check recovery.
            if depth_pct < clear_threshold {
                let clear_start = self.queue_clear_start_ms.get_or_insert(now_ms);
                let clear_elapsed = now_ms.saturating_sub(*clear_start);
                let required_clear = clear_window_ms.max(cooldown_ms);
                if clear_elapsed >= required_clear {
                    self.queue_tripped = false;
                    self.queue_trip_start_ms = None;
                    self.queue_clear_start_ms = None;
                    self.recovery_cleared_ms = Some(now_ms);
                }
            } else {
                // Not below clear threshold — reset clear accumulation.
                self.queue_clear_start_ms = None;
            }
        }
    }

    /// Returns the current EvidenceChainState for observability.
    pub fn current_state(&self) -> EvidenceChainState {
        if self.evidence_chain_state_gauge == 1 {
            EvidenceChainState::Green
        } else {
            EvidenceChainState::NotGreen
        }
    }
}

impl Default for EvidenceGuard {
    fn default() -> Self {
        Self::new()
    }
}
