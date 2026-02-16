//! Integration tests for PendingExposure Reservation
//!
//! Validates CONTRACT.md §1.4.2.1 acceptance criteria.

use soldier_core::risk::{PendingExposureTracker, ReserveResult};

/// AT-225: GIVEN 5 concurrent opens with identical current_delta=0
/// WHEN PendingExposure reservation runs
/// THEN only subset fitting budget reserves; rest reject; no over-fill
#[test]
fn test_at_225_concurrent_opens_subset_reserves() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

    // Simulate 5 concurrent intents, each requesting 30 delta
    // Budget is 100, so at most 3 can reserve (3 * 30 = 90)
    let intents = vec![
        ("intent-1", 30.0),
        ("intent-2", 30.0),
        ("intent-3", 30.0),
        ("intent-4", 30.0),
        ("intent-5", 30.0),
    ];

    let mut reserved = 0;
    let mut rejected = 0;

    for (id, delta) in intents {
        match tracker.reserve(id.to_string(), "BTC-PERP", delta, 0.0) {
            ReserveResult::Reserved => reserved += 1,
            ReserveResult::BudgetExceeded { .. } => rejected += 1,
        }
    }

    // AT-225 pass criteria:
    // - Only subset that fits budget reserves
    // - Rest reject
    // - No over-fill (total pending <= budget)
    assert_eq!(reserved, 3, "Expected exactly 3 reservations to succeed");
    assert_eq!(rejected, 2, "Expected exactly 2 reservations to fail");

    let pending = tracker.get_pending_delta("BTC-PERP");
    assert!(
        pending <= 100.0,
        "Pending delta {} exceeds budget 100.0 (over-fill)",
        pending
    );
    assert_eq!(pending, 90.0, "Expected pending delta to be 90.0 (3 * 30)");
}

/// AT-910: GIVEN reservation would breach budget
/// WHEN reserve() attempted
/// THEN rejected with PendingExposureBudgetExceeded and no dispatch
#[test]
fn test_at_910_budget_breach_rejection() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("ETH-PERP".to_string(), Some(50.0));

    // Current delta is 30, pending is 0, limit is 50 → 20 available
    let result = tracker.reserve("intent-1".to_string(), "ETH-PERP", 25.0, 30.0);

    // AT-910 pass criteria:
    // - Rejection reason is BudgetExceeded
    // - No reservation created (dispatch count = 0)
    match result {
        ReserveResult::BudgetExceeded {
            requested,
            available,
        } => {
            assert_eq!(requested, 25.0);
            assert!(
                available < requested,
                "Available {} should be less than requested {}",
                available,
                requested
            );
        }
        ReserveResult::Reserved => {
            panic!("Expected BudgetExceeded, got Reserved (dispatch occurred)");
        }
    }

    // Verify no reservation was created
    assert_eq!(
        tracker.get_pending_delta("ETH-PERP"),
        0.0,
        "No pending delta should exist after rejected reservation"
    );
}

/// Test that reservation accounts for current + pending exposure
#[test]
fn test_reservation_uses_current_plus_pending() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

    // Current delta = 40, reserve 30 → total = 70 (OK)
    let r1 = tracker.reserve("intent-1".to_string(), "BTC-PERP", 30.0, 40.0);
    assert_eq!(r1, ReserveResult::Reserved);

    // Current delta = 40, pending = 30, try to reserve 35 → total = 105 (FAIL)
    let r2 = tracker.reserve("intent-2".to_string(), "BTC-PERP", 35.0, 40.0);
    assert!(matches!(r2, ReserveResult::BudgetExceeded { .. }));

    // But 25 should work → total = 95 (OK)
    let r3 = tracker.reserve("intent-3".to_string(), "BTC-PERP", 25.0, 40.0);
    assert_eq!(r3, ReserveResult::Reserved);
}

