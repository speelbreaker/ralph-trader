//! Non-Active OPEN Cancellation tests (§2.2.3.4.1).
//!
//! Covers:
//!   AT-1065 — Non-Active OPEN cancellation bounded (cancel_open_batch_max, cancel_open_budget_ms)
//!            — cancels attempted, risk-increasing OPENs trend to zero, OPEN dispatch blocked

#[path = "../src/policy/guard.rs"]
mod guard;

use guard::{
    AxisResolver, CortexOverride, EnforcedProfile, F1CertStatus,
    PolicyEvidenceState, PolicyGuardConfig, PolicyGuardInputs, PolicyRiskState, PolicyTradingMode,
    compute_cancel_batch, is_open_intent,
};

fn clean_inputs(now_ms: u64) -> PolicyGuardInputs {
    PolicyGuardInputs {
        now_ms,
        mm_util: Some(0.50),
        mm_util_last_update_ts_ms: Some(now_ms - 1_000),
        risk_state: PolicyRiskState::Healthy,
        cortex_override: CortexOverride::None,
        bunker_mode_active: false,
        watchdog_last_heartbeat_ts_ms: Some(now_ms - 1_000),
        loop_tick_last_ts_ms: Some(now_ms - 1_000),
        disk_used_pct: Some(0.50),
        disk_used_last_update_ts_ms: Some(now_ms - 1_000),
        disk_used_pct_secondary: Some(0.50),
        disk_used_secondary_last_update_ts_ms: Some(now_ms - 1_000),
        rate_limit_session_kill_active: Some(false),
        count_10028_5m: Some(0),
        emergency_reduceonly_active: false,
        open_permission_blocked_latch: false,
        evidence_chain_state: PolicyEvidenceState::Green,
        f1_cert_status: F1CertStatus::Valid,
        fee_model_cache_age_s: None,
        policy_age_sec: 60,
        enforced_profile: EnforcedProfile::Csp,
    }
}

// ─── AT-1065: Cancel batch is bounded by cancel_open_batch_max ───────────────

#[test]
fn test_at_1065_cancel_batch_empty_when_no_open_orders() {
    let config = PolicyGuardConfig::default();
    let orders: Vec<String> = vec![];
    let batch = compute_cancel_batch(&orders, &config);
    assert!(batch.order_ids.is_empty());
    assert!(!batch.has_more);
}

#[test]
fn test_at_1065_cancel_batch_all_fit_within_max() {
    let config = PolicyGuardConfig::default(); // cancel_open_batch_max = 50
    let orders: Vec<String> = (0..20).map(|i| format!("ord-{}", i)).collect();
    let batch = compute_cancel_batch(&orders, &config);
    assert_eq!(batch.order_ids.len(), 20, "all 20 orders should fit");
    assert!(!batch.has_more);
}

#[test]
fn test_at_1065_cancel_batch_capped_at_max() {
    let config = PolicyGuardConfig::default(); // cancel_open_batch_max = 50
    let orders: Vec<String> = (0..75).map(|i| format!("ord-{}", i)).collect();
    let batch = compute_cancel_batch(&orders, &config);
    assert_eq!(
        batch.order_ids.len(),
        50,
        "batch must be capped at cancel_open_batch_max"
    );
    assert!(
        batch.has_more,
        "has_more must be true when orders exceed batch max"
    );
}

#[test]
fn test_at_1065_cancel_batch_exactly_at_max() {
    let config = PolicyGuardConfig::default(); // cancel_open_batch_max = 50
    let orders: Vec<String> = (0..50).map(|i| format!("ord-{}", i)).collect();
    let batch = compute_cancel_batch(&orders, &config);
    assert_eq!(batch.order_ids.len(), 50);
    assert!(!batch.has_more, "exactly at max should not set has_more");
}

#[test]
fn test_at_1065_cancel_batch_respects_custom_max() {
    let config = PolicyGuardConfig {
        cancel_open_batch_max: 5,
        ..PolicyGuardConfig::default()
    };
    let orders: Vec<String> = (0..10).map(|i| format!("ord-{}", i)).collect();
    let batch = compute_cancel_batch(&orders, &config);
    assert_eq!(batch.order_ids.len(), 5);
    assert!(batch.has_more);
}

// ─── Cancel loop required in ReduceOnly and Kill mode ────────────────────────

#[test]
fn test_cancel_loop_required_in_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        bunker_mode_active: true, // forces ReduceOnly
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result.trading_mode.requires_open_cancellation(),
        "cancel loop must be required in ReduceOnly"
    );
    assert!(
        !result.trading_mode.allows_open(),
        "OPEN must be blocked in ReduceOnly"
    );
}

#[test]
fn test_cancel_loop_required_in_kill() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        risk_state: PolicyRiskState::Kill,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Kill);
    assert!(
        result.trading_mode.requires_open_cancellation(),
        "cancel loop must be required in Kill"
    );
    assert!(
        !result.trading_mode.allows_open(),
        "OPEN must be blocked in Kill"
    );
}

#[test]
fn test_cancel_loop_not_required_in_active() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let result = resolver.get_effective_mode(&clean_inputs(now_ms), &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Active);
    assert!(
        !result.trading_mode.requires_open_cancellation(),
        "cancel loop must NOT be required in Active"
    );
}

// ─── Only risk-increasing orders (reduce_only != true) should be cancelled ───

#[test]
fn test_only_risk_increasing_orders_are_cancellation_targets() {
    // risk-increasing: reduce_only=false or None
    assert!(
        is_open_intent(Some(false)),
        "reduce_only=false is risk-increasing (OPEN)"
    );
    assert!(
        is_open_intent(None),
        "reduce_only=None is risk-increasing (OPEN, fail-closed)"
    );

    // risk-reducing: reduce_only=true — NOT a cancellation target
    assert!(
        !is_open_intent(Some(true)),
        "reduce_only=true is NOT risk-increasing"
    );
}

// ─── Multi-tick convergence: has_more triggers retry next tick ─────────────────

#[test]
fn test_at_1065_multi_tick_convergence() {
    let config = PolicyGuardConfig {
        cancel_open_batch_max: 3,
        ..PolicyGuardConfig::default()
    };

    let mut remaining: Vec<String> = (0..7).map(|i| format!("ord-{}", i)).collect();

    // Tick 1: cancel 3, 4 remain
    let batch1 = compute_cancel_batch(&remaining, &config);
    assert_eq!(batch1.order_ids.len(), 3);
    assert!(batch1.has_more);
    remaining.retain(|id| !batch1.order_ids.contains(id));
    assert_eq!(remaining.len(), 4);

    // Tick 2: cancel 3, 1 remains
    let batch2 = compute_cancel_batch(&remaining, &config);
    assert_eq!(batch2.order_ids.len(), 3);
    assert!(batch2.has_more);
    remaining.retain(|id| !batch2.order_ids.contains(id));
    assert_eq!(remaining.len(), 1);

    // Tick 3: cancel last 1
    let batch3 = compute_cancel_batch(&remaining, &config);
    assert_eq!(batch3.order_ids.len(), 1);
    assert!(!batch3.has_more);
    remaining.retain(|id| !batch3.order_ids.contains(id));
    assert!(
        remaining.is_empty(),
        "all orders should be cancelled after 3 ticks"
    );
}
