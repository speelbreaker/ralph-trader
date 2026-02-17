//! Integration tests for Network Jitter Monitor — Bunker Mode Override
//! Contract: §2.3.2 | AT-115, AT-205, AT-345

#[path = "../src/risk/network_jitter.rs"]
mod network_jitter;

use network_jitter::{JitterInputs, NetworkJitterConfig, NetworkJitterMonitor};

/// Helper: build all-present inputs with given values.
fn inputs(ws_lag: u64, http_p95: u64, timeout_rate: f64) -> JitterInputs {
    JitterInputs {
        ws_event_lag_ms: Some(ws_lag),
        http_p95_ms: Some(http_p95),
        request_timeout_rate: Some(timeout_rate),
    }
}

/// Helper: build inputs with ws_event_lag_ms missing.
fn inputs_no_ws(http_p95: u64, timeout_rate: f64) -> JitterInputs {
    JitterInputs {
        ws_event_lag_ms: None,
        http_p95_ms: Some(http_p95),
        request_timeout_rate: Some(timeout_rate),
    }
}

/// All metrics safe (below all thresholds).
fn safe_inputs() -> JitterInputs {
    inputs(100, 100, 0.001)
}

// ─── AT-209 / acceptance[0]: ws_event_lag_ms > 2000 → bunker entry, block OPENs ───

#[test]
fn test_ws_event_lag_above_threshold_enters_bunker() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default(); // threshold = 2000ms
    let now_ms = 1_000_000;

    // ws_event_lag_ms = 2001 > 2000 → bunker active
    let active = mon.evaluate(inputs(2001, 100, 0.001), now_ms, &cfg);
    assert!(active, "ws_event_lag_ms > 2000 must activate bunker mode");
    assert!(mon.is_active());
}

#[test]
fn test_ws_event_lag_at_threshold_no_bunker() {
    // Boundary: ws_lag == threshold → NOT > threshold → no bunker
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    let active = mon.evaluate(inputs(2000, 100, 0.001), now_ms, &cfg);
    assert!(
        !active,
        "ws_event_lag_ms == 2000 (not >) must not trigger bunker"
    );
}

// ─── AT-345 / acceptance[1]: http_p95_ms > 750 for 3 consecutive windows ───

#[test]
fn test_http_p95_three_consecutive_windows_enters_bunker() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default(); // http_p95_threshold_ms=750, consecutive=3
    let now_ms = 1_000_000;

    // Tick 1: http_p95 = 751 > 750, consecutive=1 → no trip yet
    let t1 = mon.evaluate(inputs(100, 751, 0.001), now_ms, &cfg);
    assert!(!t1, "first consecutive breach must not trip");

    // Tick 2: consecutive=2 → still no trip
    let t2 = mon.evaluate(inputs(100, 751, 0.001), now_ms + 1_000, &cfg);
    assert!(!t2, "second consecutive breach must not trip");

    // Tick 3: consecutive=3 → trip!
    let t3 = mon.evaluate(inputs(100, 751, 0.001), now_ms + 2_000, &cfg);
    assert!(t3, "third consecutive breach must trigger bunker (AT-345)");
}

#[test]
fn test_http_p95_non_breach_resets_consecutive_count() {
    // Per AT-345: "a non-breach resets the count"
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    // Two breaches
    mon.evaluate(inputs(100, 751, 0.001), now_ms, &cfg);
    mon.evaluate(inputs(100, 751, 0.001), now_ms + 1_000, &cfg);

    // Non-breach resets
    mon.evaluate(inputs(100, 750, 0.001), now_ms + 2_000, &cfg); // 750 == threshold, not > → safe

    // Two more breaches → should still require 3 consecutive
    mon.evaluate(inputs(100, 751, 0.001), now_ms + 3_000, &cfg);
    let t = mon.evaluate(inputs(100, 751, 0.001), now_ms + 4_000, &cfg);
    assert!(
        !t,
        "after reset, 2 consecutive breaches must not trigger (still need 3)"
    );

    // Third consecutive after reset → trip
    let t2 = mon.evaluate(inputs(100, 751, 0.001), now_ms + 5_000, &cfg);
    assert!(t2, "third consecutive breach after reset must trigger");
}

#[test]
fn test_http_p95_at_threshold_no_trip() {
    // Boundary: http_p95 == threshold → NOT > → no consecutive count increment
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    for i in 0..5 {
        let t = mon.evaluate(inputs(100, 750, 0.001), now_ms + i * 1_000, &cfg);
        assert!(!t, "http_p95 == 750 (not >) must never trigger bunker");
    }
}

// ─── acceptance[2]: request_timeout_rate > 0.02 → bunker entry ───

#[test]
fn test_timeout_rate_above_threshold_enters_bunker() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    // 0.021 > 0.02 → trip
    let active = mon.evaluate(inputs(100, 100, 0.021), now_ms, &cfg);
    assert!(
        active,
        "request_timeout_rate > 0.02 must activate bunker mode"
    );
}

#[test]
fn test_timeout_rate_at_threshold_no_bunker() {
    // Boundary: timeout_rate == threshold → NOT > → no trip
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    let active = mon.evaluate(inputs(100, 100, 0.02), now_ms, &cfg);
    assert!(
        !active,
        "request_timeout_rate == 0.02 (not >) must not trigger bunker"
    );
}

