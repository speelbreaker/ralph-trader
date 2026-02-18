//! Integration tests for F1 certification gate (S8-001).
//! Contract: §2.2.1 | AT-012, AT-020, AT-021
//!
//! Acceptance criteria:
//! - F1_CERT missing/unparseable → TradingMode=ReduceOnly (F1CertStatus::Missing)
//! - F1_CERT.contract_version != runtime → ReduceOnly (AT-020)
//! - F1_CERT.build_id != runtime → ReduceOnly
//! - F1_CERT.runtime_config_hash != runtime → ReduceOnly
//! - F1_CERT stale → ReduceOnly, no last-known-good bypass (AT-021)
//! - contract_version with 'v' prefix → reject (AT-012)
//! - AT-113: canonical_json_bytes ordering invariant

#[path = "../src/policy/guard.rs"]
mod guard;

use guard::{
    F1CertStatus, F1Gate, F1GateConfig, F1RuntimeBindings, JsonValue, canonical_json_bytes,
    compute_runtime_config_hash, hex_encode, sha256,
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

const RUNTIME_CONTRACT_VERSION: &str = "5.2";
const RUNTIME_BUILD_ID: &str = "test-build-001";
const RUNTIME_CONFIG_HASH: &str =
    "abc123def456abc123def456abc123def456abc123def456abc123def456abc1";

fn runtime_bindings() -> F1RuntimeBindings {
    F1RuntimeBindings {
        contract_version: RUNTIME_CONTRACT_VERSION.to_string(),
        build_id: RUNTIME_BUILD_ID.to_string(),
        runtime_config_hash: RUNTIME_CONFIG_HASH.to_string(),
    }
}

fn default_config() -> F1GateConfig {
    F1GateConfig {
        cert_path: "artifacts/F1_CERT.json".to_string(),
        f1_cert_freshness_window_s: 86_400,
    }
}

/// Build a valid PASS cert JSON string with given field overrides.
fn valid_cert_json(
    status: &str,
    generated_ts_ms: u64,
    build_id: &str,
    runtime_config_hash: &str,
    contract_version: &str,
) -> String {
    format!(
        r#"{{"status":"{status}","generated_ts_ms":{generated_ts_ms},"build_id":"{build_id}","runtime_config_hash":"{runtime_config_hash}","contract_version":"{contract_version}"}}"#
    )
}

// ─── Acceptance test 1: F1_CERT missing/unparseable → ReduceOnly ─────────────

#[test]
fn test_f1_cert_missing_returns_reduce_only() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    // None (missing file).
    let status = gate.evaluate(None, now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Missing);
    assert!(
        status.requires_reduce_only(),
        "missing cert must require ReduceOnly"
    );

    // Empty string (unparseable).
    let status = gate.evaluate(Some(""), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Missing);
    assert!(status.requires_reduce_only());

    // Garbage JSON (unparseable).
    let status = gate.evaluate(Some("{not valid json}"), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Missing);
    assert!(status.requires_reduce_only());
}

// ─── Acceptance test 2: F1_CERT.contract_version != runtime → ReduceOnly ─────

#[test]
fn test_at_020_contract_version_mismatch_returns_reduce_only() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    // Contract version mismatch: cert has "5.1", runtime has "5.2".
    let cert_json = valid_cert_json(
        "PASS",
        now_ms - 100,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        "5.1",
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Invalid);
    assert!(
        status.requires_reduce_only(),
        "AT-020: contract_version mismatch must require ReduceOnly"
    );
}

// ─── Acceptance test 3: F1_CERT.build_id != runtime → ReduceOnly ─────────────

#[test]
fn test_f1_cert_build_id_mismatch_returns_reduce_only() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    let cert_json = valid_cert_json(
        "PASS",
        now_ms - 100,
        "other-build-999",
        RUNTIME_CONFIG_HASH,
        RUNTIME_CONTRACT_VERSION,
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Invalid);
    assert!(
        status.requires_reduce_only(),
        "build_id mismatch must require ReduceOnly"
    );
}

