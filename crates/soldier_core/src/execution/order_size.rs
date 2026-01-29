use std::fmt;

use crate::venue::InstrumentKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderSizeError {
    BothQtyProvided,
    MissingQtyCoin,
    MissingQtyUsd,
    UnexpectedQtyCoin,
    UnexpectedQtyUsd,
    NonFiniteQty,
    NonPositiveQty,
    InvalidIndexPrice,
}

impl fmt::Display for OrderSizeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let code = match self {
            OrderSizeError::BothQtyProvided => "BOTH_QTY_PROVIDED",
            OrderSizeError::MissingQtyCoin => "MISSING_QTY_COIN",
            OrderSizeError::MissingQtyUsd => "MISSING_QTY_USD",
            OrderSizeError::UnexpectedQtyCoin => "UNEXPECTED_QTY_COIN",
            OrderSizeError::UnexpectedQtyUsd => "UNEXPECTED_QTY_USD",
            OrderSizeError::NonFiniteQty => "NON_FINITE_QTY",
            OrderSizeError::NonPositiveQty => "NON_POSITIVE_QTY",
            OrderSizeError::InvalidIndexPrice => "INVALID_INDEX_PRICE",
        };
        write!(f, "{code}")
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OrderSize {
    pub contracts: Option<i64>,
    pub qty_coin: Option<f64>,
    pub qty_usd: Option<f64>,
    pub notional_usd: f64,
}

impl OrderSize {
    pub fn new(
        instrument_kind: InstrumentKind,
        contracts: Option<i64>,
        qty_coin: Option<f64>,
        qty_usd: Option<f64>,
        index_price: f64,
    ) -> Result<Self, OrderSizeError> {
        if qty_coin.is_some() && qty_usd.is_some() {
            return Err(OrderSizeError::BothQtyProvided);
        }

        let (qty_coin, qty_usd, notional_usd) = match instrument_kind {
            InstrumentKind::Option | InstrumentKind::LinearFuture => {
                let qty_coin = qty_coin.ok_or(OrderSizeError::MissingQtyCoin)?;
                if qty_usd.is_some() {
                    return Err(OrderSizeError::UnexpectedQtyUsd);
                }
                validate_qty(qty_coin)?;
                validate_index_price(index_price)?;
                let notional_usd = qty_coin * index_price;
                (Some(qty_coin), None, notional_usd)
            }
            InstrumentKind::Perpetual | InstrumentKind::InverseFuture => {
                let qty_usd = qty_usd.ok_or(OrderSizeError::MissingQtyUsd)?;
                if qty_coin.is_some() {
                    return Err(OrderSizeError::UnexpectedQtyCoin);
                }
                validate_qty(qty_usd)?;
                let notional_usd = qty_usd;
                (None, Some(qty_usd), notional_usd)
            }
        };

        eprintln!(
            "OrderSizeComputed instrument_kind={:?} notional_usd={}",
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

fn validate_qty(value: f64) -> Result<(), OrderSizeError> {
    if !value.is_finite() {
        return Err(OrderSizeError::NonFiniteQty);
    }
    if value <= 0.0 {
        return Err(OrderSizeError::NonPositiveQty);
    }
    Ok(())
}

fn validate_index_price(value: f64) -> Result<(), OrderSizeError> {
    if !value.is_finite() || value <= 0.0 {
        return Err(OrderSizeError::InvalidIndexPrice);
    }
    Ok(())
}
