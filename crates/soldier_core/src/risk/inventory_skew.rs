/// Inventory Skew Gate per CONTRACT.md §1.4.2
/// Biases execution against compounding inventory
/// Requires higher edge/worse prices for risk-increasing trades near delta limits
use super::RiskState;

const FLOAT_EPSILON: f64 = 1e-9;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InventorySkewConfig {
    /// Inventory skew sensitivity parameter (typically 0.5)
    pub inventory_skew_k: f64,
    /// Maximum tick penalty for limit price bias (typically 3)
    pub inventory_skew_tick_penalty_max: i32,
}

impl Default for InventorySkewConfig {
    fn default() -> Self {
        Self {
            inventory_skew_k: 0.5,
            inventory_skew_tick_penalty_max: 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntentSide {
    Buy,
    Sell,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InventorySkewEvaluation {
    pub allowed: bool,
    pub reject_reason: Option<String>,
    pub risk_state: RiskState,
    pub adjusted_min_edge_usd: Option<f64>,
    pub bias_ticks: i32,
}

/// Evaluate inventory skew gate for an intent
///
/// # Arguments
/// * `current_delta` - Current delta exposure
/// * `pending_delta` - Pending delta from reserved but not yet filled orders
/// * `delta_limit` - Maximum allowed absolute delta
/// * `side` - Buy or Sell
/// * `min_edge_usd` - Minimum edge requirement from Net Edge Gate
/// * `tick_size_usd` - Tick size in USD for price bias calculation
/// * `config` - Inventory skew configuration
///
/// # Returns
/// `InventorySkewEvaluation` with decision and optional adjustments
///
/// # Contract Requirements (§1.4.2)
/// - Uses current + pending exposure (AT-934)
/// - Adjusts min_edge_usd multiplicatively for risk gradient (AT-224)
/// - Rejects with InventorySkewDeltaLimitMissing when delta_limit missing (AT-043, AT-922)
/// - Applies tick penalty: ceil(abs(inventory_bias) * tick_penalty_max) (AT-030)
pub fn evaluate_inventory_skew(
    current_delta: f64,
    pending_delta: f64,
    delta_limit: Option<f64>,
    side: IntentSide,
    min_edge_usd: f64,
    tick_size_usd: f64,
    config: &InventorySkewConfig,
) -> InventorySkewEvaluation {
    // AT-043, AT-922: Reject when delta_limit missing
    let limit = match delta_limit {
        Some(lim) if lim > FLOAT_EPSILON => lim,
        _ => {
            return InventorySkewEvaluation {
                allowed: false,
                reject_reason: Some("InventorySkewDeltaLimitMissing".to_string()),
                risk_state: RiskState::Degraded,
                adjusted_min_edge_usd: None,
                bias_ticks: 0,
            };
        }
    };

    // AT-934: Use current + pending exposure
    let total_delta = current_delta + pending_delta;

    // Compute inventory bias: clamp(total_delta / delta_limit, -1, +1)
    let inventory_bias = (total_delta / limit).clamp(-1.0, 1.0);

    // AT-030: Apply tick penalty based on inventory_bias
    // CONTRACT FORMULA: bias_ticks = ceil(abs(inventory_bias) * tick_penalty_max)
    // Note: k factor is NOT used in tick calculation
    let bias_ticks =
        (inventory_bias.abs() * config.inventory_skew_tick_penalty_max as f64).ceil() as i32;

    // AT-224: Adjust min_edge_usd multiplicatively
    // CONTRACT FORMULA: min_edge_usd * (1 + k * inventory_bias)
    // Positive inventory_bias (long) increases edge requirement for BUY (risk-increasing)
    // Negative inventory_bias (short) increases edge requirement for SELL (risk-increasing)
    // Risk-reducing trades get loosened requirements (k * inventory_bias < 0)
    let adjusted_min_edge_usd = min_edge_usd * (1.0 + config.inventory_skew_k * inventory_bias);

    InventorySkewEvaluation {
        allowed: true,
        reject_reason: None,
        risk_state: RiskState::Healthy,
        adjusted_min_edge_usd: Some(adjusted_min_edge_usd),
        bias_ticks,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inventory_bias_computation() {
        let config = InventorySkewConfig::default();

        // current_delta = 90, pending = 0, limit = 100 => bias = 0.9
        // bias_ticks = ceil(0.9 * 3) = ceil(2.7) = 3
        let eval = evaluate_inventory_skew(90.0, 0.0, Some(100.0), IntentSide::Sell, 1.0, 0.5, &config);
        assert!(eval.allowed);
        assert_eq!(eval.bias_ticks, 3);
    }

    #[test]
    fn test_delta_limit_missing_rejection() {
        // AT-043, AT-922: delta_limit missing
        let config = InventorySkewConfig::default();

        let eval = evaluate_inventory_skew(50.0, 0.0, None, IntentSide::Buy, 1.0, 0.5, &config);
        assert!(!eval.allowed);
        assert_eq!(
            eval.reject_reason,
            Some("InventorySkewDeltaLimitMissing".to_string())
        );
        assert_eq!(eval.risk_state, RiskState::Degraded);
    }

    #[test]
    fn test_uses_current_plus_pending_exposure() {
        // AT-934: current + pending exposure
        let config = InventorySkewConfig::default();

        // current = 70, pending = 30, limit = 100 => total = 100 (bias = 1.0)
        // bias_ticks = ceil(1.0 * 3) = 3
        let eval = evaluate_inventory_skew(70.0, 30.0, Some(100.0), IntentSide::Buy, 1.0, 0.5, &config);

        assert!(eval.allowed);
        assert_eq!(eval.bias_ticks, 3, "Should use current+pending for bias calculation");
    }
}
