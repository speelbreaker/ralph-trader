//! Integration tests for Reflexive Cortex (§2.3 Reflexive Cortex)
//!
//! Acceptance criteria:
//! - AT-231: DVOL jump >= 10% within 60s → ForceReduceOnly
//! - AT-045: spread >= spread_kill_bps OR depth <= depth_kill_min for kill_window → ForceKill
//! - AT-119: ws_gap_flag + risk-increasing cancel/replace → Blocked
//! - AT-418: ForceKill wins over ForceReduceOnly aggregation
//! - AT-420: depth_topN = min(top-5 bid USD, top-5 ask USD)
//! - AT-284: spread_bps = 26 → ForceReduceOnly
//! - AT-285: spread >= spread_kill_bps for window → ForceKill
//! - AT-286: depth_topN = 299_999 → ForceReduceOnly
//! - AT-288: depth_topN <= depth_kill_min for window → ForceKill
//! - AT-289: kill window: no trip at 9s, trip at 10s
//! - AT-290: DVOL jump >= 10% → ForceReduceOnly{cooldown_s=dvol_cooldown_s}
//! - AT-291: DVOL jump window: 61s = no trip, 59s = trip
//!
//! Named test aliases (PRD steps): test_cortex_spread_max_bps_forces_reduceonly,
//!   test_cortex_depth_min_forces_reduceonly

#[path = "../src/reflex/cortex.rs"]
mod cortex;

use cortex::{
    CancelReplacePermission, CortexConfig, CortexMonitor, CortexSignal, MarketData,
    compute_depth_top_n,
};

fn make_data(dvol: f64, spread_bps: f64, depth_top_n: f64, now_ms: u64) -> MarketData {
    MarketData {
        dvol: Some(dvol),
        spread_bps: Some(spread_bps),
        depth_top_n: Some(depth_top_n),
        now_ms,
    }
}

/// AT-231: GIVEN dvol_jump_pct >= 0.10 within dvol_jump_window_s <= 60 THEN ForceReduceOnly
#[test]
fn test_at_231_dvol_jump_triggers_reduceonly() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig::default(); // dvol_jump_pct=0.10, dvol_jump_window_s=60, dvol_cooldown_s=300

    // Tick 1: dvol = 0.80 at T=0
    let data1 = make_data(0.80, 10.0, 500_000.0, 0);
    let result1 = monitor.evaluate(data1, &config);
    assert_eq!(result1, CortexSignal::None, "No jump yet");

    // Tick 2: dvol = 0.90 at T=30s (within 60s window), jump = 12.5% (unambiguous >= 10%)
    let data2 = make_data(0.90, 10.0, 500_000.0, 30_000);
    let result2 = monitor.evaluate(data2, &config);
    assert_eq!(
        result2,
        CortexSignal::ForceReduceOnly { cooldown_s: 300 },
        "AT-231: 12.5% DVOL jump within 60s must trigger ForceReduceOnly with dvol_cooldown_s=300"
    );
}

/// AT-045: GIVEN spread >= spread_kill_bps for kill_window THEN ForceKill
#[test]
fn test_at_045_spread_kill_triggers_forcekill() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig {
        cortex_kill_window_s: 10,
        spread_kill_bps: 75.0,
        ..CortexConfig::default()
    };

    // Feed spread = 80 bps (>= 75) for 10 seconds
    let base_ms = 1_000_000u64;
    for i in 0..=10 {
        let now_ms = base_ms + i * 1_000;
        let data = make_data(0.80, 80.0, 500_000.0, now_ms);
        let result = monitor.evaluate(data, &config);
        if i == 10 {
            assert_eq!(
                result,
                CortexSignal::ForceKill,
                "AT-045: spread >= spread_kill_bps for kill_window must trigger ForceKill"
            );
        }
    }
}

