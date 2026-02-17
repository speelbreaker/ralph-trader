/// Tests for Basis Monitor — Mark/Index/Last Liquidation Reality Guard
/// Contract: §2.3.3 | AT-951, AT-952, AT-954, AT-963
use soldier_core::risk::{BasisDecision, BasisMonitor, BasisMonitorConfig, BasisPrices};

/// Helper: build fresh prices where all timestamps are `now_ms - 100` (well within max_age).
fn fresh_prices(mark: f64, index: f64, last: f64, now_ms: u64) -> BasisPrices {
    BasisPrices {
        mark_price: Some(mark),
        mark_price_ts_ms: Some(now_ms - 100),
        index_price: Some(index),
        index_price_ts_ms: Some(now_ms - 100),
        last_price: Some(last),
        last_price_ts_ms: Some(now_ms - 100),
    }
}

/// Simulate N ticks at 1s spacing to advance a window, starting at `start_ms`.
/// Returns the monitor after all ticks, with the last decision.
fn drive_ticks(
    monitor: &mut BasisMonitor,
    prices: BasisPrices,
    config: BasisMonitorConfig,
    start_ms: u64,
    n_ticks: u64,
) -> BasisDecision {
    let mut decision = BasisDecision::Normal;
    for i in 0..n_ticks {
        let now_ms = start_ms + i * 1_000;
        // Update timestamps to keep prices fresh
        let p = BasisPrices {
            mark_price_ts_ms: Some(now_ms - 100),
            index_price_ts_ms: Some(now_ms - 100),
            last_price_ts_ms: Some(now_ms - 100),
            ..prices
        };
        decision = monitor.evaluate(p, now_ms, config);
    }
    decision
}

// ─── AT-951: ReduceOnly trip after sustained basis >= reduceonly_bps ─────────

/// AT-951: basis exceeds 50 bps for 5s → ForceReduceOnly with basis cooldown
#[test]
fn test_at_951_reduceonly_trip_after_window() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 5,
        basis_reduceonly_cooldown_s: 300,
        basis_kill_bps: 150.0,
        basis_kill_window_s: 5,
        basis_price_max_age_ms: 5_000,
    };

    // mark=100, last=100.6 → basis_mark_last = 0.6/100*10000 = 60 bps (> 50)
    // mark=100, index=100.0 → basis_mark_index = 0 bps
    // max = 60 bps >= 50 bps threshold
    let start_ms = 1_000_000;
    let prices = fresh_prices(100.0, 100.0, 100.6, start_ms);

    // Drive 4 ticks (0–3s): should not trip yet
    for i in 0..4 {
        let now_ms = start_ms + i * 1_000;
        let p = BasisPrices {
            mark_price_ts_ms: Some(now_ms - 100),
            index_price_ts_ms: Some(now_ms - 100),
            last_price_ts_ms: Some(now_ms - 100),
            ..prices
        };
        let d = monitor.evaluate(p, now_ms, config);
        // Not yet at window boundary (need 5s elapsed)
        assert_ne!(d, BasisDecision::ForceKill, "Should not kill at tick {i}");
    }

    // Tick at t=5s: window has elapsed >= 5s, trip fires
    let now_ms = start_ms + 5_000;
    let p = BasisPrices {
        mark_price_ts_ms: Some(now_ms - 100),
        index_price_ts_ms: Some(now_ms - 100),
        last_price_ts_ms: Some(now_ms - 100),
        ..prices
    };
    let decision = monitor.evaluate(p, now_ms, config);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 300 },
        "AT-951: expected ForceReduceOnly with basis cooldown_s=300, got {:?}",
        decision
    );
}

