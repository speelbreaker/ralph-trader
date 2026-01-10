use std::time::{Duration, Instant};

use soldier_core::risk::RiskState;
use soldier_core::venue::{InstrumentCache, instrument_cache_stale_total};

#[test]
fn returns_healthy_for_fresh_metadata() {
    let mut cache = InstrumentCache::new(Duration::from_secs(30));
    cache.insert("BTC-PERP", "metadata");

    let read = cache.get("BTC-PERP").expect("cache hit");

    assert_eq!(read.risk_state, RiskState::Healthy);
    assert_eq!(read.metadata, &"metadata");
}

#[test]
fn returns_degraded_and_increments_metric_for_stale_metadata() {
    let ttl = Duration::from_secs(10);
    let mut cache = InstrumentCache::new(ttl);
    let updated_at = Instant::now() - Duration::from_secs(30);
    cache.insert_with_instant("ETH-PERP", "stale", updated_at);

    let before = instrument_cache_stale_total();
    let read = cache.get("ETH-PERP").expect("cache hit");
    let after = instrument_cache_stale_total();

    assert_eq!(read.risk_state, RiskState::Degraded);
    assert_eq!(read.metadata, &"stale");
    assert_eq!(after, before + 1);
}
