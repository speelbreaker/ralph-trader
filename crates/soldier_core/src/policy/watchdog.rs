//! Smart Watchdog state machine and emergency reduce-only handler.
//!
//! Per CONTRACT.md §3.2 and §2.2:
//! - `POST /api/v1/emergency/reduce_only` sets `emergency_reduceonly_until_ts_ms = now_ms + cooldown_ms`.
//! - `emergency_reduceonly_active == (now_ms < emergency_reduceonly_until_ts_ms)`.
//! - While active: cancel orders with `reduce_only == false`; preserve reduce-only closes/hedges.
//! - If exposure > limit while active: submit reduce-only hedge.
//! - Smart Watchdog: if `ws_silence_ms > 5000`, invoke the same emergency_reduceonly handler (AT-237, AT-203).
//! - Cooldown cleared when expired AND reconcile confirms safe.
//!
//! Observability: `http_emergency_reduce_only_calls_total` counter.
//!
//! Self-contained: no dependency on crate module tree; safe to include via #[path] in tests.

// NOTE: items not yet wired into the integration produce dead_code warnings intentionally.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Default cooldown in seconds per CONTRACT.md Appendix A.
pub const EMERGENCY_REDUCEONLY_COOLDOWN_S: u64 = 300;

/// Watchdog silence threshold in milliseconds per CONTRACT.md §3.2 / Appendix A.
pub const WS_SILENCE_TRIGGER_MS: u64 = 5_000;

