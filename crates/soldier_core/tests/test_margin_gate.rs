/// Acceptance tests for Margin Headroom Gate (§1.4.3)
///
/// Tests margin liquidation shield with mm_util thresholds for:
/// - OPEN rejection at mm_util_reject_opens
/// - ReduceOnly mode at mm_util_reduceonly
/// - Kill mode at mm_util_kill
use soldier_core::risk::{
    MarginConfig, MarginGateResult, MarginModeRecommendation, MarginSnapshot,
    compute_margin_mode_recommendation, evaluate_margin_gate_for_open,
};

#[test]
fn test_at_227_open_rejected_at_72pct_utilization() {
    // AT-227: equity=100k, maintenance_margin=72k → OPEN rejected
    let snapshot = MarginSnapshot {
        maintenance_margin: 72_000.0,
        equity: 100_000.0,
    };
    let config = MarginConfig::default();

    let result = evaluate_margin_gate_for_open(&snapshot, &config);
    assert_eq!(
        result,
        MarginGateResult::RejectOpens,
        "OPEN should be rejected at 72% utilization (above 70% threshold)"
    );
}

#[test]
fn test_at_912_reject_reason_margin_headroom_reject_opens() {
    // AT-912: mm_util >= mm_util_reject_opens and < mm_util_reduceonly
    // → OPEN rejected with MarginHeadroomRejectOpens reason
    let snapshot = MarginSnapshot {
        maintenance_margin: 75_000.0, // 75% utilization
        equity: 100_000.0,
    };
    let config = MarginConfig::default();

    // Verify mm_util is in the reject range but below ReduceOnly
    let mm_util = snapshot.mm_util();
    assert!(
        mm_util >= config.mm_util_reject_opens,
        "mm_util should be >= reject threshold"
    );
    assert!(
        mm_util < config.mm_util_reduceonly,
        "mm_util should be < reduceonly threshold"
    );

    // Gate evaluation
    let gate_result = evaluate_margin_gate_for_open(&snapshot, &config);
    assert_eq!(
        gate_result,
        MarginGateResult::RejectOpens,
        "OPEN must be rejected with MarginHeadroomRejectOpens reason"
    );

    // Mode recommendation should still be Active (gate rejection is independent)
    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(
        mode,
        MarginModeRecommendation::Active,
        "TradingMode should remain Active (gate rejection independent of mode)"
    );
}

#[test]
fn test_at_228_reduceonly_at_90pct_utilization() {
    // AT-228: equity=100k, maintenance_margin=90k → TradingMode=ReduceOnly
    let snapshot = MarginSnapshot {
        maintenance_margin: 90_000.0,
        equity: 100_000.0,
    };
    let config = MarginConfig::default();

    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(
        mode,
        MarginModeRecommendation::ReduceOnly,
        "TradingMode must be ReduceOnly at 90% utilization"
    );
}

#[test]
fn test_at_206_gate_independent_of_trading_mode() {
    // AT-206: mm_util >= mm_util_reject_opens but < mm_util_reduceonly
    // Gate rejects OPEN; CLOSE/HEDGE/CANCEL remain allowed
    // TradingMode may still be Active (gate rejection is independent)
    let snapshot = MarginSnapshot {
        maintenance_margin: 75_000.0, // 75% - between reject (70%) and reduceonly (85%)
        equity: 100_000.0,
    };
    let config = MarginConfig::default();

    // Verify threshold position
    let mm_util = snapshot.mm_util();
    assert!(mm_util >= config.mm_util_reject_opens);
    assert!(mm_util < config.mm_util_reduceonly);

    // Gate rejects OPEN
    let gate_result = evaluate_margin_gate_for_open(&snapshot, &config);
    assert_eq!(gate_result, MarginGateResult::RejectOpens);

    // But TradingMode remains Active (gate is independent)
    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(mode, MarginModeRecommendation::Active);
}

#[test]
fn test_at_207_reduceonly_blocks_opens_allows_closes() {
    // AT-207: mm_util >= mm_util_reduceonly but < mm_util_kill
    // → TradingMode=ReduceOnly; OPEN blocked; CLOSE/HEDGE/CANCEL allowed
    let snapshot = MarginSnapshot {
        maintenance_margin: 87_000.0, // 87% - between reduceonly (85%) and kill (95%)
        equity: 100_000.0,
    };
    let config = MarginConfig::default();

    // Verify threshold position
    let mm_util = snapshot.mm_util();
    assert!(mm_util >= config.mm_util_reduceonly);
    assert!(mm_util < config.mm_util_kill);

    // Mode is ReduceOnly
    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(
        mode,
        MarginModeRecommendation::ReduceOnly,
        "TradingMode must be ReduceOnly"
    );

    // Gate also rejects (redundant with mode, but gate is independent)
    let gate_result = evaluate_margin_gate_for_open(&snapshot, &config);
    assert_eq!(gate_result, MarginGateResult::RejectOpens);
}

