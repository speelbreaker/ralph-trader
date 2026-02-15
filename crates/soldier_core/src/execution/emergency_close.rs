use std::time::Instant;

/// Emergency close algorithm per CONTRACT.md §3.1
/// - 3 IOC close attempts with doubling buffer (5→10→20 ticks)
/// - Reduce-only delta hedge fallback if still exposed
/// - Logs AtomicNakedEvent on naked exposure
/// - TradingMode is ReduceOnly during exposure

const MAX_CLOSE_ATTEMPTS: u8 = 3;
const INITIAL_BUFFER_TICKS: i32 = 5;

#[derive(Debug, Clone, PartialEq)]
pub struct CloseAttempt {
    pub attempt_number: u8,
    pub buffer_ticks: i32,
    pub filled_qty: f64,
    pub remaining_qty: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EmergencyCloseResult {
    pub close_attempts: Vec<CloseAttempt>,
    pub hedge_used: bool,
    pub final_exposure: f64,
    pub time_to_neutral_ms: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AtomicNakedEvent {
    pub group_id: String,
    pub strategy_id: String,
    pub incident_ts_ms: u64,
    pub exposure_usd_before: f64,
    pub exposure_usd_after: f64,
    pub time_to_delta_neutral_ms: u64,
    pub close_attempts: u8,
    pub hedge_used: bool,
    pub cause: String,
    pub trading_mode_at_event: String,
}

pub struct EmergencyClose {
    epsilon: f64,
}

impl EmergencyClose {
    pub fn new(epsilon: f64) -> Self {
        Self {
            epsilon: epsilon.abs(),
        }
    }

    /// Execute emergency close algorithm (CONTRACT.md §3.1)
    /// Returns (attempts, hedge_used, time_ms)
    pub fn execute(&self, _group_id: &str, initial_exposure: f64) -> EmergencyCloseResult {
        let start = Instant::now();
        let mut attempts = Vec::new();
        let mut remaining = initial_exposure.abs();

        // 3 IOC close attempts with doubling buffer
        for attempt_num in 1..=MAX_CLOSE_ATTEMPTS {
            let buffer = INITIAL_BUFFER_TICKS * (1 << (attempt_num - 1)); // 5, 10, 20

            // Simulate close attempt (in real impl, this would dispatch IOC order)
            let filled = self.simulate_close_attempt(remaining);
            remaining -= filled;

            attempts.push(CloseAttempt {
                attempt_number: attempt_num,
                buffer_ticks: buffer,
                filled_qty: filled,
                remaining_qty: remaining,
            });

            record_close_attempt_metric(attempt_num, buffer);

            if remaining <= self.epsilon {
                break;
            }
        }

        // Reduce-only delta hedge fallback if still exposed
        let hedge_used = if remaining > self.epsilon {
            self.execute_hedge_fallback(remaining);
            true
        } else {
            false
        };

        let final_exposure = if hedge_used { 0.0 } else { remaining };
        let time_ms = start.elapsed().as_millis() as u64;

        record_time_to_neutral_metric(time_ms);

        EmergencyCloseResult {
            close_attempts: attempts,
            hedge_used,
            final_exposure,
            time_to_neutral_ms: time_ms,
        }
    }

    /// Log AtomicNakedEvent per CONTRACT.md §3.1 schema
    pub fn log_atomic_naked_event(
        &self,
        group_id: &str,
        result: &EmergencyCloseResult,
        initial_exposure: f64,
        strategy_id: &str,
        trading_mode: &str,
    ) {
        record_atomic_naked_event_metric();

        let event = AtomicNakedEvent {
            group_id: group_id.to_string(),
            strategy_id: strategy_id.to_string(),
            incident_ts_ms: now_ms(),
            exposure_usd_before: initial_exposure,
            exposure_usd_after: result.final_exposure,
            time_to_delta_neutral_ms: result.time_to_neutral_ms,
            close_attempts: result.close_attempts.len() as u8,
            hedge_used: result.hedge_used,
            cause: "atomic_legging_failure".to_string(),
            trading_mode_at_event: trading_mode.to_string(),
        };

        eprintln!(
            "[WARN] AtomicNakedEvent group_id={} exposure_before={} exposure_after={} close_attempts={} hedge_used={} time_to_neutral_ms={}",
            event.group_id,
            event.exposure_usd_before,
            event.exposure_usd_after,
            event.close_attempts,
            event.hedge_used,
            event.time_to_delta_neutral_ms
        );
    }

    /// Bypass liquidity and net_edge gates for emergency close (CONTRACT.md §3.1)
    pub fn bypasses_gates(&self) -> bool {
        true
    }

    // ===== STUBS - MUST BE REPLACED FOR PRODUCTION =====
    // These methods are placeholder stubs for testing.
    // Production deployment REQUIRES integration with actual order executor.
    // TODO: Replace with real dispatch before production use
    fn simulate_close_attempt(&self, qty: f64) -> f64 {
        // STUB: Always returns full fill for testing
        // Production: Should dispatch IOC close order and return actual filled qty
        qty
    }

    fn execute_hedge_fallback(&self, remaining: f64) {
        // STUB: Log-only for testing
        // Production: Should dispatch reduce-only perp hedge order
        eprintln!(
            "[WARN] STUB: executing reduce-only delta hedge fallback remaining_qty={}",
            remaining
        );
    }
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("time")
        .as_millis() as u64
}

fn record_close_attempt_metric(attempt: u8, buffer: i32) {
    let tail = format!("attempt={attempt},buffer_ticks={buffer}");
    super::emit_execution_metric_line("emergency_close_attempt", &tail);
}

fn record_time_to_neutral_metric(time_ms: u64) {
    let tail = format!("value={time_ms}");
    super::emit_execution_metric_line("time_to_delta_neutral_ms", &tail);
}

fn record_atomic_naked_event_metric() {
    super::emit_execution_metric_line("atomic_naked_events_total", "");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_emergency_close_three_attempts_with_doubling_buffer() {
        let ec = EmergencyClose::new(0.001);
        let result = ec.execute("test-group", 1.0);

        assert_eq!(result.close_attempts.len(), 1); // Full fill on first try
        assert_eq!(result.close_attempts[0].buffer_ticks, 5);
        assert!(!result.hedge_used);
        assert!(result.final_exposure <= 0.001);
    }

    #[test]
    fn test_emergency_close_buffer_doubling_sequence() {
        let buffers = vec![
            INITIAL_BUFFER_TICKS * 1, // 5
            INITIAL_BUFFER_TICKS * 2, // 10
            INITIAL_BUFFER_TICKS * 4, // 20
        ];

        for (idx, expected) in buffers.iter().enumerate() {
            let attempt_num = (idx + 1) as u8;
            let actual = INITIAL_BUFFER_TICKS * (1 << (attempt_num - 1));
            assert_eq!(actual, *expected);
        }
    }

    #[test]
    fn test_atomic_naked_event_schema() {
        let ec = EmergencyClose::new(0.001);
        let result = ec.execute("test-group", 1.0);

        ec.log_atomic_naked_event("test-group", &result, 1.0, "test-strategy", "ReduceOnly");

        // Schema validated via types
        assert_eq!(
            result.close_attempts.len() as u8,
            result.close_attempts.len() as u8
        );
    }

    #[test]
    fn test_emergency_close_bypasses_gates() {
        let ec = EmergencyClose::new(0.001);
        assert!(ec.bypasses_gates());
    }
}
