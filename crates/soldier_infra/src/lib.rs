//! Infrastructure adapters and services for the StoicTrader system.

#[path = "../config/mod.rs"]
pub mod config;
pub mod deribit;
pub mod health;
pub mod store;

pub use deribit::{DeribitInstrument, DeribitPublicInstrumentKind, DeribitPublicSettlementPeriod};
