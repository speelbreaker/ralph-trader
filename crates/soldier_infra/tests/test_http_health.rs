//! Integration tests for GET /api/v1/health endpoint.
//!
//! Acceptance criteria (AT-022, AT-407):
//! - AT-022: GET /api/v1/health → HTTP 200 JSON with ok=true, build_id, contract_version.
//! - Watchdog side-effect: watchdog_last_heartbeat_ts_ms updated = now_ms on success.
//! - AT-407: Non-GET request → rejected (405).
//!
//! Implementation is included via #[path] to avoid requiring lib.rs changes.

#[path = "../src/http/health.rs"]
mod health;

use health::{CONTRACT_VERSION, HealthState, HttpMethod, HttpRequest, handle_health};

/// AT-022: GIVEN GET /api/v1/health WHEN called THEN HTTP 200 JSON with ok=true, build_id, contract_version.
#[test]
fn test_at_022_get_health_returns_200_with_required_fields() {
    let state = HealthState::new("build-abc123");
    let req = HttpRequest::get();
    let resp = handle_health(&req, &state);

    assert_eq!(resp.status, 200, "AT-022: MUST return HTTP 200");

    // Parse the JSON body to verify required fields.
    let body = resp.body;
    assert!(
        body.contains(r#""ok":true"#),
        "AT-022: response MUST include ok=true, got: {body}"
    );
    assert!(
        body.contains(r#""build_id":"build-abc123""#),
        "AT-022: response MUST include build_id, got: {body}"
    );
    assert!(
        body.contains(&format!(r#""contract_version":"{}""#, CONTRACT_VERSION)),
        "AT-022: response MUST include contract_version={CONTRACT_VERSION}, got: {body}"
    );
}

/// AT-022: GIVEN GET /api/v1/health WHEN called THEN ok field MUST be true (not false).
#[test]
fn test_at_022_ok_is_true() {
    let state = HealthState::new("test-build");
    let req = HttpRequest::get();
    let resp = handle_health(&req, &state);

    assert_eq!(resp.status, 200, "status MUST be 200");
    assert!(
        resp.body.contains(r#""ok":true"#),
        "ok MUST be true, got: {}",
        resp.body
    );
    assert!(!resp.body.contains(r#""ok":false"#), "ok MUST NOT be false");
}

/// Watchdog side-effect: GIVEN GET /api/v1/health WHEN called THEN update watchdog_last_heartbeat_ts_ms = now_ms.
#[test]
fn test_watchdog_heartbeat_updated_on_get() {
    let state = HealthState::new("build-watch");

    // Before call: heartbeat is 0.
    assert_eq!(
        state.last_heartbeat_ts_ms(),
        0,
        "heartbeat MUST start at 0 before first call"
    );

    let before_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let req = HttpRequest::get();
    let resp = handle_health(&req, &state);
    assert_eq!(resp.status, 200);

    let after_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let heartbeat = state.last_heartbeat_ts_ms();
    assert!(
        heartbeat >= before_ms,
        "watchdog_last_heartbeat_ts_ms MUST be >= before call time ({before_ms}), got {heartbeat}"
    );
    assert!(
        heartbeat <= after_ms,
        "watchdog_last_heartbeat_ts_ms MUST be <= after call time ({after_ms}), got {heartbeat}"
    );
}

/// AT-407: GIVEN non-GET request WHEN called THEN reject with 405.
#[test]
fn test_at_407_post_rejected_with_405() {
    let state = HealthState::new("build-post-test");
    let req = HttpRequest::with_method(HttpMethod::Post);
    let resp = handle_health(&req, &state);

    assert_eq!(resp.status, 405, "AT-407: POST MUST be rejected with 405");
}

/// AT-407: PUT request must also be rejected with 405.
#[test]
fn test_at_407_put_rejected_with_405() {
    let state = HealthState::new("build-put-test");
    let req = HttpRequest::with_method(HttpMethod::Put);
    let resp = handle_health(&req, &state);

    assert_eq!(resp.status, 405, "AT-407: PUT MUST be rejected with 405");
}

/// AT-407: DELETE request must also be rejected with 405.
#[test]
fn test_at_407_delete_rejected_with_405() {
    let state = HealthState::new("build-delete-test");
    let req = HttpRequest::with_method(HttpMethod::Delete);
    let resp = handle_health(&req, &state);

    assert_eq!(resp.status, 405, "AT-407: DELETE MUST be rejected with 405");
}

/// Non-GET does NOT update watchdog_last_heartbeat_ts_ms.
#[test]
fn test_non_get_does_not_update_watchdog() {
    let state = HealthState::new("build-no-update");
    let req = HttpRequest::with_method(HttpMethod::Post);
    let _ = handle_health(&req, &state);

    assert_eq!(
        state.last_heartbeat_ts_ms(),
        0,
        "non-GET MUST NOT update watchdog_last_heartbeat_ts_ms"
    );
}

/// http_health_calls_total increments on each successful GET.
#[test]
fn test_http_health_calls_total_increments() {
    let state = HealthState::new("build-counter");

    assert_eq!(state.health_calls_total(), 0);

    let req = HttpRequest::get();
    handle_health(&req, &state);
    assert_eq!(
        state.health_calls_total(),
        1,
        "counter MUST be 1 after first call"
    );

    handle_health(&req, &state);
    assert_eq!(
        state.health_calls_total(),
        2,
        "counter MUST be 2 after second call"
    );
}

/// Non-GET does not increment http_health_calls_total.
#[test]
fn test_non_get_does_not_increment_counter() {
    let state = HealthState::new("build-no-count");
    let req = HttpRequest::with_method(HttpMethod::Post);
    handle_health(&req, &state);

    assert_eq!(
        state.health_calls_total(),
        0,
        "non-GET MUST NOT increment http_health_calls_total"
    );
}

/// CONTRACT_VERSION is "5.2" per CONTRACT.md Definitions.
#[test]
fn test_contract_version_is_5_2() {
    assert_eq!(CONTRACT_VERSION, "5.2");
}
