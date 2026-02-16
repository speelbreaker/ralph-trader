/// Margin Headroom Gate (§1.4.3) - Liquidation Shield
///
/// Prevents margin liquidation by rejecting opens and forcing ReduceOnly/Kill modes
/// based on maintenance margin utilization thresholds.
use std::fmt;

const EPSILON: f64 = 1e-9;

/// Margin headroom configuration thresholds
#[derive(Debug, Clone, Copy)]
pub struct MarginConfig {
    /// Reject new opens at this mm_util threshold (default 0.70)
    pub mm_util_reject_opens: f64,
    /// Force ReduceOnly mode at this threshold (default 0.85)
    pub mm_util_reduceonly: f64,
    /// Force Kill mode at this threshold (default 0.95)
    pub mm_util_kill: f64,
}

impl Default for MarginConfig {
    fn default() -> Self {
        Self {
            mm_util_reject_opens: 0.70,
            mm_util_reduceonly: 0.85,
            mm_util_kill: 0.95,
        }
    }
}

/// Account margin snapshot from /private/get_account_summary
#[derive(Debug, Clone, Copy)]
pub struct MarginSnapshot {
    pub maintenance_margin: f64,
    pub equity: f64,
}

impl MarginSnapshot {
    /// Compute mm_util = maintenance_margin / max(equity, epsilon)
    pub fn mm_util(&self) -> f64 {
        self.maintenance_margin / self.equity.max(EPSILON)
    }
}

/// Result of margin headroom gate evaluation
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarginGateResult {
    /// OPEN allowed - below reject threshold
    Allow,
    /// OPEN rejected - mm_util >= mm_util_reject_opens
    RejectOpens,
}

/// Trading mode recommendation from margin gate
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarginModeRecommendation {
    /// No restriction from margin gate
    Active,
    /// Force ReduceOnly - mm_util >= mm_util_reduceonly
    ReduceOnly,
    /// Force Kill - mm_util >= mm_util_kill
    Kill,
}

impl fmt::Display for MarginModeRecommendation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MarginModeRecommendation::Active => write!(f, "Active"),
            MarginModeRecommendation::ReduceOnly => write!(f, "ReduceOnly"),
            MarginModeRecommendation::Kill => write!(f, "Kill"),
        }
    }
}

/// Evaluate margin gate for OPEN intent
///
/// Returns RejectOpens if mm_util >= mm_util_reject_opens
pub fn evaluate_margin_gate_for_open(
    snapshot: &MarginSnapshot,
    config: &MarginConfig,
) -> MarginGateResult {
    let mm_util = snapshot.mm_util();
    if mm_util >= config.mm_util_reject_opens {
        MarginGateResult::RejectOpens
    } else {
        MarginGateResult::Allow
    }
}

/// Compute TradingMode recommendation from margin utilization
///
/// PolicyGuard MUST force the returned mode per §1.4.3
pub fn compute_margin_mode_recommendation(
    snapshot: &MarginSnapshot,
    config: &MarginConfig,
) -> MarginModeRecommendation {
    let mm_util = snapshot.mm_util();

    if mm_util >= config.mm_util_kill {
        MarginModeRecommendation::Kill
    } else if mm_util >= config.mm_util_reduceonly {
        MarginModeRecommendation::ReduceOnly
    } else {
        MarginModeRecommendation::Active
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mm_util_computation() {
        let snapshot = MarginSnapshot {
            maintenance_margin: 72_000.0,
            equity: 100_000.0,
        };
        assert_eq!(snapshot.mm_util(), 0.72);
    }

    #[test]
    fn test_mm_util_with_zero_equity_uses_epsilon() {
        let snapshot = MarginSnapshot {
            maintenance_margin: 100.0,
            equity: 0.0,
        };
        // Should use epsilon instead of zero to avoid division by zero
        let mm_util = snapshot.mm_util();
        assert!(mm_util > 0.0);
        assert!(mm_util.is_finite());
    }

    #[test]
    fn test_default_config_thresholds() {
        let config = MarginConfig::default();
        assert_eq!(config.mm_util_reject_opens, 0.70);
        assert_eq!(config.mm_util_reduceonly, 0.85);
        assert_eq!(config.mm_util_kill, 0.95);
    }
}
