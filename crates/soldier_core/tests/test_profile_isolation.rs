//! Profile isolation tests (§0.Z.7).
//!
//! Covers:
//!   AT-991 — GOP unhealthy must not affect CSP decisions when enforced_profile == CSP
//!   AT-992 — GOP enforcement applies when enforced_profile != CSP
//!
//! Per §2.2.1.1: GOP-only inputs (e.g., evidence_chain_state) are critical only when
//! enforced_profile != CSP. When enforced_profile == CSP, GOP inputs must be treated
//! as nonexistent and MUST NOT change TradingMode or OpenPermissionLatch.

#[path = "../src/policy/guard.rs"]
mod guard;

use guard::{
    AxisResolver, CortexOverride, EnforcedProfile, F1CertStatus, ModeReasonCode,
    PolicyBasisDecision, PolicyEvidenceState, PolicyGuardConfig, PolicyGuardInputs, PolicyRiskState,
    PolicyTradingMode,
};

fn base_inputs(now_ms: u64, profile: EnforcedProfile) -> PolicyGuardInputs {
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
        enforced_profile: profile,
    }
}

// ─── AT-991: GOP unhealthy must not affect CSP decisions ─────────────────────

#[test]
fn test_at_991_evidence_chain_not_green_ignored_when_csp_profile() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // enforced_profile == CSP, EvidenceChainState == NotGreen (GOP unhealthy)
    let inputs = PolicyGuardInputs {
        enforced_profile: EnforcedProfile::Csp,
        evidence_chain_state: PolicyEvidenceState::NotGreen,
        ..base_inputs(now_ms, EnforcedProfile::Csp)
    };

    let result = resolver.get_effective_mode(&inputs, &config);

    // When CSP, GOP evidence state must be treated as nonexistent
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::Active,
        "EvidenceChainState==NotGreen must NOT affect TradingMode when enforced_profile==CSP"
    );
    assert!(
        !result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyEvidenceChainNotGreen),
        "REDUCEONLY_EVIDENCE_CHAIN_NOT_GREEN must NOT appear when CSP"
    );
}

#[test]
fn test_at_991_gop_inputs_nonexistent_in_csp_all_stay_active() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // All CSP inputs clean, all GOP inputs unhealthy — must remain Active
    let inputs = PolicyGuardInputs {
        enforced_profile: EnforcedProfile::Csp,
        evidence_chain_state: PolicyEvidenceState::NotGreen, // GOP-only
        ..base_inputs(now_ms, EnforcedProfile::Csp)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Active);
    assert!(result.mode_reasons.is_empty());
}

// ─── AT-992: GOP enforcement applies when enforced_profile != CSP ────────────

#[test]
fn test_at_992_evidence_chain_not_green_blocks_open_when_gop_profile() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // enforced_profile == GOP, EvidenceChainState == NotGreen
    let inputs = PolicyGuardInputs {
        enforced_profile: EnforcedProfile::Gop,
        evidence_chain_state: PolicyEvidenceState::NotGreen,
        ..base_inputs(now_ms, EnforcedProfile::Gop)
    };

    let result = resolver.get_effective_mode(&inputs, &config);

    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "EvidenceChainState==NotGreen MUST force ReduceOnly when enforced_profile==GOP"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyEvidenceChainNotGreen),
        "REDUCEONLY_EVIDENCE_CHAIN_NOT_GREEN must appear when GOP, got {:?}",
        result.mode_reasons
    );
}

#[test]
fn test_at_992_evidence_chain_not_green_blocks_open_when_full_profile() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        enforced_profile: EnforcedProfile::Full,
        evidence_chain_state: PolicyEvidenceState::NotGreen,
        ..base_inputs(now_ms, EnforcedProfile::Full)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyEvidenceChainNotGreen)
    );
}

// ─── Profile isolation: CSP ignores GOP-only inputs in axis resolver ──────────

#[test]
fn test_csp_profile_evidence_green_stays_active() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // CSP, evidence GREEN
    let inputs = base_inputs(now_ms, EnforcedProfile::Csp);
    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Active);
}

#[test]
fn test_gop_profile_evidence_green_stays_active() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // GOP, evidence GREEN — should still be Active
    let inputs = base_inputs(now_ms, EnforcedProfile::Gop);
    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::Active);
    assert!(result.mode_reasons.is_empty());
}

// ─── CSP-only: F1 cert affects both CSP and GOP (F1 is not GOP-only) ─────────

#[test]
fn test_f1_cert_invalid_forces_reduceonly_in_csp() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    let inputs = PolicyGuardInputs {
        enforced_profile: EnforcedProfile::Csp,
        f1_cert_status: F1CertStatus::Missing,
        ..base_inputs(now_ms, EnforcedProfile::Csp)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(
        result.trading_mode,
        PolicyTradingMode::ReduceOnly,
        "F1 cert invalid must force ReduceOnly even in CSP profile"
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyF1CertInvalid)
    );
}

// ─── Multiple simultaneous reasons — tier-pure and deterministically ordered ──

#[test]
fn test_multiple_reduceonly_reasons_deterministically_ordered() {
    let now_ms = 1_000_000_u64;
    let config = PolicyGuardConfig::default();
    let mut resolver = AxisResolver::new();

    // Multiple ReduceOnly triggers simultaneously
    let inputs = PolicyGuardInputs {
        enforced_profile: EnforcedProfile::Gop,
        bunker_mode_active: true,
        evidence_chain_state: PolicyEvidenceState::NotGreen,
        open_permission_blocked_latch: true,
        ..base_inputs(now_ms, EnforcedProfile::Gop)
    };

    let result = resolver.get_effective_mode(&inputs, &config);
    assert_eq!(result.trading_mode, PolicyTradingMode::ReduceOnly);

    // Should contain all three reasons
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyOpenPermissionLatched)
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyBunkerModeActive)
    );
    assert!(
        result
            .mode_reasons
            .contains(&ModeReasonCode::ReduceOnlyEvidenceChainNotGreen)
    );

    // Reasons must be in canonical order
    let indices: Vec<u8> = result
        .mode_reasons
        .iter()
        .map(|r| r.canonical_index())
        .collect();
    let mut sorted = indices.clone();
    sorted.sort();
    assert_eq!(indices, sorted, "reasons must be in canonical order");

    // Tier-pure: no kill-tier reasons
    assert!(result.mode_reasons.iter().all(|r| r.is_reduceonly_tier()));
}