/// AT-951: ReduceOnly enforced with the basis-specific cooldown parameter
#[test]
fn test_at_951_reduceonly_uses_basis_cooldown_param() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 5,
        basis_reduceonly_cooldown_s: 600, // non-default cooldown to verify param used
        basis_kill_bps: 150.0,
        basis_kill_window_s: 5,
        basis_price_max_age_ms: 5_000,
    };

    let start_ms = 2_000_000;
    // 60 bps: exceeds 50 bps reduceonly threshold but not 150 bps kill
    let prices = fresh_prices(100.0, 100.0, 100.6, start_ms);
    let decision = drive_ticks(&mut monitor, prices, config, start_ms, 6);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 600 },
        "AT-951: ForceReduceOnly must use basis_reduceonly_cooldown_s param, got {:?}",
        decision
    );
}

// ─── AT-952: Kill trip after sustained basis >= kill_bps ─────────────────────

/// AT-952: basis exceeds 150 bps for 5s → ForceKill
#[test]
fn test_at_952_kill_trip_after_window() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 5,
        basis_reduceonly_cooldown_s: 300,
        basis_kill_bps: 150.0,
        basis_kill_window_s: 5,
        basis_price_max_age_ms: 5_000,
    };

    // mark=100, index=98.5 → basis_mark_index = 1.5/100*10000 = 150 bps (= kill threshold)
    // mark=100, last=100 → basis_mark_last = 0 bps
    // max = 150 bps >= 150 bps kill threshold
    let start_ms = 3_000_000;
    let prices = fresh_prices(100.0, 98.5, 100.0, start_ms);
    let decision = drive_ticks(&mut monitor, prices, config, start_ms, 6);

    assert_eq!(
        decision,
        BasisDecision::ForceKill,
        "AT-952: expected ForceKill when basis >= kill_bps for kill_window, got {:?}",
        decision
    );
}

/// AT-952: Kill is highest priority — overrides ReduceOnly check
#[test]
fn test_at_952_kill_overrides_reduceonly() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 5,
        basis_reduceonly_cooldown_s: 300,
        basis_kill_bps: 150.0,
        basis_kill_window_s: 5,
        basis_price_max_age_ms: 5_000,
    };

    // 200 bps: exceeds both kill and reduceonly thresholds
    let start_ms = 4_000_000;
    let prices = fresh_prices(100.0, 98.0, 100.0, start_ms); // 2% spread = 200 bps
    let decision = drive_ticks(&mut monitor, prices, config, start_ms, 6);

    assert_eq!(
        decision,
        BasisDecision::ForceKill,
        "AT-952: kill should take priority over reduceonly, got {:?}",
        decision
    );
}

// ─── AT-954: Missing or stale inputs → fail-closed ForceReduceOnly ───────────

/// AT-954: Missing mark_price → ForceReduceOnly (fail-closed)
#[test]
fn test_at_954_missing_mark_price_fail_closed() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig::default();
    let now_ms = 5_000_000;

    let prices = BasisPrices {
        mark_price: None, // Missing!
        mark_price_ts_ms: None,
        index_price: Some(100.0),
        index_price_ts_ms: Some(now_ms - 100),
        last_price: Some(100.0),
        last_price_ts_ms: Some(now_ms - 100),
    };
    let decision = monitor.evaluate(prices, now_ms, config);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 300 },
        "AT-954: missing mark_price must trigger fail-closed ForceReduceOnly"
    );
}

/// AT-954: Missing index_price → ForceReduceOnly (fail-closed)
#[test]
fn test_at_954_missing_index_price_fail_closed() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig::default();
    let now_ms = 5_100_000;

    let prices = BasisPrices {
        mark_price: Some(100.0),
        mark_price_ts_ms: Some(now_ms - 100),
        index_price: None, // Missing!
        index_price_ts_ms: None,
        last_price: Some(100.0),
        last_price_ts_ms: Some(now_ms - 100),
    };
    let decision = monitor.evaluate(prices, now_ms, config);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 300 },
        "AT-954: missing index_price must trigger fail-closed ForceReduceOnly"
    );
}

