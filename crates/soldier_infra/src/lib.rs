//! Infrastructure adapters and services for the StoicTrader system.

#[path = "../config/mod.rs"]
pub mod config;
pub mod deribit;
pub mod health;
pub mod store;
pub mod wal;

pub use deribit::{DeribitInstrument, DeribitPublicInstrumentKind, DeribitPublicSettlementPeriod};
pub use store::{TradeIdInsertOutcome, TradeIdRecord, TradeIdRegistry, TradeIdRegistryError};
pub use wal::{DurableAppendOutcome, Wal, WalConfig, WalError, WalRecord, WalSide};
