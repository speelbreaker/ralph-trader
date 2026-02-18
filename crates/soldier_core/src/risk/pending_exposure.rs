//! PendingExposure Reservation (Anti Over‑Fill)
//!
//! Implements §1.4.2.1 from CONTRACT.md.
//!
//! Without reservation, multiple concurrent signals can observe the same "free delta"
//! and over-allocate risk budget. This module provides atomic reservation of projected
//! exposure impact before dispatch.
//!
//! # Model
//! - Maintain `pending_delta` per instrument + global
//! - For each candidate group:
//!   1. Compute `delta_impact_est` from proposal greeks
//!   2. Attempt `reserve(delta_impact_est)`:
//!      - If reservation would breach limits → reject with `PendingExposureBudgetExceeded`
//!   3. On terminal outcome (Filled/Rejected/Canceled) → release reservation

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Unique identifier for a reservation (intent ID or group ID)
pub type ReservationId = String;

/// Exposure delta in contracts (positive = long, negative = short)
pub type DeltaContracts = f64;

/// Result of attempting a reservation
#[derive(Debug, Clone, PartialEq)]
pub enum ReserveResult {
    /// Reservation succeeded
    Reserved,
    /// Reservation would breach budget
    BudgetExceeded {
        requested: DeltaContracts,
        available: DeltaContracts,
    },
}

/// Per-instrument pending exposure tracker
#[derive(Debug, Clone)]
struct InstrumentPending {
    /// Total pending delta for this instrument (sum of all active reservations)
    pending_delta: DeltaContracts,
    /// Budget limit for this instrument (from config)
    delta_limit: Option<DeltaContracts>,
    /// Active reservations: reservation_id → delta_impact
    reservations: HashMap<ReservationId, DeltaContracts>,
}

impl InstrumentPending {
    fn new(delta_limit: Option<DeltaContracts>) -> Self {
        Self {
            pending_delta: 0.0,
            delta_limit,
            reservations: HashMap::new(),
        }
    }

    /// Check if reservation would breach budget
    fn can_reserve(&self, delta_impact: DeltaContracts, current_delta: DeltaContracts) -> bool {
        let Some(limit) = self.delta_limit else {
            // No limit configured → allow (fail-open for this specific check)
            return true;
        };

        let total_after_reserve =
            current_delta.abs() + self.pending_delta.abs() + delta_impact.abs();
        total_after_reserve <= limit.abs()
    }

    fn reserve(&mut self, id: ReservationId, delta_impact: DeltaContracts) {
        // Make idempotent: if reservation exists, subtract old value first
        if let Some(old_impact) = self.reservations.get(&id) {
            self.pending_delta -= old_impact.abs();
        }
        self.pending_delta += delta_impact.abs();
        self.reservations.insert(id, delta_impact);
    }

    fn release(&mut self, id: &ReservationId) -> bool {
        if let Some(delta_impact) = self.reservations.remove(id) {
            self.pending_delta -= delta_impact.abs();
            true
        } else {
            false
        }
    }
}

/// Global pending exposure tracker across all instruments
#[derive(Clone)]
pub struct PendingExposureTracker {
    /// Per-instrument pending exposure
    instruments: Arc<Mutex<HashMap<String, InstrumentPending>>>,
    /// Global pending delta limit (optional, reserved for future global budget check)
    #[allow(dead_code)]
    global_limit: Option<DeltaContracts>,
}

impl PendingExposureTracker {
    /// Create a new tracker with optional global limit
    pub fn new(global_limit: Option<DeltaContracts>) -> Self {
        Self {
            instruments: Arc::new(Mutex::new(HashMap::new())),
            global_limit,
        }
    }

