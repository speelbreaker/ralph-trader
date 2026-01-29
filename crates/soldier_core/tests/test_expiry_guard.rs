use soldier_core::execution::IntentClass;
use soldier_core::risk::{
    ExpiryGuard, ExpiryRejectReason, InstrumentState, RiskState, TerminalLifecycleErrorKind,
};

/// Test that active perpetual instruments (no expiry) are always tradeable for OPENs.
#[test]
fn test_perpetual_never_blocked_by_expiry() {
    // Perpetuals have no expiration_timestamp - OPENs should pass
    let result = ExpiryGuard::check(true, None, 0, IntentClass::Open);
    assert!(result.is_ok());

    let result = ExpiryGuard::check(true, None, i64::MAX, IntentClass::Open);
    assert!(result.is_ok());
}

/// Test that expired instruments reject OPENs with deterministic reason.
#[test]
fn test_expired_instrument_rejected_with_reason_code() {
    let expiry_ms = 1735689600000; // Some timestamp
    let current_ms = expiry_ms + 1;

    // OPEN on expired instrument should be rejected
    let err = ExpiryGuard::check(true, Some(expiry_ms), current_ms, IntentClass::Open)
        .expect_err("expired instrument should reject OPEN");

    assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);
    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason.to_string(), "INSTRUMENT_EXPIRED_OR_DELISTED");
}

/// Test that CLOSE intents are allowed on expired instruments (risk-reducing).
#[test]
fn test_close_allowed_on_expired_instrument() {
    let expiry_ms = 1735689600000;
    let current_ms = expiry_ms + 1;

    // CLOSE on expired instrument should be allowed
    let result = ExpiryGuard::check(true, Some(expiry_ms), current_ms, IntentClass::Close);
    assert!(result.is_ok(), "CLOSE should be allowed on expired instruments");
}

/// Test that CANCEL intents are allowed on expired instruments (risk-reducing).
#[test]
fn test_cancel_allowed_on_expired_instrument() {
    let expiry_ms = 1735689600000;
    let current_ms = expiry_ms + 1;

    let result = ExpiryGuard::check(true, Some(expiry_ms), current_ms, IntentClass::Cancel);
    assert!(result.is_ok(), "CANCEL should be allowed on expired instruments");
}

/// Test that delisted instruments reject OPENs with deterministic reason.
#[test]
fn test_delisted_instrument_rejected_with_reason_code() {
    // OPEN on delisted instrument should be rejected
    let err = ExpiryGuard::check(false, None, 1000, IntentClass::Open)
        .expect_err("delisted instrument should reject OPEN");

    assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);
    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason.to_string(), "INSTRUMENT_EXPIRED_OR_DELISTED");
}

/// Test that CLOSE intents are allowed on delisted instruments (risk-reducing).
#[test]
fn test_close_allowed_on_delisted_instrument() {
    // CLOSE on delisted instrument should be allowed
    let result = ExpiryGuard::check(false, None, 1000, IntentClass::Close);
    assert!(result.is_ok(), "CLOSE should be allowed on delisted instruments");
}

/// Test that expiry guard sets RiskState::Degraded for blocked OPENs.
#[test]
fn test_expiry_guard_sets_degraded_state() {
    // Expired - OPEN rejected with Degraded
    let err = ExpiryGuard::check(true, Some(1000), 2000, IntentClass::Open)
        .expect_err("should reject OPEN");
    assert_eq!(err.risk_state, RiskState::Degraded);

    // Delisted - OPEN rejected with Degraded
    let err = ExpiryGuard::check(false, None, 1000, IntentClass::Open)
        .expect_err("should reject OPEN");
    assert_eq!(err.risk_state, RiskState::Degraded);
}

