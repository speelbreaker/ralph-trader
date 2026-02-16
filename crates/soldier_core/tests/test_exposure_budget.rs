//! Acceptance Tests for Global Exposure Budget (§1.4.2.2)
//!
//! Tests correlation-aware portfolio exposure limits to prevent "safe per-instrument"
//! trades from stacking into unsafe portfolio exposure.

use soldier_core::risk::{
    GlobalBudgetConfig, GlobalBudgetResult, GlobalExposureBudget, InstrumentExposure,
};
use std::collections::HashMap;

/// AT-226: BTC+ETH correlation breach
///
/// GIVEN: BTC and ETH are both near limits
/// WHEN: a new BTC trade passes the local delta gate
/// THEN: the trade is rejected if the portfolio budget would breach after correlation adjustment
#[test]
fn test_at_226_btc_eth_correlation_breach() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    // BTC near limit: 7000 USD
    // ETH near limit: 5000 USD
    // Correlation BTC-ETH = 0.8
    // Portfolio delta ≈ sqrt(7000^2 + 5000^2 + 2*0.8*7000*5000) ≈ sqrt(105,000,000) ≈ 10247
    let mut exposures = HashMap::new();
    exposures.insert(
        "BTC-PERP".to_string(),
        InstrumentExposure { delta_usd: 7000.0 },
    );
    exposures.insert(
        "ETH-PERP".to_string(),
        InstrumentExposure { delta_usd: 5000.0 },
    );

    // Try to add 500 USD to BTC → should breach
    let result = budget.evaluate(&exposures, "BTC-PERP", 500.0);

    match result {
        GlobalBudgetResult::GlobalExposureBudgetExceeded {
            portfolio_delta_after,
            limit,
        } => {
            assert!(portfolio_delta_after > limit, "Expected breach");
            assert_eq!(limit, 10000.0);
        }
        GlobalBudgetResult::Pass => {
            panic!("Expected GlobalExposureBudgetExceeded, got Pass");
        }
    }
}

/// AT-911: Portfolio breach rejection with specific reason code
///
/// GIVEN: portfolio exposure would breach after correlation adjustment
/// WHEN: Global Exposure Budget evaluates an OPEN intent
/// THEN: the intent is rejected with `Rejected(GlobalExposureBudgetExceeded)` and no dispatch occurs
#[test]
fn test_at_911_portfolio_breach_rejection() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    // Current portfolio: BTC 8000, ETH 4000
    let mut exposures = HashMap::new();
    exposures.insert(
        "BTC-PERP".to_string(),
        InstrumentExposure { delta_usd: 8000.0 },
    );
    exposures.insert(
        "ETH-PERP".to_string(),
        InstrumentExposure { delta_usd: 4000.0 },
    );

    // Try to add 2000 USD to BTC → should breach
    let result = budget.evaluate(&exposures, "BTC-PERP", 2000.0);

    // Verify rejection with specific reason code
    match result {
        GlobalBudgetResult::GlobalExposureBudgetExceeded {
            portfolio_delta_after,
            limit,
        } => {
            assert!(portfolio_delta_after > limit);
            assert_eq!(limit, 10000.0);
            // In real integration: verify dispatch count remains 0
        }
        GlobalBudgetResult::Pass => {
            panic!("Expected GlobalExposureBudgetExceeded for portfolio breach");
        }
    }
}

/// AT-929: Current + pending exposure check
///
/// GIVEN: `pending_delta` is already reserved near the limit and `current_delta` is within limits
/// WHEN: Global Exposure Budget evaluates a new OPEN intent
/// THEN: the intent is rejected if `current + pending` would breach the portfolio budget
#[test]
fn test_at_929_current_plus_pending_exposure() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    // Current + pending exposure (combined per §1.4.2.1)
    // BTC: current=5000, pending=3000 → total=8000
    // ETH: current=1000, pending=1000 → total=2000
    let mut exposures = HashMap::new();
    exposures.insert(
        "BTC-PERP".to_string(),
        InstrumentExposure {
            delta_usd: 8000.0, // current + pending
        },
    );
    exposures.insert(
        "ETH-PERP".to_string(),
        InstrumentExposure {
            delta_usd: 2000.0, // current + pending
        },
    );

    // Portfolio is near limit due to pending reservations
    // Try to add 1500 USD to BTC → should breach
    let result = budget.evaluate(&exposures, "BTC-PERP", 1500.0);

    match result {
        GlobalBudgetResult::GlobalExposureBudgetExceeded { .. } => {
            // Expected: rejected based on combined exposure
        }
        GlobalBudgetResult::Pass => {
            panic!("Expected rejection based on current+pending exposure");
        }
    }
}

