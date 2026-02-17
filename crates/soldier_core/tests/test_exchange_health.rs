/// Tests for Exchange Health Monitor — Maintenance Mode Override
/// Contract: §2.3.1 | AT-232, AT-204
use soldier_core::risk::{
    AnnouncementEntry, ExchangeHealthConfig, ExchangeHealthDecision, ExchangeHealthInput,
    ExchangeHealthMonitor, PolicyGuard, RiskState, TradingMode,
};

/// Helper: build input with fresh announcements.
fn fresh_input(announcements: Vec<AnnouncementEntry>, now_ms: u64) -> ExchangeHealthInput {
    ExchangeHealthInput {
        announcements: Some(announcements),
        last_successful_poll_ms: Some(now_ms - 1_000), // 1s ago = fresh
    }
}

/// Helper: build stale/unreachable input (announcements = None).
fn unreachable_input(last_poll_ms: Option<u64>) -> ExchangeHealthInput {
    ExchangeHealthInput {
        announcements: None,
        last_successful_poll_ms: last_poll_ms,
    }
}

/// Helper: announcement with maintenance starting `secs_from_now` seconds in the future.
fn maintenance_in(now_ms: u64, secs_from_now: u64) -> AnnouncementEntry {
    AnnouncementEntry {
        maintenance_start_ms: Some(now_ms + secs_from_now * 1_000),
    }
}

/// Helper: announcement with no maintenance (e.g. a product release announcement).
fn non_maintenance_entry() -> AnnouncementEntry {
    AnnouncementEntry {
        maintenance_start_ms: None,
    }
}

// ────────────────────────────────────────────────────────────────────────────
// AT-232: Maintenance imminent → RiskState=Maintenance, TradingMode=ReduceOnly
// ────────────────────────────────────────────────────────────────────────────

/// AT-232: Maintenance starting in 30 minutes → ReduceOnly
#[test]
fn test_at_232_maintenance_30min_forces_reduce_only() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default(); // lookahead = 3600s = 60m
    let now_ms = 1_000_000_000_000u64;

    let input = fresh_input(vec![maintenance_in(now_ms, 1800)], now_ms); // 30m = 1800s
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::MaintenanceImminent,
        "Maintenance in 30m must trigger MaintenanceImminent"
    );
    assert_eq!(
        decision.risk_state(),
        Some(RiskState::Maintenance),
        "MaintenanceImminent must map to RiskState::Maintenance"
    );
    assert_eq!(
        decision.trading_mode(),
        TradingMode::ReduceOnly,
        "Maintenance state must force ReduceOnly"
    );
}

/// AT-232: OPEN blocked, CLOSE/HEDGE/CANCEL allowed under Maintenance
#[test]
fn test_at_232_maintenance_blocks_opens_allows_closes() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    let input = fresh_input(vec![maintenance_in(now_ms, 1800)], now_ms);
    let decision = monitor.evaluate(&input, now_ms, config);
    let mode = decision.trading_mode();

    assert!(!mode.allows_open(), "OPEN must be blocked in Maintenance");
    assert!(mode.allows_close(), "CLOSE must be allowed in Maintenance");
    assert!(mode.allows_hedge(), "HEDGE must be allowed in Maintenance");
    assert!(
        mode.allows_cancel(),
        "CANCEL must be allowed in Maintenance"
    );
}

/// PolicyGuard maps RiskState::Maintenance → TradingMode::ReduceOnly (§2.2.3)
#[test]
fn test_policy_guard_maintenance_to_reduce_only() {
    let mode = PolicyGuard::get_effective_mode(RiskState::Maintenance);
    assert_eq!(
        mode,
        TradingMode::ReduceOnly,
        "PolicyGuard must compute ReduceOnly for RiskState::Maintenance"
    );
}

/// Maintenance at exactly 60m boundary (edge case)
#[test]
fn test_maintenance_at_60min_boundary() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default(); // lookahead = 3600s
    let now_ms = 1_000_000_000_000u64;

    // Exactly 60m = 3600s → should trigger
    let input = fresh_input(vec![maintenance_in(now_ms, 3600)], now_ms);
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::MaintenanceImminent,
        "Maintenance exactly at 60m boundary must trigger MaintenanceImminent"
    );
}

/// Maintenance beyond 60m → Normal
#[test]
fn test_maintenance_beyond_60min_normal() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    // 61m = 3660s → beyond lookahead
    let input = fresh_input(vec![maintenance_in(now_ms, 3660)], now_ms);
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::Normal,
        "Maintenance 61m away must not trigger MaintenanceImminent"
    );
}

/// Non-maintenance announcement → Normal
#[test]
fn test_non_maintenance_announcement_normal() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    let input = fresh_input(vec![non_maintenance_entry()], now_ms);
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::Normal,
        "Non-maintenance announcement must not trigger MaintenanceImminent"
    );
}

/// Empty announcements list (no maintenance scheduled) → Normal
#[test]
fn test_empty_announcements_normal() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    let input = fresh_input(vec![], now_ms);
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::Normal,
        "Empty announcements must result in Normal"
    );
}

/// Maintenance start in the past → currently in maintenance window
#[test]
fn test_maintenance_start_in_past_is_imminent() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    // Start was 5 minutes ago
    let past_start_ms = now_ms - 300_000;
    let input = fresh_input(
        vec![AnnouncementEntry {
            maintenance_start_ms: Some(past_start_ms),
        }],
        now_ms,
    );
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::MaintenanceImminent,
        "Maintenance start in the past means we are in maintenance"
    );
}

