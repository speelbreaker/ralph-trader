pub mod guard;
pub mod watchdog;

pub use guard::{
    BunkerModeGuard, BunkerModeGuardConfig, F1CertStatus, F1Gate, F1GateConfig, F1RuntimeBindings,
    JsonValue, canonical_json_bytes, compute_runtime_config_hash, sha256,
};
pub use watchdog::{EmergencyReduceOnlyState, WS_SILENCE_TRIGGER_MS};

// EvidenceGuard (§2.2.2) — enforced when enforced_profile != CSP.
pub use crate::analytics::{
    EvidenceChainState, EvidenceGuard, EvidenceGuardConfig, EvidenceGuardDecision,
    EvidenceGuardInputs,
};
