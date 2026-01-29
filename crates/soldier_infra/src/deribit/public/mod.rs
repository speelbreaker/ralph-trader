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