// ────────────────────────────────────────────────────────────────────────────
// AT-204: Announcements unreachable/invalid for >= exchange_health_stale_s → ForceReduceOnly
// ────────────────────────────────────────────────────────────────────────────

/// AT-204: Endpoint unreachable (announcements=None, last_poll=None) → ForceReduceOnly immediately
#[test]
fn test_at_204_never_polled_force_reduce_only() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    let input = unreachable_input(None); // Never polled
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::ForceReduceOnly,
        "Never-polled state must trigger ForceReduceOnly (fail-closed)"
    );
    assert!(
        decision.forces_reduce_only(),
        "ForceReduceOnly must force reduce-only mode"
    );
    assert_eq!(
        decision.trading_mode(),
        TradingMode::ReduceOnly,
        "ForceReduceOnly must result in ReduceOnly TradingMode"
    );
}

/// AT-204: Endpoint unreachable for >= exchange_health_stale_s → ForceReduceOnly
#[test]
fn test_at_204_stale_announcements_force_reduce_only() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default(); // stale_s = 180s
    let now_ms = 1_000_000_000_000u64;

    // Last successful poll was 181s ago → stale
    let last_poll_ms = now_ms - 181_000;
    let input = unreachable_input(Some(last_poll_ms));
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::ForceReduceOnly,
        "Announcements stale for >180s must trigger ForceReduceOnly"
    );
}

/// AT-204: Exactly at staleness boundary (180s) → ForceReduceOnly
#[test]
fn test_at_204_exact_stale_boundary_force_reduce_only() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default(); // stale_s = 180s
    let now_ms = 1_000_000_000_000u64;

    // Last poll exactly 180s ago → should be stale (>= threshold)
    let last_poll_ms = now_ms - 180_000;
    let input = unreachable_input(Some(last_poll_ms));
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::ForceReduceOnly,
        "Announcements stale for exactly 180s must trigger ForceReduceOnly"
    );
}

/// Just below staleness threshold → Normal (no maintenance, not stale)
#[test]
fn test_just_below_stale_threshold_normal() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default(); // stale_s = 180s
    let now_ms = 1_000_000_000_000u64;

    // Last poll 179s ago → not yet stale, but announcements=None (e.g. empty response)
    // When announcements is None but not stale → Normal
    let last_poll_ms = now_ms - 179_000;
    let input = unreachable_input(Some(last_poll_ms));
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::Normal,
        "Announcements not yet stale (179s) must result in Normal"
    );
}

/// OPEN blocked under ForceReduceOnly (AT-204 fail criteria check)
#[test]
fn test_at_204_opens_blocked_when_stale() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    let input = unreachable_input(None); // Never polled → immediately stale
    let decision = monitor.evaluate(&input, now_ms, config);
    let mode = decision.trading_mode();

    assert!(
        !mode.allows_open(),
        "OPEN must be blocked when announcements stale"
    );
    assert!(
        mode.allows_close(),
        "CLOSE must be allowed even when announcements stale"
    );
}

// ────────────────────────────────────────────────────────────────────────────
// Acceptance test 3: /api/v1/status RiskState=Maintenance
// ────────────────────────────────────────────────────────────────────────────

/// Status endpoint returns risk_state=Maintenance when ExchangeHealthMonitor emits MaintenanceImminent
#[test]
fn test_status_risk_state_maintenance() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    // Maintenance in 30 minutes
    let input = fresh_input(vec![maintenance_in(now_ms, 1800)], now_ms);
    let decision = monitor.evaluate(&input, now_ms, config);

    let risk_state = decision.risk_state();
    assert_eq!(
        risk_state,
        Some(RiskState::Maintenance),
        "Status endpoint must reflect RiskState::Maintenance when maintenance is imminent"
    );

    // PolicyGuard confirms ReduceOnly for Maintenance
    let mode = PolicyGuard::get_effective_mode(RiskState::Maintenance);
    assert_eq!(
        mode,
        TradingMode::ReduceOnly,
        "PolicyGuard must compute ReduceOnly for Maintenance state"
    );
}

// ────────────────────────────────────────────────────────────────────────────
// Observability
// ────────────────────────────────────────────────────────────────────────────

/// Status counter increments on each evaluation
#[test]
fn test_status_count_increments() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    assert_eq!(monitor.status_count(), 0);

    let input = fresh_input(vec![], now_ms);
    monitor.evaluate(&input, now_ms, config);
    assert_eq!(monitor.status_count(), 1);

    monitor.evaluate(&input, now_ms + 1_000, config);
    assert_eq!(monitor.status_count(), 2);
}

/// Multiple announcements: earliest maintenance wins
#[test]
fn test_multiple_announcements_earliest_maintenance_wins() {
    let mut monitor = ExchangeHealthMonitor::new();
    let config = ExchangeHealthConfig::default();
    let now_ms = 1_000_000_000_000u64;

    // Mix of: non-maintenance, far future maintenance (>60m), near maintenance (<60m)
    let input = fresh_input(
        vec![
            non_maintenance_entry(),      // no maintenance
            maintenance_in(now_ms, 7200), // 2h away - beyond lookahead
            maintenance_in(now_ms, 1800), // 30m away - within lookahead
        ],
        now_ms,
    );
    let decision = monitor.evaluate(&input, now_ms, config);

    assert_eq!(
        decision,
        ExchangeHealthDecision::MaintenanceImminent,
        "Should detect the maintenance that is within lookahead even when others are farther"
    );
}