// ─── Acceptance test 4: F1_CERT.runtime_config_hash != runtime → ReduceOnly ──

#[test]
fn test_f1_cert_runtime_config_hash_mismatch_returns_reduce_only() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    let cert_json = valid_cert_json(
        "PASS",
        now_ms - 100,
        RUNTIME_BUILD_ID,
        "deadbeef00000000deadbeef00000000deadbeef00000000deadbeef00000000",
        RUNTIME_CONTRACT_VERSION,
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Invalid);
    assert!(
        status.requires_reduce_only(),
        "runtime_config_hash mismatch must require ReduceOnly"
    );
}

// ─── Acceptance test 5: F1_CERT stale → ReduceOnly, no last-known-good ────────

#[test]
fn test_at_021_stale_cert_returns_reduce_only_no_bypass() {
    let mut gate = F1Gate::new();
    let cfg = F1GateConfig {
        f1_cert_freshness_window_s: 86_400,
        ..F1GateConfig::default()
    };
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    // First, cert is valid (fresh).
    let cert_json = valid_cert_json(
        "PASS",
        now_ms - 100,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        RUNTIME_CONTRACT_VERSION,
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(
        status,
        F1CertStatus::Valid,
        "cert should be valid when fresh"
    );

    // Now cert becomes stale: generated_ts_ms = now_ms - 25h (> 24h freshness window).
    let stale_generated_ts_ms = now_ms - (25 * 3600 * 1000);
    let stale_cert_json = valid_cert_json(
        "PASS",
        stale_generated_ts_ms,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        RUNTIME_CONTRACT_VERSION,
    );
    let status = gate.evaluate(Some(&stale_cert_json), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Stale);
    assert!(
        status.requires_reduce_only(),
        "AT-021: stale cert must require ReduceOnly with no bypass"
    );
}

// ─── Acceptance test 6: contract_version with 'v' prefix → reject (AT-012) ───

#[test]
fn test_at_012_v_prefix_contract_version_rejected() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    // Runtime uses "5.2" (no prefix).
    let rt = F1RuntimeBindings {
        contract_version: "5.2".to_string(),
        build_id: RUNTIME_BUILD_ID.to_string(),
        runtime_config_hash: RUNTIME_CONFIG_HASH.to_string(),
    };
    let now_ms = 1_000_000_000u64;

    // Cert has "v5.2" — must be rejected (AT-012: numeric-only, no 'v' prefix).
    let cert_json = valid_cert_json(
        "PASS",
        now_ms - 100,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        "v5.2",
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Invalid);
    assert!(
        status.requires_reduce_only(),
        "AT-012: 'v' prefix in contract_version must cause ReduceOnly"
    );

    // Verify the positive case: "5.2" without prefix passes (AT-012 expected pass).
    let cert_json_ok = valid_cert_json(
        "PASS",
        now_ms - 100,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        "5.2",
    );
    let status_ok = gate.evaluate(Some(&cert_json_ok), now_ms, &cfg, &rt);
    assert_eq!(
        status_ok,
        F1CertStatus::Valid,
        "AT-012: '5.2' without prefix must be Valid"
    );
}

// ─── AT-113: canonical_json_bytes ordering invariant ─────────────────────────

#[test]
fn test_at_113_canonical_json_identical_for_key_order_variants() {
    // Two JSON objects with same content but different key order → same hash.
    let obj1 = JsonValue::Object(vec![
        ("z_key".to_string(), JsonValue::Int(1)),
        ("a_key".to_string(), JsonValue::Str("hello".to_string())),
        ("m_key".to_string(), JsonValue::Bool(true)),
    ]);
    let obj2 = JsonValue::Object(vec![
        ("a_key".to_string(), JsonValue::Str("hello".to_string())),
        ("m_key".to_string(), JsonValue::Bool(true)),
        ("z_key".to_string(), JsonValue::Int(1)),
    ]);

    let bytes1 = canonical_json_bytes(&obj1);
    let bytes2 = canonical_json_bytes(&obj2);
    assert_eq!(
        bytes1, bytes2,
        "AT-113: same content, different key order must produce identical canonical bytes"
    );

    let hash1 = compute_runtime_config_hash(&obj1);
    let hash2 = compute_runtime_config_hash(&obj2);
    assert_eq!(
        hash1, hash2,
        "AT-113: same content, different key order must produce identical runtime_config_hash"
    );
}

