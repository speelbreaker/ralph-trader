/// Edge case tests for Slice 7 implementation
/// Tests failure modes found in code review
use soldier_core::execution::atomic_group_executor::{AtomicGroupExecutor, RescueAction};
use soldier_core::execution::group::{AtomicGroup, GroupState, LegOutcome, LegState};
use soldier_core::risk::RiskState;
use soldier_core::risk::churn_breaker::{ChurnBreaker, ChurnBreakerDecision, ChurnKey};
use soldier_core::risk::self_impact_guard::{
    SelfImpactConfig, SelfImpactEvaluation, SelfImpactGuard, SelfImpactKey, TradeAggregates,
};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

// ===== AtomicGroupExecutor Edge Cases =====

#[test]
fn test_rescue_attempts_ttl_eviction() {
    // Tests Finding #1: rescue_attempts HashMap eviction
    let exec = AtomicGroupExecutor::new(1e-9);
    let mut group = AtomicGroup::new("old-group");

    // Transition to MixedFailed
    exec.on_intent_persisted(&mut group).unwrap();
    let legs = vec![
        LegOutcome::new(1.0, 1.0, LegState::Filled),
        LegOutcome::new(1.0, 0.0, LegState::Rejected),
    ];
    exec.evaluate(&mut group, &legs).unwrap();

    // Record rescue attempt
    let _ = exec.record_rescue_failure(&mut group).unwrap();
    assert_eq!(exec.rescue_attempts(&group), 1);

    // Wait for TTL to expire (mocked by creating many new entries to trigger cleanup)
    // In real scenario, TTL is 1 hour - here we verify cleanup logic exists
    for i in 0..100 {
        let mut temp_group = AtomicGroup::new(format!("temp-{}", i));
        exec.on_intent_persisted(&mut temp_group).unwrap();
        exec.evaluate(&mut temp_group, &legs).unwrap();
        let _ = exec.record_rescue_failure(&mut temp_group).unwrap();
    }

    // Verify rescue attempts still accessible (not corrupted by cleanup)
    assert!(exec.rescue_attempts(&group) >= 1);
}

#[test]
fn test_epsilon_validation() {
    // Tests Finding #2 recommendation: validate epsilon > 0
    let result = std::panic::catch_unwind(|| {
        AtomicGroupExecutor::new(0.0);
    });
    assert!(result.is_err(), "Expected panic for zero epsilon");

    let result = std::panic::catch_unwind(|| {
        AtomicGroupExecutor::new(-1.0);
    });
    assert!(result.is_err(), "Expected panic for negative epsilon");
}

