use std::sync::atomic::{AtomicU64, Ordering};

use crate::venue::InstrumentMetadata;

static QUANTIZATION_REJECT_TOO_SMALL_TOTAL: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InstrumentQuantization {
    pub tick_size: f64,
    pub amount_step: f64,
    pub min_amount: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QuantizedFields {
    pub qty_q: f64,
    pub limit_price_q: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QuantizedSteps {
    pub qty_steps: i64,
    pub price_ticks: i64,
    pub qty_q: f64,
    pub limit_price_q: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuantizeRejectReason {
    TooSmallAfterQuantization,
    InstrumentMetadataMissing,
    InvalidInput,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QuantizeReject {
    pub reason: QuantizeRejectReason,
}

impl InstrumentQuantization {
    pub fn from_metadata(meta: &InstrumentMetadata) -> Result<Self, QuantizeReject> {
        let quant = Self {
            tick_size: meta.tick_size,
            amount_step: meta.amount_step,
            min_amount: meta.min_amount,
        };
        validate_metadata(&quant)?;
        Ok(quant)
    }

    pub fn quantize(
        &self,
        side: Side,
        raw_qty: f64,
        raw_limit_price: f64,
    ) -> Result<QuantizedFields, QuantizeReject> {
        quantize(side, raw_qty, raw_limit_price, self)
    }

    pub fn quantize_steps(
        &self,
        side: Side,
        raw_qty: f64,
        raw_limit_price: f64,
    ) -> Result<QuantizedSteps, QuantizeReject> {
        quantize_steps(side, raw_qty, raw_limit_price, self)
    }
}

pub fn quantize_from_metadata(
    side: Side,
    raw_qty: f64,
    raw_limit_price: f64,
    meta: &InstrumentMetadata,
) -> Result<QuantizedFields, QuantizeReject> {
    let quant = InstrumentQuantization::from_metadata(meta)?;
    quantize(side, raw_qty, raw_limit_price, &quant)
}

pub fn quantize(
    side: Side,
    raw_qty: f64,
    raw_limit_price: f64,
    meta: &InstrumentQuantization,
) -> Result<QuantizedFields, QuantizeReject> {
    let steps = quantize_steps(side, raw_qty, raw_limit_price, meta)?;
    Ok(QuantizedFields {
        qty_q: steps.qty_q,
        limit_price_q: steps.limit_price_q,
    })
}

pub fn quantize_steps(
    side: Side,
    raw_qty: f64,
    raw_limit_price: f64,
    meta: &InstrumentQuantization,
) -> Result<QuantizedSteps, QuantizeReject> {
    validate_metadata(meta)?;
    validate_raw_inputs(raw_qty, raw_limit_price, meta)?;

    let qty_steps = steps_floor(raw_qty, meta.amount_step);
    let qty_q = qty_steps as f64 * meta.amount_step;
    if qty_q < meta.min_amount {
        return reject_too_small();
    }

    let price_ticks = match side {
        Side::Buy => steps_floor(raw_limit_price, meta.tick_size),
        Side::Sell => steps_ceil(raw_limit_price, meta.tick_size),
    };
    let limit_price_q = price_ticks as f64 * meta.tick_size;

    Ok(QuantizedSteps {
        qty_steps,
        price_ticks,
        qty_q,
        limit_price_q,
    })
}

pub fn quantization_reject_too_small_total() -> u64 {
    QUANTIZATION_REJECT_TOO_SMALL_TOTAL.load(Ordering::Relaxed)
}

fn validate_metadata(meta: &InstrumentQuantization) -> Result<(), QuantizeReject> {
    if !meta.tick_size.is_finite()
        || !meta.amount_step.is_finite()
        || !meta.min_amount.is_finite()
        || meta.tick_size <= 0.0
        || meta.amount_step <= 0.0
        || meta.min_amount < 0.0
    {
        return Err(QuantizeReject {
            reason: QuantizeRejectReason::InstrumentMetadataMissing,
        });
    }
    Ok(())
}

fn validate_raw_inputs(
    raw_qty: f64,
    raw_limit_price: f64,
    meta: &InstrumentQuantization,
) -> Result<(), QuantizeReject> {
    if !raw_qty.is_finite()
        || !raw_limit_price.is_finite()
        || raw_qty <= 0.0
        || raw_limit_price <= 0.0
    {
        return Err(QuantizeReject {
            reason: QuantizeRejectReason::InvalidInput,
        });
    }
    if !(raw_qty / meta.amount_step).is_finite() || !(raw_limit_price / meta.tick_size).is_finite()
    {
        return Err(QuantizeReject {
            reason: QuantizeRejectReason::InvalidInput,
        });
    }
    Ok(())
}

fn steps_floor(value: f64, step: f64) -> i64 {
    let ratio = value / step;
    if let Some(integer) = near_integer(ratio) {
        return integer;
    }
    ratio.floor() as i64
}

fn steps_ceil(value: f64, step: f64) -> i64 {
    let ratio = value / step;
    if let Some(integer) = near_integer(ratio) {
        return integer;
    }
    ratio.ceil() as i64
}

fn near_integer(value: f64) -> Option<i64> {
    if !value.is_finite() {
        return None;
    }
    let rounded = value.round();
    let tolerance = f64::EPSILON * value.abs().max(1.0) * 4.0;
    if (value - rounded).abs() <= tolerance {
        return Some(rounded as i64);
    }
    None
}

fn reject_too_small<T>() -> Result<T, QuantizeReject> {
    QUANTIZATION_REJECT_TOO_SMALL_TOTAL.fetch_add(1, Ordering::Relaxed);
    Err(QuantizeReject {
        reason: QuantizeRejectReason::TooSmallAfterQuantization,
    })
}
