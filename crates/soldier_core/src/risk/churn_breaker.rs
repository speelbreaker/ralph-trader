use std::collections::HashMap;
use std::time::{Duration, Instant};

/// Churn circuit breaker per CONTRACT.md §1.2.2
/// Prevents death-by-fees when strategy repeatedly legs + flattens
///
/// Rule: >2 flattens in 5m => 15m blacklist blocks opens for that key

const FLATTEN_WINDOW: Duration = Duration::from_secs(5 * 60);
const FLATTEN_TRIP_COUNT: usize = 2; // >2 means 3 or more
const BLACKLIST_DURATION: Duration = Duration::from_secs(15 * 60);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ChurnKey {
    pub strategy_id: String,
    pub structure_fingerprint: String,
}

#[derive(Debug, Clone)]
struct FlattenEvent {
    timestamp: Instant,
}

#[derive(Debug, Clone)]
struct BlacklistEntry {
    blocked_until: Instant,
}

pub struct ChurnBreaker {
    flatten_history: HashMap<ChurnKey, Vec<FlattenEvent>>,
    blacklist: HashMap<ChurnKey, BlacklistEntry>,
    trip_counter: u64, // For churn_breaker_trip_total metric
}

#[derive(Debug, Clone, PartialEq)]
pub enum ChurnBreakerDecision {
    Allow,
    Reject { reason: String, trip_count: u64 },
}

impl ChurnBreaker {
    pub fn new() -> Self {
        Self {
            flatten_history: HashMap::new(),
            blacklist: HashMap::new(),
            trip_counter: 0,
        }
    }

    /// Record a flatten event. If >2 flattens in 5m, blacklist the key for 15m.
    pub fn record_flatten(&mut self, key: ChurnKey, now: Instant) {
        // Add this flatten event
        let events = self
            .flatten_history
            .entry(key.clone())
            .or_insert_with(Vec::new);
        events.push(FlattenEvent { timestamp: now });

        // Prune events outside the 5m window
        events.retain(|e| now.duration_since(e.timestamp) <= FLATTEN_WINDOW);

        // Check if we've exceeded the trip count (>2 means 3+)
        if events.len() > FLATTEN_TRIP_COUNT {
            // Trip the breaker: blacklist this key
            self.blacklist.insert(
                key.clone(),
                BlacklistEntry {
                    blocked_until: now + BLACKLIST_DURATION,
                },
            );
            self.trip_counter += 1;
            // Note: churn breaker trip logged via decision reject reason
            // Metric: churn_breaker_trip_total (exposed via trip_count())
        }
    }

    /// Check if an OPEN intent should be allowed or blocked.
    /// Returns Reject if key is blacklisted.
    pub fn evaluate_open(&mut self, key: &ChurnKey, now: Instant) -> ChurnBreakerDecision {
        // Prune expired blacklist entries
        self.blacklist.retain(|_k, entry| now < entry.blocked_until);

        // Check if this key is blacklisted
        if let Some(entry) = self.blacklist.get(key) {
            let remaining_secs = entry.blocked_until.saturating_duration_since(now).as_secs();
            ChurnBreakerDecision::Reject {
                reason: format!(
                    "ChurnBreakerActive: blacklisted for {}s remaining",
                    remaining_secs
                ),
                trip_count: self.trip_counter,
            }
        } else {
            ChurnBreakerDecision::Allow
        }
    }

    /// Get total trip count (for churn_breaker_trip_total metric)
    pub fn trip_count(&self) -> u64 {
        self.trip_counter
    }
}

