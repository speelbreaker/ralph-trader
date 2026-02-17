use std::sync::Mutex;

use crate::risk::RiskState;

/// Position-Aware Execution Sequencer (CONTRACT.md §1.5)
///
/// Enforces close→confirm→hedge ordering to prevent creating new naked risk
/// while repairing, hedging, or closing positions.
///
/// Rules:
/// - Closing: Close → Confirm → Hedge (reduce-only)
/// - Opening: Open → Confirm → Hedge
/// - Repairs: Flatten first (emergency_close_algorithm), hedge only after retries fail
/// - Never increase exposure when RiskState != Healthy
const COUNTER_SEQUENCER_ORDER_VIOLATION: &str = "sequencer_order_violation_total";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntentKind {
    Open,
    Close,
    Repair,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ExecutionStep {
    PlaceClose { leg_id: String },
    ConfirmClose { leg_id: String },
    PlaceHedge { leg_id: String, reduce_only: bool },
    PlaceOpen { leg_id: String },
    ConfirmOpen { leg_id: String },
    FlattenViaEmergencyClose { group_id: String },
}

pub struct Sequencer {
    metrics: Mutex<std::collections::HashMap<String, u64>>,
}

impl Sequencer {
    pub fn new() -> Self {
        Self {
            metrics: Mutex::new(std::collections::HashMap::new()),
        }
    }

    /// Generate ordered execution steps based on intent kind and risk state
    ///
    /// Returns steps in deterministic order:
    /// - Close: [PlaceClose, ConfirmClose, PlaceHedge(reduce_only)]
    /// - Open: [PlaceOpen, ConfirmOpen, PlaceHedge]  (if RiskState::Healthy)
    /// - Repair: [FlattenViaEmergencyClose, PlaceHedge(reduce_only)]
    ///
    /// Invariant: Never increase exposure when RiskState != Healthy
    pub fn generate_steps(
        &self,
        intent_kind: IntentKind,
        risk_state: RiskState,
        leg_ids: &[String],
    ) -> Result<Vec<ExecutionStep>, SequenceError> {
        match intent_kind {
            IntentKind::Close => self.generate_close_steps(leg_ids),
            IntentKind::Open => self.generate_open_steps(risk_state, leg_ids),
            IntentKind::Repair => self.generate_repair_steps(leg_ids),
        }
    }

    fn generate_close_steps(
        &self,
        leg_ids: &[String],
    ) -> Result<Vec<ExecutionStep>, SequenceError> {
        if leg_ids.is_empty() {
            return Err(SequenceError::EmptyLegList);
        }

        let mut steps = Vec::new();

        // 1. Place all close orders first
        for leg_id in leg_ids {
            steps.push(ExecutionStep::PlaceClose {
                leg_id: leg_id.clone(),
            });
        }

        // 2. Confirm each close
        for leg_id in leg_ids {
            steps.push(ExecutionStep::ConfirmClose {
                leg_id: leg_id.clone(),
            });
        }

        // 3. Hedge only after close confirmation (reduce-only)
        if !leg_ids.is_empty() {
            steps.push(ExecutionStep::PlaceHedge {
                leg_id: "hedge_leg".to_string(),
                reduce_only: true,
            });
        }

        Ok(steps)
    }

    fn generate_open_steps(
        &self,
        risk_state: RiskState,
        leg_ids: &[String],
    ) -> Result<Vec<ExecutionStep>, SequenceError> {
        // Never increase exposure when RiskState != Healthy
        if risk_state != RiskState::Healthy {
            self.increment_counter(COUNTER_SEQUENCER_ORDER_VIOLATION);
            return Err(SequenceError::RiskStateNotHealthy { risk_state });
        }

        if leg_ids.is_empty() {
            return Err(SequenceError::EmptyLegList);
        }

        let mut steps = Vec::new();

        // 1. Place all open orders first
        for leg_id in leg_ids {
            steps.push(ExecutionStep::PlaceOpen {
                leg_id: leg_id.clone(),
            });
        }

        // 2. Confirm each open
        for leg_id in leg_ids {
            steps.push(ExecutionStep::ConfirmOpen {
                leg_id: leg_id.clone(),
            });
        }

        // 3. Hedge after confirmation
        if !leg_ids.is_empty() {
            steps.push(ExecutionStep::PlaceHedge {
                leg_id: "hedge_leg".to_string(),
                reduce_only: false,
            });
        }

        Ok(steps)
    }

    fn generate_repair_steps(
        &self,
        leg_ids: &[String],
    ) -> Result<Vec<ExecutionStep>, SequenceError> {
        if leg_ids.is_empty() {
            return Err(SequenceError::EmptyLegList);
        }

        let mut steps = Vec::new();

        // 1. Flatten filled legs first via emergency_close_algorithm
        for leg_id in leg_ids {
            steps.push(ExecutionStep::FlattenViaEmergencyClose {
                group_id: leg_id.clone(),
            });
        }

        // 2. Hedge only after flatten retries fail (reduce-only fallback)
        steps.push(ExecutionStep::PlaceHedge {
            leg_id: "hedge_leg".to_string(),
            reduce_only: true,
        });

        Ok(steps)
    }

    fn increment_counter(&self, name: &str) {
        let mut metrics = match self.metrics.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                eprintln!("sequencer metrics lock poisoned, recovering");
                poisoned.into_inner()
            }
        };
        *metrics.entry(name.to_string()).or_insert(0) += 1;
    }

    pub fn get_counter(&self, name: &str) -> u64 {
        let metrics = match self.metrics.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                eprintln!("sequencer metrics lock poisoned, recovering");
                poisoned.into_inner()
            }
        };
        metrics.get(name).copied().unwrap_or(0)
    }
}

