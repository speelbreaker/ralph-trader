//! PolicyGuard Axis Resolver tests (§2.2.3).
//!
//! Covers:
//!   AT-1048 — all 27 axis combinations deterministic
//!   AT-1050 — axis isolation: MarketIntegrityAxis (bunker_mode only)
//!   AT-1051 — axis isolation: CapitalRiskAxis (mm_util only)
//!   AT-1052 — axis isolation: SystemIntegrityAxis (open_permission_latch only)
//!   AT-1053 — monotonicity: no less-restrictive output on worse axes
//!   AT-1055 — reduce_only=true is NOT an OPEN intent
//!   AT-1065 — Non-Active OPEN cancellation bounded
//!   AT-1066 — watchdog unconfirmed → REDUCEONLY_WATCHDOG_UNCONFIRMED
//!   AT-1067 — disk kill unconfirmed → REDUCEONLY_DISK_KILL_UNCONFIRMED
//!   AT-1068 — session kill unconfirmed → REDUCEONLY_SESSION_KILL_UNCONFIRMED
//!   AT-1069 — confirmed kill predicates → Kill
//!   §2.3.3   — BasisMonitor pathway: ForceKill → Kill, ForceReduceOnly → ReduceOnly

#[path = "../src/policy/guard.rs"]
mod guard;

use guard::{
    AxisResolver, CapitalRiskAxis, CortexOverride, EnforcedProfile, F1CertStatus,
    MarketIntegrityAxis, ModeReasonCode, PolicyBasisDecision, PolicyEvidenceState,
    PolicyGuardConfig, PolicyGuardInputs, PolicyRiskState, PolicyTradingMode, SystemIntegrityAxis,
    compute_cancel_batch, is_open_intent, resolve_trading_mode,
};

/// Build a "clean" input snapshot that results in Active (all good).
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

// ─── AT-1048: 27-state axis mapping table (canonical §2.2.3.3) ────────────────

#[test]
fn test_at_1048_all_27_axis_combinations_deterministic() {
    use CapitalRiskAxis::*;
    use MarketIntegrityAxis::*;
    use PolicyTradingMode::*;
    use SystemIntegrityAxis::*;

    let table: Vec<(
        CapitalRiskAxis,
        MarketIntegrityAxis,
        SystemIntegrityAxis,
        PolicyTradingMode,
    )> = vec![
        // Row 1-9: SAFE capital
        (Safe, Stable, Healthy, Active),
        (Safe, Stable, Degraded, ReduceOnly),
        (Safe, Stable, Failing, Kill),
        (Safe, Stressed, Healthy, ReduceOnly),
        (Safe, Stressed, Degraded, ReduceOnly),
        (Safe, Stressed, Failing, Kill),
        (Safe, Broken, Healthy, ReduceOnly),
        (Safe, Broken, Degraded, ReduceOnly),
        (Safe, Broken, Failing, Kill),
        // Row 10-18: WARNING capital
        (Warning, Stable, Healthy, ReduceOnly),
        (Warning, Stable, Degraded, ReduceOnly),
        (Warning, Stable, Failing, Kill),
        (Warning, Stressed, Healthy, ReduceOnly),
        (Warning, Stressed, Degraded, ReduceOnly),
        (Warning, Stressed, Failing, Kill),
        (Warning, Broken, Healthy, ReduceOnly),
        (Warning, Broken, Degraded, ReduceOnly),
        (Warning, Broken, Failing, Kill),
        // Row 19-27: CRITICAL capital
        (Critical, Stable, Healthy, Kill),
        (Critical, Stable, Degraded, Kill),
        (Critical, Stable, Failing, Kill),
        (Critical, Stressed, Healthy, Kill),
        (Critical, Stressed, Degraded, Kill),
        (Critical, Stressed, Failing, Kill),
        (Critical, Broken, Healthy, Kill),
        (Critical, Broken, Degraded, Kill),
        (Critical, Broken, Failing, Kill),
    ];

    assert_eq!(table.len(), 27, "must have exactly 27 combinations");

    for (i, (capital, market, system, expected)) in table.iter().enumerate() {
        let actual = resolve_trading_mode(*capital, *market, *system);
        assert_eq!(
            actual,
            *expected,
            "Row {}: ({:?}, {:?}, {:?}) expected {:?} got {:?}",
            i + 1,
            capital,
            market,
            system,
            expected,
            actual
        );
    }
}

// ─── AT-1050: MarketIntegrityAxis isolation (bunker_mode only) ────────────────

#[test]
fn test_at_1050_bunker_mode_active_only_forces_reduceonly_with_exact_reason() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        bunker_mode_active: true,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert_eq!(
        result.mode_reasons,
        vec![ModeReasonCode::ReduceOnlyBunkerModeActive],
        "must have exactly [REDUCEONLY_BUNKER_MODE_ACTIVE] when only bunker_mode_active"
    );
}

