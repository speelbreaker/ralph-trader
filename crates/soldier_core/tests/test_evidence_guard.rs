//! Integration tests for EvidenceGuard (S8-002).
//! Contract: §2.2.2 | AT-005, AT-105, AT-107
//!
//! Tests acceptance criteria from PRD S8-002 and CONTRACT.md §2.2.2.

#[path = "../src/analytics/evidence_chain_state.rs"]
mod evidence_chain_state;

use evidence_chain_state::{
    EvidenceEnforcedProfile, EvidenceGuard, EvidenceGuardConfig, EvidenceGuardDecision,
    EvidenceGuardInputs,
};

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Healthy baseline inputs: all counters present and zero, queue safe.
fn healthy_inputs(now_ms: u64) -> EvidenceGuardInputs {
    EvidenceGuardInputs {
        now_ms,
        truth_capsule_write_errors: Some(0),
        decision_snapshot_write_errors: Some(0),
        wal_write_errors: Some(0),
        parquet_queue_overflow_count: Some(0),
        parquet_queue_depth: Some(50),
        parquet_queue_capacity: Some(1000),
        counters_last_update_ts_ms: Some(now_ms),
        enforced_profile: EvidenceEnforcedProfile::Gop,
    }
}

/// Healthy inputs with parquet_queue_depth_pct = given ratio.
fn inputs_with_depth_pct(now_ms: u64, depth_pct: f64) -> EvidenceGuardInputs {
    let capacity = 10_000u64;
    let depth = (depth_pct * capacity as f64) as u64;
    EvidenceGuardInputs {
        now_ms,
        truth_capsule_write_errors: Some(0),
        decision_snapshot_write_errors: Some(0),
        wal_write_errors: Some(0),
        parquet_queue_overflow_count: Some(0),
        parquet_queue_depth: Some(depth),
        parquet_queue_capacity: Some(capacity),
        counters_last_update_ts_ms: Some(now_ms),
        enforced_profile: EvidenceEnforcedProfile::Gop,
    }
}

fn default_config() -> EvidenceGuardConfig {
    EvidenceGuardConfig::default()
}

// ─── Acceptance criteria 1: depth_pct > 0.90 for ≥5s → NOT GREEN ──────────

#[test]
fn test_ac1_depth_above_trip_for_5s_trips() {
    // depth_pct = 0.91 > 0.90, for >= 5s → NOT GREEN
    let mut guard = EvidenceGuard::new();
    let cfg = default_config(); // trip_pct=0.90, trip_window_s=5
    let t0 = 1_000_000u64;

    // T0: depth=0.91, first tick — trip window starts
    let inp = inputs_with_depth_pct(t0, 0.91);
    let d = guard.evaluate(&inp, &cfg);
    // Trip timer just started, elapsed = 0 < 5000ms → still not tripped
    assert_eq!(
        d,
        EvidenceGuardDecision::Green,
        "trip window hasn't elapsed yet at T0"
    );

    // T0+4s: elapsed 4000ms < 5000ms → still not tripped
    let inp = inputs_with_depth_pct(t0 + 4_000, 0.91);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(d, EvidenceGuardDecision::Green, "4s < 5s trip window");

    // T0+5s: elapsed 5000ms >= 5000ms → TRIPPED
    let inp = inputs_with_depth_pct(t0 + 5_000, 0.91);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "5s elapsed → EvidenceChainState != GREEN"
    );
}

// ─── Acceptance criteria 2: depth_pct == 0.90 does NOT trip (strict >) ─────

#[test]
fn test_ac2_depth_exactly_trip_pct_does_not_trip() {
    // parquet_queue_depth_pct == 0.90 → NOT > 0.90 → must NOT trip (strict comparator)
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let t0 = 1_000_000u64;

    for i in 0..=10u64 {
        let inp = inputs_with_depth_pct(t0 + i * 2_000, 0.90);
        let d = guard.evaluate(&inp, &cfg);
        assert_eq!(
            d,
            EvidenceGuardDecision::Green,
            "depth_pct == 0.90 MUST NOT trip (strict >), tick {i}"
        );
    }
}

// ─── Acceptance criteria 3: depth_pct == 0.9001 for ≥5s trips ─────────────

