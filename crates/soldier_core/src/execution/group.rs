use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupState {
    New,
    Dispatched,
    Complete,
    MixedFailed,
    Flattening,
    Flattened,
}

impl GroupState {
    #[allow(dead_code)]
    pub fn is_terminal(self) -> bool {
        matches!(self, GroupState::Complete | GroupState::Flattened)
    }

    pub fn allows_open(self) -> bool {
        !matches!(self, GroupState::MixedFailed | GroupState::Flattening)
    }

    #[allow(dead_code)]
    pub fn as_str(self) -> &'static str {
        match self {
            GroupState::New => "New",
            GroupState::Dispatched => "Dispatched",
            GroupState::Complete => "Complete",
            GroupState::MixedFailed => "MixedFailed",
            GroupState::Flattening => "Flattening",
            GroupState::Flattened => "Flattened",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupFailure {
    Rejected,
    Canceled,
    Unfilled,
    PartialFill,
    FillMismatch,
}

impl GroupFailure {
    #[allow(dead_code)]
    pub fn as_str(self) -> &'static str {
        match self {
            GroupFailure::Rejected => "Rejected",
            GroupFailure::Canceled => "Canceled",
            GroupFailure::Unfilled => "Unfilled",
            GroupFailure::PartialFill => "PartialFill",
            GroupFailure::FillMismatch => "FillMismatch",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum LegState {
    Pending,
    Filled,
    Rejected,
    Canceled,
    Unfilled,
}

#[derive(Debug, Clone, Copy)]
pub struct LegOutcome {
    pub requested_qty: f64,
    pub filled_qty: f64,
    pub state: LegState,
}

impl LegOutcome {
    pub fn new(requested_qty: f64, filled_qty: f64, state: LegState) -> Self {
        Self {
            requested_qty,
            filled_qty,
            state,
        }
    }

    #[allow(dead_code)]
    pub fn pending(requested_qty: f64) -> Self {
        Self::new(requested_qty, 0.0, LegState::Pending)
    }

    pub fn filled(requested_qty: f64) -> Self {
        Self::new(requested_qty, requested_qty, LegState::Filled)
    }

    pub fn rejected(requested_qty: f64) -> Self {
        Self::new(requested_qty, 0.0, LegState::Rejected)
    }

    #[allow(dead_code)]
    pub fn canceled(requested_qty: f64) -> Self {
        Self::new(requested_qty, 0.0, LegState::Canceled)
    }

    #[allow(dead_code)]
    pub fn unfilled(requested_qty: f64) -> Self {
        Self::new(requested_qty, 0.0, LegState::Unfilled)
    }

    pub fn is_terminal(&self) -> bool {
        matches!(
            self.state,
            LegState::Filled | LegState::Rejected | LegState::Canceled | LegState::Unfilled
        )
    }

    pub fn is_partial(&self) -> bool {
        self.filled_qty > 0.0 && self.filled_qty < self.requested_qty
    }
}

#[derive(Debug, Clone)]
pub struct GroupTransitionError {
    pub message: String,
}

impl GroupTransitionError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for GroupTransitionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for GroupTransitionError {}

pub struct AtomicGroup {
    group_id: String,
    state: GroupState,
    first_failure: Option<GroupFailure>,
}

impl AtomicGroup {
    pub fn new(group_id: impl Into<String>) -> Self {
        let group = Self {
            group_id: group_id.into(),
            state: GroupState::New,
            first_failure: None,
        };
        record_state(group.state);
        group
    }

    pub fn group_id(&self) -> &str {
        &self.group_id
    }

    pub fn state(&self) -> GroupState {
        self.state
    }

    pub fn first_failure(&self) -> Option<GroupFailure> {
        self.first_failure
    }

    pub fn seed_first_failure(&mut self, failure: GroupFailure) {
        if self.first_failure.is_none() {
            self.first_failure = Some(failure);
        }
    }

    pub fn transition_to(&mut self, next: GroupState) -> Result<(), GroupTransitionError> {
        if self.state == next {
            return Ok(());
        }
        if !transition_allowed(self.state, next) {
            return Err(GroupTransitionError::new(format!(
                "illegal group transition: {:?} -> {:?}",
                self.state, next
            )));
        }
        self.state = next;
        record_state(self.state);
        Ok(())
    }
}

#[allow(dead_code)]
pub fn atomic_group_state_total(state: GroupState) -> u64 {
    ATOMIC_GROUP_METRICS.total(state)
}

struct AtomicGroupMetrics {
    new_total: AtomicU64,
    dispatched_total: AtomicU64,
    complete_total: AtomicU64,
    mixed_failed_total: AtomicU64,
    flattening_total: AtomicU64,
    flattened_total: AtomicU64,
}

impl AtomicGroupMetrics {
    pub const fn new() -> Self {
        Self {
            new_total: AtomicU64::new(0),
            dispatched_total: AtomicU64::new(0),
            complete_total: AtomicU64::new(0),
            mixed_failed_total: AtomicU64::new(0),
            flattening_total: AtomicU64::new(0),
            flattened_total: AtomicU64::new(0),
        }
    }

    #[allow(dead_code)]
    pub fn total(&self, state: GroupState) -> u64 {
        match state {
            GroupState::New => self.new_total.load(Ordering::Relaxed),
            GroupState::Dispatched => self.dispatched_total.load(Ordering::Relaxed),
            GroupState::Complete => self.complete_total.load(Ordering::Relaxed),
            GroupState::MixedFailed => self.mixed_failed_total.load(Ordering::Relaxed),
            GroupState::Flattening => self.flattening_total.load(Ordering::Relaxed),
            GroupState::Flattened => self.flattened_total.load(Ordering::Relaxed),
        }
    }

    pub fn bump(&self, state: GroupState) {
        match state {
            GroupState::New => {
                self.new_total.fetch_add(1, Ordering::Relaxed);
            }
            GroupState::Dispatched => {
                self.dispatched_total.fetch_add(1, Ordering::Relaxed);
            }
            GroupState::Complete => {
                self.complete_total.fetch_add(1, Ordering::Relaxed);
            }
            GroupState::MixedFailed => {
                self.mixed_failed_total.fetch_add(1, Ordering::Relaxed);
            }
            GroupState::Flattening => {
                self.flattening_total.fetch_add(1, Ordering::Relaxed);
            }
            GroupState::Flattened => {
                self.flattened_total.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

static ATOMIC_GROUP_METRICS: AtomicGroupMetrics = AtomicGroupMetrics::new();

fn record_state(state: GroupState) {
    ATOMIC_GROUP_METRICS.bump(state);
    let tail = format!("state={}", state.as_str());
    super::emit_execution_metric_line("atomic_group_state_total", &tail);
}

fn transition_allowed(from: GroupState, to: GroupState) -> bool {
    matches!(
        (from, to),
        (GroupState::New, GroupState::Dispatched)
            | (GroupState::Dispatched, GroupState::Complete)
            | (GroupState::Dispatched, GroupState::MixedFailed)
            | (GroupState::MixedFailed, GroupState::Flattening)
            | (GroupState::Flattening, GroupState::Flattened)
    )
}
