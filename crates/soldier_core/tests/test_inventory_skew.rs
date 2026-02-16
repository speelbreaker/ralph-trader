/// Integration tests for Inventory Skew Gate (CONTRACT.md §1.4.2)
///
/// Enforces AT-224, AT-043, AT-922, AT-030, AT-934
use soldier_core::risk::{IntentSide, InventorySkewConfig, RiskState, evaluate_inventory_skew};

#[test]
fn test_at224_buy_rejected_near_limit_sell_allowed() {
    // AT-224: Near positive limit, BUY gets harsh edge requirement, SELL gets looser edge
    let config = InventorySkewConfig::default(); // k=0.5
    let min_edge_usd = 1.0;

    // current_delta = 90, limit = 100 => inventory_bias = 0.9
    let current_delta = 90.0;
    let pending_delta = 0.0;
    let delta_limit = Some(100.0);
    let tick_size_usd = 0.5;

    // BUY is risk-increasing (adds to positive delta)
    // directed_bias = inventory_bias * side_sign = 0.9 * 1.0 = 0.9
    // edge_multiplier = 1.0 + 0.5 * 0.9 = 1.45 > threshold (1.4) => REJECTED
    let eval_buy = evaluate_inventory_skew(
        current_delta,
        pending_delta,
        delta_limit,
        IntentSide::Buy,
        min_edge_usd,
        tick_size_usd,
        &config,
    );
    assert!(
        !eval_buy.allowed,
        "BUY should be rejected near positive limit (AT-224)"
    );
    assert_eq!(
        eval_buy.reject_reason,
        Some("InventorySkew".to_string()),
        "BUY rejection reason should indicate excessive edge"
    );

    // SELL is risk-reducing (reduces positive delta)
    // directed_bias = inventory_bias * side_sign = 0.9 * (-1.0) = -0.9
    // adjusted = 1.0 * (1 + 0.5 * (-0.9)) = 0.55 (looser)
    let eval_sell = evaluate_inventory_skew(
        current_delta,
        pending_delta,
        delta_limit,
        IntentSide::Sell,
        min_edge_usd,
        tick_size_usd,
        &config,
    );
    assert!(eval_sell.allowed, "SELL should be allowed (risk-reducing)");
    assert!(
        eval_sell.adjusted_min_edge_usd.unwrap() < min_edge_usd,
        "SELL should get looser edge near positive limit (risk-reducing)"
    );
    let expected_sell_edge = min_edge_usd * (1.0 + config.inventory_skew_k * (-0.9));
    assert!(
        (eval_sell.adjusted_min_edge_usd.unwrap() - expected_sell_edge).abs() < 0.001,
        "SELL edge adjustment should use directed_bias"
    );
}

#[test]
fn test_at224_buy_rejected_when_edge_multiplier_excessive() {
    // AT-224 enforcement: BUY rejected at full inventory limit
    // With k=0.5 and bias=1.0: multiplier = 1 + 0.5*1.0 = 1.5 > threshold (1.4) => REJECT
    let config = InventorySkewConfig::default(); // threshold = 1.4

    // current_delta = 100, limit = 100 => inventory_bias = 1.0
    // BUY: directed_bias = 1.0, multiplier = 1.5 > 1.4 => REJECT
    let eval_buy = evaluate_inventory_skew(
        100.0,
        0.0,
        Some(100.0),
        IntentSide::Buy,
        1.0,
        0.5,
        &config,
    );
    assert!(
        !eval_buy.allowed,
        "BUY should be rejected when edge multiplier > threshold"
    );
    assert_eq!(
        eval_buy.reject_reason,
        Some("InventorySkew".to_string())
    );

    // SELL: directed_bias = -1.0, multiplier = 0.0 < threshold => ALLOWED
    let eval_sell = evaluate_inventory_skew(
        100.0,
        0.0,
        Some(100.0),
        IntentSide::Sell,
        1.0,
        0.5,
        &config,
    );
    assert!(eval_sell.allowed, "SELL should be allowed (risk-reducing)");
}

#[test]
fn test_at043_delta_limit_missing_open_rejected_degraded() {
    // AT-043: delta_limit missing => reject OPEN, RiskState Degraded
    let config = InventorySkewConfig::default();

    let eval = evaluate_inventory_skew(50.0, 0.0, None, IntentSide::Buy, 1.0, 0.5, &config);

    assert!(!eval.allowed, "OPEN intent should be rejected");
    assert_eq!(eval.risk_state, RiskState::Degraded);
}

