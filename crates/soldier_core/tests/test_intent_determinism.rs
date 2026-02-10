use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use soldier_core::execution::{InstrumentQuantization, QuantizedSteps, Side};
use soldier_core::idempotency::{IntentHashInput, intent_hash};

const EVIDENCE_RELATIVE_PATH: &str = "evidence/phase1/determinism/intent_hashes.txt";
const SAMPLE_INSTRUMENT_ID: &str = "BTC-PERP";
const SAMPLE_GROUP_ID: &str = "determinism-group-1";

struct FixedClock {
    now_ms: u64,
}

impl FixedClock {
    fn new(now_ms: u64) -> Self {
        Self { now_ms }
    }

    fn now_ms(&self) -> u64 {
        self.now_ms
    }
}

struct IntentSnapshot<'a> {
    input: IntentHashInput<'a>,
    created_ts_ms: u64,
}

fn sample_quantized() -> QuantizedSteps {
    let meta = InstrumentQuantization {
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.0,
    };
    meta.quantize_steps(Side::Buy, 1.29, 100.74)
        .expect("quantize sample")
}

fn build_input<'a>(
    instrument_id: &'a str,
    group_id: &'a str,
    leg_idx: u8,
    side: Side,
    quantized: QuantizedSteps,
) -> IntentHashInput<'a> {
    IntentHashInput {
        instrument_id,
        side,
        quantized,
        group_id,
        leg_idx,
    }
}

fn build_snapshot<'a>(clock: &FixedClock, input: IntentHashInput<'a>) -> IntentSnapshot<'a> {
    IntentSnapshot {
        input,
        created_ts_ms: clock.now_ms(),
    }
}

fn encode_intent_bytes(input: &IntentHashInput<'_>) -> Vec<u8> {
    let mut buf = Vec::with_capacity(64);
    write_str(&mut buf, input.instrument_id);
    write_u8(&mut buf, side_code(input.side));
    write_i64(&mut buf, input.quantized.qty_steps);
    write_i64(&mut buf, input.quantized.price_ticks);
    write_str(&mut buf, input.group_id);
    write_u8(&mut buf, input.leg_idx);
    buf
}

fn write_str(buf: &mut Vec<u8>, value: &str) {
    let len = value.len() as u32;
    buf.extend_from_slice(&len.to_le_bytes());
    buf.extend_from_slice(value.as_bytes());
}

fn write_u8(buf: &mut Vec<u8>, value: u8) {
    buf.push(value);
}

fn write_i64(buf: &mut Vec<u8>, value: i64) {
    buf.extend_from_slice(&value.to_le_bytes());
}

fn side_code(side: Side) -> u8 {
    match side {
        Side::Buy => 0,
        Side::Sell => 1,
    }
}

fn hex_bytes(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(out, "{:02x}", byte);
    }
    out
}

fn hash_hex(hash: u64) -> String {
    format!("{:016x}", hash)
}

fn evidence_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(EVIDENCE_RELATIVE_PATH)
}

struct EvidenceSnapshot {
    intent_bytes_hex: String,
    intent_hash_hex: String,
    run_1: String,
    run_2: String,
}

fn parse_evidence(contents: &str) -> EvidenceSnapshot {
    let mut intent_bytes_hex = None;
    let mut intent_hash_hex = None;
    let mut run_1 = None;
    let mut run_2 = None;

    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = match line.split_once(':') {
            Some((key, value)) => (key.trim(), value.trim()),
            None => continue,
        };
        match key {
            "intent_bytes_hex" => intent_bytes_hex = Some(value.to_string()),
            "intent_hash_hex" => intent_hash_hex = Some(value.to_string()),
            "run_1" => run_1 = Some(value.to_string()),
            "run_2" => run_2 = Some(value.to_string()),
            _ => {}
        }
    }

    EvidenceSnapshot {
        intent_bytes_hex: intent_bytes_hex.expect("intent_bytes_hex missing"),
        intent_hash_hex: intent_hash_hex.expect("intent_hash_hex missing"),
        run_1: run_1.expect("run_1 missing"),
        run_2: run_2.expect("run_2 missing"),
    }
}

fn maybe_log_snapshot(label: &str, bytes_hex: &str, hash_hex: &str) {
    if std::env::var("INTENT_DETERMINISM_DEBUG").is_ok() {
        println!("{label} bytes_hex={bytes_hex}");
        println!("{label} hash_hex={hash_hex}");
    }
}

fn stable_group_id_from_tags(tags: &HashMap<&'static str, &'static str>) -> String {
    let mut entries: Vec<_> = tags.iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    entries
        .into_iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("|")
}

#[test]
fn test_intent_determinism_same_inputs_same_hash() {
    let clock = FixedClock::new(1_700_000_000_000);
    let quantized = sample_quantized();

    assert_eq!(quantized.qty_steps, 12, "expected canonical qty steps");
    assert_eq!(quantized.price_ticks, 201, "expected canonical price ticks");

    let input = build_input(
        SAMPLE_INSTRUMENT_ID,
        SAMPLE_GROUP_ID,
        0,
        Side::Buy,
        quantized,
    );
    let first = build_snapshot(&clock, input.clone());
    let second = build_snapshot(&clock, input);

    assert_eq!(first.created_ts_ms, second.created_ts_ms);

    let hash_a = intent_hash(&first.input);
    let hash_b = intent_hash(&second.input);
    assert_eq!(
        hash_a, hash_b,
        "hash must be identical for identical inputs"
    );

    let bytes_hex = hex_bytes(&encode_intent_bytes(&first.input));
    let hash_hex = hash_hex(hash_a);
    maybe_log_snapshot("intent", &bytes_hex, &hash_hex);

    let evidence_contents = fs::read_to_string(evidence_path()).expect("read evidence file");
    let evidence = parse_evidence(&evidence_contents);

    assert_eq!(evidence.intent_bytes_hex, bytes_hex);
    assert_eq!(evidence.intent_hash_hex, hash_hex);
    assert_eq!(evidence.run_1, hash_hex);
    assert_eq!(evidence.run_2, hash_hex);
}

#[test]
fn test_intent_determinism_hashmap_order_independent() {
    let quantized = sample_quantized();

    let mut tags_a = HashMap::new();
    tags_a.insert("leg", "0");
    tags_a.insert("strategy", "alpha");
    tags_a.insert("group", "determinism");

    let mut tags_b = HashMap::new();
    tags_b.insert("group", "determinism");
    tags_b.insert("strategy", "alpha");
    tags_b.insert("leg", "0");

    let group_a = stable_group_id_from_tags(&tags_a);
    let group_b = stable_group_id_from_tags(&tags_b);

    assert_eq!(group_a, group_b);

    let input_a = build_input(
        SAMPLE_INSTRUMENT_ID,
        group_a.as_str(),
        0,
        Side::Buy,
        quantized,
    );
    let input_b = build_input(
        SAMPLE_INSTRUMENT_ID,
        group_b.as_str(),
        0,
        Side::Buy,
        quantized,
    );

    assert_eq!(intent_hash(&input_a), intent_hash(&input_b));
}
