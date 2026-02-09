use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::risk::RiskState;

static INSTRUMENT_CACHE_STALE_TOTAL: AtomicU64 = AtomicU64::new(0);
static INSTRUMENT_CACHE_HITS_TOTAL: AtomicU64 = AtomicU64::new(0);
static INSTRUMENT_CACHE_AGE_MS: AtomicU64 = AtomicU64::new(0);
static INSTRUMENT_CACHE_REFRESH_ERRORS_TOTAL: AtomicU64 = AtomicU64::new(0);
static LAST_TTL_BREACH: Mutex<Option<InstrumentCacheTtlBreach>> = Mutex::new(None);

#[derive(Debug, Clone, PartialEq)]
pub struct InstrumentCacheTtlBreach {
    pub instrument_id: String,
    pub age_s: f64,
    pub ttl_s: f64,
}

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
        self.get_with_instant(instrument, Instant::now())
    }

    pub fn get_with_instant(&self, instrument: &str, now: Instant) -> Option<CacheRead<'_, T>> {
        let entry = self.entries.get(instrument)?;
        INSTRUMENT_CACHE_HITS_TOTAL.fetch_add(1, Ordering::Relaxed);
        let age = now.saturating_duration_since(entry.updated_at);
        INSTRUMENT_CACHE_AGE_MS.store(age.as_millis() as u64, Ordering::Relaxed);
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

pub fn instrument_cache_hits_total() -> u64 {
    INSTRUMENT_CACHE_HITS_TOTAL.load(Ordering::Relaxed)
}

pub fn instrument_cache_age_s() -> f64 {
    INSTRUMENT_CACHE_AGE_MS.load(Ordering::Relaxed) as f64 / 1000.0
}

pub fn instrument_cache_refresh_errors_total() -> u64 {
    INSTRUMENT_CACHE_REFRESH_ERRORS_TOTAL.load(Ordering::Relaxed)
}

pub fn record_instrument_cache_refresh_error() {
    INSTRUMENT_CACHE_REFRESH_ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
}

pub fn take_instrument_cache_ttl_breach() -> Option<InstrumentCacheTtlBreach> {
    let mut guard = LAST_TTL_BREACH
        .lock()
        .expect("instrument cache ttl breach lock");
    guard.take()
}

fn record_stale(instrument: &str, age: Duration, ttl: Duration) {
    INSTRUMENT_CACHE_STALE_TOTAL.fetch_add(1, Ordering::Relaxed);
    let age_s = age.as_secs_f64();
    let ttl_s = ttl.as_secs_f64();
    let breach = InstrumentCacheTtlBreach {
        instrument_id: instrument.to_string(),
        age_s,
        ttl_s,
    };
    if let Ok(mut guard) = LAST_TTL_BREACH.lock() {
        *guard = Some(breach);
    }
    eprintln!(
        "InstrumentCacheTtlBreach{{instrument_id=\"{}\", age_s={}, ttl_s={}}}",
        instrument, age_s, ttl_s
    );
}
