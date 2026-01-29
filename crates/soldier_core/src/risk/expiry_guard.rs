use std::fmt;

use super::RiskState;
use crate::execution::IntentClass;

/// Deterministic reject reason for expiry/delist guard failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ExpiryRejectReason {
    /// Instrument is expired or delisted (contract uses a single reason code).
    InstrumentExpiredOrDelisted,
}

impl fmt::Display for ExpiryRejectReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ExpiryRejectReason::InstrumentExpiredOrDelisted => {
                write!(f, "INSTRUMENT_EXPIRED_OR_DELISTED")
            }
        }
    }
}

/// Result of expiry guard check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExpiryReject {
    pub risk_state: RiskState,
    pub reason: ExpiryRejectReason,
}

/// Derived instrument lifecycle state (contract §1.0.Y).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstrumentState {
    Active,
    DelistingSoon,
    ExpiredOrDelisted,
}

/// Terminal lifecycle errors returned by venue APIs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalLifecycleErrorKind {
    InvalidInstrument,
    NotFound,
    OrderbookClosed,
    InstrumentNotOpen,
}

/// Expiry guard that rejects OPEN orders on expired or delisted instruments.
///
/// This guard implements CONTRACT.md S1.4 requirements:
/// - Block NEW OPEN intents on expired/delisted instruments
/// - Allow CLOSE/HEDGE/CANCEL intents to pass (risk-reducing)
/// - Return deterministic reject reason codes
pub struct ExpiryGuard;

impl ExpiryGuard {
    /// Check if an intent is allowed given instrument expiry/delist status.
    ///
    /// Per CONTRACT S1.4:
    /// - OPEN intents are blocked on expired/delisted instruments
    /// - CLOSE intents are allowed (they reduce risk)
    ///
    /// Returns Ok(()) if allowed.
    /// Returns Err(ExpiryReject) with deterministic reason if blocked.
    pub fn check(
        is_active: bool,
        expiration_timestamp: Option<i64>,
        current_time_ms: i64,
        intent_class: IntentClass,
    ) -> Result<(), ExpiryReject> {
        // CLOSE/CANCEL intents are always allowed - they reduce risk
        if matches!(intent_class, IntentClass::Close | IntentClass::Cancel) {
            return Ok(());
        }

        // For OPEN intents, check expiry/delist status
        Self::check_instrument_status(is_active, expiration_timestamp, current_time_ms)
    }

    /// Check with a time buffer before expiry (fail-closed for near-expiry OPENs).
    ///
    /// `buffer_ms` is the number of milliseconds before expiry to start rejecting OPENs.
    /// CLOSE intents are always allowed regardless of buffer.
    pub fn check_with_buffer(
        is_active: bool,
        expiration_timestamp: Option<i64>,
        current_time_ms: i64,
        buffer_ms: i64,
        intent_class: IntentClass,
    ) -> Result<(), ExpiryReject> {
        // CLOSE/CANCEL intents are always allowed
        if matches!(intent_class, IntentClass::Close | IntentClass::Cancel) {
            return Ok(());
        }

        // For OPEN intents, reject if instrument is delisting soon or expired/delisted.
        match Self::derive_instrument_state(
            is_active,
            expiration_timestamp,
            current_time_ms,
            buffer_ms,
        ) {
            InstrumentState::Active => Ok(()),
            InstrumentState::DelistingSoon | InstrumentState::ExpiredOrDelisted => {
                Err(ExpiryReject {
                    risk_state: RiskState::Degraded,
                    reason: ExpiryRejectReason::InstrumentExpiredOrDelisted,
                })
            }
        }
    }

    /// Check instrument status only (no intent filtering).
    /// Returns the expiry/delist status for informational purposes.
    fn check_instrument_status(
        is_active: bool,
        expiration_timestamp: Option<i64>,
        current_time_ms: i64,
    ) -> Result<(), ExpiryReject> {
        // Check delisted first
        if !is_active {
            return Err(ExpiryReject {
                risk_state: RiskState::Degraded,
                reason: ExpiryRejectReason::InstrumentExpiredOrDelisted,
            });
        }

        // Check expired
        if let Some(expiry_ms) = expiration_timestamp {
            if current_time_ms >= expiry_ms {
                return Err(ExpiryReject {
                    risk_state: RiskState::Degraded,
                    reason: ExpiryRejectReason::InstrumentExpiredOrDelisted,
                });
            }
        }

        Ok(())
    }

    /// Check if instrument is expired or delisted (status check only).
    /// Returns true if the instrument is NOT tradeable for new positions.
    pub fn is_expired_or_delisted(
        is_active: bool,
        expiration_timestamp: Option<i64>,
        current_time_ms: i64,
    ) -> bool {
        Self::check_instrument_status(is_active, expiration_timestamp, current_time_ms).is_err()
    }

