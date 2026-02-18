use soldier_core::risk::{
    LatchReason, RiskState, SelfImpactConfig, SelfImpactGuard, SelfImpactKey, TradeAggregates,
};
use std::time::Instant;

/// AT-953: Stale trade feed => Degraded + latch + block opens
#[test]
fn test_self_impact_stale_feed_sets_latch() {
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "s1".to_string(),
        structure_fingerprint: "struct1".to_string(),
    };

    let config = SelfImpactConfig::default(); // public_trade_feed_max_age_ms = 5000

    let now_ms = 100_000;
    let now_instant = Instant::now();

    // Stale feed: last update was 6 seconds ago (> 5s threshold)
    let aggregates = TradeAggregates {
        public_notional_usd: 100_000.0,
        self_notional_usd: 40_000.0,
        public_trades_last_update_ts_ms: Some(now_ms - 6_000),
    };

    let result = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    assert!(!result.allowed, "OPEN should be blocked");
    assert_eq!(
        result.latch_reason,
        Some(LatchReason::WsTradesGapReconcileRequired),
        "Latch reason should be WsTradesGapReconcileRequired"
    );
    assert_eq!(
        result.risk_state,
        RiskState::Degraded,
        "RiskState should be Degraded"
    );
    assert_eq!(
        result.reject_reason, None,
        "No reject reason (blocked by latch, not rejection)"
    );
}

/// AT-953: Missing trade feed => Degraded + latch + block opens
#[test]
fn test_self_impact_missing_feed_sets_latch() {
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "s1".to_string(),
        structure_fingerprint: "struct1".to_string(),
    };

    let config = SelfImpactConfig::default();
    let now_ms = 100_000;
    let now_instant = Instant::now();

    // Missing trade feed
    let aggregates = TradeAggregates {
        public_notional_usd: 100_000.0,
        self_notional_usd: 40_000.0,
        public_trades_last_update_ts_ms: None,
    };

    let result = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    assert!(!result.allowed, "OPEN should be blocked");
    assert_eq!(
        result.latch_reason,
        Some(LatchReason::WsTradesGapReconcileRequired)
    );
    assert_eq!(result.risk_state, RiskState::Degraded);
    assert_eq!(result.reject_reason, None);
}

/// AT-955: self_fraction trip => reject with FeedbackLoopGuardActive
#[test]
fn test_self_impact_fraction_trip_rejects() {
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "s1".to_string(),
        structure_fingerprint: "struct1".to_string(),
    };

    let config = SelfImpactConfig {
        public_trade_feed_max_age_ms: 5000,
        feedback_loop_window_s: 10,
        self_trade_fraction_trip: 0.25,
        self_trade_min_self_notional_usd: 10_000.0,
        self_trade_notional_trip_usd: 150_000.0,
        feedback_loop_cooldown_s: 60,
    };

    let now_ms = 100_000;
    let now_instant = Instant::now();

    // Fresh feed: last update was 1s ago (< 5s threshold)
    // self_fraction = 40_000 / 100_000 = 0.40 (>= 0.25 trip threshold)
    // self_notional = 40_000 (>= 10_000 min threshold)
    let aggregates = TradeAggregates {
        public_notional_usd: 100_000.0,
        self_notional_usd: 40_000.0,
        public_trades_last_update_ts_ms: Some(now_ms - 1_000),
    };

    let result = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    assert!(!result.allowed, "OPEN should be rejected");
    assert_eq!(result.latch_reason, None, "No latch (feed is fresh)");
    assert_eq!(result.risk_state, RiskState::Healthy);
    assert!(
        result
            .reject_reason
            .as_ref()
            .is_some_and(|r| r.contains("FeedbackLoopGuardActive")),
        "Reject reason should be FeedbackLoopGuardActive, got: {:?}",
        result.reject_reason
    );
}

/// AT-956: self_notional trip => reject with FeedbackLoopGuardActive
#[test]
fn test_self_impact_notional_trip_rejects() {
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "s1".to_string(),
        structure_fingerprint: "struct1".to_string(),
    };

    let config = SelfImpactConfig {
        public_trade_feed_max_age_ms: 5000,
        feedback_loop_window_s: 10,
        self_trade_fraction_trip: 0.25,
        self_trade_min_self_notional_usd: 10_000.0,
        self_trade_notional_trip_usd: 150_000.0,
        feedback_loop_cooldown_s: 60,
    };

    let now_ms = 100_000;
    let now_instant = Instant::now();

    // Fresh feed
    // self_fraction = 200_000 / 10_000_000 = 0.02 (< 0.25, below fraction threshold)
    // BUT self_notional = 200_000 (>= 150_000 notional trip threshold)
    let aggregates = TradeAggregates {
        public_notional_usd: 10_000_000.0,
        self_notional_usd: 200_000.0,
        public_trades_last_update_ts_ms: Some(now_ms - 1_000),
    };

    let result = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    assert!(!result.allowed, "OPEN should be rejected via notional trip");
    assert_eq!(result.latch_reason, None);
    assert_eq!(result.risk_state, RiskState::Healthy);
    assert!(
        result
            .reject_reason
            .as_ref()
            .is_some_and(|r| r.contains("FeedbackLoopGuardActive")),
        "Reject reason should be FeedbackLoopGuardActive, got: {:?}",
        result.reject_reason
    );
}

