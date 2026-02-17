pub mod guard;
pub mod watchdog;

pub use guard::{BunkerModeGuard, BunkerModeGuardConfig};
pub use watchdog::{EmergencyReduceOnlyState, WS_SILENCE_TRIGGER_MS};

// EvidenceGuard (§2.2.2) — enforced when enforced_profile != CSP.
pub use crate::analytics::{
    EvidenceChainState, EvidenceGuard, EvidenceGuardConfig, EvidenceGuardDecision,
    EvidenceGuardInputs,
};
