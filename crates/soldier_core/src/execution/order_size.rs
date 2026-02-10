use crate::venue::InstrumentKind;

pub const CONTRACTS_AMOUNT_MATCH_TOLERANCE: f64 = 0.001;
pub const CONTRACTS_AMOUNT_MATCH_EPSILON: f64 = 1e-9;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OrderSize {
    pub contracts: Option<i64>,
    pub qty_coin: Option<f64>,
    pub qty_usd: Option<f64>,
    pub notional_usd: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderSizeError {
    BothCanonical,
    MissingCanonical,
    InvalidIndexPrice,
}

impl OrderSize {
    pub fn new(
        instrument_kind: InstrumentKind,
        contracts: Option<i64>,
        qty_coin: Option<f64>,
        qty_usd: Option<f64>,
        index_price: f64,
    ) -> Self {
        Self::try_new(instrument_kind, contracts, qty_coin, qty_usd, index_price)
            .expect("OrderSize::new invalid input")
    }

    pub fn try_new(
        instrument_kind: InstrumentKind,
        contracts: Option<i64>,
        qty_coin: Option<f64>,
        qty_usd: Option<f64>,
        index_price: f64,
    ) -> Result<Self, OrderSizeError> {
        if qty_coin.is_some() && qty_usd.is_some() {
            return Err(OrderSizeError::BothCanonical);
        }

        let (qty_coin, qty_usd, notional_usd) = match instrument_kind {
            InstrumentKind::Option | InstrumentKind::LinearFuture => {
                let qty_coin = qty_coin.ok_or(OrderSizeError::MissingCanonical)?;
                if index_price <= 0.0 {
                    return Err(OrderSizeError::InvalidIndexPrice);
                }
                let notional_usd = qty_coin * index_price;
                (Some(qty_coin), None, notional_usd)
            }
            InstrumentKind::Perpetual | InstrumentKind::InverseFuture => {
                let qty_usd = qty_usd.ok_or(OrderSizeError::MissingCanonical)?;
                let notional_usd = qty_usd;
                (None, Some(qty_usd), notional_usd)
            }
        };

        eprintln!(
            "OrderSizeComputed{{instrument_kind={:?}, notional_usd={}}}",
            instrument_kind, notional_usd
        );

        Ok(Self {
            contracts,
            qty_coin,
            qty_usd,
            notional_usd,
        })
    }
}

pub fn contracts_amount_matches(amount: f64, contracts: i64, contract_multiplier: f64) -> bool {
    if !amount.is_finite() || !contract_multiplier.is_finite() {
        return false;
    }
    if contract_multiplier <= 0.0 {
        return false;
    }
    let expected = contracts as f64 * contract_multiplier;
    let denom = amount.abs().max(CONTRACTS_AMOUNT_MATCH_EPSILON);
    ((amount - expected).abs() / denom) <= CONTRACTS_AMOUNT_MATCH_TOLERANCE
}
