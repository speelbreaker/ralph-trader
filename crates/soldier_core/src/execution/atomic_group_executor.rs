use super::group::{
    AtomicGroup, GroupFailure, GroupState, GroupTransitionError, LegOutcome, LegState,
};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAX_RESCUE_ATTEMPTS: u8 = 2;
const RESCUE_ATTEMPTS_TTL: Duration = Duration::from_secs(3600); // 1 hour eviction

#[derive(Debug, Clone)]
struct RescueAttemptEntry {
    count: u8,
    last_updated: Instant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RescueAction {
    Retry,
    Flatten,
    Noop,
}

pub struct AtomicGroupExecutor {
    epsilon: f64,
    rescue_attempts: Mutex<HashMap<String, RescueAttemptEntry>>,
}

impl AtomicGroupExecutor {
    pub fn new(epsilon: f64) -> Self {
        assert!(epsilon > 0.0, "epsilon must be positive, got {}", epsilon);
        Self {
            epsilon,
            rescue_attempts: Mutex::new(HashMap::new()),
        }
    }

    pub fn on_intent_persisted(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> {
        group.transition_to(GroupState::Dispatched)
    }

    pub fn evaluate(
        &self,
        group: &mut AtomicGroup,
        legs: &[LegOutcome],
    ) -> Result<(), GroupTransitionError> {
        match group.state() {
            GroupState::New => return Ok(()),
            GroupState::Complete | GroupState::Flattened => return Ok(()),
            GroupState::MixedFailed | GroupState::Flattening => return Ok(()),
            GroupState::Dispatched => {}
        }

        if let Some(failure) = detect_failure(legs, self.epsilon) {
            group.seed_first_failure(failure);
            group.transition_to(GroupState::MixedFailed)?;
            self.clear_rescue_attempts(group);
            return Ok(());
        }

        if !legs.iter().all(LegOutcome::is_terminal) {
            return Ok(());
        }

        if is_safe_complete(legs, self.epsilon) {
            group.transition_to(GroupState::Complete)?;
            self.clear_rescue_attempts(group);
            return Ok(());
        }

        Ok(())
    }

    pub fn start_containment(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> {
        group.transition_to(GroupState::Flattening)
    }

    pub fn mark_flattened(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> {
        group.transition_to(GroupState::Flattened)?;
        self.clear_rescue_attempts(group);
        Ok(())
    }

    pub fn open_allowed(&self, group: &AtomicGroup) -> bool {
        group.state().allows_open()
    }

    pub fn rescue_attempts(&self, group: &AtomicGroup) -> u8 {
        self.lookup_rescue_attempts(group)
    }

    pub fn record_rescue_failure(
        &self,
        group: &mut AtomicGroup,
    ) -> Result<RescueAction, GroupTransitionError> {
        if group.state() != GroupState::MixedFailed {
            return Ok(RescueAction::Noop);
        }

        let attempt = self.bump_rescue_attempts(group);
        record_rescue_attempt_metric(attempt);

        if attempt >= MAX_RESCUE_ATTEMPTS {
            self.start_containment(group)?;
            return Ok(RescueAction::Flatten);
        }

        Ok(RescueAction::Retry)
    }

    fn lookup_rescue_attempts(&self, group: &AtomicGroup) -> u8 {
        let map = match self.rescue_attempts.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("rescue_attempts lock poisoned: {e}"),
        };
        map.get(group.group_id()).map(|e| e.count).unwrap_or(0)
    }

    fn bump_rescue_attempts(&self, group: &AtomicGroup) -> u8 {
        let mut map = match self.rescue_attempts.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("rescue_attempts lock poisoned: {e}"),
        };

        // Evict stale entries (TTL-based cleanup)
        let now = Instant::now();
        map.retain(|_k, entry| now.duration_since(entry.last_updated) <= RESCUE_ATTEMPTS_TTL);

        let entry = map
            .entry(group.group_id().to_string())
            .or_insert(RescueAttemptEntry {
                count: 0,
                last_updated: now,
            });
        if entry.count < MAX_RESCUE_ATTEMPTS {
            entry.count += 1;
        }
        entry.last_updated = now;
        entry.count
    }

    fn clear_rescue_attempts(&self, group: &AtomicGroup) {
        let mut map = match self.rescue_attempts.lock() {
            Ok(guard) => guard,
            Err(e) => panic!("rescue_attempts lock poisoned: {e}"),
        };
        map.remove(group.group_id());
    }
}

fn record_rescue_attempt_metric(attempt: u8) {
    let tail = format!("value={attempt}");
    super::emit_execution_metric_line("atomic_rescue_attempts", &tail);
}

fn detect_failure(legs: &[LegOutcome], epsilon: f64) -> Option<GroupFailure> {
    for leg in legs {
        match leg.state {
            LegState::Rejected => return Some(GroupFailure::Rejected),
            LegState::Canceled => return Some(GroupFailure::Canceled),
            LegState::Unfilled => return Some(GroupFailure::Unfilled),
            LegState::Pending | LegState::Filled => {}
        }
        if leg.is_partial() {
            return Some(GroupFailure::PartialFill);
        }
    }

    if fill_mismatch(legs, epsilon) {
        return Some(GroupFailure::FillMismatch);
    }

    None
}

fn is_safe_complete(legs: &[LegOutcome], epsilon: f64) -> bool {
    if legs.is_empty() {
        return false;
    }

    if legs.iter().any(LegOutcome::is_partial) {
        return false;
    }

    !fill_mismatch(legs, epsilon)
}

fn fill_mismatch(legs: &[LegOutcome], epsilon: f64) -> bool {
    if legs.is_empty() {
        return false;
    }

    let mut min_fill = f64::INFINITY;
    let mut max_fill = f64::NEG_INFINITY;
    for leg in legs {
        min_fill = min_fill.min(leg.filled_qty);
        max_fill = max_fill.max(leg.filled_qty);
    }

    max_fill - min_fill > epsilon
}
