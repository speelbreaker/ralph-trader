#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstrumentKind {
    Option,
    LinearFuture,
    InverseFuture,
    Perpetual,
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
