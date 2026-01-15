use crate::execution::{QuantizedFields, Side};

const PRIME1: u64 = 11400714785074694791;
const PRIME2: u64 = 14029467366897019727;
const PRIME3: u64 = 1609587929392839161;
const PRIME4: u64 = 9650029242287828579;
const PRIME5: u64 = 2870177450012600261;

#[derive(Debug, Clone)]
pub struct IntentHashInput<'a> {
    pub instrument_id: &'a str,
    pub side: Side,
    pub quantized: QuantizedFields,
    pub group_id: &'a str,
    pub leg_idx: u8,
}

pub fn intent_hash(input: &IntentHashInput<'_>) -> u64 {
    let mut buf = Vec::with_capacity(64);
    write_str(&mut buf, input.instrument_id);
    write_u8(&mut buf, side_code(input.side));
    write_f64_bits(&mut buf, input.quantized.qty_q);
    write_f64_bits(&mut buf, input.quantized.limit_price_q);
    write_str(&mut buf, input.group_id);
    write_u8(&mut buf, input.leg_idx);
    xxhash64(&buf)
}

fn side_code(side: Side) -> u8 {
    match side {
        Side::Buy => 0,
        Side::Sell => 1,
    }
}

fn write_str(buf: &mut Vec<u8>, value: &str) {
    let len = value.len() as u32;
    buf.extend_from_slice(&len.to_le_bytes());
    buf.extend_from_slice(value.as_bytes());
}

fn write_u8(buf: &mut Vec<u8>, value: u8) {
    buf.push(value);
}

fn write_f64_bits(buf: &mut Vec<u8>, value: f64) {
    buf.extend_from_slice(&value.to_bits().to_le_bytes());
}

fn xxhash64(input: &[u8]) -> u64 {
    let len = input.len();
    let mut index = 0usize;
    let mut hash: u64;

    if len >= 32 {
        let mut v1 = PRIME1.wrapping_add(PRIME2);
        let mut v2 = PRIME2;
        let mut v3 = 0u64;
        let mut v4 = 0u64.wrapping_sub(PRIME1);

        while index + 32 <= len {
            v1 = round(v1, read_u64_le(&input[index..index + 8]));
            v2 = round(v2, read_u64_le(&input[index + 8..index + 16]));
            v3 = round(v3, read_u64_le(&input[index + 16..index + 24]));
            v4 = round(v4, read_u64_le(&input[index + 24..index + 32]));
            index += 32;
        }

        hash = v1
            .rotate_left(1)
            .wrapping_add(v2.rotate_left(7))
            .wrapping_add(v3.rotate_left(12))
            .wrapping_add(v4.rotate_left(18));

        hash = merge_round(hash, v1);
        hash = merge_round(hash, v2);
        hash = merge_round(hash, v3);
        hash = merge_round(hash, v4);
    } else {
        hash = PRIME5;
    }

    hash = hash.wrapping_add(len as u64);

    while index + 8 <= len {
        let k1 = round(0, read_u64_le(&input[index..index + 8]));
        hash ^= k1;
        hash = hash
            .rotate_left(27)
            .wrapping_mul(PRIME1)
            .wrapping_add(PRIME4);
        index += 8;
    }

    if index + 4 <= len {
        let k1 = read_u32_le(&input[index..index + 4]) as u64;
        hash ^= k1.wrapping_mul(PRIME1);
        hash = hash
            .rotate_left(23)
            .wrapping_mul(PRIME2)
            .wrapping_add(PRIME3);
        index += 4;
    }

    while index < len {
        hash ^= (input[index] as u64).wrapping_mul(PRIME5);
        hash = hash.rotate_left(11).wrapping_mul(PRIME1);
        index += 1;
    }

    hash ^= hash >> 33;
    hash = hash.wrapping_mul(PRIME2);
    hash ^= hash >> 29;
    hash = hash.wrapping_mul(PRIME3);
    hash ^= hash >> 32;

    hash
}

fn round(acc: u64, input: u64) -> u64 {
    acc.wrapping_add(input.wrapping_mul(PRIME2))
        .rotate_left(31)
        .wrapping_mul(PRIME1)
}

fn merge_round(acc: u64, val: u64) -> u64 {
    let mut acc = acc ^ round(0, val);
    acc = acc.wrapping_mul(PRIME1).wrapping_add(PRIME4);
    acc
}

fn read_u64_le(bytes: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&bytes[..8]);
    u64::from_le_bytes(buf)
}

fn read_u32_le(bytes: &[u8]) -> u32 {
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&bytes[..4]);
    u32::from_le_bytes(buf)
}