// ─── AT-205 / acceptance[3]: ws_event_lag_ms missing → fail-closed ───

#[test]
fn test_at_205_ws_event_lag_missing_fail_closed() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    // ws_event_lag_ms = None → fail-closed → bunker active
    let active = mon.evaluate(inputs_no_ws(100, 0.001), now_ms, &cfg);
    assert!(
        active,
        "AT-205: missing ws_event_lag_ms must activate bunker (fail-closed)"
    );
}

#[test]
fn test_http_p95_missing_fail_closed() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    let inp = JitterInputs {
        ws_event_lag_ms: Some(100),
        http_p95_ms: None,
        request_timeout_rate: Some(0.001),
    };
    let active = mon.evaluate(inp, now_ms, &cfg);
    assert!(
        active,
        "missing http_p95_ms must activate bunker (fail-closed)"
    );
}

#[test]
fn test_timeout_rate_missing_fail_closed() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    let inp = JitterInputs {
        ws_event_lag_ms: Some(100),
        http_p95_ms: Some(100),
        request_timeout_rate: None,
    };
    let active = mon.evaluate(inp, now_ms, &cfg);
    assert!(
        active,
        "missing request_timeout_rate must activate bunker (fail-closed)"
    );
}

// ─── AT-115 / acceptance[4]: Exit only after 120s stable ───

#[test]
fn test_at_115_exit_bunker_only_after_120s_stable() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default(); // bunker_exit_stable_s = 120

    let t0 = 1_000_000_u64;

    // Enter bunker via ws_lag
    let active = mon.evaluate(inputs(2001, 100, 0.001), t0, &cfg);
    assert!(active, "should enter bunker");

    // Start stable period: all metrics below thresholds
    // 119s stable — must still be in bunker
    let still_active = mon.evaluate(safe_inputs(), t0 + 119_000, &cfg);
    assert!(
        still_active,
        "AT-115: must remain in bunker at 119s stable (< 120s required)"
    );

    // 120s stable — may exit
    let exited = mon.evaluate(safe_inputs(), t0 + 239_000, &cfg);
    // Note: stable timer starts at t0+1 (first safe evaluation), so 120s = t0+121_000
    // Let's compute properly:
    // - bunker entered at t0
    // - first safe tick at t0+119_000 → stable_start = t0+119_000
    // - next safe tick at t0+239_000 → stable_ms = 120_000 >= 120_000 → exit
    assert!(
        !exited,
        "AT-115: must exit bunker after full 120s stable period"
    );
}

#[test]
fn test_stable_timer_resets_when_trip_reoccurs() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let t0 = 1_000_000_u64;

    // Enter bunker
    mon.evaluate(inputs(2001, 100, 0.001), t0, &cfg);

    // 60s of stable metrics
    mon.evaluate(safe_inputs(), t0 + 60_000, &cfg);

    // Trip again — stable timer must reset
    mon.evaluate(inputs(2001, 100, 0.001), t0 + 90_000, &cfg);

    // 119s after re-trip start — still in bunker
    let still_in = mon.evaluate(safe_inputs(), t0 + 209_000, &cfg);
    assert!(
        still_in,
        "stable timer must reset on re-trip; must remain in bunker at 119s from re-trip"
    );
}

#[test]
fn test_bunker_not_active_when_all_safe() {
    // No trip conditions → never enters bunker
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    let active = mon.evaluate(safe_inputs(), now_ms, &cfg);
    assert!(!active, "no trip conditions → bunker must not activate");
}

// ─── Observability: bunker_mode_trip_total counter ───

#[test]
fn test_trip_total_counter_increments_on_entry() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig::default();
    let now_ms = 1_000_000;

    assert_eq!(mon.trip_total(), 0);

    // Enter bunker
    mon.evaluate(inputs(2001, 100, 0.001), now_ms, &cfg);
    assert_eq!(
        mon.trip_total(),
        1,
        "trip_total must increment on bunker entry"
    );

    // Remain in bunker — no additional increment
    mon.evaluate(inputs(2001, 100, 0.001), now_ms + 1_000, &cfg);
    assert_eq!(
        mon.trip_total(),
        1,
        "trip_total must not increment while bunker remains active"
    );
}

#[test]
fn test_trip_total_increments_on_reentry() {
    let mut mon = NetworkJitterMonitor::new();
    let cfg = NetworkJitterConfig {
        bunker_exit_stable_s: 1, // 1s exit for fast test
        ..Default::default()
    };
    let t0 = 1_000_000_u64;

    // First trip
    mon.evaluate(inputs(2001, 100, 0.001), t0, &cfg);
    assert_eq!(mon.trip_total(), 1);

    // Exit bunker: stable for 1s
    mon.evaluate(safe_inputs(), t0 + 1_000, &cfg); // stable_start = t0+1_000
    mon.evaluate(safe_inputs(), t0 + 2_000, &cfg); // stable_ms=1000 → exit

    // Second trip
    mon.evaluate(inputs(2001, 100, 0.001), t0 + 3_000, &cfg);
    assert_eq!(
        mon.trip_total(),
        2,
        "trip_total must increment on re-entry after exit"
    );
}
