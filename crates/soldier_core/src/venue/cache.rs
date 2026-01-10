use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::risk::RiskState;

static INSTRUMENT_CACHE_STALE_TOTAL: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone)]
struct InstrumentCacheEntry<T> {
    value: T,
    updated_at: Instant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheRead<'a, T> {
    pub metadata: &'a T,
    pub risk_state: RiskState,
}

#[derive(Debug)]
pub struct InstrumentCache<T> {
    ttl: Duration,
    entries: HashMap<String, InstrumentCacheEntry<T>>,
}

impl<T> InstrumentCache<T> {
    pub fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            entries: HashMap::new(),
        }
    }

    pub fn insert(&mut self, instrument: impl Into<String>, metadata: T) {
        self.insert_with_instant(instrument, metadata, Instant::now());
    }

    pub fn insert_with_instant(
        &mut self,
        instrument: impl Into<String>,
        metadata: T,
        updated_at: Instant,
    ) {
        self.entries.insert(
            instrument.into(),
            InstrumentCacheEntry {
                value: metadata,
                updated_at,
            },
        );
    }

    pub fn get(&self, instrument: &str) -> Option<CacheRead<'_, T>> {
        let entry = self.entries.get(instrument)?;
        let age = Instant::now().saturating_duration_since(entry.updated_at);
        if age > self.ttl {
            record_stale(instrument, age, self.ttl);
            Some(CacheRead {
                metadata: &entry.value,
                risk_state: RiskState::Degraded,
            })
        } else {
            Some(CacheRead {
                metadata: &entry.value,
                risk_state: RiskState::Healthy,
            })
        }
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }
}

pub fn instrument_cache_stale_total() -> u64 {
    INSTRUMENT_CACHE_STALE_TOTAL.load(Ordering::Relaxed)
}

fn record_stale(instrument: &str, age: Duration, ttl: Duration) {
    INSTRUMENT_CACHE_STALE_TOTAL.fetch_add(1, Ordering::Relaxed);
    eprintln!(
        "instrument_cache_stale instrument={} age_ms={} ttl_ms={}",
        instrument,
        age.as_millis(),
        ttl.as_millis()
    );
}
