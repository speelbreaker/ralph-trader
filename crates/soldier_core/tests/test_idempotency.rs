use soldier_core::execution::{InstrumentQuantization, QuantizedSteps, Side};
use soldier_core::idempotency::{IntentHashInput, intent_hash};

#[test]
fn test_intent_hash_deterministic_from_quantized() {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.0,
    };

    let first = meta
        .quantize_steps(Side::Buy, 1.29, 100.74)
        .expect("quantize first");
    let second = meta
        .quantize_steps(Side::Buy, 1.24, 100.51)
        .expect("quantize second");

    assert_eq!(first.qty_steps, second.qty_steps);
    assert_eq!(first.price_ticks, second.price_ticks);

    let input_a = IntentHashInput {
        instrument_id: "BTC-PERP",
        side: Side::Buy,
        quantized: first,
        group_id: "group-1",
        leg_idx: 0,
    };
    let input_b = IntentHashInput {
        instrument_id: "BTC-PERP",
        side: Side::Buy,
        quantized: second,
        group_id: "group-1",
        leg_idx: 0,
    };

    assert_eq!(intent_hash(&input_a), intent_hash(&input_b));
}

#[test]
fn test_intent_hash_excludes_timestamps() {
    struct IntentWithTimestamp<'a> {
        input: IntentHashInput<'a>,
        _timestamp_ms: u64,
    }

    fn hash_for(intent: &IntentWithTimestamp<'_>) -> u64 {
        intent_hash(&intent.input)
    }

    let quantized = QuantizedSteps {
        qty_steps: 12,
        price_ticks: 201,
        qty_q: 1.2,
        limit_price_q: 100.5,
    };

    let first = IntentWithTimestamp {
        input: IntentHashInput {
            instrument_id: "ETH-PERP",
            side: Side::Sell,
            quantized,
            group_id: "group-2",
            leg_idx: 1,
        },
        _timestamp_ms: 1_700_000_000_000,
    };
    let second = IntentWithTimestamp {
        input: IntentHashInput {
            instrument_id: "ETH-PERP",
            side: Side::Sell,
            quantized,
            group_id: "group-2",
            leg_idx: 1,
        },
        _timestamp_ms: 1_700_000_000_500,
    };

    assert_eq!(hash_for(&first), hash_for(&second));
}

#[test]
fn test_intent_hash_uses_quantized_steps_only() {
    let base = IntentHashInput {
        instrument_id: "ETH-PERP",
        side: Side::Buy,
        quantized: QuantizedSteps {
            qty_steps: 12,
            price_ticks: 201,
            qty_q: 1.2,
            limit_price_q: 100.5,
        },
        group_id: "group-3",
        leg_idx: 0,
    };

    let float_adjusted = IntentHashInput {
        instrument_id: "ETH-PERP",
        side: Side::Buy,
        quantized: QuantizedSteps {
            qty_steps: 12,
            price_ticks: 201,
            qty_q: 1.2000001,
            limit_price_q: 100.5000001,
        },
        group_id: "group-3",
        leg_idx: 0,
    };

    assert_eq!(intent_hash(&base), intent_hash(&float_adjusted));

    let step_adjusted = IntentHashInput {
        instrument_id: "ETH-PERP",
        side: Side::Buy,
        quantized: QuantizedSteps {
            qty_steps: 13,
            price_ticks: 201,
            qty_q: 1.3,
            limit_price_q: 100.5,
        },
        group_id: "group-3",
        leg_idx: 0,
    };

    assert_ne!(intent_hash(&base), intent_hash(&step_adjusted));
}