    /// Derive instrument lifecycle state with a delist buffer.
    pub fn derive_instrument_state(
        is_active: bool,
        expiration_timestamp: Option<i64>,
        current_time_ms: i64,
        buffer_ms: i64,
    ) -> InstrumentState {
        if !is_active {
            return InstrumentState::ExpiredOrDelisted;
        }
        if let Some(expiry_ms) = expiration_timestamp {
            if current_time_ms >= expiry_ms {
                return InstrumentState::ExpiredOrDelisted;
            }
            if current_time_ms >= expiry_ms.saturating_sub(buffer_ms) {
                return InstrumentState::DelistingSoon;
            }
        }
        InstrumentState::Active
    }

    /// Classify a terminal lifecycle error for an expired/delisted instrument.
    ///
    /// Returns Some(InstrumentState::ExpiredOrDelisted) when the error should be treated as
    /// terminal and idempotent for CANCEL handling.
    pub fn handle_terminal_lifecycle_error(
        is_active: bool,
        expiration_timestamp: Option<i64>,
        current_time_ms: i64,
        _error_kind: TerminalLifecycleErrorKind,
    ) -> Option<InstrumentState> {
        if Self::is_expired_or_delisted(is_active, expiration_timestamp, current_time_ms) {
            Some(InstrumentState::ExpiredOrDelisted)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_open_on_active_perpetual_passes() {
        let result = ExpiryGuard::check(true, None, 1000, IntentClass::Open);
        assert!(result.is_ok());
    }

    #[test]
    fn test_open_on_active_non_expired_option_passes() {
        let expiry_ms = 2000;
        let current_ms = 1000;
        let result = ExpiryGuard::check(true, Some(expiry_ms), current_ms, IntentClass::Open);
        assert!(result.is_ok());
    }

    #[test]
    fn test_open_on_expired_instrument_rejected() {
        let expiry_ms = 1000;
        let current_ms = 1000; // Exactly at expiry
        let result = ExpiryGuard::check(true, Some(expiry_ms), current_ms, IntentClass::Open);
        let err = result.expect_err("should reject expired OPEN");
        assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);
        assert_eq!(err.risk_state, RiskState::Degraded);
    }

    #[test]
    fn test_close_on_expired_instrument_allowed() {
        let expiry_ms = 1000;
        let current_ms = 2000; // Past expiry
        let result = ExpiryGuard::check(true, Some(expiry_ms), current_ms, IntentClass::Close);
        assert!(
            result.is_ok(),
            "CLOSE should be allowed on expired instruments"
        );
    }

    #[test]
    fn test_open_on_delisted_instrument_rejected() {
        let result = ExpiryGuard::check(false, None, 1000, IntentClass::Open);
        let err = result.expect_err("should reject delisted OPEN");
        assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);
        assert_eq!(err.risk_state, RiskState::Degraded);
    }

    #[test]
    fn test_close_on_delisted_instrument_allowed() {
        let result = ExpiryGuard::check(false, None, 1000, IntentClass::Close);
        assert!(
            result.is_ok(),
            "CLOSE should be allowed on delisted instruments"
        );
    }

    #[test]
    fn test_buffer_rejects_near_expiry_opens() {
        let expiry_ms = 10000;
        let buffer_ms = 5000;
        let current_ms = 6000; // Within buffer

        let result = ExpiryGuard::check_with_buffer(
            true,
            Some(expiry_ms),
            current_ms,
            buffer_ms,
            IntentClass::Open,
        );
        let err = result.expect_err("should reject near-expiry OPEN");
        assert_eq!(err.reason, ExpiryRejectReason::InstrumentExpiredOrDelisted);
    }

    #[test]
    fn test_buffer_allows_near_expiry_closes() {
        let expiry_ms = 10000;
        let buffer_ms = 5000;
        let current_ms = 6000; // Within buffer

        let result = ExpiryGuard::check_with_buffer(
            true,
            Some(expiry_ms),
            current_ms,
            buffer_ms,
            IntentClass::Close,
        );
        assert!(
            result.is_ok(),
            "CLOSE should be allowed even within expiry buffer"
        );
    }

    #[test]
    fn test_buffer_allows_before_buffer_window() {
        let expiry_ms = 10000;
        let buffer_ms = 5000;
        let current_ms = 4000; // Before buffer

        let result = ExpiryGuard::check_with_buffer(
            true,
            Some(expiry_ms),
            current_ms,
            buffer_ms,
            IntentClass::Open,
        );
        assert!(result.is_ok());
    }

    #[test]
    fn test_is_expired_or_delisted() {
        // Active, not expired
        assert!(!ExpiryGuard::is_expired_or_delisted(true, Some(2000), 1000));

        // Active, expired
        assert!(ExpiryGuard::is_expired_or_delisted(true, Some(1000), 2000));

        // Delisted
        assert!(ExpiryGuard::is_expired_or_delisted(false, None, 1000));

        // Perpetual (no expiry)
        assert!(!ExpiryGuard::is_expired_or_delisted(true, None, 1000));
    }
}
