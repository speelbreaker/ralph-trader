//! GET /api/v1/health handler.
//!
//! Per CONTRACT.md §7.0 AT-022:
//! - Response MUST include ok=true, build_id, contract_version.
//! - Side-effect: update watchdog_last_heartbeat_ts_ms = now_ms (§3.2 Smart Watchdog).
//! - Non-GET requests MUST be rejected with 405 (AT-407).
//! - Observability: http_health_calls_total counter.
//!
//! Self-contained: no dependency on crate module tree; safe to include via #[path] in tests.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Contract version per CONTRACT.md Definitions.
pub const CONTRACT_VERSION: &str = "5.2";

/// HTTP method for routing (AT-407: non-GET MUST be rejected).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Delete,
}

/// Minimal HTTP request.
#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub method: HttpMethod,
}

impl HttpRequest {
    pub fn get() -> Self {
        Self {
            method: HttpMethod::Get,
        }
    }

    pub fn with_method(method: HttpMethod) -> Self {
        Self { method }
    }
}

/// Minimal HTTP response.
#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
}

/// Health payload fields.
#[derive(Debug, Clone)]
pub struct HealthPayload {
    pub ok: bool,
    pub build_id: String,
    pub contract_version: String,
}

impl HealthPayload {
    /// Serialize to minimal JSON string (no external dependency).
    pub fn to_json(&self) -> String {
        let ok_str = if self.ok { "true" } else { "false" };
        format!(
            r#"{{"ok":{},"build_id":"{}","contract_version":"{}"}}"#,
            ok_str,
            escape_json(self.build_id.as_str()),
            escape_json(self.contract_version.as_str()),
        )
    }
}

fn escape_json(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Shared state updated by GET /api/v1/health.
pub struct HealthState {
    /// Last heartbeat timestamp ms (epoch). Updated on each successful GET.
    /// Per CONTRACT.md §3.2: used by PolicyGuard for watchdog evaluation.
    pub watchdog_last_heartbeat_ts_ms: Arc<AtomicU64>,
    /// Total GET /api/v1/health calls (observability: http_health_calls_total counter).
    pub http_health_calls_total: Arc<AtomicU64>,
    /// Build identifier (git SHA or build tag).
    pub build_id: String,
}

impl HealthState {
    pub fn new(build_id: impl Into<String>) -> Self {
        Self {
            watchdog_last_heartbeat_ts_ms: Arc::new(AtomicU64::new(0)),
            http_health_calls_total: Arc::new(AtomicU64::new(0)),
            build_id: build_id.into(),
        }
    }

    /// Read the current watchdog_last_heartbeat_ts_ms value.
    pub fn last_heartbeat_ts_ms(&self) -> u64 {
        self.watchdog_last_heartbeat_ts_ms.load(Ordering::Relaxed)
    }

    /// Read the total health call count.
    pub fn health_calls_total(&self) -> u64 {
        self.http_health_calls_total.load(Ordering::Relaxed)
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Handle a request to GET /api/v1/health.
///
/// - GET → 200 JSON { ok: true, build_id, contract_version } + update watchdog heartbeat (AT-022).
/// - Non-GET → 405 (AT-407).
pub fn handle_health(req: &HttpRequest, state: &HealthState) -> HttpResponse {
    if req.method != HttpMethod::Get {
        return HttpResponse {
            status: 405,
            body: r#"{"error":"method not allowed"}"#.to_string(),
        };
    }

    // Side-effect: update watchdog_last_heartbeat_ts_ms = now_ms (CONTRACT.md §3.2).
    state
        .watchdog_last_heartbeat_ts_ms
        .store(now_ms(), Ordering::Relaxed);

    // Increment http_health_calls_total observability counter.
    state
        .http_health_calls_total
        .fetch_add(1, Ordering::Relaxed);

    let payload = HealthPayload {
        ok: true,
        build_id: state.build_id.clone(),
        contract_version: CONTRACT_VERSION.to_string(),
    };

    HttpResponse {
        status: 200,
        body: payload.to_json(),
    }
}