#[test]
fn test_at922_delta_limit_missing_specific_reject_reason() {
    // AT-922: delta_limit missing => reject with InventorySkewDeltaLimitMissing
    let config = InventorySkewConfig::default();

    let eval = evaluate_inventory_skew(50.0, 0.0, None, IntentSide::Buy, 1.0, 0.5, &config);

    assert!(!eval.allowed);
    assert_eq!(
        eval.reject_reason,
        Some("InventorySkewDeltaLimitMissing".to_string()),
        "Rejection reason must match"
    );
}

#[test]
fn test_at030_three_tick_shift_at_full_bias() {
    // AT-030: inventory_bias=1.0 => 3 tick shift
    // CONTRACT FORMULA: bias_ticks = ceil(abs(inventory_bias) * tick_penalty_max)
    // With default config: ceil(abs(1.0) * 3) = ceil(3.0) = 3
    let config = InventorySkewConfig::default(); // k=0.5, max=3

    // current_delta = 100, limit = 100 => inventory_bias = 1.0
    let current_delta = 100.0;
    let pending_delta = 0.0;
    let delta_limit = Some(100.0);
    let tick_size_usd = 0.5;
    let min_edge_usd = 1.0;

    let eval = evaluate_inventory_skew(
        current_delta,
        pending_delta,
        delta_limit,
        IntentSide::Buy,
        min_edge_usd,
        tick_size_usd,
        &config,
    );

    // inventory_bias = 100/100 = 1.0
    // bias_ticks = ceil(1.0 * 3) = 3
    assert_eq!(
        eval.bias_ticks, 3,
        "Should shift 3 ticks at inventory_bias=1.0"
    );
}

#[test]
fn test_at030_exact_three_tick_penalty_at_inventory_bias_one() {
    // AT-030 verification with explicit inventory_bias = 1.0
    let config = InventorySkewConfig {
        inventory_skew_k: 0.5, // CONTRACT default
        edge_rejection_threshold: 1.4,
        inventory_skew_tick_penalty_max: 3,
    };

    // current_delta = limit => inventory_bias = 1.0
    let current_delta = 100.0;
    let delta_limit = Some(100.0);

    let eval = evaluate_inventory_skew(
        current_delta,
        0.0,
        delta_limit,
        IntentSide::Buy,
        1.0,
        0.5,
        &config,
    );

    // CONTRACT: ceil(abs(1.0) * 3) = 3
    assert_eq!(eval.bias_ticks, 3, "Should calculate 3 tick bias");
}

#[test]
fn test_at934_current_plus_pending_exposure_used() {
    // AT-934: current + pending exposure used for decision
    let config = InventorySkewConfig::default();

    // current_delta = 60, pending_delta = 20, limit = 100
    // total = 80 => inventory_bias = 0.8
    let current_delta = 60.0;
    let pending_delta = 20.0;
    let delta_limit = Some(100.0);

    let eval = evaluate_inventory_skew(
        current_delta,
        pending_delta,
        delta_limit,
        IntentSide::Buy,
        1.0,
        0.5,
        &config,
    );

    // With combined exposure = 80 (bias=0.8), edge_multiplier = 1.4 (at threshold)
    // Should be allowed (not strictly greater than threshold)
    assert!(eval.allowed);
    // bias_ticks = ceil(0.8 * 3) = ceil(2.4) = 3
    assert_eq!(eval.bias_ticks, 3, "Should use current + pending for bias");

    // Verify with specific values where current alone vs current+pending differ
    // current alone: bias = 0.3, ticks = ceil(0.3*3) = ceil(0.9) = 1
    // current+pending: total = 40, bias = 0.4, ticks = ceil(0.4*3) = ceil(1.2) = 2
    let eval2 = evaluate_inventory_skew(
        30.0,  // current: bias = 0.3, ticks = 1
        10.0,  // combined: total = 40, bias = 0.4, ticks = 2
        delta_limit,
        IntentSide::Buy,
        1.0,
        0.5,
        &config,
    );
    assert_eq!(
        eval2.bias_ticks, 2,
        "Should use current+pending: ceil(0.4*3)=2 not ceil(0.3*3)=1"
    );
}