/// Test that buffer prevents OPEN orders too close to expiry.
#[test]
fn test_near_expiry_buffer_blocks_open_orders() {
    let expiry_ms = 1_000_000;
    let buffer_ms = 60_000; // 1 minute buffer
    let safe_time = expiry_ms - buffer_ms - 1; // Just before buffer
    let near_expiry = expiry_ms - buffer_ms; // At buffer boundary
    let past_expiry = expiry_ms + 1;

    // Before buffer: OPEN OK
    assert!(ExpiryGuard::check_with_buffer(
        true,
        Some(expiry_ms),
        safe_time,
        buffer_ms,
        IntentClass::Open
    )
    .is_ok());

    // At buffer boundary: OPEN rejected
    let err = ExpiryGuard::check_with_buffer(
        true,
        Some(expiry_ms),
        near_expiry,
        buffer_ms,
        IntentClass::Open,
    )
    .expect_err("should reject near-expiry OPEN");
    assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);

    // Past expiry: OPEN rejected
    let err = ExpiryGuard::check_with_buffer(
        true,
        Some(expiry_ms),
        past_expiry,
        buffer_ms,
        IntentClass::Open,
    )
    .expect_err("should reject past-expiry OPEN");
    assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);
}

/// Test that buffer does NOT block CLOSE orders (risk-reducing always allowed).
#[test]
fn test_near_expiry_buffer_allows_close_orders() {
    let expiry_ms = 1_000_000;
    let buffer_ms = 60_000;
    let near_expiry = expiry_ms - buffer_ms;
    let past_expiry = expiry_ms + 1;

    // Near expiry: CLOSE allowed
    assert!(ExpiryGuard::check_with_buffer(
        true,
        Some(expiry_ms),
        near_expiry,
        buffer_ms,
        IntentClass::Close
    )
    .is_ok());

    // Past expiry: CLOSE allowed
    assert!(ExpiryGuard::check_with_buffer(
        true,
        Some(expiry_ms),
        past_expiry,
        buffer_ms,
        IntentClass::Close
    )
    .is_ok());
}

/// Test delisted takes precedence over expiry (checked first) for OPENs.
#[test]
fn test_delisted_precedence_over_expiry() {
    // Delisted AND expired: OPEN should report delisted (checked first)
    let err = ExpiryGuard::check(false, Some(1000), 2000, IntentClass::Open)
        .expect_err("should reject OPEN");
    assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);

    // But CLOSE should still be allowed
    let result = ExpiryGuard::check(false, Some(1000), 2000, IntentClass::Close);
    assert!(result.is_ok(), "CLOSE should be allowed even when delisted AND expired");
}

#[test]
fn test_derive_instrument_state_with_buffer() {
    let expiry_ms = 10_000;
    let buffer_ms = 5_000;

    // Active, far from expiry
    assert_eq!(
        ExpiryGuard::derive_instrument_state(true, Some(expiry_ms), 1000, buffer_ms),
        InstrumentState::Active
    );

    // Within buffer
    assert_eq!(
        ExpiryGuard::derive_instrument_state(true, Some(expiry_ms), 6000, buffer_ms),
        InstrumentState::DelistingSoon
    );

    // Past expiry
    assert_eq!(
        ExpiryGuard::derive_instrument_state(true, Some(expiry_ms), 12_000, buffer_ms),
        InstrumentState::ExpiredOrDelisted
    );

    // Delisted
    assert_eq!(
        ExpiryGuard::derive_instrument_state(false, Some(expiry_ms), 1000, buffer_ms),
        InstrumentState::ExpiredOrDelisted
    );
}

#[test]
fn test_handle_terminal_lifecycle_error_idempotent_cancel() {
    let expiry_ms = 1_000;
    let now_ms = 2_000;

    let result = ExpiryGuard::handle_terminal_lifecycle_error(
        true,
        Some(expiry_ms),
        now_ms,
        TerminalLifecycleErrorKind::InvalidInstrument,
    );
    assert_eq!(result, Some(InstrumentState::ExpiredOrDelisted));

    let result = ExpiryGuard::handle_terminal_lifecycle_error(
        true,
        Some(expiry_ms),
        now_ms,
        TerminalLifecycleErrorKind::OrderbookClosed,
    );
    assert_eq!(result, Some(InstrumentState::ExpiredOrDelisted));
}