// ─── AT-1051: CapitalRiskAxis isolation (mm_util only) ────────────────────────

#[test]
fn test_at_1051_mm_util_high_only_forces_reduceonly_with_exact_reason() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // mm_util_reduceonly = 0.85, mm_util_kill = 0.95
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        mm_util: Some(0.87), // >= reduceonly, < kill
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert_eq!(
        result.mode_reasons,
        vec![ModeReasonCode::ReduceOnlyMarginMmUtilHigh],
        "must have exactly [REDUCEONLY_MARGIN_MM_UTIL_HIGH] when only mm_util high"
    );
}

// ─── AT-1052: SystemIntegrityAxis isolation (open_permission_latch only) ──────

#[test]
fn test_at_1052_open_permission_latch_only_forces_reduceonly_with_exact_reason() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        open_permission_blocked_latch: true,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert_eq!(
        result.mode_reasons,
        vec![ModeReasonCode::ReduceOnlyOpenPermissionLatched],
        "must have exactly [REDUCEONLY_OPEN_PERMISSION_LATCHED] when only latch set"
    );
}

// ─── AT-1053: Monotonicity ─────────────────────────────────────────────────────

#[test]
fn test_at_1053_monotonicity_worse_axes_never_less_restrictive() {
    use CapitalRiskAxis::*;
    use MarketIntegrityAxis::*;
    use SystemIntegrityAxis::*;

    let capital_order = [Safe, Warning, Critical];
    let market_order = [Stable, Stressed, Broken];
    let system_order = [Healthy, Degraded, Failing];

    // For each pair (A, B) where B is equal or worse on all axes, at least one strictly worse,
    // resolve(B) must not be less restrictive than resolve(A).
    for &ca in &capital_order {
        for &ma in &market_order {
            for &sa in &system_order {
                let mode_a = resolve_trading_mode(ca, ma, sa);
                for &cb in &capital_order {
                    for &mb in &market_order {
                        for &sb in &system_order {
                            // B must be >= A on all axes
                            if cb >= ca && mb >= ma && sb >= sa {
                                // At least one strictly worse
                                if cb > ca || mb > ma || sb > sa {
                                    let mode_b = resolve_trading_mode(cb, mb, sb);
                                    assert!(
                                        mode_b.restrictiveness() >= mode_a.restrictiveness(),
                                        "Monotonicity violated: ({:?},{:?},{:?})={:?} then ({:?},{:?},{:?})={:?}",
                                        ca,
                                        ma,
                                        sa,
                                        mode_a,
                                        cb,
                                        mb,
                                        sb,
                                        mode_b
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ─── AT-1055: reduce_only=true is NOT an OPEN intent ─────────────────────────

#[test]
fn test_at_1055_reduce_only_true_is_not_open_intent() {
    // reduce_only == Some(true) → NOT an OPEN
    assert!(
        !is_open_intent(Some(true)),
        "reduce_only=true must not be classified as OPEN"
    );
    // reduce_only == Some(false) → OPEN
    assert!(
        is_open_intent(Some(false)),
        "reduce_only=false must be classified as OPEN"
    );
    // reduce_only == None → OPEN (fail-closed)
    assert!(
        is_open_intent(None),
        "reduce_only=None must be classified as OPEN (fail-closed)"
    );
}

#[test]
fn test_at_1055_reduce_only_intent_allowed_in_reduceonly_mode() {
    // reduce_only=true intents pass even in ReduceOnly mode (they are close/hedge, not OPEN)
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        bunker_mode_active: true, // forces ReduceOnly
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);

    // A reduce_only=true intent is allowed (not blocked by ReduceOnly mode)
    let reduce_only_intent = is_open_intent(Some(true));
    assert!(
        !reduce_only_intent,
        "reduce_only=true intent is allowed through ReduceOnly"
    );
}

// ─── AT-1065: Non-Active OPEN Cancellation bounded ───────────────────────────

#[test]
fn test_at_1065_cancel_batch_bounded_by_config() {
    let config = PolicyGuardConfig::default(); // cancel_open_batch_max = 50

    // 30 orders — all fit in one batch
    let orders_30: Vec<String> = (0..30).map(|i| format!("order-{}", i)).collect();
    let batch = compute_cancel_batch(&orders_30, &config);
    assert_eq!(batch.order_ids.len(), 30);
    assert!(!batch.has_more, "30 orders should fit in one batch of 50");

    // 60 orders — bounded at 50
    let orders_60: Vec<String> = (0..60).map(|i| format!("order-{}", i)).collect();
    let batch = compute_cancel_batch(&orders_60, &config);
    assert_eq!(batch.order_ids.len(), 50);
    assert!(
        batch.has_more,
        "60 orders exceed batch_max of 50, has_more should be true"
    );
}

#[test]
fn test_at_1065_cancel_not_triggered_in_active_mode() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = clean_inputs(now_ms);
    let result = resolver.get_effective_mode(&inputs, &config);

    // When Active, cancellation loop is not required
    assert_eq!(result.trading_mode, PolicyTradingMode::Active);
    assert!(!result.trading_mode.requires_open_cancellation());
}

#[test]
fn test_at_1065_cancel_required_in_reduceonly_mode() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        bunker_mode_active: true,
        ..clean_inputs(now_ms)
    };
    let result = resolver.get_effective_mode(&inputs, &config);

    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(result.trading_mode.requires_open_cancellation());
}

// ─── AT-1066: Watchdog unconfirmed → REDUCEONLY_WATCHDOG_UNCONFIRMED ──────────

#[test]
fn test_at_1066_watchdog_heartbeat_stale_but_loop_tick_fresh_gives_reduceonly_unconfirmed() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // watchdog_kill_s = 10
    let mut resolver = AxisResolver::new();

    // Heartbeat stale (15s ago), loop_tick fresh (1s ago)
    let inputs = PolicyGuardInputs {
        watchdog_last_heartbeat_ts_ms: Some(now_ms - 15_000), // stale
        loop_tick_last_ts_ms: Some(now_ms - 1_000),           // fresh
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "should be ReduceOnly, not Kill"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyWatchdogUnconfirmed),
        "must include REDUCEONLY_WATCHDOG_UNCONFIRMED, got {:?}",
        result.mode_reasons
    );
    assert!(
        !result
            .mode_reasons
            .contains(&ModeReasonCode::KillWatchdogHeartbeatStale),
        "must NOT include KILL_WATCHDOG_HEARTBEAT_STALE (only one signal stale)"
    );
}

// ─── AT-1067: Disk kill unconfirmed → REDUCEONLY_DISK_KILL_UNCONFIRMED ────────

#[test]
fn test_at_1067_disk_primary_kill_but_secondary_below_kill_gives_reduceonly_unconfirmed() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // disk_kill_pct = 0.92
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        disk_used_pct: Some(0.95), // primary >= kill
        disk_used_last_update_ts_ms: Some(now_ms - 1_000),
        disk_used_pct_secondary: Some(0.80), // secondary < kill
        disk_used_secondary_last_update_ts_ms: Some(now_ms - 1_000),
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "should be ReduceOnly, not Kill"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyDiskKillUnconfirmed),
        "must include REDUCEONLY_DISK_KILL_UNCONFIRMED, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_at_1067_disk_primary_kill_but_secondary_missing_gives_reduceonly_unconfirmed() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        disk_used_pct: Some(0.95),
        disk_used_last_update_ts_ms: Some(now_ms - 1_000),
        disk_used_pct_secondary: None, // missing secondary
        disk_used_secondary_last_update_ts_ms: None,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyDiskKillUnconfirmed),
        "missing secondary = unconfirmed disk kill, got {:?}",
        result.mode_reasons
    );
}

