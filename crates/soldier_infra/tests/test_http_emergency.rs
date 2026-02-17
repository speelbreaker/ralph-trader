//! Integration tests for POST /api/v1/emergency/reduce_only endpoint.
//!
//! Acceptance criteria per CONTRACT.md §2.2 and §3.2:
//! - GIVEN POST /api/v1/emergency/reduce_only WHEN called THEN set emergency_reduceonly_until_ts_ms.
//! - GIVEN emergency_reduceonly_active WHEN evaluated THEN cancel reduce_only==false orders, preserve closes/hedges.
//! - GIVEN emergency_reduceonly_active AND exposure > limit WHEN evaluated THEN submit reduce-only hedge.
//! - GIVEN ws_silence_ms > 5000 WHEN watchdog checked THEN invoke same emergency_reduceonly handler.
//! - GIVEN cooldown expired AND reconcile confirms safe WHEN evaluated THEN clear emergency_reduceonly_active.
//!
//! AT-237: network hiccup mid-hedge → watchdog triggers → hedge stays alive.
//! AT-203: emergency_reduceonly_active → only reduce_only==false orders canceled; reduce-only orders preserved.

#[path = "../../soldier_core/src/policy/watchdog.rs"]
mod watchdog;

use watchdog::{
    EMERGENCY_REDUCEONLY_COOLDOWN_S, EmergencyReduceOnlyState, HttpMethod, HttpRequest, Order,
    WS_SILENCE_TRIGGER_MS, check_watchdog, evaluate_emergency_reduceonly,
    handle_emergency_reduce_only_at, maybe_clear_emergency_reduceonly,
};

// ── Endpoint tests ──────────────────────────────────────────────────────────

/// GIVEN POST /api/v1/emergency/reduce_only WHEN called THEN set emergency_reduceonly_until_ts_ms.
#[test]
fn test_post_sets_emergency_reduceonly_until_ts_ms() {
    let state = EmergencyReduceOnlyState::new(EMERGENCY_REDUCEONLY_COOLDOWN_S);
    let req = HttpRequest::post();
    let now_ms: u64 = 1_700_000_000_000;

    assert_eq!(state.until_ts_ms(), 0, "latch must start cleared");

    let resp = handle_emergency_reduce_only_at(&req, &state, now_ms);

    assert_eq!(resp.status, 200, "POST must return 200");
    assert!(
        resp.body.contains(r#""ok":true"#),
        "body must contain ok:true, got: {}",
        resp.body
    );

    let expected_until = now_ms + EMERGENCY_REDUCEONLY_COOLDOWN_S * 1000;
    assert_eq!(
        state.until_ts_ms(),
        expected_until,
        "emergency_reduceonly_until_ts_ms must be now_ms + cooldown_ms"
    );
    assert!(
        resp.body.contains(&format!("{}", expected_until)),
        "response body must include the until timestamp, got: {}",
        resp.body
    );
}

/// GIVEN latch set WHEN is_active checked before expiry THEN returns true.
#[test]
fn test_emergency_reduceonly_active_before_expiry() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 1_000_000_000;

    state.activate(now_ms);
    let check_ms = now_ms + 100_000; // 100s later, still within 300s

    assert!(
        state.is_active(check_ms),
        "emergency_reduceonly_active must be true before cooldown expires"
    );
}

/// GIVEN latch set WHEN is_active checked after expiry THEN returns false.
#[test]
fn test_emergency_reduceonly_inactive_after_expiry() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 1_000_000_000;

    state.activate(now_ms);
    let after_ms = now_ms + 300_001; // just past 300s

    assert!(
        !state.is_active(after_ms),
        "emergency_reduceonly_active must be false after cooldown expires"
    );
}

/// Non-POST requests must be rejected with 405.
#[test]
fn test_non_post_rejected_405() {
    let state = EmergencyReduceOnlyState::new(300);
    let req = HttpRequest::with_method(HttpMethod::Get);
    let resp = handle_emergency_reduce_only_at(&req, &state, 1_000_000_000);

    assert_eq!(
        resp.status, 405,
        "GET to emergency endpoint must return 405"
    );
    assert_eq!(state.until_ts_ms(), 0, "latch must not be set on non-POST");
}

/// PUT to emergency endpoint must also return 405.
#[test]
fn test_put_rejected_405() {
    let state = EmergencyReduceOnlyState::new(300);
    let req = HttpRequest::with_method(HttpMethod::Put);
    let resp = handle_emergency_reduce_only_at(&req, &state, 1_000_000_000);

    assert_eq!(
        resp.status, 405,
        "PUT to emergency endpoint must return 405"
    );
}

