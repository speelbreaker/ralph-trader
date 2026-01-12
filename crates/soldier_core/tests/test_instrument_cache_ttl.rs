use std::time::{Duration, Instant};

use soldier_core::risk::{PolicyGuard, RiskState, TradingMode};
use soldier_core::venue::{
    InstrumentCache, instrument_cache_age_s, instrument_cache_hits_total,
    instrument_cache_stale_total,
};

#[test]
fn test_fresh_instrument_cache_is_healthy() {
    let mut cache = InstrumentCache::new(Duration::from_secs(30));
    cache.insert("BTC-PERP", "metadata");

    let hits_before = instrument_cache_hits_total();
    let read = cache.get("BTC-PERP").expect("cache hit");
    let hits_after = instrument_cache_hits_total();

    assert_eq!(read.risk_state, RiskState::Healthy);
    assert_eq!(read.metadata, &"metadata");
    assert!(hits_after > hits_before);
}

#[test]
fn test_stale_instrument_cache_sets_degraded() {
    let ttl = Duration::from_secs(10);
    let mut cache = InstrumentCache::new(ttl);
    let updated_at = Instant::now() - Duration::from_secs(30);
    cache.insert_with_instant("ETH-PERP", "stale", updated_at);

    let hits_before = instrument_cache_hits_total();
    let before = instrument_cache_stale_total();
    let read = cache.get("ETH-PERP").expect("cache hit");
    let after = instrument_cache_stale_total();
    let hits_after = instrument_cache_hits_total();
    let age_s = instrument_cache_age_s();

    assert_eq!(read.risk_state, RiskState::Degraded);
    assert_eq!(read.metadata, &"stale");
    assert!(after > before);
    assert!(hits_after > hits_before);
    assert!(age_s >= 29.0);
    assert!(age_s < 120.0);
}

#[test]
fn test_instrument_cache_ttl_blocks_opens_allows_closes() {
    let ttl = Duration::from_secs(10);
    let mut cache = InstrumentCache::new(ttl);
    let updated_at = Instant::now() - Duration::from_secs(30);
    cache.insert_with_instant("SOL-PERP", "stale", updated_at);

    let read = cache.get("SOL-PERP").expect("cache hit");
    let mode = PolicyGuard::get_effective_mode(read.risk_state);

    assert_eq!(mode, TradingMode::ReduceOnly);
    assert!(!mode.allows_open());
    assert!(mode.allows_close());
    assert!(mode.allows_hedge());
    assert!(mode.allows_cancel());
}