// ─── AT-1068: Session kill unconfirmed → REDUCEONLY_SESSION_KILL_UNCONFIRMED ──

#[test]
fn test_at_1068_session_kill_active_but_10028_count_below_min_gives_unconfirmed() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // rate_limit_kill_min_10028 = 3
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        rate_limit_session_kill_active: Some(true),
        count_10028_5m: Some(2), // below min of 3
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlySessionKillUnconfirmed),
        "must include REDUCEONLY_SESSION_KILL_UNCONFIRMED, got {:?}",
        result.mode_reasons
    );
    assert!(
        !result.mode_reasons.iter().any(|r| r.is_kill_tier()),
        "must NOT have Kill-tier reasons"
    );
}

#[test]
fn test_at_1068_session_kill_active_missing_10028_count_gives_unconfirmed() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        rate_limit_session_kill_active: Some(true),
        count_10028_5m: None, // missing
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlySessionKillUnconfirmed),
        "missing 10028 count = unconfirmed, got {:?}",
        result.mode_reasons
    );
}

// ─── AT-1069: Confirmed kill predicates → Kill ────────────────────────────────

#[test]
fn test_at_1069_confirmed_watchdog_kill_both_stale_gives_kill() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // watchdog_kill_s = 10
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        watchdog_last_heartbeat_ts_ms: Some(now_ms - 15_000), // stale
        loop_tick_last_ts_ms: Some(now_ms - 15_000),          // stale (both)
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Kill);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::KillWatchdogHeartbeatStale),
        "must include KILL_WATCHDOG_HEARTBEAT_STALE, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_at_1069_confirmed_disk_kill_both_above_threshold_gives_kill() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // disk_kill_pct = 0.92
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        disk_used_pct: Some(0.95),
        disk_used_last_update_ts_ms: Some(now_ms - 1_000),
        disk_used_pct_secondary: Some(0.94),
        disk_used_secondary_last_update_ts_ms: Some(now_ms - 1_000),
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Kill);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::KillDiskWatermarkKill),
        "must include KILL_DISK_WATERMARK_KILL, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_at_1069_confirmed_session_termination_kill_gives_kill() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // rate_limit_kill_min_10028 = 3
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        rate_limit_session_kill_active: Some(true),
        count_10028_5m: Some(5), // >= 3
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Kill);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::KillRateLimitSessionTermination),
        "must include KILL_RATE_LIMIT_SESSION_TERMINATION, got {:?}",
        result.mode_reasons
    );
}