/// AT-045 (depth variant): GIVEN depth_topN <= depth_kill_min for kill_window THEN ForceKill
#[test]
fn test_at_045_depth_kill_triggers_forcekill() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig {
        cortex_kill_window_s: 10,
        depth_kill_min: 100_000.0,
        ..CortexConfig::default()
    };

    // Feed depth = 99_999 (<= 100_000) for 10 seconds
    let base_ms = 2_000_000u64;
    for i in 0..=10 {
        let now_ms = base_ms + i * 1_000;
        let data = make_data(0.80, 10.0, 99_999.0, now_ms);
        let result = monitor.evaluate(data, &config);
        if i == 10 {
            assert_eq!(
                result,
                CortexSignal::ForceKill,
                "AT-045: depth <= depth_kill_min for kill_window must trigger ForceKill"
            );
        }
    }
}

/// AT-119: GIVEN ws_gap_flag=true AND risk-increasing cancel/replace THEN Blocked
#[test]
fn test_at_119_ws_gap_blocks_risk_increasing_cancel_replace() {
    let result = CortexMonitor::evaluate_cancel_replace(
        /*ws_gap_flag=*/ true, /*is_risk_increasing=*/ true,
    );
    assert_eq!(
        result,
        CancelReplacePermission::Blocked,
        "AT-119: ws_gap=true + risk-increasing cancel/replace must be Blocked"
    );
}

/// AT-119: GIVEN ws_gap_flag=true AND risk-REDUCING cancel/replace THEN Allowed
#[test]
fn test_at_119_ws_gap_allows_risk_reducing_cancel_replace() {
    let result = CortexMonitor::evaluate_cancel_replace(
        /*ws_gap_flag=*/ true, /*is_risk_increasing=*/ false,
    );
    assert_eq!(
        result,
        CancelReplacePermission::Allowed,
        "AT-119: ws_gap=true + risk-reducing cancel/replace must be Allowed"
    );
}

/// AT-418: ForceKill wins over ForceReduceOnly in aggregation
#[test]
fn test_at_418_forcekill_wins_aggregation() {
    let kill = CortexSignal::ForceKill;
    let ro = CortexSignal::ForceReduceOnly { cooldown_s: 120 };
    assert_eq!(
        CortexSignal::max_severity(kill, ro),
        CortexSignal::ForceKill,
        "AT-418: ForceKill must win over ForceReduceOnly in max_severity"
    );
    assert_eq!(
        CortexSignal::max_severity(ro, kill),
        CortexSignal::ForceKill,
        "AT-418: Order of args must not matter"
    );
}

/// AT-420: depth_topN = min(top-5 bid USD, top-5 ask USD)
#[test]
fn test_at_420_depth_top_n_computation() {
    // top-5 bids: assume 5 levels each contributing 64_000 USD → total 320_000
    // top-5 asks: assume 5 levels each contributing 56_000 USD → total 280_000
    let bids: Vec<(f64, f64)> = vec![
        (40_000.0, 1.6),
        (39_999.0, 1.6),
        (39_998.0, 1.6),
        (39_997.0, 1.6),
        (39_996.0, 1.6),
    ];
    let asks: Vec<(f64, f64)> = vec![
        (40_001.0, 1.4),
        (40_002.0, 1.4),
        (40_003.0, 1.4),
        (40_004.0, 1.4),
        (40_005.0, 1.4),
    ];
    let depth = compute_depth_top_n(&bids, &asks);
    // bid total = 40_000*1.6 + ... ≈ 320_000; ask total ≈ 280_000
    let bid_usd: f64 = bids.iter().map(|(p, q)| p * q).sum();
    let ask_usd: f64 = asks.iter().map(|(p, q)| p * q).sum();
    assert!(
        (depth - ask_usd.min(bid_usd)).abs() < 1.0,
        "AT-420: depth_topN must be min(bid_usd, ask_usd), got {}",
        depth
    );
    assert!(
        depth < bid_usd,
        "AT-420: depth_topN should be the ask (conservative) side"
    );
}

/// AT-284 (named alias: test_cortex_spread_max_bps_forces_reduceonly)
/// GIVEN spread_bps = 26 (> spread_max_bps=25) THEN ForceReduceOnly
#[test]
fn test_cortex_spread_max_bps_forces_reduceonly() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig::default(); // spread_max_bps=25
    let data = make_data(0.80, 26.0, 500_000.0, 100_000);
    let result = monitor.evaluate(data, &config);
    assert_eq!(
        result,
        CortexSignal::ForceReduceOnly {
            cooldown_s: config.spread_depth_cooldown_s
        },
        "AT-284: spread=26 > spread_max_bps=25 must trigger ForceReduceOnly"
    );
}