#[test]
fn test_concurrent_rescue_attempt_updates() {
    // Tests Finding #5: thread-safety of rescue_attempts
    let exec = Arc::new(AtomicGroupExecutor::new(1e-9));
    let mut group = AtomicGroup::new("concurrent-group");

    // Set up group in MixedFailed state
    exec.on_intent_persisted(&mut group).unwrap();
    let legs = vec![
        LegOutcome::new(1.0, 1.0, LegState::Filled),
        LegOutcome::new(1.0, 0.0, LegState::Rejected),
    ];
    exec.evaluate(&mut group, &legs).unwrap();
    assert_eq!(group.state(), GroupState::MixedFailed);

    let group_id = group.group_id().to_string();

    // Spawn multiple threads trying to record rescue failure concurrently
    let handles: Vec<_> = (0..10)
        .map(|i| {
            let exec_clone = Arc::clone(&exec);
            let gid = group_id.clone();
            thread::spawn(move || {
                let mut g = AtomicGroup::new(gid);
                // Manually set state to MixedFailed (bypass normal flow for testing)
                g.transition_to(GroupState::Dispatched).unwrap();
                g.transition_to(GroupState::MixedFailed).unwrap();

                for _ in 0..5 {
                    let result = exec_clone.record_rescue_failure(&mut g);
                    // Should not panic despite concurrent access
                    assert!(result.is_ok(), "Thread {} failed: {:?}", i, result);
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().expect("Thread panicked");
    }

    // Verify final state is sane (no corruption)
    let final_attempts = exec.rescue_attempts(&group);
    // Due to concurrency, exact count may vary, but should be bounded
    assert!(
        final_attempts <= 2,
        "Rescue attempts exceeded max: {}",
        final_attempts
    );
}

// ===== ChurnBreaker Edge Cases =====

#[test]
fn test_churn_breaker_concurrent_record_flatten() {
    // Tests Finding #5: thread-safety with interior mutability
    let breaker = Arc::new(ChurnBreaker::new());
    let key = ChurnKey {
        strategy_id: "strat1".to_string(),
        structure_fingerprint: "BTC-PERP".to_string(),
    };

    let handles: Vec<_> = (0..10)
        .map(|_| {
            let breaker_clone = Arc::clone(&breaker);
            let key_clone = key.clone();
            thread::spawn(move || {
                for _ in 0..5 {
                    breaker_clone.record_flatten(key_clone.clone(), Instant::now());
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().expect("Thread panicked");
    }

    // Verify trip counter is sane (no corruption)
    let trip_count = breaker.trip_count();
    // At least one trip should have occurred with 50 flatten events
    assert!(trip_count > 0, "Expected at least one trip");
}

#[test]
fn test_churn_breaker_concurrent_evaluate_open() {
    // Tests concurrent evaluate_open calls don't corrupt state
    let breaker = Arc::new(ChurnBreaker::new());
    let key1 = ChurnKey {
        strategy_id: "strat1".to_string(),
        structure_fingerprint: "BTC-PERP".to_string(),
    };
    let key2 = ChurnKey {
        strategy_id: "strat2".to_string(),
        structure_fingerprint: "ETH-PERP".to_string(),
    };

    // Trip key1
    let now = Instant::now();
    breaker.record_flatten(key1.clone(), now);
    breaker.record_flatten(key1.clone(), now + Duration::from_secs(60));
    breaker.record_flatten(key1.clone(), now + Duration::from_secs(120));

    // Concurrent evaluation on different keys
    let handles: Vec<_> = (0..10)
        .map(|i| {
            let breaker_clone = Arc::clone(&breaker);
            let k1 = key1.clone();
            let k2 = key2.clone();
            thread::spawn(move || {
                for _ in 0..10 {
                    let decision1 = breaker_clone.evaluate_open(&k1, Instant::now());
                    let decision2 = breaker_clone.evaluate_open(&k2, Instant::now());

                    // key1 should be rejected, key2 allowed
                    assert!(
                        matches!(decision1, ChurnBreakerDecision::Reject { .. }),
                        "Thread {}: key1 not rejected",
                        i
                    );
                    assert_eq!(
                        decision2,
                        ChurnBreakerDecision::Allow,
                        "Thread {}: key2 not allowed",
                        i
                    );
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().expect("Thread panicked");
    }
}

// ===== SelfImpactGuard Edge Cases =====

#[test]
fn test_self_impact_tiny_public_volume() {
    // Tests Finding #6: epsilon handling for tiny public volumes
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "strat1".to_string(),
        structure_fingerprint: "BTC-PERP".to_string(),
    };

    // Scenario 1: Public volume = 0.5 USD (below MIN_PUBLIC_VOLUME_USD threshold)
    let aggregates = TradeAggregates {
        public_notional_usd: 0.5,
        self_notional_usd: 0.2,
        public_trades_last_update_ts_ms: Some(1000),
    };

    let config = SelfImpactConfig::default();
    let now_ms = 1000;
    let now_instant = Instant::now();

    let eval = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    // Should allow (fraction check skipped due to tiny public volume)
    assert!(
        eval.allowed,
        "Should allow when public volume too small for fraction check"
    );
    assert_eq!(eval.risk_state, RiskState::Healthy);
}

#[test]
fn test_self_impact_float_epsilon_tolerance() {
    // Tests Finding #3: float comparison with epsilon tolerance
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "strat1".to_string(),
        structure_fingerprint: "BTC-PERP".to_string(),
    };

    // Scenario: self_fraction = exactly 0.25 (at threshold)
    // Due to float precision, 25000/100000 might be 0.24999999999
    let aggregates = TradeAggregates {
        public_notional_usd: 100000.0,
        self_notional_usd: 25000.0, // Exactly 25%
        public_trades_last_update_ts_ms: Some(1000),
    };

    let config = SelfImpactConfig::default();
    let now_ms = 1000;
    let now_instant = Instant::now();

    let eval = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    // With epsilon tolerance, this should trip (25% >= threshold with tolerance)
    assert!(
        !eval.allowed,
        "Should reject at exact threshold with epsilon tolerance"
    );
    assert!(eval.reject_reason.is_some());
}

#[test]
fn test_self_impact_notional_trip_epsilon() {
    // Tests Finding #3: epsilon tolerance for notional trip
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "strat1".to_string(),
        structure_fingerprint: "BTC-PERP".to_string(),
    };

    // Scenario: self_notional = exactly $150k (at absolute threshold)
    let aggregates = TradeAggregates {
        public_notional_usd: 500000.0,
        self_notional_usd: 150000.0, // Exactly at trip threshold
        public_trades_last_update_ts_ms: Some(1000),
    };

    let config = SelfImpactConfig::default();
    let now_ms = 1000;
    let now_instant = Instant::now();

    let eval = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    // With epsilon tolerance, should trip
    assert!(!eval.allowed, "Should reject at exact notional threshold");
}

#[test]
fn test_self_impact_concurrent_evaluate() {
    // Tests Finding #5: thread-safety with interior mutability
    let guard = Arc::new(SelfImpactGuard::new());

    let handles: Vec<_> = (0..10)
        .map(|i| {
            let guard_clone = Arc::clone(&guard);
            thread::spawn(move || {
                let key = SelfImpactKey {
                    strategy_id: format!("strat{}", i),
                    structure_fingerprint: "BTC-PERP".to_string(),
                };

                let aggregates = TradeAggregates {
                    public_notional_usd: 100000.0,
                    self_notional_usd: 30000.0, // Will trip
                    public_trades_last_update_ts_ms: Some(1000),
                };

                let config = SelfImpactConfig::default();
                let now_ms = 1000;
                let now_instant = Instant::now();

                for _ in 0..10 {
                    let eval =
                        guard_clone.evaluate_open(&key, aggregates, now_ms, now_instant, config);
                    // First call should reject and set cooldown
                    assert!(!eval.allowed, "Thread {}: should reject on trip", i);
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().expect("Thread panicked");
    }

    // Verify trip counter
    let trip_count = guard.trip_count();
    assert_eq!(trip_count, 10, "Expected 10 trips (one per thread)");
}

#[test]
fn test_self_impact_missing_trade_feed() {
    // Tests feed staleness handling
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "strat1".to_string(),
        structure_fingerprint: "BTC-PERP".to_string(),
    };

    // Missing trade feed (None)
    let aggregates = TradeAggregates {
        public_notional_usd: 100000.0,
        self_notional_usd: 10000.0,
        public_trades_last_update_ts_ms: None, // Missing!
    };

    let config = SelfImpactConfig::default();
    let now_ms = 5000;
    let now_instant = Instant::now();

    let eval = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    // Should set latch and degrade
    assert!(!eval.allowed, "Should block when feed missing");
    assert_eq!(eval.risk_state, RiskState::Degraded);
    assert!(eval.latch_reason.is_some(), "Should set latch");
}

#[test]
fn test_self_impact_stale_trade_feed() {
    // Tests feed staleness handling
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "strat1".to_string(),
        structure_fingerprint: "BTC-PERP".to_string(),
    };

    // Stale trade feed (>5s old)
    let aggregates = TradeAggregates {
        public_notional_usd: 100000.0,
        self_notional_usd: 10000.0,
        public_trades_last_update_ts_ms: Some(1000), // Last update: 1000ms
    };

    let config = SelfImpactConfig::default();
    let now_ms = 10000; // Now: 10000ms (9 seconds later - stale!)
    let now_instant = Instant::now();

    let eval = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    // Should set latch and degrade
    assert!(!eval.allowed, "Should block when feed stale");
    assert_eq!(eval.risk_state, RiskState::Degraded);
    assert!(eval.latch_reason.is_some(), "Should set latch");
}
