//! Global Exposure Budget (Cross-Instrument, Correlation-Aware)
//!
//! Implements §1.4.2.2 from CONTRACT.md.
//!
//! Prevents "safe per-instrument" trades from stacking into unsafe portfolio exposure
//! by using correlation-aware aggregation across instruments.
//!
//! # Model
//! - Track exposures per instrument: `delta_usd` (required), `vega_usd` (optional), `gamma_usd` (optional)
//! - Portfolio aggregation uses conservative correlation buckets:
//!   - `corr(BTC,ETH)=0.8`, `corr(BTC,alts)=0.6`, `corr(ETH,alts)=0.6`
//! - Gate new opens if portfolio exposure breaches limits even if single-instrument gates pass
//! - Rejections for portfolio breach MUST use `Rejected(GlobalExposureBudgetExceeded)`
//!
//! # Integration Rule
//! The Global Budget must be checked using **current + pending** exposure (see §1.4.2.1).

use std::collections::HashMap;

/// Instrument exposure in USD
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InstrumentExposure {
    pub delta_usd: f64,
}

/// Portfolio-level exposure budget configuration
#[derive(Debug, Clone)]
pub struct GlobalBudgetConfig {
    /// Maximum portfolio delta exposure in USD
    pub portfolio_delta_limit_usd: f64,
}

/// Result of global budget evaluation
#[derive(Debug, Clone, PartialEq)]
pub enum GlobalBudgetResult {
    /// Budget check passed
    Pass,
    /// Portfolio budget would be exceeded
    GlobalExposureBudgetExceeded {
        portfolio_delta_after: f64,
        limit: f64,
    },
}

/// Correlation bucket for an instrument
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum CorrelationBucket {
    Btc,
    Eth,
    Alts,
}

impl CorrelationBucket {
    /// Classify instrument into correlation bucket based on symbol
    ///
    /// Matches "BTC-*" or "ETH-*" precisely at the start of the instrument ID
    fn classify(instrument_id: &str) -> Self {
        let upper = instrument_id.to_uppercase();
        // Match "BTC-" or "BTC_" at start, or standalone "BTC"
        if upper.starts_with("BTC-") || upper.starts_with("BTC_") || upper == "BTC" {
            CorrelationBucket::Btc
        } else if upper.starts_with("ETH-") || upper.starts_with("ETH_") || upper == "ETH" {
            CorrelationBucket::Eth
        } else {
            CorrelationBucket::Alts
        }
    }

    /// Get correlation coefficient between two buckets
    fn correlation(a: CorrelationBucket, b: CorrelationBucket) -> f64 {
        use CorrelationBucket::*;
        match (a, b) {
            (Btc, Btc) | (Eth, Eth) | (Alts, Alts) => 1.0,
            (Btc, Eth) | (Eth, Btc) => 0.8,
            (Btc, Alts) | (Alts, Btc) => 0.6,
            (Eth, Alts) | (Alts, Eth) => 0.6,
        }
    }
}

/// Global exposure budget evaluator
pub struct GlobalExposureBudget {
    config: GlobalBudgetConfig,
}

impl GlobalExposureBudget {
    /// Create a new global budget evaluator
    pub fn new(config: GlobalBudgetConfig) -> Self {
        Self { config }
    }

    /// Evaluate if a new trade would breach the portfolio budget
    ///
    /// # Arguments
    /// * `current_exposures` - Current + pending exposure per instrument (combined per §1.4.2.1)
    /// * `new_instrument` - Instrument for the new trade
    /// * `new_delta_usd` - Additional delta USD from the new trade
    ///
    /// # Returns
    /// * `GlobalBudgetResult::Pass` if portfolio budget OK
    /// * `GlobalBudgetResult::GlobalExposureBudgetExceeded` if portfolio would breach
    pub fn evaluate(
        &self,
        current_exposures: &HashMap<String, InstrumentExposure>,
        new_instrument: &str,
        new_delta_usd: f64,
    ) -> GlobalBudgetResult {
        // Build portfolio exposure after adding new trade
        let mut exposures_after = current_exposures.clone();
        exposures_after
            .entry(new_instrument.to_string())
            .and_modify(|e| e.delta_usd += new_delta_usd)
            .or_insert(InstrumentExposure {
                delta_usd: new_delta_usd,
            });

        // Compute correlation-aware portfolio delta
        let portfolio_delta = self.compute_portfolio_delta(&exposures_after);

        // Check against limit
        if portfolio_delta.abs() > self.config.portfolio_delta_limit_usd {
            GlobalBudgetResult::GlobalExposureBudgetExceeded {
                portfolio_delta_after: portfolio_delta,
                limit: self.config.portfolio_delta_limit_usd,
            }
        } else {
            GlobalBudgetResult::Pass
        }
    }