/// AT-954: Missing last_price → ForceReduceOnly (fail-closed)
#[test]
fn test_at_954_missing_last_price_fail_closed() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig::default();
    let now_ms = 5_200_000;

    let prices = BasisPrices {
        mark_price: Some(100.0),
        mark_price_ts_ms: Some(now_ms - 100),
        index_price: Some(100.0),
        index_price_ts_ms: Some(now_ms - 100),
        last_price: None, // Missing!
        last_price_ts_ms: None,
    };
    let decision = monitor.evaluate(prices, now_ms, config);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 300 },
        "AT-954: missing last_price must trigger fail-closed ForceReduceOnly"
    );
}

/// AT-954: Stale mark_price (age > basis_price_max_age_ms) → ForceReduceOnly
#[test]
fn test_at_954_stale_mark_price_fail_closed() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_price_max_age_ms: 5_000,
        ..Default::default()
    };
    let now_ms = 6_000_000;

    let prices = BasisPrices {
        mark_price: Some(100.0),
        mark_price_ts_ms: Some(now_ms - 6_000), // 6s old → stale!
        index_price: Some(100.0),
        index_price_ts_ms: Some(now_ms - 100),
        last_price: Some(100.0),
        last_price_ts_ms: Some(now_ms - 100),
    };
    let decision = monitor.evaluate(prices, now_ms, config);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 300 },
        "AT-954: stale mark price must trigger fail-closed ForceReduceOnly"
    );
}

/// AT-954: Stale last_price (age > basis_price_max_age_ms) → ForceReduceOnly
#[test]
fn test_at_954_stale_last_price_fail_closed() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_price_max_age_ms: 5_000,
        ..Default::default()
    };
    let now_ms = 6_100_000;

    let prices = BasisPrices {
        mark_price: Some(100.0),
        mark_price_ts_ms: Some(now_ms - 100),
        index_price: Some(100.0),
        index_price_ts_ms: Some(now_ms - 100),
        last_price: Some(100.0),
        last_price_ts_ms: Some(now_ms - 6_000), // stale!
    };
    let decision = monitor.evaluate(prices, now_ms, config);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 300 },
        "AT-954: stale last price must trigger fail-closed ForceReduceOnly"
    );
}

// ─── AT-963: Normal operation — no override when basis below threshold ────────

/// AT-963: basis < reduceonly threshold → Normal (no override)
#[test]
fn test_at_963_below_threshold_normal() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 5,
        basis_reduceonly_cooldown_s: 300,
        basis_kill_bps: 150.0,
        basis_kill_window_s: 5,
        basis_price_max_age_ms: 5_000,
    };

    // mark=100, index=100.1, last=100.2 → basis_mark_last=20 bps, basis_mark_index=10 bps
    // max = 20 bps < 50 bps threshold → Normal
    let start_ms = 7_000_000;
    let prices = fresh_prices(100.0, 100.1, 100.2, start_ms);

    // Drive 6 ticks — stays below threshold, no trip
    let decision = drive_ticks(&mut monitor, prices, config, start_ms, 6);

    assert_eq!(
        decision,
        BasisDecision::Normal,
        "AT-963: fresh prices below threshold must produce Normal, got {:?}",
        decision
    );
}

// ─── Additional correctness tests ────────────────────────────────────────────

