use std::sync::Mutex;
use std::time::{Duration, Instant};

use soldier_core::risk::{PolicyGuard, RiskState, TradingMode};
use soldier_core::venue::{
    InstrumentCache, instrument_cache_age_s, instrument_cache_hits_total,
    instrument_cache_stale_total,
};

static TEST_MUTEX: Mutex<()> = Mutex::new(());

#[test]
fn test_fresh_instrument_cache_is_healthy() {
    let _guard = TEST_MUTEX.lock().expect("instrument cache test mutex");
    let mut cache = InstrumentCache::new(Duration::from_secs(30));
    let base = Instant::now();
    cache.insert_with_instant("BTC-PERP", "metadata", base);

    let hits_before = instrument_cache_hits_total();
    let read = cache
        .get_with_instant("BTC-PERP", base + Duration::from_secs(5))
        .expect("cache hit");
    let hits_after = instrument_cache_hits_total();

    assert_eq!(read.risk_state, RiskState::Healthy);
    assert_eq!(read.metadata, &"metadata");
    assert!(hits_after > hits_before);
}

#[test]
fn test_instrument_cache_ttl_boundary_is_healthy() {
    let _guard = TEST_MUTEX.lock().expect("instrument cache test mutex");
    let ttl = Duration::from_secs(10);
    let mut cache = InstrumentCache::new(ttl);
    let base = Instant::now();
    cache.insert_with_instant("BTC-BOUNDARY", "metadata", base);

    let hits_before = instrument_cache_hits_total();
    let stale_before = instrument_cache_stale_total();
    let read = cache
        .get_with_instant("BTC-BOUNDARY", base + ttl)
        .expect("cache hit");
    let hits_after = instrument_cache_hits_total();
    let stale_after = instrument_cache_stale_total();
    let age_s = instrument_cache_age_s();

    assert_eq!(read.risk_state, RiskState::Healthy);
    assert_eq!(read.metadata, &"metadata");
    assert!(hits_after > hits_before);
    assert_eq!(stale_after, stale_before);
    assert!((age_s - 10.0).abs() < 0.001);
}

#[test]
fn test_stale_instrument_cache_sets_degraded() {
    let _guard = TEST_MUTEX.lock().expect("instrument cache test mutex");
    let ttl = Duration::from_secs(10);
    let mut cache = InstrumentCache::new(ttl);
    let base = Instant::now();
    cache.insert_with_instant("ETH-PERP", "stale", base);

    let hits_before = instrument_cache_hits_total();
    let before = instrument_cache_stale_total();
    let read = cache
        .get_with_instant("ETH-PERP", base + Duration::from_secs(30))
        .expect("cache hit");
    let after = instrument_cache_stale_total();
    let hits_after = instrument_cache_hits_total();
    let age_s = instrument_cache_age_s();

    assert_eq!(read.risk_state, RiskState::Degraded);
    assert_eq!(read.metadata, &"stale");
    assert!(after > before);
    assert!(hits_after > hits_before);
    assert!((age_s - 30.0).abs() < 0.001);
}

#[test]
fn test_instrument_cache_ttl_blocks_opens_allows_closes() {
    let _guard = TEST_MUTEX.lock().expect("instrument cache test mutex");
    let ttl = Duration::from_secs(10);
    let mut cache = InstrumentCache::new(ttl);
    let base = Instant::now();
    cache.insert_with_instant("SOL-PERP", "stale", base);

    let read = cache
        .get_with_instant("SOL-PERP", base + Duration::from_secs(30))
        .expect("cache hit");
    let mode = PolicyGuard::get_effective_mode(read.risk_state);

    assert_eq!(mode, TradingMode::ReduceOnly);
    assert!(!mode.allows_open());
    assert!(mode.allows_close());
    assert!(mode.allows_hedge());
    assert!(mode.allows_cancel());
}