    /// Compute correlation-aware portfolio delta from per-instrument exposures
    ///
    /// Uses correlation buckets:
    /// - corr(BTC, BTC) = 1.0
    /// - corr(BTC, ETH) = 0.8
    /// - corr(BTC, alts) = 0.6
    /// - corr(ETH, alts) = 0.6
    ///
    /// Portfolio variance = sum_i sum_j corr(i,j) * delta_i * delta_j
    /// Portfolio delta = sqrt(variance) with sign preserved from net delta
    fn compute_portfolio_delta(&self, exposures: &HashMap<String, InstrumentExposure>) -> f64 {
        if exposures.is_empty() {
            return 0.0;
        }

        // Group exposures by correlation bucket
        let mut bucket_deltas: HashMap<CorrelationBucket, f64> = HashMap::new();
        for (instrument_id, exposure) in exposures {
            let bucket = CorrelationBucket::classify(instrument_id);
            *bucket_deltas.entry(bucket).or_insert(0.0) += exposure.delta_usd;
        }

        // Compute portfolio variance using correlation matrix
        // Use signed deltas so opposite positions (hedge) reduce variance
        let mut variance = 0.0;
        for (&bucket_i, &delta_i) in &bucket_deltas {
            for (&bucket_j, &delta_j) in &bucket_deltas {
                let corr = CorrelationBucket::correlation(bucket_i, bucket_j);
                variance += corr * delta_i * delta_j;
            }
        }

        // Portfolio delta is sqrt of variance, with sign from net delta
        let net_delta: f64 = bucket_deltas.values().sum();

        // Defensive: variance can be negative with offsetting positions in signed-delta model
        // Take absolute value before sqrt to avoid NaN
        let variance_abs = variance.abs();
        let portfolio_delta = variance_abs.sqrt();

        // Check for NaN (safety net for floating-point edge cases)
        // Fail-closed: return INFINITY to force rejection
        if portfolio_delta.is_nan() {
            eprintln!(
                "exposure_budget: NaN portfolio_delta detected (variance={}), returning INFINITY (fail-closed)",
                variance
            );
            return f64::INFINITY;
        }

        // Preserve sign
        if net_delta < 0.0 {
            -portfolio_delta
        } else {
            portfolio_delta
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_correlation_bucket_classification() {
        assert_eq!(
            CorrelationBucket::classify("BTC-PERP"),
            CorrelationBucket::Btc
        );
        assert_eq!(
            CorrelationBucket::classify("BTC-25JAN25"),
            CorrelationBucket::Btc
        );
        assert_eq!(
            CorrelationBucket::classify("ETH-PERP"),
            CorrelationBucket::Eth
        );
        assert_eq!(
            CorrelationBucket::classify("ETH-25JAN25"),
            CorrelationBucket::Eth
        );
        assert_eq!(
            CorrelationBucket::classify("SOL-PERP"),
            CorrelationBucket::Alts
        );
        assert_eq!(
            CorrelationBucket::classify("DOGE-PERP"),
            CorrelationBucket::Alts
        );
    }

    #[test]
    fn test_correlation_coefficients() {
        assert_eq!(
            CorrelationBucket::correlation(CorrelationBucket::Btc, CorrelationBucket::Btc),
            1.0
        );
        assert_eq!(
            CorrelationBucket::correlation(CorrelationBucket::Btc, CorrelationBucket::Eth),
            0.8
        );
        assert_eq!(
            CorrelationBucket::correlation(CorrelationBucket::Btc, CorrelationBucket::Alts),
            0.6
        );
        assert_eq!(
            CorrelationBucket::correlation(CorrelationBucket::Eth, CorrelationBucket::Alts),
            0.6
        );
    }

    #[test]
    fn test_single_instrument_within_limit() {
        let config = GlobalBudgetConfig {
            portfolio_delta_limit_usd: 10000.0,
        };
        let budget = GlobalExposureBudget::new(config);

        let exposures = HashMap::new();
        let result = budget.evaluate(&exposures, "BTC-PERP", 5000.0);

        assert_eq!(result, GlobalBudgetResult::Pass);
    }

    #[test]
    fn test_single_instrument_exceeds_limit() {
        let config = GlobalBudgetConfig {
            portfolio_delta_limit_usd: 10000.0,
        };
        let budget = GlobalExposureBudget::new(config);

        let exposures = HashMap::new();
        let result = budget.evaluate(&exposures, "BTC-PERP", 15000.0);

        match result {
            GlobalBudgetResult::GlobalExposureBudgetExceeded {
                portfolio_delta_after,
                limit,
            } => {
                assert!(portfolio_delta_after.abs() > 10000.0);
                assert_eq!(limit, 10000.0);
            }
            _ => panic!("Expected GlobalExposureBudgetExceeded"),
        }
    }

    #[test]
    fn test_offsetting_positions_handle_negative_variance() {
        // REMAINING-5 from failure review: test negative variance handling with offsetting positions
        let config = GlobalBudgetConfig {
            portfolio_delta_limit_usd: 10000.0,
        };
        let budget = GlobalExposureBudget::new(config);

        // Create offsetting positions: large BTC long + large ETH short
        // Cross-correlation terms: 0.8 * 8000 * (-9000) = -57,600,000
        // Self terms: 1.0 * 8000^2 + 1.0 * (-9000)^2 = 64,000,000 + 81,000,000 = 145,000,000
        // Total variance: 145,000,000 - 2*57,600,000 = 145,000,000 - 115,200,000 = 29,800,000
        // sqrt(29,800,000) ≈ 5,459
        let mut exposures = HashMap::new();
        exposures.insert(
            "BTC-PERP".to_string(),
            InstrumentExposure {
                delta_usd: 8000.0, // Long BTC
            },
        );
        exposures.insert(
            "ETH-PERP".to_string(),
            InstrumentExposure {
                delta_usd: -9000.0, // Short ETH (offsetting)
            },
        );

        // Compute portfolio delta - should handle negative variance gracefully
        let portfolio_delta = budget.compute_portfolio_delta(&exposures);

        // Should not be NaN or infinite
        assert!(portfolio_delta.is_finite(), "Portfolio delta should be finite");
        assert!(!portfolio_delta.is_nan(), "Portfolio delta should not be NaN");

        // With offsetting positions, portfolio delta should be less than sum of absolutes
        let sum_of_absolutes = 8000.0 + 9000.0;
        assert!(
            portfolio_delta.abs() < sum_of_absolutes,
            "Offsetting positions should reduce portfolio delta below sum of absolutes"
        );

        // Adding a small position should still pass
        let result = budget.evaluate(&exposures, "SOL-PERP", 1000.0);
        assert_eq!(result, GlobalBudgetResult::Pass);
    }

    #[test]
    fn test_extreme_offsetting_returns_infinity_on_nan() {
        // Edge case: if variance calculation somehow produces NaN, should return INFINITY (fail-closed)
        let config = GlobalBudgetConfig {
            portfolio_delta_limit_usd: 10000.0,
        };
        let budget = GlobalExposureBudget::new(config);

        // Create extreme scenario that might cause numerical issues
        let mut exposures = HashMap::new();
        exposures.insert(
            "BTC-PERP".to_string(),
            InstrumentExposure {
                delta_usd: f64::MAX / 2.0,
            },
        );
        exposures.insert(
            "ETH-PERP".to_string(),
            InstrumentExposure {
                delta_usd: -f64::MAX / 2.0,
            },
        );

        // This might overflow/underflow, but should be handled gracefully
        let portfolio_delta = budget.compute_portfolio_delta(&exposures);

        // Should either be finite or INFINITY (never NaN)
        assert!(
            !portfolio_delta.is_nan(),
            "NaN should be caught and converted to INFINITY"
        );

        // If it's INFINITY, the fail-closed behavior worked
        if portfolio_delta.is_infinite() {
            // Verify that evaluate would reject
            let result = budget.evaluate(&exposures, "SOL-PERP", 100.0);
            match result {
                GlobalBudgetResult::GlobalExposureBudgetExceeded { .. } => {
                    // Expected: INFINITY exceeds any limit
                }
                GlobalBudgetResult::Pass => {
                    panic!("INFINITY portfolio delta should fail budget check")
                }
            }
        }
    }
}