/// HTTP method for routing (reused from handler pattern).
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
    pub fn post() -> Self {
        Self {
            method: HttpMethod::Post,
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

/// Order representation used by the watchdog cancellation logic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Order {
    pub order_id: String,
    /// If true, this is a reduce-only close/hedge order (must NOT be canceled under emergency).
    pub reduce_only: bool,
}

/// Outcome of the emergency reduce-only evaluation for a set of orders.
#[derive(Debug, Clone, Default)]
pub struct EmergencyReduceOnlyEffect {
    /// Orders that MUST be canceled (reduce_only == false).
    pub cancel_orders: Vec<String>,
    /// Orders that MUST be preserved (reduce_only == true).
    pub preserve_orders: Vec<String>,
    /// Whether a reduce-only hedge should be submitted (exposure > limit while active).
    pub submit_hedge: bool,
}

/// Shared state for the emergency reduce-only latch.
pub struct EmergencyReduceOnlyState {
    /// Timestamp (epoch ms) until which the emergency reduce-only latch is active.
    /// Active when `now_ms < emergency_reduceonly_until_ts_ms`.
    pub emergency_reduceonly_until_ts_ms: Arc<AtomicU64>,
    /// Cooldown duration in ms (default: 300s * 1000).
    pub cooldown_ms: u64,
    /// Observability counter: total calls to POST /api/v1/emergency/reduce_only.
    pub http_emergency_reduce_only_calls_total: Arc<AtomicU64>,
}

impl EmergencyReduceOnlyState {
    pub fn new(cooldown_s: u64) -> Self {
        Self {
            emergency_reduceonly_until_ts_ms: Arc::new(AtomicU64::new(0)),
            cooldown_ms: cooldown_s.saturating_mul(1000),
            http_emergency_reduce_only_calls_total: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Whether the emergency reduce-only latch is currently active.
    pub fn is_active(&self, now_ms: u64) -> bool {
        let until = self
            .emergency_reduceonly_until_ts_ms
            .load(Ordering::Relaxed);
        until > 0 && now_ms < until
    }

    /// Activate the emergency reduce-only latch with the current timestamp.
    /// Sets `emergency_reduceonly_until_ts_ms = now_ms + cooldown_ms`.
    pub fn activate(&self, now_ms: u64) {
        let until = now_ms.saturating_add(self.cooldown_ms);
        self.emergency_reduceonly_until_ts_ms
            .store(until, Ordering::Relaxed);
        self.http_emergency_reduce_only_calls_total
            .fetch_add(1, Ordering::Relaxed);
    }

    /// Read the until-timestamp.
    pub fn until_ts_ms(&self) -> u64 {
        self.emergency_reduceonly_until_ts_ms
            .load(Ordering::Relaxed)
    }

    /// Total calls counter.
    pub fn calls_total(&self) -> u64 {
        self.http_emergency_reduce_only_calls_total
            .load(Ordering::Relaxed)
    }

    /// Clear the latch (cooldown expired and reconcile confirms safe).
    pub fn clear(&self) {
        self.emergency_reduceonly_until_ts_ms
            .store(0, Ordering::Relaxed);
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Handle `POST /api/v1/emergency/reduce_only`.
///
/// - POST → 200 JSON `{"ok":true,"emergency_reduceonly_until_ts_ms":<ts>}` + activate latch (AT acceptance).
/// - Non-POST → 405 (AT-407 pattern: wrong-method rejection).
pub fn handle_emergency_reduce_only(
    req: &HttpRequest,
    state: &EmergencyReduceOnlyState,
) -> HttpResponse {
    if req.method != HttpMethod::Post {
        return HttpResponse {
            status: 405,
            body: r#"{"error":"method not allowed"}"#.to_string(),
        };
    }

    let ts = now_ms();
    state.activate(ts);
    let until = state.until_ts_ms();

    HttpResponse {
        status: 200,
        body: format!(
            r#"{{"ok":true,"emergency_reduceonly_until_ts_ms":{}}}"#,
            until
        ),
    }
}

/// Handle `POST /api/v1/emergency/reduce_only` with an injected timestamp (for testing).
pub fn handle_emergency_reduce_only_at(
    req: &HttpRequest,
    state: &EmergencyReduceOnlyState,
    now_ms: u64,
) -> HttpResponse {
    if req.method != HttpMethod::Post {
        return HttpResponse {
            status: 405,
            body: r#"{"error":"method not allowed"}"#.to_string(),
        };
    }

    state.activate(now_ms);
    let until = state.until_ts_ms();

    HttpResponse {
        status: 200,
        body: format!(
            r#"{{"ok":true,"emergency_reduceonly_until_ts_ms":{}}}"#,
            until
        ),
    }
}

/// Evaluate orders under emergency reduce-only and compute cancellations/preservations.
///
/// Per CONTRACT.md §3.2:
/// - Cancel orders where `reduce_only == false`.
/// - Preserve orders where `reduce_only == true` (closes/hedges).
/// - If `exposure_notional > exposure_limit` and active: set `submit_hedge = true`.
pub fn evaluate_emergency_reduceonly(
    orders: &[Order],
    exposure_notional: f64,
    exposure_limit: f64,
) -> EmergencyReduceOnlyEffect {
    let mut effect = EmergencyReduceOnlyEffect::default();

    for order in orders {
        if order.reduce_only {
            effect.preserve_orders.push(order.order_id.clone());
        } else {
            effect.cancel_orders.push(order.order_id.clone());
        }
    }

    if exposure_notional > exposure_limit {
        effect.submit_hedge = true;
    }

    effect
}

/// Smart Watchdog trigger check.
///
/// Per CONTRACT.md §3.2: if `ws_silence_ms > 5000`, invoke the emergency_reduceonly handler.
/// Returns true if the watchdog triggered (and activated the latch).
pub fn check_watchdog(ws_silence_ms: u64, state: &EmergencyReduceOnlyState, now_ms: u64) -> bool {
    if ws_silence_ms > WS_SILENCE_TRIGGER_MS {
        state.activate(now_ms);
        true
    } else {
        false
    }
}

/// Check whether cooldown has expired; clear latch if so and reconcile_safe is true.
///
/// Per CONTRACT.md §2.2: latch remains active for `emergency_reduceonly_cooldown_s` after call.
/// Once expired AND reconcile confirms safe, clear latch.
pub fn maybe_clear_emergency_reduceonly(
    state: &EmergencyReduceOnlyState,
    now_ms: u64,
    reconcile_safe: bool,
) {
    let until = state.until_ts_ms();
    if until > 0 && now_ms >= until && reconcile_safe {
        state.clear();
    }
}
