use super::group::{
    AtomicGroup, GroupFailure, GroupState, GroupTransitionError, LegOutcome, LegState,
};

pub struct AtomicGroupExecutor {
    epsilon: f64,
}

impl AtomicGroupExecutor {
    pub fn new(epsilon: f64) -> Self {
        Self {
            epsilon: epsilon.abs(),
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
            return group.transition_to(GroupState::MixedFailed);
        }

        if !legs.iter().all(LegOutcome::is_terminal) {
            return Ok(());
        }

        if is_safe_complete(legs, self.epsilon) {
            return group.transition_to(GroupState::Complete);
        }

        Ok(())
    }

    pub fn start_containment(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> {
        group.transition_to(GroupState::Flattening)
    }

    pub fn mark_flattened(&self, group: &mut AtomicGroup) -> Result<(), GroupTransitionError> {
        group.transition_to(GroupState::Flattened)
    }

    pub fn open_allowed(&self, group: &AtomicGroup) -> bool {
        group.state().allows_open()
    }
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