#[test]
fn test_ac3_depth_9001_for_5s_trips() {
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let t0 = 2_000_000u64;

    // 0.9001 > 0.90 → trip accumulation begins
    let inp = inputs_with_depth_pct(t0, 0.9001);
    let _ = guard.evaluate(&inp, &cfg);

    let inp = inputs_with_depth_pct(t0 + 4_999, 0.9001);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(d, EvidenceGuardDecision::Green, "4999ms < 5000ms");

    let inp = inputs_with_depth_pct(t0 + 5_000, 0.9001);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "depth=0.9001 ≥5s → NOT GREEN"
    );
}

// ─── Acceptance criteria 4: EvidenceChainState != GREEN → OPEN rejected ────

#[test]
fn test_ac4_not_green_blocks_open_intent() {
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let t0 = 3_000_000u64;

    // Trigger NOT GREEN via missing counter.
    let inp = EvidenceGuardInputs {
        now_ms: t0,
        truth_capsule_write_errors: None, // fail-closed
        decision_snapshot_write_errors: Some(0),
        wal_write_errors: Some(0),
        parquet_queue_overflow_count: Some(0),
        parquet_queue_depth: Some(50),
        parquet_queue_capacity: Some(1000),
        counters_last_update_ts_ms: Some(t0),
        enforced_profile: EvidenceEnforcedProfile::Gop,
    };
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(d, EvidenceGuardDecision::NotGreen);

    // blocks_open must return true → OPEN rejected before WAL/dispatch.
    assert!(
        EvidenceGuard::blocks_open(d),
        "EvidenceChainState != GREEN must block OPEN intents"
    );

    // Verify the counter increments on a blocked open.
    guard.record_blocked_open();
    assert_eq!(guard.evidence_guard_blocked_opens_count, 1);
}

// ─── Acceptance criteria 5: recovery — depth_pct < 0.70 for ≥120s + cooldown → GREEN ─

#[test]
fn test_ac5_recovery_after_cooldown() {
    let mut guard = EvidenceGuard::new();
    let cfg = EvidenceGuardConfig {
        evidenceguard_global_cooldown: 0, // no extra cooldown
        ..EvidenceGuardConfig::default()
    };
    let t0 = 4_000_000u64;

    // Trip the guard: depth=0.91 for 5s.
    let inp = inputs_with_depth_pct(t0, 0.91);
    guard.evaluate(&inp, &cfg);
    let inp = inputs_with_depth_pct(t0 + 5_000, 0.91);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(d, EvidenceGuardDecision::NotGreen, "guard must be tripped");

    // Recovery: depth drops below 0.70 but not long enough yet.
    let inp = inputs_with_depth_pct(t0 + 5_000 + 60_000, 0.65);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "119s < 120s clear window"
    );

    // Recovery: depth below 0.70 for >= 120s → GREEN.
    // Required: queue_clear_window_s=120, so clear_elapsed must be >= 120s.
    // Clear started at t0+65_000. Need t0+65_000+120_000 = t0+185_000.
    let inp = inputs_with_depth_pct(t0 + 5_000 + 60_000 + 120_000, 0.65);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::Green,
        "depth < 0.70 for >=120s → should recover to GREEN"
    );
}

// ─── Acceptance criteria 6: OPEN with zero fills → AT-005 non-fill exception ─

#[test]
fn test_ac6_at005_zero_fills_open_does_not_require_attribution() {
    // EvidenceGuard must NOT block opens solely because attribution row is absent
    // when no fills occurred. All writer counters healthy → GREEN.
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let now_ms = 5_000_000u64;

    // Healthy inputs: attribution rows not tracked by EvidenceGuard counters.
    // WAL + TruthCapsule + DecisionSnapshot writers all zero errors.
    let inp = healthy_inputs(now_ms);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::Green,
        "AT-005: OPEN with zero fills must not flip EvidenceChainState to NOT GREEN"
    );
    assert!(
        !EvidenceGuard::blocks_open(d),
        "AT-005: EvidenceGuard must NOT block OPEN when attribution row absent but no fills"
    );
}

// ─── Acceptance criteria 7: enforced_profile == CSP → NOT_ENFORCED ─────────

#[test]
fn test_ac7_csp_profile_not_enforced() {
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let now_ms = 6_000_000u64;

    // Make inputs look bad — but profile is CSP.
    let inp = EvidenceGuardInputs {
        now_ms,
        truth_capsule_write_errors: None, // would fail-close under GOP
        decision_snapshot_write_errors: None,
        wal_write_errors: None,
        parquet_queue_overflow_count: None,
        parquet_queue_depth: None,
        parquet_queue_capacity: None,
        counters_last_update_ts_ms: None,
        enforced_profile: EvidenceEnforcedProfile::Csp,
    };
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotEnforced,
        "enforced_profile == CSP must return NotEnforced regardless of inputs"
    );
    assert!(
        !EvidenceGuard::blocks_open(d),
        "CSP profile: EvidenceGuard must NOT block OPEN intents"
    );
}

