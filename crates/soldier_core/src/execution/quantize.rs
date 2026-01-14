use std::sync::atomic::{AtomicU64, Ordering};

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuantizeRejectReason {
    TooSmallAfterQuantization,
    InvalidMetadata,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QuantizeReject {
    pub reason: QuantizeRejectReason,
}

impl InstrumentQuantization {
    pub fn quantize(
        &self,
        side: Side,
        raw_qty: f64,
        raw_limit_price: f64,
    ) -> Result<QuantizedFields, QuantizeReject> {
        quantize(side, raw_qty, raw_limit_price, self)
    }
}

pub fn quantize(
    side: Side,
    raw_qty: f64,
    raw_limit_price: f64,
    meta: &InstrumentQuantization,
) -> Result<QuantizedFields, QuantizeReject> {
    validate_metadata(meta)?;

    let qty_q = round_down(raw_qty, meta.amount_step);
    if qty_q < meta.min_amount {
        return reject_too_small();
    }

    let limit_price_q = match side {
        Side::Buy => round_down(raw_limit_price, meta.tick_size),
        Side::Sell => round_up(raw_limit_price, meta.tick_size),
    };

    Ok(QuantizedFields {
        qty_q,
        limit_price_q,
    })
}

pub fn quantization_reject_too_small_total() -> u64 {
    QUANTIZATION_REJECT_TOO_SMALL_TOTAL.load(Ordering::Relaxed)
}

fn validate_metadata(meta: &InstrumentQuantization) -> Result<(), QuantizeReject> {
    if meta.tick_size <= 0.0 || meta.amount_step <= 0.0 || meta.min_amount < 0.0 {
        return Err(QuantizeReject {
            reason: QuantizeRejectReason::InvalidMetadata,
        });
    }
    Ok(())
}

fn round_down(value: f64, step: f64) -> f64 {
    let steps = (value / step).floor();
    steps * step
}

fn round_up(value: f64, step: f64) -> f64 {
    let steps = (value / step).ceil();
    steps * step
}

fn reject_too_small() -> Result<QuantizedFields, QuantizeReject> {
    QUANTIZATION_REJECT_TOO_SMALL_TOTAL.fetch_add(1, Ordering::Relaxed);
    Err(QuantizeReject {
        reason: QuantizeRejectReason::TooSmallAfterQuantization,
    })
}
