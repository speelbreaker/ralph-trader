//! Durable storage adapters (WAL, trade-id registry, etc.).

pub mod ledger;

pub use ledger::{
    Ledger, LedgerConfig, LedgerError, LedgerRecord, LedgerReplay, RecordOutcome, ReplayOutcome,
    Side,
};
