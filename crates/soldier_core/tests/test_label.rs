use soldier_core::execution::{
    decode_compact_label, encode_compact_label, encode_compact_label_with_hashes,
    label_truncated_total,
};

#[test]
fn test_compact_label_encode_decode() {
    let strat_id = "strat-abc";
    let group_id = "550e8400-e29b-41d4-a716-446655440000";
    let leg_idx = 1;
    let intent_hash = 0x0123456789abcdefu64;

    let label = encode_compact_label(strat_id, group_id, leg_idx, intent_hash);
    assert!(label.len() <= 64);

    let parts: Vec<&str> = label.split(':').collect();
    assert_eq!(parts.len(), 5);
    assert_eq!(parts[0], "s4");
    assert_eq!(parts[2], "550e8400e29b");
    assert_eq!(parts[3], "1");
    assert_eq!(parts[1].len(), 8);
    assert_eq!(parts[4].len(), 16);

    let decoded = decode_compact_label(&label).expect("decode compact label");
    assert_eq!(decoded.gid12, "550e8400e29b");
    assert_eq!(decoded.leg_idx, 1);
    assert_eq!(decoded.sid8.len(), 8);
    assert_eq!(decoded.ih16.len(), 16);
}

#[test]
fn test_decode_parses_components() {
    let label = "s4:deadbeef:0123456789ab:0:0011223344556677";
    let decoded = decode_compact_label(label).expect("decode compact label");
    assert_eq!(decoded.sid8, "deadbeef");
    assert_eq!(decoded.gid12, "0123456789ab");
    assert_eq!(decoded.leg_idx, 0);
    assert_eq!(decoded.ih16, "0011223344556677");
}

#[test]
fn test_overlength_truncates_hashes_and_increments_counter() {
    let before = label_truncated_total();
    let sid = "s".repeat(80);
    let ih = "i".repeat(80);
    let gid12 = "0123456789ab";

    let label = encode_compact_label_with_hashes(&sid, gid12, 0, &ih);
    let after = label_truncated_total();

    assert!(label.len() <= 64);
    let parts: Vec<&str> = label.split(':').collect();
    assert_eq!(parts.len(), 5);
    assert_eq!(parts[0], "s4");
    assert_eq!(parts[2], gid12);
    assert_eq!(parts[3], "0");
    assert!(parts[1].len() < sid.len() || parts[4].len() < ih.len());
    assert_eq!(after, before + 1);
}
