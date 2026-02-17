//! HTTP router for owner-grade endpoints.
//!
//! Per CONTRACT.md §7.0: owner endpoints are read-only; non-GET requests MUST be rejected (AT-407).
//!
//! Route table:
//! - GET /api/v1/health → health handler (AT-022)
//! - Non-GET to any owner endpoint → 405 (AT-407)
//! - Unknown paths → 404

/// Known owner endpoint paths.
pub const PATH_HEALTH: &str = "/api/v1/health";
