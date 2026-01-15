use soldier_core::execution::{
    InstrumentQuantization, QuantizeRejectReason, Side, quantization_reject_too_small_total,
};

#[test]
fn test_quantization_rounding_buy_sell() {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.2,
    };

    let buy = meta
        .quantize(Side::Buy, 1.24, 100.74)
        .expect("buy quantize");
    assert!((buy.qty_q - 1.2).abs() < 1e-9);
    assert!((buy.limit_price_q - 100.5).abs() < 1e-9);

    let sell = meta
        .quantize(Side::Sell, 1.24, 100.74)
        .expect("sell quantize");
    assert!((sell.qty_q - 1.2).abs() < 1e-9);
    assert!((sell.limit_price_q - 101.0).abs() < 1e-9);
}

#[test]
fn test_rejects_too_small_after_quantization() {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 1.0,
    };

    let before = quantization_reject_too_small_total();
    let err = meta
        .quantize(Side::Buy, 0.95, 100.0)
        .expect_err("too small should reject");
    let after = quantization_reject_too_small_total();

    assert_eq!(err.reason, QuantizeRejectReason::TooSmallAfterQuantization);
    assert_eq!(after, before + 1);
}
