use std::sync::atomic::{AtomicU64, Ordering};

const LABEL_PREFIX: &str = "s4";
const MAX_LABEL_LEN: usize = 64;
const SID_LEN: usize = 8;
const GID_LEN: usize = 12;

static LABEL_TRUNCATED_TOTAL: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactLabelParts {
    pub sid8: String,
    pub gid12: String,
    pub leg_idx: u8,
    pub ih16: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LabelDecodeError {
    InvalidPrefix,
    InvalidFormat,
    InvalidLegIdx,
}

pub fn encode_compact_label(
    strat_id: &str,
    group_id: &str,
    leg_idx: u8,
    intent_hash: u64,
) -> String {
    let sid_full = hash_hex64(strat_id.as_bytes());
    let sid8 = &sid_full[..SID_LEN.min(sid_full.len())];
    let gid12 = compact_group_id(group_id);
    let ih16 = format!("{:016x}", intent_hash);
    encode_compact_label_with_hashes(sid8, &gid12, leg_idx, &ih16)
}

pub fn encode_compact_label_with_hashes(sid: &str, gid12: &str, leg_idx: u8, ih: &str) -> String {
    let leg_str = leg_idx.to_string();
    let mut sid_use = sid;
    let mut ih_use = ih;
    let total_len = label_len(sid_use, gid12, &leg_str, ih_use);
    if total_len > MAX_LABEL_LEN {
        let fixed = LABEL_PREFIX.len() + 4 + gid12.len() + leg_str.len();
        if fixed >= MAX_LABEL_LEN {
            sid_use = "";
            ih_use = "";
        } else {
            let remaining = MAX_LABEL_LEN - fixed;
            let (sid_len, ih_len) = allocate_hash_lengths(sid_use.len(), ih_use.len(), remaining);
            sid_use = &sid_use[..sid_len];
            ih_use = &ih_use[..ih_len];
        }
        LABEL_TRUNCATED_TOTAL.fetch_add(1, Ordering::Relaxed);
    }

    format!(
        "{}:{}:{}:{}:{}",
        LABEL_PREFIX, sid_use, gid12, leg_str, ih_use
    )
}

pub fn decode_compact_label(label: &str) -> Result<CompactLabelParts, LabelDecodeError> {
    let mut parts = label.split(':');
    let prefix = parts.next().ok_or(LabelDecodeError::InvalidFormat)?;
    if prefix != LABEL_PREFIX {
        return Err(LabelDecodeError::InvalidPrefix);
    }
    let sid8 = parts.next().ok_or(LabelDecodeError::InvalidFormat)?;
    let gid12 = parts.next().ok_or(LabelDecodeError::InvalidFormat)?;
    let leg_idx_raw = parts.next().ok_or(LabelDecodeError::InvalidFormat)?;
    let ih16 = parts.next().ok_or(LabelDecodeError::InvalidFormat)?;
    if parts.next().is_some() {
        return Err(LabelDecodeError::InvalidFormat);
    }

    let leg_idx = leg_idx_raw
        .parse::<u8>()
        .map_err(|_| LabelDecodeError::InvalidLegIdx)?;

    Ok(CompactLabelParts {
        sid8: sid8.to_string(),
        gid12: gid12.to_string(),
        leg_idx,
        ih16: ih16.to_string(),
    })
}

pub fn label_truncated_total() -> u64 {
    LABEL_TRUNCATED_TOTAL.load(Ordering::Relaxed)
}

fn compact_group_id(group_id: &str) -> String {
    let mut buf = String::with_capacity(GID_LEN);
    for ch in group_id.chars() {
        if ch == '-' {
            continue;
        }
        if buf.len() >= GID_LEN {
            break;
        }
        buf.push(ch);
    }
    buf
}

fn label_len(sid: &str, gid12: &str, leg_idx: &str, ih: &str) -> usize {
    LABEL_PREFIX.len() + 4 + sid.len() + gid12.len() + leg_idx.len() + ih.len()
}

fn allocate_hash_lengths(sid_len: usize, ih_len: usize, remaining: usize) -> (usize, usize) {
    if remaining == 0 {
        return (0, 0);
    }
    if remaining == 1 {
        return (0, ih_len.min(1));
    }
    let ih_keep = ih_len.min(remaining - 1);
    let sid_keep = sid_len.min(remaining - ih_keep);
    if sid_keep == 0 {
        return (0, ih_len.min(remaining));
    }
    (sid_keep, ih_keep)
}

fn hash_hex64(input: &[u8]) -> String {
    let hash = xxhash64(input);
    format!("{:016x}", hash)
}

fn xxhash64(input: &[u8]) -> u64 {
    const PRIME1: u64 = 11400714785074694791;
    const PRIME2: u64 = 14029467366897019727;
    const PRIME3: u64 = 1609587929392839161;
    const PRIME4: u64 = 9650029242287828579;
    const PRIME5: u64 = 2870177450012600261;

    let len = input.len();
    let mut index = 0usize;
    let mut hash: u64;

    if len >= 32 {
        let mut v1 = PRIME1.wrapping_add(PRIME2);
        let mut v2 = PRIME2;
        let mut v3 = 0u64;
        let mut v4 = 0u64.wrapping_sub(PRIME1);

        while index + 32 <= len {
            v1 = round(v1, read_u64_le(&input[index..index + 8]), PRIME1, PRIME2);
            v2 = round(
                v2,
                read_u64_le(&input[index + 8..index + 16]),
                PRIME1,
                PRIME2,
            );
            v3 = round(
                v3,
                read_u64_le(&input[index + 16..index + 24]),
                PRIME1,
                PRIME2,
            );
            v4 = round(
                v4,
                read_u64_le(&input[index + 24..index + 32]),
                PRIME1,
                PRIME2,
            );
            index += 32;
        }

        hash = v1
            .rotate_left(1)
            .wrapping_add(v2.rotate_left(7))
            .wrapping_add(v3.rotate_left(12))
            .wrapping_add(v4.rotate_left(18));

        hash = merge_round(hash, v1, PRIME1, PRIME4);
        hash = merge_round(hash, v2, PRIME1, PRIME4);
        hash = merge_round(hash, v3, PRIME1, PRIME4);
        hash = merge_round(hash, v4, PRIME1, PRIME4);
    } else {
        hash = PRIME5;
    }

    hash = hash.wrapping_add(len as u64);

    while index + 8 <= len {
        let k1 = round(0, read_u64_le(&input[index..index + 8]), PRIME1, PRIME2);
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

fn round(acc: u64, input: u64, prime1: u64, prime2: u64) -> u64 {
    acc.wrapping_add(input.wrapping_mul(prime2))
        .rotate_left(31)
        .wrapping_mul(prime1)
}

fn merge_round(acc: u64, val: u64, prime1: u64, prime4: u64) -> u64 {
    let mut acc = acc ^ round(0, val, prime1, prime4);
    acc = acc.wrapping_mul(prime1).wrapping_add(prime4);
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