/// Observability: http_emergency_reduce_only_calls_total increments on each POST.
#[test]
fn test_calls_total_counter_increments() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 1_000_000_000;

    assert_eq!(state.calls_total(), 0);

    let req = HttpRequest::post();
    handle_emergency_reduce_only_at(&req, &state, now_ms);
    assert_eq!(state.calls_total(), 1, "counter must be 1 after first call");

    handle_emergency_reduce_only_at(&req, &state, now_ms + 1000);
    assert_eq!(
        state.calls_total(),
        2,
        "counter must be 2 after second call"
    );
}

/// Non-POST does NOT increment calls_total.
#[test]
fn test_non_post_does_not_increment_counter() {
    let state = EmergencyReduceOnlyState::new(300);
    let req = HttpRequest::with_method(HttpMethod::Get);
    handle_emergency_reduce_only_at(&req, &state, 1_000_000_000);

    assert_eq!(
        state.calls_total(),
        0,
        "non-POST must not increment calls_total"
    );
}

// ── AT-203: Order cancellation / preservation tests ──────────────────────────

/// AT-203: GIVEN emergency_reduceonly_active WHEN evaluated THEN cancel reduce_only==false orders,
/// preserve closes/hedges (reduce_only==true).
#[test]
fn test_at_203_cancel_non_reduce_only_preserve_closes_hedges() {
    let orders = vec![
        Order {
            order_id: "open-1".to_string(),
            reduce_only: false,
        },
        Order {
            order_id: "hedge-1".to_string(),
            reduce_only: true,
        },
        Order {
            order_id: "open-2".to_string(),
            reduce_only: false,
        },
        Order {
            order_id: "close-1".to_string(),
            reduce_only: true,
        },
    ];

    let effect = evaluate_emergency_reduceonly(&orders, 0.0, 100.0);

    // Cancel only non-reduce-only orders.
    assert!(
        effect.cancel_orders.contains(&"open-1".to_string()),
        "open-1 (reduce_only=false) MUST be canceled"
    );
    assert!(
        effect.cancel_orders.contains(&"open-2".to_string()),
        "open-2 (reduce_only=false) MUST be canceled"
    );
    assert_eq!(
        effect.cancel_orders.len(),
        2,
        "exactly 2 orders must be canceled"
    );

    // Preserve reduce-only orders.
    assert!(
        effect.preserve_orders.contains(&"hedge-1".to_string()),
        "hedge-1 (reduce_only=true) MUST be preserved (AT-203)"
    );
    assert!(
        effect.preserve_orders.contains(&"close-1".to_string()),
        "close-1 (reduce_only=true) MUST be preserved (AT-203)"
    );
    assert_eq!(
        effect.preserve_orders.len(),
        2,
        "exactly 2 orders must be preserved"
    );
}

/// AT-203: All-reduce-only orders — nothing canceled.
#[test]
fn test_at_203_all_reduce_only_nothing_canceled() {
    let orders = vec![
        Order {
            order_id: "hedge-a".to_string(),
            reduce_only: true,
        },
        Order {
            order_id: "close-b".to_string(),
            reduce_only: true,
        },
    ];

    let effect = evaluate_emergency_reduceonly(&orders, 0.0, 100.0);

    assert!(
        effect.cancel_orders.is_empty(),
        "no orders canceled when all are reduce-only"
    );
    assert_eq!(effect.preserve_orders.len(), 2);
}

/// GIVEN emergency_reduceonly_active AND exposure > limit THEN submit reduce-only hedge.
#[test]
fn test_exposure_over_limit_triggers_hedge() {
    let orders: Vec<Order> = vec![];
    let effect = evaluate_emergency_reduceonly(&orders, 150.0, 100.0);

    assert!(
        effect.submit_hedge,
        "submit_hedge must be true when exposure_notional > exposure_limit"
    );
}

/// GIVEN exposure <= limit THEN no hedge submitted.
#[test]
fn test_exposure_within_limit_no_hedge() {
    let orders: Vec<Order> = vec![];
    let effect = evaluate_emergency_reduceonly(&orders, 50.0, 100.0);

    assert!(
        !effect.submit_hedge,
        "submit_hedge must be false when exposure_notional <= exposure_limit"
    );
}

// ── AT-237: Smart Watchdog tests ─────────────────────────────────────────────