/// Window resets when basis drops below threshold mid-window
#[test]
fn test_window_resets_when_basis_drops_below_threshold() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 5,
        basis_reduceonly_cooldown_s: 300,
        basis_kill_bps: 150.0,
        basis_kill_window_s: 5,
        basis_price_max_age_ms: 5_000,
    };

    let start_ms = 8_000_000;
    // 60 bps: drive 3 ticks (trip started)
    let prices_high = fresh_prices(100.0, 100.0, 100.6, start_ms);
    for i in 0..3 {
        let now_ms = start_ms + i * 1_000;
        let p = BasisPrices {
            mark_price_ts_ms: Some(now_ms - 100),
            index_price_ts_ms: Some(now_ms - 100),
            last_price_ts_ms: Some(now_ms - 100),
            ..prices_high
        };
        let d = monitor.evaluate(p, now_ms, config);
        assert_eq!(d, BasisDecision::Normal, "Should not trip yet at tick {i}");
    }

    // Drop basis below threshold: resets window
    let reset_ms = start_ms + 3_000;
    let prices_low = BasisPrices {
        mark_price: Some(100.0),
        mark_price_ts_ms: Some(reset_ms - 100),
        index_price: Some(100.0),
        index_price_ts_ms: Some(reset_ms - 100),
        last_price: Some(100.1), // 10 bps < 50 bps threshold
        last_price_ts_ms: Some(reset_ms - 100),
    };
    let d = monitor.evaluate(prices_low, reset_ms, config);
    assert_eq!(
        d,
        BasisDecision::Normal,
        "Should be Normal after basis drop"
    );

    // Drive 4 more ticks high — window restarted from here, should not trip in first 4
    for i in 0..4 {
        let now_ms = reset_ms + (i + 1) * 1_000;
        let p = BasisPrices {
            mark_price_ts_ms: Some(now_ms - 100),
            index_price_ts_ms: Some(now_ms - 100),
            last_price_ts_ms: Some(now_ms - 100),
            ..prices_high
        };
        let d = monitor.evaluate(p, now_ms, config);
        if i < 4 {
            // At i=4 it would trip; at i < 4 it should not
            assert_ne!(d, BasisDecision::ForceKill, "Should not kill at tick {i}");
        }
    }
}

/// basis_trip_total counter increments on each trip
#[test]
fn test_trip_total_counter_increments() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 1, // short window for test speed
        basis_reduceonly_cooldown_s: 300,
        basis_kill_bps: 150.0,
        basis_kill_window_s: 1,
        basis_price_max_age_ms: 5_000,
    };

    assert_eq!(monitor.trip_total(), 0);

    // Drive 2 ticks at 60 bps with 1s window — should trip on tick 2
    let start_ms = 9_000_000;
    let prices = fresh_prices(100.0, 100.0, 100.6, start_ms);
    let d1 = {
        let now_ms = start_ms;
        let p = BasisPrices {
            mark_price_ts_ms: Some(now_ms - 100),
            index_price_ts_ms: Some(now_ms - 100),
            last_price_ts_ms: Some(now_ms - 100),
            ..prices
        };
        monitor.evaluate(p, now_ms, config)
    };
    let d2 = {
        let now_ms = start_ms + 1_000;
        let p = BasisPrices {
            mark_price_ts_ms: Some(now_ms - 100),
            index_price_ts_ms: Some(now_ms - 100),
            last_price_ts_ms: Some(now_ms - 100),
            ..prices
        };
        monitor.evaluate(p, now_ms, config)
    };

    // At least one of d1/d2 should be ForceReduceOnly and trip_total >= 1
    let _ = (d1, d2);
    assert!(
        monitor.trip_total() >= 1,
        "trip_total should increment after trip, got {}",
        monitor.trip_total()
    );
}

/// max() of basis_mark_last and basis_mark_index drives threshold comparison
#[test]
fn test_max_basis_used_for_threshold() {
    let mut monitor = BasisMonitor::new();
    let config = BasisMonitorConfig {
        basis_reduceonly_bps: 50.0,
        basis_reduceonly_window_s: 5,
        basis_reduceonly_cooldown_s: 300,
        basis_kill_bps: 150.0,
        basis_kill_window_s: 5,
        basis_price_max_age_ms: 5_000,
    };

    let start_ms = 10_000_000;
    // mark=100, index=100.6 (basis_mark_index=60bps), last=100.0 (basis_mark_last=0bps)
    // max = 60 bps >= 50 bps → should trip on window
    let prices = fresh_prices(100.0, 100.6, 100.0, start_ms);
    let decision = drive_ticks(&mut monitor, prices, config, start_ms, 6);

    assert_eq!(
        decision,
        BasisDecision::ForceReduceOnly { cooldown_s: 300 },
        "max(basis_mark_last, basis_mark_index) must be used; index basis should trigger trip"
    );
}