    /// Register an instrument with its delta limit
    pub fn register_instrument(&self, instrument_id: String, delta_limit: Option<DeltaContracts>) {
        if delta_limit.is_none() {
            eprintln!(
                "[WARN] pending_exposure: instrument '{}' registered with no delta limit — all reservations will be allowed (fail-open)",
                instrument_id
            );
        }
        let mut instruments = match self.instruments.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("pending_exposure lock poisoned: {e}"),
        };
        instruments.insert(instrument_id, InstrumentPending::new(delta_limit));
    }

    /// Attempt to reserve exposure for a new intent
    ///
    /// # Arguments
    /// * `reservation_id` - Unique ID for this reservation (intent/group ID)
    /// * `instrument_id` - Instrument being traded
    /// * `delta_impact_est` - Estimated delta impact (absolute value)
    /// * `current_delta` - Current realized delta for this instrument
    ///
    /// # Returns
    /// * `ReserveResult::Reserved` if successful
    /// * `ReserveResult::BudgetExceeded` if reservation would breach limits
    pub fn reserve(
        &self,
        reservation_id: ReservationId,
        instrument_id: &str,
        delta_impact_est: DeltaContracts,
        current_delta: DeltaContracts,
    ) -> ReserveResult {
        // Defensive: clamp negative delta_impact_est to absolute value
        let delta_impact_est = if delta_impact_est < 0.0 {
            eprintln!(
                "pending_exposure: negative delta_impact_est={}, using absolute value",
                delta_impact_est
            );
            delta_impact_est.abs()
        } else {
            delta_impact_est
        };

        let mut instruments = match self.instruments.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("pending_exposure lock poisoned: {e}"),
        };

        // Get instrument tracker - fail-closed: reject unregistered instruments
        let inst = match instruments.get_mut(instrument_id) {
            Some(inst) => inst,
            None => {
                eprintln!(
                    "pending_exposure: instrument '{}' not registered, rejecting (fail-closed)",
                    instrument_id
                );
                return ReserveResult::BudgetExceeded {
                    requested: delta_impact_est.abs(),
                    available: 0.0,
                };
            }
        };

        // Check if reservation would breach budget
        if !inst.can_reserve(delta_impact_est, current_delta) {
            let available = inst.delta_limit.unwrap_or(0.0).abs()
                - current_delta.abs()
                - inst.pending_delta.abs();
            return ReserveResult::BudgetExceeded {
                requested: delta_impact_est.abs(),
                available: available.max(0.0),
            };
        }

        // Reserve
        inst.reserve(reservation_id, delta_impact_est);

        ReserveResult::Reserved
    }

    /// Release a reservation when intent reaches terminal state
    ///
    /// # Arguments
    /// * `reservation_id` - Reservation to release
    /// * `instrument_id` - Instrument for the reservation
    ///
    /// # Returns
    /// `true` if reservation was found and released, `false` if not found
    pub fn release(&self, reservation_id: &ReservationId, instrument_id: &str) -> bool {
        let mut instruments = match self.instruments.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("pending_exposure lock poisoned: {e}"),
        };

        if let Some(inst) = instruments.get_mut(instrument_id) {
            inst.release(reservation_id)
        } else {
            false
        }
    }

    /// Get current pending delta for an instrument
    pub fn get_pending_delta(&self, instrument_id: &str) -> DeltaContracts {
        let instruments = match self.instruments.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("pending_exposure lock poisoned: {e}"),
        };
        instruments
            .get(instrument_id)
            .map(|inst| inst.pending_delta)
            .unwrap_or(0.0)
    }

    /// Get total global pending delta across all instruments
    pub fn get_global_pending_delta(&self) -> DeltaContracts {
        let instruments = match self.instruments.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("pending_exposure lock poisoned: {e}"),
        };
        instruments.values().map(|inst| inst.pending_delta).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_reserve_succeeds_within_budget() {
        let tracker = PendingExposureTracker::new(None);
        tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

        let result = tracker.reserve(
            "intent-1".to_string(),
            "BTC-PERP",
            10.0, // delta_impact_est
            0.0,  // current_delta
        );

        assert_eq!(result, ReserveResult::Reserved);
        assert_eq!(tracker.get_pending_delta("BTC-PERP"), 10.0);
    }

    #[test]
    fn test_reserve_rejects_when_budget_exceeded() {
        let tracker = PendingExposureTracker::new(None);
        tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

        // Reserve 95, leaving 5 available
        let result1 = tracker.reserve("intent-1".to_string(), "BTC-PERP", 95.0, 0.0);
        assert_eq!(result1, ReserveResult::Reserved);

        // Try to reserve 10 more → should fail
        let result2 = tracker.reserve("intent-2".to_string(), "BTC-PERP", 10.0, 0.0);
        match result2 {
            ReserveResult::BudgetExceeded {
                requested,
                available,
            } => {
                assert_eq!(requested, 10.0);
                assert!(available < 10.0);
            }
            _ => panic!("Expected BudgetExceeded"),
        }
    }

    #[test]
    fn test_release_frees_capacity() {
        let tracker = PendingExposureTracker::new(None);
        tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

        tracker.reserve("intent-1".to_string(), "BTC-PERP", 50.0, 0.0);
        assert_eq!(tracker.get_pending_delta("BTC-PERP"), 50.0);

        let released = tracker.release(&"intent-1".to_string(), "BTC-PERP");
        assert!(released);
        assert_eq!(tracker.get_pending_delta("BTC-PERP"), 0.0);

        // Now we can reserve again
        let result = tracker.reserve("intent-2".to_string(), "BTC-PERP", 50.0, 0.0);
        assert_eq!(result, ReserveResult::Reserved);
    }

    #[test]
    fn test_concurrent_reservations_with_current_delta() {
        let tracker = PendingExposureTracker::new(None);
        tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

        // Current delta = 50, so only 50 available
        let result1 = tracker.reserve("intent-1".to_string(), "BTC-PERP", 30.0, 50.0);
        assert_eq!(result1, ReserveResult::Reserved);

        // Try to reserve 25 more → should fail (50 + 30 + 25 = 105 > 100)
        let result2 = tracker.reserve("intent-2".to_string(), "BTC-PERP", 25.0, 50.0);
        assert!(matches!(result2, ReserveResult::BudgetExceeded { .. }));

        // But 15 should work (50 + 30 + 15 = 95 <= 100)
        let result3 = tracker.reserve("intent-3".to_string(), "BTC-PERP", 15.0, 50.0);
        assert_eq!(result3, ReserveResult::Reserved);
    }

    #[test]
    fn test_no_limit_allows_all_reservations() {
        let tracker = PendingExposureTracker::new(None);
        tracker.register_instrument("BTC-PERP".to_string(), None); // No limit

        let result = tracker.reserve("intent-1".to_string(), "BTC-PERP", 1000.0, 0.0);
        assert_eq!(result, ReserveResult::Reserved);
    }

    #[test]
    fn test_multiple_instruments_isolated() {
        let tracker = PendingExposureTracker::new(None);
        tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));
        tracker.register_instrument("ETH-PERP".to_string(), Some(50.0));

        tracker.reserve("intent-1".to_string(), "BTC-PERP", 90.0, 0.0);
        tracker.reserve("intent-2".to_string(), "ETH-PERP", 40.0, 0.0);

        assert_eq!(tracker.get_pending_delta("BTC-PERP"), 90.0);
        assert_eq!(tracker.get_pending_delta("ETH-PERP"), 40.0);

        // BTC is almost full, but ETH still has room
        let result_btc = tracker.reserve("intent-3".to_string(), "BTC-PERP", 15.0, 0.0);
        assert!(matches!(result_btc, ReserveResult::BudgetExceeded { .. }));

        let result_eth = tracker.reserve("intent-4".to_string(), "ETH-PERP", 8.0, 0.0);
        assert_eq!(result_eth, ReserveResult::Reserved);
    }

    #[test]
    fn test_unregistered_instrument_rejected_fail_closed() {
        // REMAINING-2 from failure review: test fail-closed behavior for unregistered instruments
        let tracker = PendingExposureTracker::new(None);
        tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

        // Attempt to reserve on unregistered instrument should be rejected
        let result = tracker.reserve(
            "intent-1".to_string(),
            "UNKNOWN-PERP", // Not registered
            10.0,
            0.0,
        );

        // Should reject with BudgetExceeded (available=0)
        match result {
            ReserveResult::BudgetExceeded {
                requested,
                available,
            } => {
                assert_eq!(requested, 10.0);
                assert_eq!(available, 0.0);
            }
            ReserveResult::Reserved => {
                panic!("Unregistered instrument should be rejected (fail-closed)")
            }
        }

        // Verify no pending delta was recorded
        assert_eq!(tracker.get_pending_delta("UNKNOWN-PERP"), 0.0);
    }
}