#[test]
fn test_at_208_kill_mode_at_95pct() {
    // AT-208: mm_util >= mm_util_kill → TradingMode=Kill + emergency flatten
    let snapshot = MarginSnapshot {
        maintenance_margin: 96_000.0, // 96% - above kill threshold (95%)
        equity: 100_000.0,
    };
    let config = MarginConfig::default();

    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(
        mode,
        MarginModeRecommendation::Kill,
        "TradingMode must be Kill at 96% utilization"
    );
}

#[test]
fn test_open_allowed_below_reject_threshold() {
    // Below 70% threshold - OPEN allowed
    let snapshot = MarginSnapshot {
        maintenance_margin: 60_000.0,
        equity: 100_000.0,
    };
    let config = MarginConfig::default();

    let result = evaluate_margin_gate_for_open(&snapshot, &config);
    assert_eq!(result, MarginGateResult::Allow);

    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(mode, MarginModeRecommendation::Active);
}

#[test]
fn test_exact_threshold_boundaries() {
    let config = MarginConfig::default();

    // Exact 70% - should reject
    let snapshot_70 = MarginSnapshot {
        maintenance_margin: 70_000.0,
        equity: 100_000.0,
    };
    assert_eq!(
        evaluate_margin_gate_for_open(&snapshot_70, &config),
        MarginGateResult::RejectOpens
    );
    assert_eq!(
        compute_margin_mode_recommendation(&snapshot_70, &config),
        MarginModeRecommendation::Active
    );

    // Exact 85% - should be ReduceOnly
    let snapshot_85 = MarginSnapshot {
        maintenance_margin: 85_000.0,
        equity: 100_000.0,
    };
    assert_eq!(
        evaluate_margin_gate_for_open(&snapshot_85, &config),
        MarginGateResult::RejectOpens
    );
    assert_eq!(
        compute_margin_mode_recommendation(&snapshot_85, &config),
        MarginModeRecommendation::ReduceOnly
    );

    // Exact 95% - should be Kill
    let snapshot_95 = MarginSnapshot {
        maintenance_margin: 95_000.0,
        equity: 100_000.0,
    };
    assert_eq!(
        evaluate_margin_gate_for_open(&snapshot_95, &config),
        MarginGateResult::RejectOpens
    );
    assert_eq!(
        compute_margin_mode_recommendation(&snapshot_95, &config),
        MarginModeRecommendation::Kill
    );
}

#[test]
fn test_zero_equity_uses_epsilon() {
    // Edge case: zero equity should use epsilon to avoid division by zero
    let snapshot = MarginSnapshot {
        maintenance_margin: 100.0,
        equity: 0.0,
    };
    let config = MarginConfig::default();

    // Should not panic, should use epsilon
    let mm_util = snapshot.mm_util();
    assert!(mm_util > 0.0);
    assert!(mm_util.is_finite());

    // Very high utilization - should trigger Kill
    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(mode, MarginModeRecommendation::Kill);
}

#[test]
fn test_negative_equity_scenario() {
    // Edge case: negative equity (liquidation scenario)
    // Should be treated as very small positive via max(equity, epsilon)
    let snapshot = MarginSnapshot {
        maintenance_margin: 50_000.0,
        equity: -10_000.0,
    };
    let config = MarginConfig::default();

    let mm_util = snapshot.mm_util();
    assert!(mm_util > 0.0);
    assert!(mm_util.is_finite());

    // Should trigger Kill mode
    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(mode, MarginModeRecommendation::Kill);
}

#[test]
fn test_custom_config_thresholds() {
    // Test with custom (more conservative) thresholds
    let config = MarginConfig {
        mm_util_reject_opens: 0.60,
        mm_util_reduceonly: 0.75,
        mm_util_kill: 0.90,
    };

    let snapshot = MarginSnapshot {
        maintenance_margin: 65_000.0, // 65%
        equity: 100_000.0,
    };

    // Should reject with custom threshold (60%)
    let gate_result = evaluate_margin_gate_for_open(&snapshot, &config);
    assert_eq!(gate_result, MarginGateResult::RejectOpens);

    // Should still be Active (below 75%)
    let mode = compute_margin_mode_recommendation(&snapshot, &config);
    assert_eq!(mode, MarginModeRecommendation::Active);
}
