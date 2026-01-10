use soldier_core::venue::{DeribitInstrumentKind, DeribitSettlementPeriod, InstrumentKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeribitInstrument {
    pub kind: DeribitInstrumentKind,
    pub settlement_period: DeribitSettlementPeriod,
    pub quote_currency: String,
}

impl DeribitInstrument {
    pub fn derive_instrument_kind(&self) -> InstrumentKind {
        InstrumentKind::from_deribit(
            self.kind,
            self.settlement_period,
            self.quote_currency.as_str(),
        )
    }
}