/// AT-286 (named alias: test_cortex_depth_min_forces_reduceonly)
/// GIVEN depth_topN = 299_999 (< depth_min=300_000) THEN ForceReduceOnly
#[test]
fn test_cortex_depth_min_forces_reduceonly() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig::default(); // depth_min=300_000
    let data = make_data(0.80, 10.0, 299_999.0, 100_000);
    let result = monitor.evaluate(data, &config);
    assert_eq!(
        result,
        CortexSignal::ForceReduceOnly {
            cooldown_s: config.spread_depth_cooldown_s
        },
        "AT-286: depth=299_999 < depth_min=300_000 must trigger ForceReduceOnly"
    );
}

/// AT-285: spread >= spread_kill_bps for window → ForceKill (point check)
#[test]
fn test_at_285_spread_kill_bps_triggers_forcekill() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig {
        cortex_kill_window_s: 10,
        ..CortexConfig::default()
    };
    // Feed spread = 75 bps (== spread_kill_bps) for exactly 10 seconds
    for i in 0..=10 {
        let now_ms = i * 1_000u64;
        let data = make_data(0.80, 75.0, 500_000.0, now_ms);
        let result = monitor.evaluate(data, &config);
        if i == 10 {
            assert_eq!(
                result,
                CortexSignal::ForceKill,
                "AT-285: spread >= spread_kill_bps for kill_window must trigger ForceKill"
            );
        }
    }
}

/// AT-288: depth_topN <= depth_kill_min for window → ForceKill (point check)
#[test]
fn test_at_288_depth_kill_min_triggers_forcekill() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig {
        cortex_kill_window_s: 10,
        ..CortexConfig::default()
    };
    // Feed depth = 100_000 (<= depth_kill_min) for exactly 10 seconds
    for i in 0..=10 {
        let now_ms = i * 1_000u64 + 10_000_000;
        let data = make_data(0.80, 10.0, 100_000.0, now_ms);
        let result = monitor.evaluate(data, &config);
        if i == 10 {
            assert_eq!(
                result,
                CortexSignal::ForceKill,
                "AT-288: depth <= depth_kill_min for kill_window must trigger ForceKill"
            );
        }
    }
}

/// AT-289: kill window — no trip at 9s, trip at 10s
#[test]
fn test_at_289_kill_window_threshold() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig {
        cortex_kill_window_s: 10,
        ..CortexConfig::default()
    };

    // Feed spread kill for 9 seconds — no trip yet
    for i in 0..=9 {
        let now_ms = i * 1_000u64 + 20_000_000;
        let data = make_data(0.80, 80.0, 500_000.0, now_ms);
        let result = monitor.evaluate(data, &config);
        if i == 9 {
            assert_ne!(
                result,
                CortexSignal::ForceKill,
                "AT-289: must not trip at 9s (window is 10s)"
            );
        }
    }

    // One more second — should trip now
    let now_ms = 10 * 1_000u64 + 20_000_000;
    let data = make_data(0.80, 80.0, 500_000.0, now_ms);
    let result = monitor.evaluate(data, &config);
    assert_eq!(
        result,
        CortexSignal::ForceKill,
        "AT-289: must trip at 10s (== kill window)"
    );
}

/// AT-290: DVOL jump >= 10% within window → ForceReduceOnly{cooldown_s=dvol_cooldown_s}
#[test]
fn test_at_290_dvol_jump_pct_triggers_reduceonly() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig::default(); // dvol_jump_pct=0.10, dvol_cooldown_s=300

    // Seed with dvol = 0.50 at T=0
    let data1 = make_data(0.50, 10.0, 500_000.0, 0);
    let _ = monitor.evaluate(data1, &config);

    // Jump to 0.55 at T=30s (exactly 10% jump, within 60s window)
    let data2 = make_data(0.55, 10.0, 500_000.0, 30_000);
    let result = monitor.evaluate(data2, &config);
    assert_eq!(
        result,
        CortexSignal::ForceReduceOnly { cooldown_s: 300 },
        "AT-290: DVOL jump >= 10% must trigger ForceReduceOnly with cooldown_s=dvol_cooldown_s=300"
    );
}