/// AT-957: Below threshold => allow OPEN
#[test]
fn test_self_impact_below_threshold_allows() {
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "s1".to_string(),
        structure_fingerprint: "struct1".to_string(),
    };

    let config = SelfImpactConfig {
        public_trade_feed_max_age_ms: 5000,
        feedback_loop_window_s: 10,
        self_trade_fraction_trip: 0.25,
        self_trade_min_self_notional_usd: 10_000.0,
        self_trade_notional_trip_usd: 150_000.0,
        feedback_loop_cooldown_s: 60,
    };

    let now_ms = 100_000;
    let now_instant = Instant::now();

    // Fresh feed
    // self_fraction = 20_000 / 200_000 = 0.10 (< 0.25, below fraction threshold)
    // self_notional = 20_000 (< 150_000, below notional trip threshold)
    let aggregates = TradeAggregates {
        public_notional_usd: 200_000.0,
        self_notional_usd: 20_000.0,
        public_trades_last_update_ts_ms: Some(now_ms - 1_000),
    };

    let result = guard.evaluate_open(&key, aggregates, now_ms, now_instant, config);

    assert!(result.allowed, "OPEN should be allowed");
    assert_eq!(result.latch_reason, None);
    assert_eq!(result.risk_state, RiskState::Healthy);
    assert_eq!(result.reject_reason, None);
}

/// Test cooldown behavior: after trip, subsequent OPENs are blocked during cooldown
#[test]
fn test_self_impact_cooldown_blocks_subsequent_opens() {
    let guard = SelfImpactGuard::new();
    let key = SelfImpactKey {
        strategy_id: "s1".to_string(),
        structure_fingerprint: "struct1".to_string(),
    };

    let config = SelfImpactConfig {
        feedback_loop_cooldown_s: 60,
        ..Default::default()
    };

    let now_ms = 100_000;
    let now_instant = Instant::now();

    // First call: trip the guard (self_fraction = 0.40)
    let aggregates_trip = TradeAggregates {
        public_notional_usd: 100_000.0,
        self_notional_usd: 40_000.0,
        public_trades_last_update_ts_ms: Some(now_ms - 1_000),
    };

    let result1 = guard.evaluate_open(&key, aggregates_trip, now_ms, now_instant, config);
    assert!(!result1.allowed, "First call should reject (trip)");
    assert!(
        result1
            .reject_reason
            .as_ref()
            .unwrap()
            .contains("FeedbackLoopGuardActive")
    );

    // Second call: even with low self_fraction, should still be blocked (cooldown)
    let aggregates_low = TradeAggregates {
        public_notional_usd: 200_000.0,
        self_notional_usd: 5_000.0, // Well below threshold
        public_trades_last_update_ts_ms: Some(now_ms - 1_000),
    };

    let result2 = guard.evaluate_open(&key, aggregates_low, now_ms, now_instant, config);
    assert!(!result2.allowed, "Second call should be blocked (cooldown)");
    assert!(
        result2
            .reject_reason
            .as_ref()
            .unwrap()
            .contains("cooldown active")
    );
}

/// Test trip counter metric
#[test]
fn test_self_impact_trip_counter_increments() {
    let guard = SelfImpactGuard::new();
    let key1 = SelfImpactKey {
        strategy_id: "s1".to_string(),
        structure_fingerprint: "struct1".to_string(),
    };
    let key2 = SelfImpactKey {
        strategy_id: "s2".to_string(),
        structure_fingerprint: "struct2".to_string(),
    };

    let config = SelfImpactConfig::default();
    let now_ms = 100_000;
    let now_instant = Instant::now();

    assert_eq!(guard.trip_count(), 0, "Initial trip count should be 0");

    // Trip key1
    let aggregates_trip = TradeAggregates {
        public_notional_usd: 100_000.0,
        self_notional_usd: 40_000.0,
        public_trades_last_update_ts_ms: Some(now_ms - 1_000),
    };
    guard.evaluate_open(&key1, aggregates_trip, now_ms, now_instant, config);
    assert_eq!(guard.trip_count(), 1, "Trip count should increment to 1");

    // Trip key2
    guard.evaluate_open(&key2, aggregates_trip, now_ms, now_instant, config);
    assert_eq!(guard.trip_count(), 2, "Trip count should increment to 2");
}
