//! Durable storage adapters (WAL, trade-id registry, etc.).

pub mod ledger;
pub mod trade_id_registry;

pub use ledger::{
    Ledger, LedgerConfig, LedgerError, LedgerRecord, LedgerReplay, RecordOutcome, ReplayOutcome,
    Side,
};
pub use trade_id_registry::{
    TradeIdInsertOutcome, TradeIdRecord, TradeIdRegistry, TradeIdRegistryError,
};