impl Default for Sequencer {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SequenceError {
    EmptyLegList,
    RiskStateNotHealthy { risk_state: RiskState },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_close_steps_ordering() {
        let seq = Sequencer::new();
        let leg_ids = vec!["leg1".to_string(), "leg2".to_string()];

        let steps = seq
            .generate_steps(IntentKind::Close, RiskState::Healthy, &leg_ids)
            .unwrap();

        // Verify close→confirm→hedge ordering
        assert_eq!(steps.len(), 5);
        assert!(matches!(steps[0], ExecutionStep::PlaceClose { .. }));
        assert!(matches!(steps[1], ExecutionStep::PlaceClose { .. }));
        assert!(matches!(steps[2], ExecutionStep::ConfirmClose { .. }));
        assert!(matches!(steps[3], ExecutionStep::ConfirmClose { .. }));
        assert!(matches!(
            steps[4],
            ExecutionStep::PlaceHedge {
                reduce_only: true,
                ..
            }
        ));
    }

    #[test]
    fn test_open_blocked_when_risk_state_degraded() {
        let seq = Sequencer::new();
        let leg_ids = vec!["leg1".to_string()];

        let result = seq.generate_steps(IntentKind::Open, RiskState::Degraded, &leg_ids);

        assert!(matches!(
            result,
            Err(SequenceError::RiskStateNotHealthy {
                risk_state: RiskState::Degraded
            })
        ));
        assert_eq!(seq.get_counter(COUNTER_SEQUENCER_ORDER_VIOLATION), 1);
    }

    #[test]
    fn test_repair_flattens_before_hedge() {
        let seq = Sequencer::new();
        let leg_ids = vec!["group1".to_string()];

        let steps = seq
            .generate_steps(IntentKind::Repair, RiskState::Degraded, &leg_ids)
            .unwrap();

        // Verify flatten→hedge ordering
        assert_eq!(steps.len(), 2);
        assert!(matches!(
            steps[0],
            ExecutionStep::FlattenViaEmergencyClose { .. }
        ));
        assert!(matches!(
            steps[1],
            ExecutionStep::PlaceHedge {
                reduce_only: true,
                ..
            }
        ));
    }
}
