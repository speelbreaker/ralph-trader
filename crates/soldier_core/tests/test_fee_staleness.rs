use std::sync::Mutex;

use soldier_core::risk::{
    FeeStalenessConfig, PolicyGuard, RiskState, TradingMode, evaluate_fee_staleness,
};

static TEST_MUTEX: Mutex<()> = Mutex::new(());

#[test]
fn test_fee_cache_soft_s_applies_buffer_after_300s() {
    let _guard = TEST_MUTEX.lock().expect("fee staleness test mutex");
    let config = FeeStalenessConfig::default();
    let fee_rate = 0.001;
    let now_ms = (config.fee_cache_soft_s + 1) * 1000;

    let decision = evaluate_fee_staleness(fee_rate, now_ms, Some(0), config);

    assert_eq!(decision.risk_state, RiskState::Healthy);
    assert!(decision.is_soft_stale());
    assert!(!decision.is_hard_stale());
    assert!((decision.cache_age_s - 301.0).abs() < 0.001);
    assert!((decision.fee_rate_effective - fee_rate * 1.2).abs() < 1e-9);
}

#[test]
fn test_fee_cache_hard_s_forces_degraded_after_900s() {
    let _guard = TEST_MUTEX.lock().expect("fee staleness test mutex");
    let config = FeeStalenessConfig::default();
    let fee_rate = 0.002;
    let now_ms = (config.fee_cache_hard_s + 1) * 1000;

    let decision = evaluate_fee_staleness(fee_rate, now_ms, Some(0), config);
    let mode = PolicyGuard::get_effective_mode(decision.risk_state);

    assert_eq!(decision.risk_state, RiskState::Degraded);
    assert!(decision.is_hard_stale());
    assert!(!decision.is_soft_stale());
    assert!((decision.cache_age_s - 901.0).abs() < 0.001);
    assert_eq!(mode, TradingMode::ReduceOnly);
    assert!(!mode.allows_open());
    assert!(mode.allows_close());
    assert!(mode.allows_hedge());
    assert!(mode.allows_cancel());
}

#[test]
fn test_fee_stale_buffer_multiplies_fees_by_1_20() {
    let _guard = TEST_MUTEX.lock().expect("fee staleness test mutex");
    let config = FeeStalenessConfig::default();
    let fee_rate = 0.01;
    let now_ms = (config.fee_cache_soft_s + 10) * 1000;

    let decision = evaluate_fee_staleness(fee_rate, now_ms, Some(0), config);

    assert!(decision.is_soft_stale());
    assert!((decision.fee_rate_effective - fee_rate * 1.2).abs() < 1e-9);
}