/// Test that release frees capacity for new reservations
#[test]
fn test_release_terminal_outcome() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

    // Reserve up to limit
    tracker.reserve("intent-1".to_string(), "BTC-PERP", 60.0, 0.0);
    tracker.reserve("intent-2".to_string(), "BTC-PERP", 40.0, 0.0);

    // Try to reserve more → should fail
    let r1 = tracker.reserve("intent-3".to_string(), "BTC-PERP", 10.0, 0.0);
    assert!(matches!(r1, ReserveResult::BudgetExceeded { .. }));

    // Release one reservation (terminal outcome: Filled)
    let released = tracker.release(&"intent-1".to_string(), "BTC-PERP");
    assert!(released, "Release should succeed");

    // Now we can reserve again
    let r2 = tracker.reserve("intent-4".to_string(), "BTC-PERP", 50.0, 0.0);
    assert_eq!(r2, ReserveResult::Reserved);
}

/// Test that reservations are isolated per instrument
#[test]
fn test_per_instrument_isolation() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));
    tracker.register_instrument("ETH-PERP".to_string(), Some(50.0));

    // Fill BTC budget
    tracker.reserve("intent-1".to_string(), "BTC-PERP", 100.0, 0.0);

    // BTC should reject new reservations
    let btc_result = tracker.reserve("intent-2".to_string(), "BTC-PERP", 10.0, 0.0);
    assert!(matches!(btc_result, ReserveResult::BudgetExceeded { .. }));

    // But ETH should still accept reservations
    let eth_result = tracker.reserve("intent-3".to_string(), "ETH-PERP", 40.0, 0.0);
    assert_eq!(eth_result, ReserveResult::Reserved);
}

/// Test that missing delta_limit allows all reservations (fail-open for unconfigured instruments)
#[test]
fn test_missing_delta_limit_allows_all() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), None); // No limit

    // Should allow arbitrarily large reservations
    let r1 = tracker.reserve("intent-1".to_string(), "BTC-PERP", 1000.0, 0.0);
    assert_eq!(r1, ReserveResult::Reserved);

    let r2 = tracker.reserve("intent-2".to_string(), "BTC-PERP", 5000.0, 0.0);
    assert_eq!(r2, ReserveResult::Reserved);
}

/// Test double-release is safe (idempotent)
#[test]
fn test_double_release_is_safe() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

    tracker.reserve("intent-1".to_string(), "BTC-PERP", 50.0, 0.0);

    let released1 = tracker.release(&"intent-1".to_string(), "BTC-PERP");
    assert!(released1);

    // Second release should return false but not panic
    let released2 = tracker.release(&"intent-1".to_string(), "BTC-PERP");
    assert!(!released2);

    // Pending should still be 0
    assert_eq!(tracker.get_pending_delta("BTC-PERP"), 0.0);
}

/// Test global pending delta aggregation
#[test]
fn test_global_pending_delta_aggregation() {
    let tracker = PendingExposureTracker::new(Some(200.0));
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));
    tracker.register_instrument("ETH-PERP".to_string(), Some(80.0));

    tracker.reserve("intent-1".to_string(), "BTC-PERP", 60.0, 0.0);
    tracker.reserve("intent-2".to_string(), "ETH-PERP", 50.0, 0.0);

    assert_eq!(tracker.get_global_pending_delta(), 110.0);

    tracker.release(&"intent-1".to_string(), "BTC-PERP");
    assert_eq!(tracker.get_global_pending_delta(), 50.0);
}

/// Test edge case: zero delta reservation
#[test]
fn test_zero_delta_reservation() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

    let result = tracker.reserve("intent-1".to_string(), "BTC-PERP", 0.0, 0.0);
    assert_eq!(result, ReserveResult::Reserved);
    assert_eq!(tracker.get_pending_delta("BTC-PERP"), 0.0);
}

/// Test negative delta (short) reservations
#[test]
fn test_negative_delta_reservations() {
    let tracker = PendingExposureTracker::new(None);
    tracker.register_instrument("BTC-PERP".to_string(), Some(100.0));

    // Reserve short delta (negative value) → should use absolute value
    let result = tracker.reserve("intent-1".to_string(), "BTC-PERP", -50.0, 0.0);
    assert_eq!(result, ReserveResult::Reserved);

    // Pending should be positive (absolute value)
    assert_eq!(tracker.get_pending_delta("BTC-PERP"), 50.0);
}