// ─── Reasons are tier-pure ────────────────────────────────────────────────────

#[test]
fn test_mode_reasons_are_tier_pure() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // Kill scenario
    let kill_inputs = PolicyGuardInputs {
        risk_state: PolicyRiskState::Kill,
        ..clean_inputs(now_ms)
    };
    let kill_result = resolver.get_effective_mode(&kill_inputs, &config);
    assert_eq!(kill_result.trading_mode, PolicyTradingMode::Kill);
    assert!(
        kill_result.mode_reasons.iter().all(|r| r.is_kill_tier()),
        "Kill mode reasons must be kill-tier only: {:?}",
        kill_result.mode_reasons
    );

    // ReduceOnly scenario
    let ro_inputs = PolicyGuardInputs {
        bunker_mode_active: true,
        ..clean_inputs(now_ms)
    };
    let ro_result = resolver.get_effective_mode(&ro_inputs, &config);
    assert_eq!(ro_result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        ro_result
            .mode_reasons
            .iter()
            .all(|r| r.is_reduceonly_tier()),
        "ReduceOnly mode reasons must be reduceonly-tier only: {:?}",
        ro_result.mode_reasons
    );

    // Active scenario
    let active_result = resolver.get_effective_mode(&clean_inputs(now_ms), &config);
    assert_eq!(active_result.trading_mode, PolicyTradingMode::Active);
    assert!(
        active_result.mode_reasons.is_empty(),
        "Active mode reasons must be empty: {:?}",
        active_result.mode_reasons
    );
}

// ─── Kill-tier reasons are present when risk_state == Kill ───────────────────

#[test]
fn test_riskstate_kill_gives_kill_mode_with_kill_reason() {
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
        result
            .mode_reasons
            .contains(&ModeReasonCode::KillRiskstateKill)
    );
}

// ─── mm_util >= kill → Kill ──────────────────────────────────────────────────

#[test]
fn test_mm_util_at_kill_threshold_gives_kill() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default(); // mm_util_kill = 0.95
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        mm_util: Some(0.95),
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Kill);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::KillMarginMmUtilCritical)
    );
}

// ─── Cortex ForceKill → Kill ─────────────────────────────────────────────────

#[test]
fn test_cortex_force_kill_gives_kill() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        cortex_override: CortexOverride::ForceKill,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Kill);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::KillCortexForceKill)
    );
}

// ─── §2.3.3 BasisMonitor pathway ─────────────────────────────────────────────
// basis_decision is the integration seam for BasisMonitor (mark/index/last price
// divergence). These tests prove causality: only basis_decision differs from the
// clean baseline, so it is the sole cause of the mode change.

#[test]
fn test_basis_decision_force_kill_trips_kill_mode() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // Only basis_decision differs from clean baseline — sole cause.
    let inputs = PolicyGuardInputs {
        basis_decision: PolicyBasisDecision::ForceKill,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::Kill,
        "PolicyBasisDecision::ForceKill must produce Kill mode"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::KillBasisMonitor),
        "KillBasisMonitor reason must be present for ForceKill basis, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_basis_decision_force_reduceonly_trips_reduceonly_mode() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // Only basis_decision differs from clean baseline — sole cause.
    let inputs = PolicyGuardInputs {
        basis_decision: PolicyBasisDecision::ForceReduceOnly,
        ..clean_inputs(now_ms)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "PolicyBasisDecision::ForceReduceOnly must produce ReduceOnly mode"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyBasisMonitor),
        "ReduceOnlyBasisMonitor reason must be present for ForceReduceOnly basis, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_basis_decision_normal_does_not_trip() {
    // Baseline check: Normal basis_decision must not change TradingMode.
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let result = resolver.get_effective_mode(&clean_inputs(now_ms), &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Active);
}
