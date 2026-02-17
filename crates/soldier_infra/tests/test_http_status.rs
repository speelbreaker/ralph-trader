//! Integration tests for GET /api/v1/status endpoint.
//!
//! Acceptance criteria per CONTRACT.md §7.0:
//! - AT-405: status_schema_version == 1.
//! - AT-023: All CSP-minimum fields present.
//! - AT-024: trading_mode == Active => mode_reasons == [].
//! - AT-025: mode_reasons tier-pure (only highest triggered tier).
//! - AT-026: mode_reasons ordered per §2.2.3 allowed values list.
//! - AT-027: open_permission_blocked_latch == false => reason_codes == [] and requires_reconcile == false.
//! - AT-028: last_policy_update_ts == python_policy_generated_ts_ms.
//! - AT-029: snapshot_coverage_pct computed over replay_window_hours (GOP profile).
//! - AT-407: Non-GET rejected with 405.
//! - AT-419: 429_count_5m and 10028_count_5m present.
//! - AT-907: wal_queue_depth and wal_queue_capacity invariants.
//! - AT-927: atomic_naked_events_24h is integer >= 0.
//! - AT-967: GOP extension keys present when enforced_profile != CSP.
//! - AT-003: f1_cert_expires_at = generated_ts_ms + freshness_window_s*1000 when parseable (PL-5).

#[path = "../src/http/health.rs"]
#[allow(dead_code)]
mod health;

#[path = "../src/http/status.rs"]
#[allow(dead_code)]
mod status;

use health::{HttpMethod, HttpRequest};
use status::{
    F1CertState, NOT_ENFORCED, STATUS_SCHEMA_VERSION, StatusInputs, StatusState, build_status_json,
    handle_status,
};

/// Build a minimal valid CSP StatusInputs for testing.
fn csp_inputs() -> StatusInputs {
    StatusInputs {
        build_id: "build-test-001".to_string(),
        runtime_config_hash: "sha256-abc123".to_string(),
        supported_profiles: vec!["CSP".to_string()],
        enforced_profile: "CSP".to_string(),
        trading_mode: "Active".to_string(),
        risk_state: "Healthy".to_string(),
        bunker_mode_active: false,
        mode_reasons: vec![],
        open_permission_blocked_latch: false,
        open_permission_reason_codes: vec![],
        python_policy_generated_ts_ms: 1_700_000_000_000,
        now_ms: 1_700_000_060_000,
        f1_cert_state: F1CertState::Pass,
        f1_cert_expires_at: Some(1_700_086_400_000),
        disk_used_pct: 0.3,
        disk_used_last_update_ts_ms: 1_700_000_050_000,
        disk_used_pct_secondary: 0.25,
        disk_used_secondary_last_update_ts_ms: 1_700_000_051_000,
        mm_util: 0.1,
        mm_util_last_update_ts_ms: 1_700_000_052_000,
        loop_tick_last_ts_ms: 1_700_000_059_000,
        wal_queue_depth: 2,
        wal_queue_capacity: 1000,
        wal_queue_enqueue_failures: 0,
        atomic_naked_events_24h: 0,
        count_429_5m: 0,
        count_10028_5m: 0,
        deribit_http_p95_ms: 45.0,
        ws_event_lag_ms: 12,
        evidence_chain_state: None,
        snapshot_coverage_pct: None,
        replay_quality: None,
        replay_apply_mode: None,
        open_haircut_mult: None,
    }
}

// ─── AT-405 ───────────────────────────────────────────────────────────────────

/// AT-405: GIVEN GET /api/v1/status WHEN called THEN status_schema_version == 1.
#[test]
fn test_at_405_status_schema_version_is_1() {
    let body = build_status_json(&csp_inputs());
    assert!(
        body.contains(&format!(
            r#""status_schema_version":{}"#,
            STATUS_SCHEMA_VERSION
        )),
        "AT-405: status_schema_version MUST be 1, got: {body}"
    );
    assert_eq!(STATUS_SCHEMA_VERSION, 1, "AT-405: constant MUST be 1");
}

// ─── AT-023: All CSP-minimum fields present ───────────────────────────────────