/// AT-291: DVOL jump window — 61s = no trip, 59s = trip (window boundary)
#[test]
fn test_at_291_dvol_jump_window_boundary() {
    let config = CortexConfig::default(); // dvol_jump_window_s=60

    // Case 1: jump over 61 seconds (outside window) → no trip
    {
        let mut monitor = CortexMonitor::new();
        let data1 = make_data(0.50, 10.0, 500_000.0, 0);
        let _ = monitor.evaluate(data1, &config);
        // Advance 61s — old sample is now outside the 60s window
        let data2 = make_data(0.55, 10.0, 500_000.0, 61_000);
        let result = monitor.evaluate(data2, &config);
        assert_ne!(
            result,
            CortexSignal::ForceReduceOnly { cooldown_s: 300 },
            "AT-291: DVOL jump over 61s must NOT trigger (outside 60s window)"
        );
    }

    // Case 2: jump over 59 seconds (inside window) → trip
    {
        let mut monitor = CortexMonitor::new();
        let data1 = make_data(0.50, 10.0, 500_000.0, 0);
        let _ = monitor.evaluate(data1, &config);
        // Advance 59s — old sample is still within the 60s window
        let data2 = make_data(0.55, 10.0, 500_000.0, 59_000);
        let result = monitor.evaluate(data2, &config);
        assert_eq!(
            result,
            CortexSignal::ForceReduceOnly { cooldown_s: 300 },
            "AT-291: DVOL jump over 59s must trigger (inside 60s window)"
        );
    }
}

/// ForceKill supersedes ForceReduceOnly when both conditions are met in the same tick
#[test]
fn test_forcekill_supersedes_forcereduceonly_same_tick() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig {
        cortex_kill_window_s: 1, // very short window for test
        ..CortexConfig::default()
    };

    // Seed DVOL so jump condition is met
    let data1 = make_data(0.50, 10.0, 500_000.0, 0);
    let _ = monitor.evaluate(data1, &config);

    // Now: dvol jumps 10%, AND spread >= spread_kill for 1s window
    // First tick: start kill window and trigger dvol jump
    let data2 = make_data(0.55, 80.0, 500_000.0, 1_000); // kill window starts
    let _ = monitor.evaluate(data2, &config);

    // Second tick at 1s boundary: kill window expires → ForceKill wins
    let data3 = make_data(0.55, 80.0, 500_000.0, 2_000);
    let result = monitor.evaluate(data3, &config);
    assert_eq!(
        result,
        CortexSignal::ForceKill,
        "ForceKill must supersede ForceReduceOnly when both triggered"
    );
}

/// Verify counters increment correctly
#[test]
fn test_counters_increment() {
    let mut monitor = CortexMonitor::new();
    let config = CortexConfig::default();

    // Trigger a ForceReduceOnly via spread
    let data = make_data(0.80, 26.0, 500_000.0, 100_000);
    let _ = monitor.evaluate(data, &config);
    assert_eq!(monitor.counters.force_reduce_only_total, 1);

    // Trigger fail-closed
    let data2 = MarketData {
        dvol: None,
        spread_bps: Some(10.0),
        depth_top_n: Some(500_000.0),
        now_ms: 200_000,
    };
    let _ = monitor.evaluate(data2, &config);
    assert_eq!(monitor.counters.fail_closed_total, 1);
    assert_eq!(monitor.counters.force_reduce_only_total, 2);
}

/// No ws_gap flag → cancel/replace always allowed regardless of risk direction
#[test]
fn test_no_ws_gap_always_allows_cancel_replace() {
    assert_eq!(
        CortexMonitor::evaluate_cancel_replace(false, true),
        CancelReplacePermission::Allowed,
        "No ws_gap: risk-increasing cancel/replace must be Allowed"
    );
    assert_eq!(
        CortexMonitor::evaluate_cancel_replace(false, false),
        CancelReplacePermission::Allowed,
        "No ws_gap: risk-reducing cancel/replace must be Allowed"
    );
}
