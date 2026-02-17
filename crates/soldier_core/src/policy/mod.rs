pub mod guard;
pub mod watchdog;

pub use guard::{BunkerModeGuard, BunkerModeGuardConfig};
pub use watchdog::{EmergencyReduceOnlyState, WS_SILENCE_TRIGGER_MS};