impl Default for ChurnBreaker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key(strategy_id: &str, fingerprint: &str) -> ChurnKey {
        ChurnKey {
            strategy_id: strategy_id.to_string(),
            structure_fingerprint: fingerprint.to_string(),
        }
    }

    #[test]
    fn test_churn_breaker_allows_opens_when_inactive() {
        // GIVEN: churn breaker inactive
        let mut breaker = ChurnBreaker::new();
        let key = test_key("strat1", "BTC-PERP-delta0.5");
        let now = Instant::now();

        // WHEN: evaluating opens
        let decision = breaker.evaluate_open(&key, now);

        // THEN: opens are allowed
        assert_eq!(decision, ChurnBreakerDecision::Allow);
    }

    #[test]
    fn test_churn_breaker_blacklists_after_three_flattens() {
        // GIVEN: 3 flattens in 5m window
        let mut breaker = ChurnBreaker::new();
        let key = test_key("strat1", "BTC-PERP-delta0.5");
        let now = Instant::now();

        breaker.record_flatten(key.clone(), now);
        breaker.record_flatten(key.clone(), now + Duration::from_secs(60));
        breaker.record_flatten(key.clone(), now + Duration::from_secs(120));

        // WHEN: evaluating a 4th open attempt
        let decision = breaker.evaluate_open(&key, now + Duration::from_secs(180));

        // THEN: the open is blocked
        match decision {
            ChurnBreakerDecision::Reject { reason, trip_count } => {
                assert!(reason.contains("ChurnBreakerActive"));
                assert_eq!(trip_count, 1);
            }
            _ => panic!("Expected Reject, got {:?}", decision),
        }
    }

    #[test]
    fn test_churn_breaker_enforces_15m_blacklist_ttl() {
        // GIVEN: 3 flattens triggering blacklist
        let mut breaker = ChurnBreaker::new();
        let key = test_key("strat1", "BTC-PERP-delta0.5");
        let now = Instant::now();

        breaker.record_flatten(key.clone(), now);
        breaker.record_flatten(key.clone(), now + Duration::from_secs(60));
        // Third flatten at 2m triggers the blacklist (blocked_until = 2m + 15m = 17m)
        breaker.record_flatten(key.clone(), now + Duration::from_secs(120));

        // WHEN: evaluating at 16m (within blacklist, which expires at 17m)
        let decision_within = breaker.evaluate_open(&key, now + Duration::from_secs(16 * 60));
        assert!(matches!(
            decision_within,
            ChurnBreakerDecision::Reject { .. }
        ));

        // WHEN: evaluating at 18m (after blacklist expires at 17m)
        let decision_after = breaker.evaluate_open(&key, now + Duration::from_secs(18 * 60));

        // THEN: blacklist is cleared, opens allowed
        assert_eq!(decision_after, ChurnBreakerDecision::Allow);
    }

    #[test]
    fn test_churn_breaker_prunes_old_flatten_events() {
        // GIVEN: 2 flattens within window, 1 outside
        let mut breaker = ChurnBreaker::new();
        let key = test_key("strat1", "BTC-PERP-delta0.5");
        let now = Instant::now();

        // Old flatten (outside 5m window)
        breaker.record_flatten(key.clone(), now);

        // Two recent flattens (within window)
        breaker.record_flatten(key.clone(), now + Duration::from_secs(6 * 60)); // 6m later
        breaker.record_flatten(key.clone(), now + Duration::from_secs(7 * 60)); // 7m later

        // WHEN: evaluating at 8m
        // THEN: only 2 flattens in window, should not trip (need >2)
        let decision = breaker.evaluate_open(&key, now + Duration::from_secs(8 * 60));
        assert_eq!(decision, ChurnBreakerDecision::Allow);
    }

    #[test]
    fn test_churn_breaker_isolates_keys() {
        // GIVEN: key1 trips, key2 doesn't
        let mut breaker = ChurnBreaker::new();
        let key1 = test_key("strat1", "BTC-PERP-delta0.5");
        let key2 = test_key("strat2", "ETH-PERP-delta0.3");
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

    #[test]
    fn test_churn_breaker_trip_counter_increments() {
        // GIVEN: multiple trips across different keys
        let mut breaker = ChurnBreaker::new();
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
}