/// GIVEN ws_silence_ms > 5000 WHEN watchdog checked THEN invoke emergency_reduceonly handler.
#[test]
fn test_at_237_watchdog_triggers_on_silence_over_5000ms() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 2_000_000_000;

    let triggered = check_watchdog(WS_SILENCE_TRIGGER_MS + 1, &state, now_ms);

    assert!(
        triggered,
        "watchdog must trigger on ws_silence_ms > {WS_SILENCE_TRIGGER_MS}"
    );
    assert!(
        state.is_active(now_ms + 1),
        "emergency_reduceonly_active must be true after watchdog triggers"
    );
    let expected_until = now_ms + 300 * 1000;
    assert_eq!(
        state.until_ts_ms(),
        expected_until,
        "watchdog must set until_ts_ms = now_ms + cooldown"
    );
}

/// GIVEN ws_silence_ms == 5000 (exactly at threshold) WHEN checked THEN does NOT trigger.
#[test]
fn test_watchdog_does_not_trigger_at_exactly_5000ms() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 2_000_000_000;

    let triggered = check_watchdog(WS_SILENCE_TRIGGER_MS, &state, now_ms);

    assert!(
        !triggered,
        "watchdog must NOT trigger at exactly {WS_SILENCE_TRIGGER_MS}ms (requires strictly > 5000)"
    );
    assert_eq!(state.until_ts_ms(), 0, "latch must not be set");
}

/// AT-237: Watchdog preserves reduce-only hedge alive (integration: watchdog triggers → hedge in preserve list).
#[test]
fn test_at_237_watchdog_triggered_hedge_preserved() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 2_000_000_000;

    // Simulate watchdog trigger.
    let triggered = check_watchdog(6000, &state, now_ms);
    assert!(triggered, "watchdog must trigger on 6000ms silence");

    // Orders include a hedge order with reduce_only=true.
    let orders = vec![
        Order {
            order_id: "open-x".to_string(),
            reduce_only: false,
        },
        Order {
            order_id: "hedge-y".to_string(),
            reduce_only: true,
        },
    ];

    let effect = evaluate_emergency_reduceonly(&orders, 0.0, 100.0);

    assert!(
        effect.preserve_orders.contains(&"hedge-y".to_string()),
        "AT-237: hedge must stay alive after watchdog triggers"
    );
    assert!(
        effect.cancel_orders.contains(&"open-x".to_string()),
        "non-reduce-only open must be canceled"
    );
}

// ── Cooldown / reconcile tests ────────────────────────────────────────────────

/// GIVEN cooldown expired AND reconcile confirms safe WHEN evaluated THEN clear latch.
#[test]
fn test_cooldown_expired_reconcile_safe_clears_latch() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 1_000_000_000;

    state.activate(now_ms);

    // Just after cooldown expires.
    let after_ms = now_ms + 300_001;
    maybe_clear_emergency_reduceonly(&state, after_ms, true);

    assert_eq!(
        state.until_ts_ms(),
        0,
        "latch must be cleared when cooldown expired and reconcile_safe=true"
    );
    assert!(
        !state.is_active(after_ms),
        "emergency_reduceonly_active must be false after latch cleared"
    );
}

/// GIVEN cooldown expired BUT reconcile NOT safe THEN latch NOT cleared.
#[test]
fn test_cooldown_expired_reconcile_not_safe_does_not_clear() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 1_000_000_000;

    state.activate(now_ms);
    let after_ms = now_ms + 300_001;
    maybe_clear_emergency_reduceonly(&state, after_ms, false);

    // Until is non-zero but is_active depends on now_ms vs until.
    // Since now_ms >= until, is_active returns false regardless of clear.
    // The key check: until_ts_ms is NOT 0 (latch still set for state tracking).
    assert_ne!(
        state.until_ts_ms(),
        0,
        "latch must NOT be cleared when reconcile_safe=false"
    );
}

/// GIVEN cooldown NOT yet expired THEN latch not cleared even if reconcile_safe.
#[test]
fn test_cooldown_not_expired_does_not_clear() {
    let state = EmergencyReduceOnlyState::new(300);
    let now_ms: u64 = 1_000_000_000;

    state.activate(now_ms);
    let mid_ms = now_ms + 100_000; // 100s < 300s cooldown
    maybe_clear_emergency_reduceonly(&state, mid_ms, true);

    let expected_until = now_ms + 300 * 1000;
    assert_eq!(
        state.until_ts_ms(),
        expected_until,
        "latch must not be cleared before cooldown expires"
    );
    assert!(
        state.is_active(mid_ms),
        "emergency_reduceonly_active must still be true during cooldown"
    );
}