// ─── AT-105: window boundary affects GREEN deterministically ─────────────────

#[test]
fn test_at105_window_boundary_truth_capsule_errors() {
    // AT-105: truth_capsule_write_errors increases at T0.
    // At T0+59s: NOT GREEN (within 60s window).
    // At T0+61s: MAY become GREEN (window elapsed, all other criteria satisfied).
    let mut guard = EvidenceGuard::new();
    let cfg = EvidenceGuardConfig {
        evidenceguard_window_s: 60,
        ..EvidenceGuardConfig::default()
    };
    let t0 = 7_000_000u64;

    // Baseline: error=0 at start.
    let inp = healthy_inputs(t0);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::Green,
        "initial state must be GREEN"
    );

    // Error increments at T0.
    let mut inp = healthy_inputs(t0);
    inp.truth_capsule_write_errors = Some(1);
    inp.counters_last_update_ts_ms = Some(t0);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "error at T0 → NOT GREEN"
    );

    // T0+59s: still within 60s window → NOT GREEN.
    let mut inp = healthy_inputs(t0 + 59_000);
    inp.truth_capsule_write_errors = Some(1); // no further increase
    inp.counters_last_update_ts_ms = Some(t0 + 59_000);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "T0+59s: within window → NOT GREEN"
    );

    // T0+61s: window elapsed (61s > 60s) → MAY become GREEN (no further increases).
    let mut inp = healthy_inputs(t0 + 61_000);
    inp.truth_capsule_write_errors = Some(1); // same value, no increase
    inp.counters_last_update_ts_ms = Some(t0 + 61_000);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::Green,
        "T0+61s: window elapsed, no further increase → GREEN"
    );
}

// ─── AT-107: WAL write errors → NOT GREEN ────────────────────────────────────

#[test]
fn test_at107_wal_write_errors_blocks_opens() {
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let t0 = 8_000_000u64;

    // Healthy baseline.
    let inp = healthy_inputs(t0);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(d, EvidenceGuardDecision::Green);

    // WAL write error increments → NOT GREEN.
    let mut inp = healthy_inputs(t0 + 1_000);
    inp.wal_write_errors = Some(1);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "AT-107: WAL write failure must force NOT GREEN"
    );
    assert!(
        EvidenceGuard::blocks_open(d),
        "AT-107: OPEN must be blocked when wal_write_errors increases"
    );
}

// ─── Additional: missing counters → fail-closed ──────────────────────────────

#[test]
fn test_missing_wal_errors_fail_closed() {
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let now_ms = 9_000_000u64;

    let inp = EvidenceGuardInputs {
        now_ms,
        truth_capsule_write_errors: Some(0),
        decision_snapshot_write_errors: Some(0),
        wal_write_errors: None, // missing
        parquet_queue_overflow_count: Some(0),
        parquet_queue_depth: Some(50),
        parquet_queue_capacity: Some(1000),
        counters_last_update_ts_ms: Some(now_ms),
        enforced_profile: EvidenceEnforcedProfile::Gop,
    };
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "missing wal_write_errors → fail-closed"
    );
}

#[test]
fn test_missing_snapshot_errors_fail_closed() {
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let now_ms = 10_000_000u64;

    let inp = EvidenceGuardInputs {
        now_ms,
        truth_capsule_write_errors: Some(0),
        decision_snapshot_write_errors: None, // missing
        wal_write_errors: Some(0),
        parquet_queue_overflow_count: Some(0),
        parquet_queue_depth: Some(50),
        parquet_queue_capacity: Some(1000),
        counters_last_update_ts_ms: Some(now_ms),
        enforced_profile: EvidenceEnforcedProfile::Gop,
    };
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "missing decision_snapshot_write_errors → fail-closed"
    );
}

#[test]
fn test_missing_parquet_queue_metrics_fail_closed() {
    // AT-335: parquet_queue_depth missing → fail-closed.
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let now_ms = 11_000_000u64;

    let inp = EvidenceGuardInputs {
        now_ms,
        truth_capsule_write_errors: Some(0),
        decision_snapshot_write_errors: Some(0),
        wal_write_errors: Some(0),
        parquet_queue_overflow_count: Some(0),
        parquet_queue_depth: None, // missing
        parquet_queue_capacity: Some(1000),
        counters_last_update_ts_ms: Some(now_ms),
        enforced_profile: EvidenceEnforcedProfile::Gop,
    };
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "missing parquet_queue_depth → fail-closed"
    );
}