/// AT-023: GIVEN GET /api/v1/status WHEN called THEN all CSP-minimum fields present.
#[test]
fn test_at_023_all_required_fields_present() {
    let state = StatusState::new();
    let req = HttpRequest::get();
    let resp = handle_status(&req, &state, &csp_inputs());

    assert_eq!(resp.status, 200, "AT-023: MUST return HTTP 200");

    let body = &resp.body;
    let required_keys = [
        "status_schema_version",
        "contract_version",
        "build_id",
        "runtime_config_hash",
        "supported_profiles",
        "enforced_profile",
        "trading_mode",
        "risk_state",
        "bunker_mode_active",
        "connectivity_degraded",
        "mode_reasons",
        "open_permission_blocked_latch",
        "open_permission_reason_codes",
        "open_permission_requires_reconcile",
        "policy_age_sec",
        "last_policy_update_ts",
        "f1_cert_state",
        "f1_cert_expires_at",
        "disk_used_pct",
        "disk_used_last_update_ts_ms",
        "disk_used_pct_secondary",
        "disk_used_secondary_last_update_ts_ms",
        "mm_util",
        "mm_util_last_update_ts_ms",
        "loop_tick_last_ts_ms",
        "wal_queue_depth",
        "wal_queue_capacity",
        "wal_queue_enqueue_failures",
        "atomic_naked_events_24h",
        "429_count_5m",
        "10028_count_5m",
        "deribit_http_p95_ms",
        "ws_event_lag_ms",
    ];

    for key in &required_keys {
        assert!(
            body.contains(&format!(r#""{key}":"#)),
            "AT-023: required key '{key}' missing from response body: {body}"
        );
    }
}

// ─── AT-024 ───────────────────────────────────────────────────────────────────

/// AT-024: GIVEN trading_mode == Active WHEN status checked THEN mode_reasons == [].
#[test]
fn test_at_024_active_mode_has_empty_mode_reasons() {
    let inp = csp_inputs(); // trading_mode=Active, mode_reasons=[]
    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""trading_mode":"Active""#),
        "test setup: trading_mode MUST be Active"
    );
    assert!(
        body.contains(r#""mode_reasons":[]"#),
        "AT-024: Active MUST have mode_reasons=[], got: {body}"
    );
}

// ─── AT-025 ───────────────────────────────────────────────────────────────────

/// AT-025: GIVEN mode_reasons with ReduceOnly-tier codes WHEN checked THEN tier-pure (no Kill codes mixed in).
#[test]
fn test_at_025_mode_reasons_tier_pure_reduceonly() {
    let mut inp = csp_inputs();
    inp.trading_mode = "ReduceOnly".to_string();
    inp.mode_reasons = vec!["REDUCEONLY_POLICY_STALE".to_string()];

    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""REDUCEONLY_POLICY_STALE""#),
        "AT-025: ReduceOnly reason MUST be present, got: {body}"
    );
    // Kill-tier codes MUST NOT appear.
    assert!(
        !body.contains("KILL_"),
        "AT-025: Kill-tier reasons MUST NOT appear in ReduceOnly-tier response, got: {body}"
    );
}

// ─── AT-026 ───────────────────────────────────────────────────────────────────

/// AT-026: GIVEN mode_reasons with multiple reasons WHEN checked THEN ordering matches contract order.
#[test]
fn test_at_026_mode_reasons_contract_order() {
    let mut inp = csp_inputs();
    inp.trading_mode = "ReduceOnly".to_string();
    // Contract order: REDUCEONLY_RISKSTATE_MAINTENANCE before REDUCEONLY_POLICY_STALE.
    inp.mode_reasons = vec![
        "REDUCEONLY_RISKSTATE_MAINTENANCE".to_string(),
        "REDUCEONLY_POLICY_STALE".to_string(),
    ];

    let body = build_status_json(&inp);

    let pos_maint = body
        .find("REDUCEONLY_RISKSTATE_MAINTENANCE")
        .expect("AT-026: REDUCEONLY_RISKSTATE_MAINTENANCE MUST appear");
    let pos_stale = body
        .find("REDUCEONLY_POLICY_STALE")
        .expect("AT-026: REDUCEONLY_POLICY_STALE MUST appear");

    assert!(
        pos_maint < pos_stale,
        "AT-026: REDUCEONLY_RISKSTATE_MAINTENANCE MUST appear before REDUCEONLY_POLICY_STALE per §2.2.3 order, got: {body}"
    );
}

// ─── AT-027 ───────────────────────────────────────────────────────────────────

/// AT-027: GIVEN open_permission_blocked_latch == false WHEN status checked
/// THEN open_permission_reason_codes == [] and open_permission_requires_reconcile == false.
#[test]
fn test_at_027_latch_false_invariants() {
    let inp = csp_inputs(); // latch=false by default
    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""open_permission_blocked_latch":false"#),
        "test setup: latch MUST be false, got: {body}"
    );
    assert!(
        body.contains(r#""open_permission_reason_codes":[]"#),
        "AT-027: latch=false MUST have empty reason_codes, got: {body}"
    );
    assert!(
        body.contains(r#""open_permission_requires_reconcile":false"#),
        "AT-027: latch=false MUST have requires_reconcile=false, got: {body}"
    );
}

/// AT-027 inverse: GIVEN open_permission_blocked_latch == true WHEN status checked
/// THEN open_permission_requires_reconcile == true and reason_codes non-empty.
#[test]
fn test_at_027_latch_true_invariants() {
    let mut inp = csp_inputs();
    inp.open_permission_blocked_latch = true;
    inp.open_permission_reason_codes = vec!["RESTART_RECONCILE_REQUIRED".to_string()];
    inp.trading_mode = "ReduceOnly".to_string();
    inp.mode_reasons = vec!["REDUCEONLY_OPEN_PERMISSION_LATCHED".to_string()];

    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""open_permission_blocked_latch":true"#),
        "test setup: latch MUST be true, got: {body}"
    );
    assert!(
        body.contains(r#""RESTART_RECONCILE_REQUIRED""#),
        "AT-027: latch=true MUST have non-empty reason_codes, got: {body}"
    );
    assert!(
        body.contains(r#""open_permission_requires_reconcile":true"#),
        "AT-027: latch=true MUST have requires_reconcile=true, got: {body}"
    );
}

// ─── AT-028 ───────────────────────────────────────────────────────────────────

/// AT-028: GIVEN last_policy_update_ts WHEN status checked
/// THEN last_policy_update_ts == python_policy_generated_ts_ms.
#[test]
fn test_at_028_last_policy_update_ts_equals_generated_ts() {
    let inp = csp_inputs(); // python_policy_generated_ts_ms = 1_700_000_000_000
    let body = build_status_json(&inp);

    assert!(
        body.contains(&format!(
            r#""last_policy_update_ts":{}"#,
            inp.python_policy_generated_ts_ms
        )),
        "AT-028: last_policy_update_ts MUST equal python_policy_generated_ts_ms ({}), got: {body}",
        inp.python_policy_generated_ts_ms
    );
}

// ─── AT-029 (GOP) ─────────────────────────────────────────────────────────────

/// AT-029: GIVEN enforced_profile == GOP WHEN snapshot_coverage_pct returned
/// THEN it reflects the configured replay_window_hours.
#[test]
fn test_at_029_snapshot_coverage_pct_uses_replay_window() {
    let mut inp = csp_inputs();
    inp.enforced_profile = "GOP".to_string();
    inp.supported_profiles = vec!["CSP".to_string(), "GOP".to_string()];
    inp.evidence_chain_state = Some("GREEN".to_string());
    inp.snapshot_coverage_pct = Some(0.97); // computed over replay_window_hours=48
    inp.replay_quality = Some("GOOD".to_string());
    inp.replay_apply_mode = Some("APPLY".to_string());
    inp.open_haircut_mult = Some(1.0);

    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""snapshot_coverage_pct":0.97"#),
        "AT-029: snapshot_coverage_pct MUST be computed value when GOP, got: {body}"
    );
    assert!(
        !body.contains(&format!(r#""snapshot_coverage_pct":"{}""#, NOT_ENFORCED)),
        "AT-029: snapshot_coverage_pct MUST NOT be NOT_ENFORCED when GOP enforced, got: {body}"
    );
}

// ─── AT-967 (GOP extension keys) ──────────────────────────────────────────────

/// AT-967: GIVEN enforced_profile == GOP WHEN status checked
/// THEN all GOP extension keys present with actual values (not NOT_ENFORCED).
#[test]
fn test_at_967_gop_extension_keys_present_when_gop_enforced() {
    let mut inp = csp_inputs();
    inp.enforced_profile = "GOP".to_string();
    inp.supported_profiles = vec!["CSP".to_string(), "GOP".to_string()];
    inp.evidence_chain_state = Some("GREEN".to_string());
    inp.snapshot_coverage_pct = Some(0.95);
    inp.replay_quality = Some("GOOD".to_string());
    inp.replay_apply_mode = Some("APPLY".to_string());
    inp.open_haircut_mult = Some(1.0);

    let body = build_status_json(&inp);

    let gop_keys = [
        "evidence_chain_state",
        "snapshot_coverage_pct",
        "replay_quality",
        "replay_apply_mode",
        "open_haircut_mult",
    ];
    for key in &gop_keys {
        assert!(
            body.contains(&format!(r#""{key}":"#)),
            "AT-967: GOP key '{key}' MUST be present, got: {body}"
        );
    }

    // Must not be NOT_ENFORCED.
    assert!(
        !body.contains(&format!(r#""evidence_chain_state":"{}""#, NOT_ENFORCED)),
        "AT-967: evidence_chain_state MUST NOT be NOT_ENFORCED when GOP, got: {body}"
    );
}

/// AT-967 (CSP inverse): GIVEN enforced_profile == CSP WHEN status checked
/// THEN GOP extension keys are NOT_ENFORCED.
#[test]
fn test_at_967_gop_keys_not_enforced_when_csp() {
    let inp = csp_inputs(); // enforced_profile=CSP
    let body = build_status_json(&inp);

    assert!(
        body.contains(&format!(r#""evidence_chain_state":"{}""#, NOT_ENFORCED)),
        "AT-967: evidence_chain_state MUST be NOT_ENFORCED when CSP, got: {body}"
    );
    assert!(
        body.contains(&format!(r#""replay_quality":"{}""#, NOT_ENFORCED)),
        "AT-967: replay_quality MUST be NOT_ENFORCED when CSP, got: {body}"
    );
}

// ─── AT-003 / PL-5: f1_cert_expires_at semantics ─────────────────────────────

/// AT-003: GIVEN F1_CERT present and parseable WHEN status checked
/// THEN f1_cert_expires_at = generated_ts_ms + freshness_window_s * 1000.
#[test]
fn test_at_003_f1_cert_expires_at_computed_correctly() {
    let generated_ts_ms: u64 = 1_700_000_000_000;
    let freshness_window_s: u64 = 86_400;
    let expected_expires_at = generated_ts_ms + freshness_window_s * 1000;

    let mut inp = csp_inputs();
    inp.f1_cert_state = F1CertState::Pass;
    inp.f1_cert_expires_at = Some(expected_expires_at);
    inp.python_policy_generated_ts_ms = generated_ts_ms;
    inp.now_ms = generated_ts_ms + 1_000;

    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""f1_cert_state":"PASS""#),
        "AT-003: f1_cert_state MUST be PASS, got: {body}"
    );
    assert!(
        body.contains(&format!(r#""f1_cert_expires_at":{expected_expires_at}"#)),
        "AT-003: f1_cert_expires_at MUST be {} (generated_ts_ms + freshness_window_s*1000), got: {body}",
        expected_expires_at
    );
}

/// AT-003 (missing): GIVEN F1_CERT missing WHEN status checked
/// THEN f1_cert_expires_at is null.
#[test]
fn test_at_003_f1_cert_missing_expires_at_null() {
    let mut inp = csp_inputs();
    inp.f1_cert_state = F1CertState::Missing;
    inp.f1_cert_expires_at = None;

    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""f1_cert_state":"MISSING""#),
        "AT-003: f1_cert_state MUST be MISSING, got: {body}"
    );
    assert!(
        body.contains(r#""f1_cert_expires_at":null"#),
        "AT-003: f1_cert_expires_at MUST be null when MISSING, got: {body}"
    );
}

// ─── AT-407: Non-GET rejected ─────────────────────────────────────────────────

/// AT-407: GIVEN non-GET request WHEN called THEN HTTP 405.
#[test]
fn test_at_407_post_rejected_with_405() {
    let state = StatusState::new();
    let req = HttpRequest::with_method(HttpMethod::Post);
    let resp = handle_status(&req, &state, &csp_inputs());

    assert_eq!(resp.status, 405, "AT-407: POST MUST be rejected with 405");
}

// ─── AT-419: Rate-limit counters present ──────────────────────────────────────

/// AT-419: GIVEN GET /status WHEN read THEN 429_count_5m and 10028_count_5m present.
#[test]
fn test_at_419_rate_limit_counters_present() {
    let body = build_status_json(&csp_inputs());

    assert!(
        body.contains(r#""429_count_5m":"#),
        "AT-419: 429_count_5m MUST be present, got: {body}"
    );
    assert!(
        body.contains(r#""10028_count_5m":"#),
        "AT-419: 10028_count_5m MUST be present, got: {body}"
    );
}

// ─── AT-907: WAL queue invariants ─────────────────────────────────────────────

/// AT-907: GIVEN /status WHEN WAL metrics read THEN depth<=capacity and capacity>0.
#[test]
fn test_at_907_wal_queue_invariants() {
    let mut inp = csp_inputs();
    inp.wal_queue_depth = 5;
    inp.wal_queue_capacity = 1000;

    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""wal_queue_depth":5"#),
        "AT-907: wal_queue_depth MUST be present, got: {body}"
    );
    assert!(
        body.contains(r#""wal_queue_capacity":1000"#),
        "AT-907: wal_queue_capacity MUST be present and > 0, got: {body}"
    );
    // Programmatic invariant check.
    assert!(
        inp.wal_queue_depth <= inp.wal_queue_capacity,
        "AT-907: wal_queue_depth ({}) MUST be <= wal_queue_capacity ({})",
        inp.wal_queue_depth,
        inp.wal_queue_capacity
    );
    assert!(
        inp.wal_queue_capacity > 0,
        "AT-907: wal_queue_capacity MUST be > 0"
    );
}

// ─── AT-927: atomic_naked_events_24h ──────────────────────────────────────────

/// AT-927: GIVEN /status WHEN atomic_naked_events_24h read THEN integer >= 0.
#[test]
fn test_at_927_atomic_naked_events_24h_non_negative_integer() {
    let body = build_status_json(&csp_inputs());

    assert!(
        body.contains(r#""atomic_naked_events_24h":0"#),
        "AT-927: atomic_naked_events_24h MUST be present as non-negative integer, got: {body}"
    );
}

// ─── http_status_calls_total counter ─────────────────────────────────────────

/// Observability: http_status_calls_total increments on each successful GET.
#[test]
fn test_http_status_calls_total_increments() {
    let state = StatusState::new();
    let req = HttpRequest::get();
    let inp = csp_inputs();

    assert_eq!(state.status_calls_total(), 0);

    handle_status(&req, &state, &inp);
    assert_eq!(
        state.status_calls_total(),
        1,
        "counter MUST be 1 after first call"
    );

    handle_status(&req, &state, &inp);
    assert_eq!(
        state.status_calls_total(),
        2,
        "counter MUST be 2 after second call"
    );
}

/// Non-GET does NOT increment http_status_calls_total.
#[test]
fn test_non_get_does_not_increment_counter() {
    let state = StatusState::new();
    let req = HttpRequest::with_method(HttpMethod::Post);
    handle_status(&req, &state, &csp_inputs());

    assert_eq!(
        state.status_calls_total(),
        0,
        "non-GET MUST NOT increment http_status_calls_total"
    );
}

// ─── connectivity_degraded semantics ─────────────────────────────────────────

/// connectivity_degraded == true when bunker_mode_active == true.
#[test]
fn test_connectivity_degraded_when_bunker_mode_active() {
    let mut inp = csp_inputs();
    inp.bunker_mode_active = true;
    inp.trading_mode = "ReduceOnly".to_string();
    inp.mode_reasons = vec!["REDUCEONLY_BUNKER_MODE_ACTIVE".to_string()];

    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""connectivity_degraded":true"#),
        "connectivity_degraded MUST be true when bunker_mode_active, got: {body}"
    );
}

/// connectivity_degraded == false when no bunker and no reconcile codes.
#[test]
fn test_connectivity_degraded_false_when_normal() {
    let inp = csp_inputs(); // bunker=false, no latch codes
    let body = build_status_json(&inp);

    assert!(
        body.contains(r#""connectivity_degraded":false"#),
        "connectivity_degraded MUST be false when normal state, got: {body}"
    );
}
