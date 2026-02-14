use soldier_core::execution::{
    InstrumentQuantization, QuantizeRejectReason, Side, quantization_reject_too_small_total,
    quantize_from_metadata,
};
use soldier_core::venue::{InstrumentKind, InstrumentMetadata};

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

    let exact = meta
        .quantize_steps(Side::Buy, 1.2, 100.5)
        .expect("exact quantize");
    assert_eq!(exact.qty_steps, 12);
    assert_eq!(exact.price_ticks, 201);
    assert!((exact.qty_q - 1.2).abs() < 1e-12);
    assert!((exact.limit_price_q - 100.5).abs() < 1e-12);
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

#[test]
fn test_missing_metadata_rejects_open() {
    let meta = InstrumentMetadata {
        instrument_kind: InstrumentKind::Perpetual,
        tick_size: 0.0,
        amount_step: 0.1,
        min_amount: 0.2,
        contract_multiplier: 1.0,
    };

    let err = quantize_from_metadata(Side::Buy, 1.0, 100.0, &meta)
        .expect_err("missing tick size should reject");
    assert_eq!(err.reason, QuantizeRejectReason::InstrumentMetadataMissing);
}

#[test]
fn test_non_finite_raw_inputs_reject_fail_closed() {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.2,
    };

    let bad_inputs = [
        (f64::NAN, 100.0),
        (f64::INFINITY, 100.0),
        (1.0, f64::NAN),
        (1.0, f64::INFINITY),
    ];
    for (raw_qty, raw_limit_price) in bad_inputs {
        let err = meta
            .quantize(Side::Buy, raw_qty, raw_limit_price)
            .expect_err("non-finite input should reject");
        assert_eq!(err.reason, QuantizeRejectReason::InvalidInput);
    }
}

#[test]
fn test_quantize_invalid_metadata_matrix() {
    let cases = [
        InstrumentQuantization {
            tick_size: 0.0,
            amount_step: 0.1,
            min_amount: 0.2,
        },
        InstrumentQuantization {
            tick_size: 0.5,
            amount_step: 0.0,
            min_amount: 0.2,
        },
        InstrumentQuantization {
            tick_size: 0.5,
            amount_step: 0.1,
            min_amount: -0.1,
        },
        InstrumentQuantization {
            tick_size: f64::NAN,
            amount_step: 0.1,
            min_amount: 0.2,
        },
        InstrumentQuantization {
            tick_size: 0.5,
            amount_step: f64::INFINITY,
            min_amount: 0.2,
        },
    ];

    for meta in cases {
        let err = meta
            .quantize(Side::Buy, 1.0, 100.0)
            .expect_err("invalid metadata should reject");
        assert_eq!(err.reason, QuantizeRejectReason::InstrumentMetadataMissing);
    }
}

#[test]
fn test_quantize_invalid_raw_input_matrix() {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.1,
    };
    let cases = [
        (0.0, 100.0),
        (-1.0, 100.0),
        (1.0, 0.0),
        (1.0, -100.0),
        (f64::NEG_INFINITY, 100.0),
    ];
    for (raw_qty, raw_limit_price) in cases {
        let err = meta
            .quantize(Side::Buy, raw_qty, raw_limit_price)
            .expect_err("invalid raw input should reject");
        assert_eq!(err.reason, QuantizeRejectReason::InvalidInput);
    }
}

#[test]
fn test_quantize_near_integer_boundary_stability() {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.1,
    };
    let steps = meta
        .quantize_steps(Side::Buy, 0.30000000000000004, 100.50000000000001)
        .expect("near-integer should quantize deterministically");
    assert_eq!(steps.qty_steps, 3);
    assert_eq!(steps.price_ticks, 201);
    assert!((steps.qty_q - 0.3).abs() < 1e-12);
    assert!((steps.limit_price_q - 100.5).abs() < 1e-12);
}

#[test]
fn test_quantize_rounding_matrix_by_side() {
    struct Case {
        side: Side,
        raw_limit_price: f64,
        expected_limit_price: f64,
    }

    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.1,
    };
    let cases = [
        Case {
            side: Side::Buy,
            raw_limit_price: 100.49,
            expected_limit_price: 100.0,
        },
        Case {
            side: Side::Buy,
            raw_limit_price: 100.5,
            expected_limit_price: 100.5,
        },
        Case {
            side: Side::Sell,
            raw_limit_price: 100.01,
            expected_limit_price: 100.5,
        },
        Case {
            side: Side::Sell,
            raw_limit_price: 100.5,
            expected_limit_price: 100.5,
        },
    ];

    for case in cases {
        let quantized = meta
            .quantize(case.side, 1.0, case.raw_limit_price)
            .expect("quantize should succeed");
        assert!(
            (quantized.limit_price_q - case.expected_limit_price).abs() < 1e-12,
            "side={:?} raw_limit_price={} expected={} got={}",
            case.side,
            case.raw_limit_price,
            case.expected_limit_price,
            quantized.limit_price_q
        );
    }
}
