use std::sync::Mutex;

use soldier_core::risk::{
    FEE_MODEL_POLL_INTERVAL_MS, FeeModelCache, FeeModelSnapshot, FeeStalenessConfig, PolicyGuard,
    RiskState, TradingMode, evaluate_fee_staleness, fee_model_cache_age_s,
};

static TEST_MUTEX: Mutex<()> = Mutex::new(());

#[test]
fn test_fee_cache_timestamp_missing_or_unparseable_forces_reduceonly() {
    let _guard = TEST_MUTEX.lock().expect("fee cache test mutex");
    let config = FeeStalenessConfig::default();
    let now_ms = (config.fee_cache_soft_s + 1) * 1000;

    let decision = evaluate_fee_staleness(0.001, now_ms, None, config);
    let mode = PolicyGuard::get_effective_mode(decision.risk_state);

    assert_eq!(decision.risk_state, RiskState::Degraded);
    assert!(decision.is_hard_stale());
    assert!(decision.cache_age_s > config.fee_cache_hard_s as f64);
    assert_eq!(mode, TradingMode::ReduceOnly);
    assert!(!mode.allows_open());
    assert!(mode.allows_close());
    assert!(mode.allows_hedge());
    assert!(mode.allows_cancel());
}

#[test]
fn test_fee_cache_epoch_ms_survives_restart() {
    let _guard = TEST_MUTEX.lock().expect("fee cache test mutex");
    let config = FeeStalenessConfig::default();
    let cached_at_ms = 1_700_000_000_000u64;
    let now_ms = cached_at_ms + (config.fee_cache_hard_s * 1000) + 1;

    let decision = evaluate_fee_staleness(0.002, now_ms, Some(cached_at_ms), config);
    let expected_age_s = config.fee_cache_hard_s as f64 + 0.001;
    let observed_age_s = fee_model_cache_age_s();

    assert!((decision.cache_age_s - expected_age_s).abs() < 0.002);
    assert!((observed_age_s - expected_age_s).abs() < 0.002);
    assert_eq!(decision.risk_state, RiskState::Degraded);
    assert!(decision.is_hard_stale());
}

#[test]
fn test_fee_tier_change_updates_net_edge_within_one_cycle() {
    let _guard = TEST_MUTEX.lock().expect("fee cache test mutex");
    let mut cache = FeeModelCache::new();
    let config = FeeStalenessConfig::default();
    let start_ms = 10_000u64;

    let initial = FeeModelSnapshot {
        fee_tier: 1,
        maker_fee_rate: 0.0001,
        taker_fee_rate: 0.0005,
        fee_model_cached_at_ts_ms: Some(start_ms),
    };
    cache.apply_snapshot(initial, start_ms);

    assert_eq!(cache.fee_tier(), 1);
    assert!(!cache.should_poll(start_ms + FEE_MODEL_POLL_INTERVAL_MS - 1));

    let next_poll_ms = start_ms + FEE_MODEL_POLL_INTERVAL_MS;
    assert!(cache.should_poll(next_poll_ms));

    let updated = FeeModelSnapshot {
        fee_tier: 2,
        maker_fee_rate: 0.0002,
        taker_fee_rate: 0.0006,
        fee_model_cached_at_ts_ms: Some(next_poll_ms),
    };
    cache.apply_snapshot(updated, next_poll_ms);

    assert_eq!(cache.fee_tier(), 2);
    let decision = cache.effective_fee_rate(next_poll_ms, config, false);
    assert_eq!(decision.risk_state, RiskState::Healthy);
    assert!((decision.fee_rate_effective - updated.taker_fee_rate).abs() < 1e-9);
}
