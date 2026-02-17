use soldier_core::risk::churn_breaker::{ChurnBreaker, ChurnBreakerDecision, ChurnKey};
use std::time::{Duration, Instant};

fn test_key(strategy_id: &str, fingerprint: &str) -> ChurnKey {
    ChurnKey {
        strategy_id: strategy_id.to_string(),
        structure_fingerprint: fingerprint.to_string(),
    }
}

/// AT-221: Churn breaker blacklists after >2 flattens in 5m
#[test]
fn test_churn_breaker_blacklists_after_three_flattens_in_5m() {
    // GIVEN: 3 EmergencyFlattenGroup triggers for the same key within 5 minutes
    let breaker = ChurnBreaker::new();
    let key = test_key("delta_neutral_btc", "BTC-PERP-delta0.5-legs2");
    let now = Instant::now();

    breaker.record_flatten(key.clone(), now);
    breaker.record_flatten(key.clone(), now + Duration::from_secs(120)); // 2m later
    breaker.record_flatten(key.clone(), now + Duration::from_secs(240)); // 4m later

    // WHEN: a 4th attempt is evaluated
    let decision = breaker.evaluate_open(&key, now + Duration::from_secs(300)); // 5m later

    // THEN: the 4th attempt is rejected and logged (ChurnBreakerTrip), with blacklist TTL enforced
    match decision {
        ChurnBreakerDecision::Reject { reason, trip_count } => {
            assert!(
                reason.contains("ChurnBreakerActive"),
                "Expected ChurnBreakerActive in reason, got: {}",
                reason
            );
            assert_eq!(trip_count, 1, "Expected trip_count=1");
        }
        _ => panic!("Expected Reject, got {:?}", decision),
    }
}

/// AT-221: Verify blacklist TTL enforcement (15m)
#[test]
fn test_churn_breaker_enforces_15m_ttl() {
    // GIVEN: 3 flattens triggering blacklist
    let breaker = ChurnBreaker::new();
    let key = test_key("strategy1", "fingerprint1");
    let now = Instant::now();

    breaker.record_flatten(key.clone(), now);
    breaker.record_flatten(key.clone(), now + Duration::from_secs(60));
    // Third flatten at 2m triggers the blacklist (blocked_until = 2m + 15m = 17m)
    breaker.record_flatten(key.clone(), now + Duration::from_secs(120));

    // WHEN: evaluating at 16m (within blacklist, which expires at 17m)
    let decision_within = breaker.evaluate_open(&key, now + Duration::from_secs(16 * 60));
    assert!(
        matches!(decision_within, ChurnBreakerDecision::Reject { .. }),
        "Expected rejection at 16m (blacklist active until 17m)"
    );

    // WHEN: evaluating at 18m (after blacklist expires at 17m)
    let decision_after = breaker.evaluate_open(&key, now + Duration::from_secs(18 * 60));

    // THEN: blacklist cleared, opens allowed
    assert_eq!(
        decision_after,
        ChurnBreakerDecision::Allow,
        "Expected Allow after 18m (blacklist expired)"
    );
}

/// Verify churn breaker allows opens when inactive
#[test]
fn test_churn_breaker_allows_opens_when_inactive() {
    // GIVEN: churn breaker inactive (no flattens recorded)
    let breaker = ChurnBreaker::new();
    let key = test_key("strategy1", "fingerprint1");
    let now = Instant::now();

    // WHEN: evaluating opens
    let decision = breaker.evaluate_open(&key, now);

    // THEN: opens are allowed
    assert_eq!(decision, ChurnBreakerDecision::Allow);
}

/// Verify churn breaker blocks opens for blacklisted keys
#[test]
fn test_churn_breaker_blocks_opens_for_blacklisted_keys() {
    // GIVEN: blacklist active (3 flattens)
    let breaker = ChurnBreaker::new();
    let key = test_key("strategy1", "fingerprint1");
    let now = Instant::now();

    breaker.record_flatten(key.clone(), now);
    breaker.record_flatten(key.clone(), now + Duration::from_secs(60));
    breaker.record_flatten(key.clone(), now + Duration::from_secs(120));

    // WHEN: evaluating opens
    let decision = breaker.evaluate_open(&key, now + Duration::from_secs(180));

    // THEN: opens are blocked
    assert!(matches!(decision, ChurnBreakerDecision::Reject { .. }));
}

/// Verify churn breaker prunes old flatten events outside 5m window
#[test]
fn test_churn_breaker_prunes_old_events() {
    // GIVEN: 2 flattens within window, 1 outside
    let breaker = ChurnBreaker::new();
    let key = test_key("strategy1", "fingerprint1");
    let now = Instant::now();

    // Old flatten (6m ago, outside 5m window)
    breaker.record_flatten(key.clone(), now);

    // Two recent flattens
    breaker.record_flatten(key.clone(), now + Duration::from_secs(6 * 60));
    breaker.record_flatten(key.clone(), now + Duration::from_secs(7 * 60));

    // WHEN: evaluating at 8m
    // THEN: only 2 recent flattens count, should not trip (need >2)
    let decision = breaker.evaluate_open(&key, now + Duration::from_secs(8 * 60));
    assert_eq!(decision, ChurnBreakerDecision::Allow);
}

/// Verify churn breaker isolates keys
#[test]
fn test_churn_breaker_isolates_keys() {
    // GIVEN: key1 trips, key2 doesn't
    let breaker = ChurnBreaker::new();
    let key1 = test_key("strat1", "BTC-PERP");
    let key2 = test_key("strat2", "ETH-PERP");
    let now = Instant::now();

    // Trip key1
    breaker.record_flatten(key1.clone(), now);
    breaker.record_flatten(key1.clone(), now + Duration::from_secs(60));
    breaker.record_flatten(key1.clone(), now + Duration::from_secs(120));

    // WHEN: evaluating both keys
    let decision1 = breaker.evaluate_open(&key1, now + Duration::from_secs(180));
    let decision2 = breaker.evaluate_open(&key2, now + Duration::from_secs(180));

    // THEN: key1 blocked, key2 allowed
    assert!(matches!(decision1, ChurnBreakerDecision::Reject { .. }));
    assert_eq!(decision2, ChurnBreakerDecision::Allow);
}

/// Verify trip counter increments correctly
#[test]
fn test_churn_breaker_trip_counter() {
    // GIVEN: multiple trips across different keys
    let breaker = ChurnBreaker::new();
    let key1 = test_key("strat1", "BTC-PERP");
    let key2 = test_key("strat2", "ETH-PERP");
    let now = Instant::now();

    assert_eq!(breaker.trip_count(), 0);

    // Trip key1
    breaker.record_flatten(key1.clone(), now);
    breaker.record_flatten(key1.clone(), now + Duration::from_secs(60));
    breaker.record_flatten(key1.clone(), now + Duration::from_secs(120));
    assert_eq!(breaker.trip_count(), 1);

    // Trip key2
    breaker.record_flatten(key2.clone(), now + Duration::from_secs(180));
    breaker.record_flatten(key2.clone(), now + Duration::from_secs(240));
    breaker.record_flatten(key2.clone(), now + Duration::from_secs(300));
    assert_eq!(breaker.trip_count(), 2);
}
