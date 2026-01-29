use serde::Deserialize;
use soldier_core::execution::InstrumentQuantization;
use soldier_core::venue::{DeribitInstrumentKind, DeribitSettlementPeriod, InstrumentKind};

#[derive(Debug, Clone, PartialEq)]
pub struct DeribitInstrument {
    pub instrument_name: String,
    pub kind: DeribitInstrumentKind,
    pub settlement_period: DeribitSettlementPeriod,
    pub quote_currency: String,
    pub tick_size: f64,
    pub amount_step: f64,
    pub min_amount: f64,
    pub contract_multiplier: Option<f64>,
    pub expiration_timestamp: Option<i64>,
    pub is_active: bool,
}

#[derive(Debug, Deserialize)]
pub struct DeribitInstrumentRaw {
    instrument_name: String,
    kind: String,
    settlement_period: String,
    quote_currency: String,
    tick_size: f64,
    min_trade_amount: f64,
    contract_size: Option<f64>,
    expiration_timestamp: Option<i64>,
    is_active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeribitInstrumentParseError {
    UnknownKind(String),
}

impl DeribitInstrumentRaw {
    pub fn into_domain(self) -> Result<DeribitInstrument, DeribitInstrumentParseError> {
        let kind =
            parse_kind(&self.kind).ok_or(DeribitInstrumentParseError::UnknownKind(self.kind))?;
        let settlement_period = parse_settlement_period(&self.settlement_period);
        Ok(DeribitInstrument {
            instrument_name: self.instrument_name,
            kind,
            settlement_period,
            quote_currency: self.quote_currency,
            tick_size: self.tick_size,
            amount_step: self.min_trade_amount,
            min_amount: self.min_trade_amount,
            contract_multiplier: self.contract_size,
            expiration_timestamp: self.expiration_timestamp,
            is_active: self.is_active,
        })
    }
}

impl DeribitInstrument {
    pub fn derive_instrument_kind(&self) -> InstrumentKind {
        InstrumentKind::from_deribit(
            self.kind,
            self.settlement_period,
            self.quote_currency.as_str(),
        )
    }

    pub fn to_quantization(&self) -> InstrumentQuantization {
        InstrumentQuantization {
            tick_size: self.tick_size,
            amount_step: self.amount_step,
            min_amount: self.min_amount,
        }
    }
}

fn parse_kind(value: &str) -> Option<DeribitInstrumentKind> {
    match value.to_ascii_lowercase().as_str() {
        "option" => Some(DeribitInstrumentKind::Option),
        "future" => Some(DeribitInstrumentKind::Future),
        _ => None,
    }
}

fn parse_settlement_period(value: &str) -> DeribitSettlementPeriod {
    match value.to_ascii_lowercase().as_str() {
        "perpetual" => DeribitSettlementPeriod::Perpetual,
        "week" => DeribitSettlementPeriod::Week,
        "month" => DeribitSettlementPeriod::Month,
        _ => DeribitSettlementPeriod::Other,
    }
}
