//! HTTP router for owner-grade endpoints.
//!
//! Per CONTRACT.md §7.0: owner endpoints are read-only; non-GET requests MUST be rejected (AT-407).
//!
//! Route table:
//! - GET /api/v1/health → health handler (AT-022)
//! - GET /api/v1/status → status handler (AT-023, AT-405)
//! - POST /api/v1/emergency/reduce_only → emergency reduce-only handler (§2.2, §3.2)
//! - Non-GET to GET-only endpoints → 405 (AT-407)
//! - Unknown paths → 404

/// Known owner endpoint paths.
pub const PATH_HEALTH: &str = "/api/v1/health";
pub const PATH_STATUS: &str = "/api/v1/status";
pub const PATH_EMERGENCY_REDUCE_ONLY: &str = "/api/v1/emergency/reduce_only";
