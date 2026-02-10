#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstrumentKind {
    Option,
    LinearFuture,
    InverseFuture,
    Perpetual,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InstrumentMetadata {
    pub instrument_kind: InstrumentKind,
    pub tick_size: f64,
    pub amount_step: f64,
    pub min_amount: f64,
    pub contract_multiplier: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeribitInstrumentKind {
    Option,
    Future,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeribitSettlementPeriod {
    Perpetual,
    Week,
    Month,
    Other,
}

impl InstrumentKind {
    pub fn from_deribit(
        kind: DeribitInstrumentKind,
        settlement_period: DeribitSettlementPeriod,
        quote_currency: &str,
    ) -> Self {
        let is_linear = quote_currency.eq_ignore_ascii_case("USDC");
        match kind {
            DeribitInstrumentKind::Option => InstrumentKind::Option,
            DeribitInstrumentKind::Future => match settlement_period {
                DeribitSettlementPeriod::Perpetual => {
                    if is_linear {
                        InstrumentKind::LinearFuture
                    } else {
                        InstrumentKind::Perpetual
                    }
                }
                _ => {
                    if is_linear {
                        InstrumentKind::LinearFuture
                    } else {
                        InstrumentKind::InverseFuture
                    }
                }
            },
        }
    }
}

impl InstrumentMetadata {
    pub fn from_deribit(
        kind: DeribitInstrumentKind,
        settlement_period: DeribitSettlementPeriod,
        quote_currency: &str,
        tick_size: f64,
        amount_step: f64,
        min_amount: f64,
        contract_multiplier: f64,
    ) -> Self {
        Self {
            instrument_kind: InstrumentKind::from_deribit(kind, settlement_period, quote_currency),
            tick_size,
            amount_step,
            min_amount,
            contract_multiplier,
        }
    }
}
