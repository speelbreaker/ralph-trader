use soldier_core::execution::{InstrumentQuantization, QuantizedFields, Side};
use soldier_core::idempotency::{IntentHashInput, intent_hash};

#[test]
fn test_intent_hash_deterministic_from_quantized() {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.0,
    };

    let first = meta
        .quantize(Side::Buy, 1.29, 100.74)
        .expect("quantize first");
    let second = meta
        .quantize(Side::Buy, 1.24, 100.51)
        .expect("quantize second");

    assert_eq!(first, second);

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

    let quantized = QuantizedFields {
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
fn test_intent_hash_uses_quantized_fields_verbatim() {
    let base = IntentHashInput {
        instrument_id: "ETH-PERP",
        side: Side::Buy,
        quantized: QuantizedFields {
            qty_q: 1.21,
            limit_price_q: 100.5,
        },
        group_id: "group-3",
        leg_idx: 0,
    };

    let adjusted = IntentHashInput {
        instrument_id: "ETH-PERP",
        side: Side::Buy,
        quantized: QuantizedFields {
            qty_q: 1.24,
            limit_price_q: 100.5,
        },
        group_id: "group-3",
        leg_idx: 0,
    };

    assert_ne!(intent_hash(&base), intent_hash(&adjusted));
}