// ─── Valid cert → Valid status ────────────────────────────────────────────────

#[test]
fn test_f1_cert_valid_returns_valid() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    let cert_json = valid_cert_json(
        "PASS",
        now_ms - 100,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        RUNTIME_CONTRACT_VERSION,
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Valid);
    assert!(
        !status.requires_reduce_only(),
        "valid cert must not require ReduceOnly"
    );
}

// ─── F1_CERT status=FAIL → Fail (ReduceOnly) ─────────────────────────────────

#[test]
fn test_f1_cert_fail_status_returns_reduce_only() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    let cert_json = valid_cert_json(
        "FAIL",
        now_ms - 100,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        RUNTIME_CONTRACT_VERSION,
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(status, F1CertStatus::Fail);
    assert!(
        status.requires_reduce_only(),
        "FAIL cert must require ReduceOnly"
    );
}

// ─── Observability: f1_cert_age_s gauge ───────────────────────────────────────

#[test]
fn test_f1_cert_age_s_gauge_updated() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;
    let age_ms = 3600 * 1_000u64; // 1 hour
    let generated_ts_ms = now_ms - age_ms;

    let cert_json = valid_cert_json(
        "PASS",
        generated_ts_ms,
        RUNTIME_BUILD_ID,
        RUNTIME_CONFIG_HASH,
        RUNTIME_CONTRACT_VERSION,
    );
    gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(
        gate.f1_cert_age_s, 3600,
        "f1_cert_age_s must reflect cert age in seconds"
    );
}

// ─── Observability: f1_cert_gate_block_opens_total counter ───────────────────

#[test]
fn test_f1_cert_gate_block_opens_total_counter() {
    let mut gate = F1Gate::new();
    assert_eq!(gate.f1_cert_gate_block_opens_total, 0);
    gate.record_blocked_open();
    gate.record_blocked_open();
    gate.record_blocked_open();
    assert_eq!(
        gate.f1_cert_gate_block_opens_total, 3,
        "f1_cert_gate_block_opens_total must increment per blocked open"
    );
}

// ─── SHA-256 correctness: known vector ───────────────────────────────────────

#[test]
fn test_sha256_known_vector() {
    // SHA-256("") known NIST vector.
    let digest = sha256(b"");
    let hex = hex_encode(&digest);
    assert_eq!(
        hex,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );

    // SHA-256("abc") known NIST vector.
    let digest2 = sha256(b"abc");
    let hex2 = hex_encode(&digest2);
    assert_eq!(
        hex2,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

// ─── policy_hash_at_cert_time is NOT used as a gate (AT-410) ─────────────────

#[test]
fn test_at_410_policy_hash_not_used_as_gate() {
    let mut gate = F1Gate::new();
    let cfg = default_config();
    let rt = runtime_bindings();
    let now_ms = 1_000_000_000u64;

    // Cert includes policy_hash_at_cert_time field (extra key) — must be ignored.
    let cert_json = format!(
        r#"{{"status":"PASS","generated_ts_ms":{now_ms},"build_id":"{RUNTIME_BUILD_ID}","runtime_config_hash":"{RUNTIME_CONFIG_HASH}","contract_version":"{RUNTIME_CONTRACT_VERSION}","policy_hash_at_cert_time":"some-different-hash"}}"#,
        now_ms = now_ms - 100,
    );
    let status = gate.evaluate(Some(&cert_json), now_ms, &cfg, &rt);
    assert_eq!(
        status,
        F1CertStatus::Valid,
        "AT-410: policy_hash_at_cert_time must be ignored; cert still valid"
    );
    assert!(!status.requires_reduce_only());
}
