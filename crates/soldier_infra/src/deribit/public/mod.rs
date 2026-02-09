use serde::Deserialize;
use soldier_core::venue::{DeribitInstrumentKind, DeribitSettlementPeriod, InstrumentKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeribitPublicInstrumentKind {
    Option,
    Future,
    OptionCombo,
}

impl DeribitPublicInstrumentKind {
    fn to_core(self) -> DeribitInstrumentKind {
        match self {
            DeribitPublicInstrumentKind::Option | DeribitPublicInstrumentKind::OptionCombo => {
                DeribitInstrumentKind::Option
            }
            DeribitPublicInstrumentKind::Future => DeribitInstrumentKind::Future,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeribitPublicSettlementPeriod {
    Perpetual,
    Week,
    Month,
    #[serde(other)]
    Other,
}

impl DeribitPublicSettlementPeriod {
    fn to_core(self) -> DeribitSettlementPeriod {
        match self {
            DeribitPublicSettlementPeriod::Perpetual => DeribitSettlementPeriod::Perpetual,
            DeribitPublicSettlementPeriod::Week => DeribitSettlementPeriod::Week,
            DeribitPublicSettlementPeriod::Month => DeribitSettlementPeriod::Month,
            DeribitPublicSettlementPeriod::Other => DeribitSettlementPeriod::Other,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DeribitInstrument {
    pub kind: DeribitPublicInstrumentKind,
    pub settlement_period: DeribitPublicSettlementPeriod,
    pub quote_currency: String,
    pub tick_size: f64,
    pub amount_step: f64,
    pub min_amount: f64,
    pub contract_multiplier: f64,
}

#[derive(Debug, Deserialize)]
struct DeribitInstrumentRaw {
    pub kind: DeribitPublicInstrumentKind,
    pub settlement_period: DeribitPublicSettlementPeriod,
    pub quote_currency: String,
    pub tick_size: f64,
    #[serde(rename = "amount_step", alias = "trade_amount_step")]
    pub amount_step: Option<f64>,
    #[serde(rename = "min_trade_amount", alias = "min_amount")]
    pub min_amount: f64,
    #[serde(rename = "contract_size", alias = "contract_multiplier")]
    pub contract_multiplier: f64,
}

impl<'de> Deserialize<'de> for DeribitInstrument {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = DeribitInstrumentRaw::deserialize(deserializer)?;
        let amount_step = raw.amount_step.unwrap_or(raw.min_amount);
        Ok(DeribitInstrument {
            kind: raw.kind,
            settlement_period: raw.settlement_period,
            quote_currency: raw.quote_currency,
            tick_size: raw.tick_size,
            amount_step,
            min_amount: raw.min_amount,
            contract_multiplier: raw.contract_multiplier,
        })
    }
}

impl DeribitInstrument {
    pub fn derive_instrument_kind(&self) -> InstrumentKind {
        InstrumentKind::from_deribit(
            self.kind.to_core(),
            self.settlement_period.to_core(),
            self.quote_currency.as_str(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soldier_core::venue::InstrumentKind;

    #[test]
    fn deserializes_public_instrument_metadata() {
        let payload = r#"{
            "kind": "future",
            "settlement_period": "perpetual",
            "quote_currency": "USDC",
            "tick_size": 0.5,
            "amount_step": 0.1,
            "min_trade_amount": 0.01,
            "contract_size": 10.0
        }"#;

        let instrument: DeribitInstrument =
            serde_json::from_str(payload).expect("instrument metadata should deserialize");

        assert_eq!(instrument.kind, DeribitPublicInstrumentKind::Future);
        assert_eq!(
            instrument.settlement_period,
            DeribitPublicSettlementPeriod::Perpetual
        );
        assert_eq!(instrument.quote_currency, "USDC");
        assert_eq!(instrument.tick_size, 0.5);
        assert_eq!(instrument.amount_step, 0.1);
        assert_eq!(instrument.min_amount, 0.01);
        assert_eq!(instrument.contract_multiplier, 10.0);
        assert_eq!(
            instrument.derive_instrument_kind(),
            InstrumentKind::LinearFuture
        );
    }

    #[test]
    fn falls_back_to_min_amount_when_amount_step_missing() {
        let payload = r#"{
            "kind": "option",
            "settlement_period": "month",
            "quote_currency": "BTC",
            "tick_size": 0.25,
            "min_trade_amount": 0.05,
            "contract_size": 1.0
        }"#;

        let instrument: DeribitInstrument =
            serde_json::from_str(payload).expect("instrument metadata should deserialize");

        assert_eq!(instrument.amount_step, instrument.min_amount);
    }
}