#[test]
fn test_sell_allowed_near_negative_limit() {
    // Test symmetry: SELL when short gets harsh edge, BUY when short gets looser edge
    let config = InventorySkewConfig::default();

    // current_delta = -90, limit = 100 => inventory_bias = -0.9 (short position)
    let current_delta = -90.0;
    let delta_limit = Some(100.0);
    let min_edge_usd = 1.0;

    // SELL is risk-increasing (makes delta more negative)
    // directed_bias = inventory_bias * side_sign = (-0.9) * (-1.0) = +0.9
    // edge_multiplier = 1.0 + 0.5 * 0.9 = 1.45 > threshold (1.4) => REJECTED
    let eval_sell = evaluate_inventory_skew(
        current_delta,
        0.0,
        delta_limit,
        IntentSide::Sell,
        min_edge_usd,
        0.5,
        &config,
    );
    assert!(
        !eval_sell.allowed,
        "SELL when short should be rejected (risk-increasing, excessive edge)"
    );
    assert_eq!(
        eval_sell.reject_reason,
        Some("InventorySkew".to_string())
    );

    // BUY is risk-reducing (reduces negative delta)
    // directed_bias = inventory_bias * side_sign = (-0.9) * (+1.0) = -0.9
    // adjusted = 1.0 * (1 + 0.5 * (-0.9)) = 0.55 (looser)
    let eval_buy = evaluate_inventory_skew(
        current_delta,
        0.0,
        delta_limit,
        IntentSide::Buy,
        min_edge_usd,
        0.5,
        &config,
    );
    assert!(eval_buy.allowed);
    assert!(
        eval_buy.adjusted_min_edge_usd.unwrap() < min_edge_usd,
        "BUY when short should get looser edge (risk-reducing)"
    );
    let expected_buy_edge = min_edge_usd * (1.0 + config.inventory_skew_k * (-0.9));
    assert!(
        (eval_buy.adjusted_min_edge_usd.unwrap() - expected_buy_edge).abs() < 0.001,
        "BUY uses directed_bias = bias * side_sign"
    );
}
#[test]
fn test_bias_ticks_calculation_ceiling() {
    // Verify bias_ticks uses ceiling (not rounding)
    let config = InventorySkewConfig {
        inventory_skew_k: 0.5,
        edge_rejection_threshold: 1.4,
        inventory_skew_tick_penalty_max: 3,
    };

    // inventory_bias = 0.5 => ceil(0.5 * 3) = ceil(1.5) = 2
    let eval = evaluate_inventory_skew(50.0, 0.0, Some(100.0), IntentSide::Buy, 1.0, 0.5, &config);
    assert_eq!(eval.bias_ticks, 2, "ceil(0.5*3) = 2");

    // inventory_bias = 0.4 => ceil(0.4 * 3) = ceil(1.2) = 2
    let eval2 = evaluate_inventory_skew(40.0, 0.0, Some(100.0), IntentSide::Buy, 1.0, 0.5, &config);
    assert_eq!(eval2.bias_ticks, 2, "ceil(0.4*3) = 2");

    // inventory_bias = 0.1 => ceil(0.1 * 3) = ceil(0.3) = 1
    let eval3 = evaluate_inventory_skew(10.0, 0.0, Some(100.0), IntentSide::Buy, 1.0, 0.5, &config);
    assert_eq!(eval3.bias_ticks, 1, "ceil(0.1*3) = 1");
}

#[test]
fn test_zero_pending_delta() {
    // Verify behavior with zero pending delta
    let config = InventorySkewConfig::default();

    let eval = evaluate_inventory_skew(50.0, 0.0, Some(100.0), IntentSide::Buy, 1.0, 0.5, &config);

    assert!(eval.allowed);
    // inventory_bias = 50/100 = 0.5
    // bias_ticks = ceil(0.5 * 3) = ceil(1.5) = 2
    assert_eq!(eval.bias_ticks, 2);
}

#[test]
fn test_adjusted_min_edge_usd_calculation() {
    // Verify adjusted_min_edge_usd is multiplicative
    let config = InventorySkewConfig {
        edge_rejection_threshold: 1.4,
        inventory_skew_k: 0.5,
        inventory_skew_tick_penalty_max: 3,
    };

    let min_edge_usd = 2.0;

    // inventory_bias = 60/100 = 0.6
    // adjusted = 2.0 * (1 + 0.5 * 0.6) = 2.0 * 1.3 = 2.6
    let eval = evaluate_inventory_skew(
        60.0,
        0.0,
        Some(100.0),
        IntentSide::Buy,
        min_edge_usd,
        0.25,
        &config,
    );

    let expected = min_edge_usd * (1.0 + config.inventory_skew_k * 0.6);
    assert!(
        (eval.adjusted_min_edge_usd.unwrap() - expected).abs() < 0.001,
        "Adjusted edge should be multiplicative: {} vs {}",
        eval.adjusted_min_edge_usd.unwrap(),
        expected
    );

    // Also verify bias_ticks = ceil(0.6 * 3) = ceil(1.8) = 2
    assert_eq!(eval.bias_ticks, 2);
}