/// Test: BTC alone within limit
#[test]
fn test_btc_alone_within_limit() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    let exposures = HashMap::new();
    let result = budget.evaluate(&exposures, "BTC-PERP", 9000.0);

    assert_eq!(result, GlobalBudgetResult::Pass);
}

/// Test: BTC alone exceeds limit
#[test]
fn test_btc_alone_exceeds_limit() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    let exposures = HashMap::new();
    let result = budget.evaluate(&exposures, "BTC-PERP", 11000.0);

    assert!(matches!(
        result,
        GlobalBudgetResult::GlobalExposureBudgetExceeded { .. }
    ));
}

/// Test: BTC+ETH pass with low correlation impact
#[test]
fn test_btc_eth_pass_with_low_impact() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    // Small exposures, well under limit
    let mut exposures = HashMap::new();
    exposures.insert(
        "BTC-PERP".to_string(),
        InstrumentExposure { delta_usd: 3000.0 },
    );
    exposures.insert(
        "ETH-PERP".to_string(),
        InstrumentExposure { delta_usd: 2000.0 },
    );

    let result = budget.evaluate(&exposures, "BTC-PERP", 1000.0);

    assert_eq!(result, GlobalBudgetResult::Pass);
}

/// Test: Three-instrument portfolio (BTC+ETH+alts)
#[test]
fn test_three_instrument_portfolio() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    // BTC=7000, ETH=5000, SOL=3000
    // Correlations: BTC-ETH=0.8, BTC-SOL=0.6, ETH-SOL=0.6
    // Portfolio should be near or over limit
    let mut exposures = HashMap::new();
    exposures.insert(
        "BTC-PERP".to_string(),
        InstrumentExposure { delta_usd: 7000.0 },
    );
    exposures.insert(
        "ETH-PERP".to_string(),
        InstrumentExposure { delta_usd: 5000.0 },
    );
    exposures.insert(
        "SOL-PERP".to_string(),
        InstrumentExposure { delta_usd: 3000.0 },
    );

    // Adding 1000 to BTC should breach
    let result = budget.evaluate(&exposures, "BTC-PERP", 1000.0);

    match result {
        GlobalBudgetResult::GlobalExposureBudgetExceeded {
            portfolio_delta_after,
            limit,
        } => {
            assert!(portfolio_delta_after > limit);
        }
        GlobalBudgetResult::Pass => {
            panic!("Expected breach with three-instrument portfolio");
        }
    }
}

/// Test: Empty portfolio allows first trade
#[test]
fn test_empty_portfolio_allows_first_trade() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    let exposures = HashMap::new();
    let result = budget.evaluate(&exposures, "BTC-PERP", 5000.0);

    assert_eq!(result, GlobalBudgetResult::Pass);
}

/// Test: Negative delta (short exposure) handled correctly
#[test]
fn test_negative_delta_short_exposure() {
    let config = GlobalBudgetConfig {
        portfolio_delta_limit_usd: 10000.0,
    };
    let budget = GlobalExposureBudget::new(config);

    // Short BTC position
    let mut exposures = HashMap::new();
    exposures.insert(
        "BTC-PERP".to_string(),
        InstrumentExposure { delta_usd: -8000.0 },
    );

    // Try to add more short exposure → should breach
    let result = budget.evaluate(&exposures, "BTC-PERP", -3000.0);

    match result {
        GlobalBudgetResult::GlobalExposureBudgetExceeded { .. } => {
            // Expected: absolute exposure matters
        }
        GlobalBudgetResult::Pass => {
            panic!("Expected breach for large short exposure");
        }
    }
}