// ─── Stale counters → fail-closed ─────────────────────────────────────────────

#[test]
fn test_stale_counters_fail_closed() {
    let mut guard = EvidenceGuard::new();
    let cfg = EvidenceGuardConfig {
        evidenceguard_counters_max_age_ms: 60_000,
        ..EvidenceGuardConfig::default()
    };
    let now_ms = 12_000_000u64;

    let inp = EvidenceGuardInputs {
        now_ms,
        truth_capsule_write_errors: Some(0),
        decision_snapshot_write_errors: Some(0),
        wal_write_errors: Some(0),
        parquet_queue_overflow_count: Some(0),
        parquet_queue_depth: Some(50),
        parquet_queue_capacity: Some(1000),
        // last update was 61s ago → stale
        counters_last_update_ts_ms: Some(now_ms - 61_000),
        enforced_profile: EvidenceEnforcedProfile::Gop,
    };
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "stale counters → fail-closed"
    );
}

// ─── AT-422: configurable trip/clear thresholds ───────────────────────────────

#[test]
fn test_at422_configurable_trip_and_clear_thresholds() {
    let mut guard = EvidenceGuard::new();
    let cfg = EvidenceGuardConfig {
        parquet_queue_trip_pct: 0.80,
        parquet_queue_trip_window_s: 5,
        parquet_queue_clear_pct: 0.75,
        queue_clear_window_s: 10,
        evidenceguard_global_cooldown: 0,
        ..EvidenceGuardConfig::default()
    };
    let t0 = 13_000_000u64;

    // Step 1: depth=0.85 for 6s → NOT GREEN.
    let inp = inputs_with_depth_pct(t0, 0.85);
    guard.evaluate(&inp, &cfg);
    let inp = inputs_with_depth_pct(t0 + 5_000, 0.85);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(d, EvidenceGuardDecision::NotGreen, "0.85 for 5s → tripped");
    // Simulate one more tick to confirm the trip stays.
    let inp = inputs_with_depth_pct(t0 + 6_000, 0.85);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(d, EvidenceGuardDecision::NotGreen, "still tripped at 6s");

    // Step 2: depth=0.72 for 9s → still NOT GREEN (9s < 10s clear window).
    let clear_start = t0 + 6_000 + 1; // depth drops below 0.75
    let inp = inputs_with_depth_pct(clear_start, 0.72);
    guard.evaluate(&inp, &cfg);
    let inp = inputs_with_depth_pct(clear_start + 9_000 - 1, 0.72);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "9s < 10s clear window → still NOT GREEN"
    );

    // Step 3: depth=0.72 for 10s total → GREEN.
    let inp = inputs_with_depth_pct(clear_start + 10_000, 0.72);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::Green,
        "10s below 0.75 → recovered GREEN"
    );
}

// ─── decision_snapshot_write_errors → NOT GREEN ───────────────────────────────

#[test]
fn test_decision_snapshot_errors_blocks_opens() {
    // AT-334
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let t0 = 14_000_000u64;

    let inp = healthy_inputs(t0);
    guard.evaluate(&inp, &cfg);

    let mut inp = healthy_inputs(t0 + 1_000);
    inp.decision_snapshot_write_errors = Some(1);
    let d = guard.evaluate(&inp, &cfg);
    assert_eq!(
        d,
        EvidenceGuardDecision::NotGreen,
        "AT-334: decision_snapshot errors → NOT GREEN"
    );
    assert!(EvidenceGuard::blocks_open(d));
}

// ─── Observability: evidence_chain_state gauge ────────────────────────────────

#[test]
fn test_evidence_chain_state_gauge() {
    let mut guard = EvidenceGuard::new();
    let cfg = default_config();
    let now_ms = 15_000_000u64;

    // GREEN → gauge = 1
    let inp = healthy_inputs(now_ms);
    guard.evaluate(&inp, &cfg);
    assert_eq!(guard.evidence_chain_state_gauge, 1, "GREEN → gauge=1");

    // NOT GREEN → gauge = 0
    let mut inp = healthy_inputs(now_ms + 1_000);
    inp.wal_write_errors = Some(1);
    guard.evaluate(&inp, &cfg);
    assert_eq!(guard.evidence_chain_state_gauge, 0, "NOT GREEN → gauge=0");
}
