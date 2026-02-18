//! PolicyGuard Critical Input Freshness tests (§2.2.1.1).
//!
//! Covers:
//!   AT-001 — mm_util stale → ReduceOnly + REDUCEONLY_INPUT_MISSING_OR_STALE
//!   AT-112 — watchdog missing → ReduceOnly + REDUCEONLY_INPUT_MISSING_OR_STALE
//!   AT-1054 — policy_age_sec == 300 does NOT trip; 301 trips with REDUCEONLY_POLICY_STALE

#[path = "../src/policy/guard.rs"]
mod guard;

use guard::{
    AxisResolver, CortexOverride, EnforcedProfile, F1CertStatus, ModeReasonCode,
    PolicyBasisDecision, PolicyEvidenceState, PolicyGuardConfig, PolicyGuardInputs, PolicyRiskState,
    PolicyTradingMode,
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
        basis_decision: PolicyBasisDecision::Normal,
        fee_model_cache_age_s: None,
        policy_age_sec: 60,
        enforced_profile: EnforcedProfile::Csp,
    }
}

// ─── AT-001: mm_util stale → ReduceOnly ────────────────────────────────────

#[test]
fn test_at_001_mm_util_stale_forces_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // mm_util_max_age_ms = 30_000

    let mut resolver = AxisResolver::new();

    // mm_util timestamp is 31s ago (stale)
    let inputs = PolicyGuardInputs {
        mm_util: Some(0.50),
        mm_util_last_update_ts_ms: Some(now_ms - 31_000),
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "stale mm_util must force ReduceOnly"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyInputMissingOrStale),
        "must include REDUCEONLY_INPUT_MISSING_OR_STALE, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_at_001_mm_util_missing_forces_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        mm_util: None,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyInputMissingOrStale)
    );
}

#[test]
fn test_at_001_mm_util_timestamp_missing_forces_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        mm_util: Some(0.50),
        mm_util_last_update_ts_ms: None, // missing timestamp
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyInputMissingOrStale)
    );
}

#[test]
fn test_at_001_mm_util_exactly_at_boundary_does_not_trip() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // mm_util_max_age_ms = 30_000

    let mut resolver = AxisResolver::new();

    // Exactly at boundary (30_000ms ago) — must NOT trip (> not >=)
    let inputs = PolicyGuardInputs {
        mm_util: Some(0.50),
        mm_util_last_update_ts_ms: Some(now_ms - 30_000),
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    // At exactly the boundary, should not be stale (> not >=)
    assert_eq!(result.trading_mode, PolicyTradingMode::Active);
}

// ─── AT-112: watchdog missing → ReduceOnly ──────────────────────────────────

#[test]
fn test_at_112_watchdog_missing_forces_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // watchdog_last_heartbeat_ts_ms is None (missing/unparseable)
    let inputs = PolicyGuardInputs {
        watchdog_last_heartbeat_ts_ms: None,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "missing watchdog must force ReduceOnly"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyInputMissingOrStale),
        "must include REDUCEONLY_INPUT_MISSING_OR_STALE, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_at_112_watchdog_missing_does_not_dispatch_open() {
    // Verify that ReduceOnly blocks OPEN (is_open_intent check)
    use guard::is_open_intent;
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        watchdog_last_heartbeat_ts_ms: None,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    // OPEN (reduce_only=None) must not dispatch
    assert!(
        !result.trading_mode.allows_open(),
        "OPEN must be blocked in ReduceOnly"
    );
    assert!(is_open_intent(None), "None reduce_only = OPEN intent");
}

// ─── Additional freshness: disk_used_pct stale → ReduceOnly ─────────────────

#[test]
fn test_disk_used_pct_stale_forces_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // disk_used_max_age_ms = 30_000
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        disk_used_pct: Some(0.50),
        disk_used_last_update_ts_ms: Some(now_ms - 31_000), // stale
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyInputMissingOrStale)
    );
}

#[test]
fn test_rate_limit_session_kill_missing_forces_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        rate_limit_session_kill_active: None, // missing
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyInputMissingOrStale)
    );
}

// ─── AT-1054: policy_age_sec boundary ────────────────────────────────────────

#[test]
fn test_at_1054_policy_age_sec_300_does_not_trip() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // max_policy_age_sec = 300
    let mut resolver = AxisResolver::new();

    // Exactly at boundary — must NOT trip (> not >=)
    let inputs = PolicyGuardInputs {
        policy_age_sec: 300,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::Active,
        "policy_age_sec == 300 must NOT trip (boundary is exclusive: > 300)"
    );
    assert!(
        !result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyPolicyStale),
        "must NOT include REDUCEONLY_POLICY_STALE at exactly 300s"
    );
}

#[test]
fn test_at_1054_policy_age_sec_301_trips_reduceonly() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // max_policy_age_sec = 300
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        policy_age_sec: 301,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "policy_age_sec == 301 must trip ReduceOnly"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyPolicyStale),
        "must include REDUCEONLY_POLICY_STALE at 301s, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_policy_age_sec_gauge_emitted() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        policy_age_sec: 123,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.policy_age_sec, 123,
        "policy_age_sec gauge must be emitted"
    );
}

#[test]
fn test_policy_stale_reduceonly_counter_increments() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    assert_eq!(resolver.policy_stale_reduceonly_total, 0);

    let inputs = PolicyGuardInputs {
        policy_age_sec: 301,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert!(result.policy_stale_this_tick);
    assert_eq!(resolver.policy_stale_reduceonly_total, 1);

    // Second stale tick
    let _ = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(resolver.policy_stale_reduceonly_total, 2);
}

// ─── CLOSE/HEDGE allowed while ReduceOnly ────────────────────────────────────

#[test]
fn test_close_allowed_in_reduceonly_mode() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        bunker_mode_active: true, // forces ReduceOnly
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);

    // reduce_only=true intents (closes/hedges) must be allowed
    assert!(
        !guard::is_open_intent(Some(true)),
        "reduce_only=true is NOT an OPEN"
    );
}
