//! GET /api/v1/status handler.
//!
//! Per CONTRACT.md §7.0:
//! - Response MUST include all CSP minimum fields (AT-023).
//! - status_schema_version MUST be 1 (AT-405).
//! - mode_reasons MUST be [] when trading_mode == Active (AT-024).
//! - mode_reasons MUST be tier-pure (AT-025) and ordered (AT-026).
//! - open_permission invariants (AT-027).
//! - last_policy_update_ts MUST equal python_policy_generated_ts_ms (AT-028).
//! - snapshot_coverage_pct MUST be computed over replay_window_hours (AT-029, GOP).
//! - GOP extension keys when enforced_profile != CSP (AT-967).
//! - f1_cert_expires_at semantics (AT-003, PL-5).
//! - Non-GET MUST be rejected with 405 (AT-407).
//! - Observability: http_status_calls_total counter.
//!
//! Self-contained: no dependency on crate module tree beyond shared http primitives.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

// Shared HTTP primitives and contract version. These come from health.rs which is
// included via #[path] in tests, or via the http module in normal crate compilation.
pub use super::health::{CONTRACT_VERSION, HttpMethod, HttpRequest, HttpResponse};

/// Schema version per CONTRACT.md §7.0 AT-405.
pub const STATUS_SCHEMA_VERSION: u64 = 1;

/// F1 certificate state values per CONTRACT.md §7.0.
#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum F1CertState {
    Pass,
    Fail,
    Stale,
    Missing,
    Invalid,
}

impl F1CertState {
    pub fn as_str(&self) -> &'static str {
        match self {
            F1CertState::Pass => "PASS",
            F1CertState::Fail => "FAIL",
            F1CertState::Stale => "STALE",
            F1CertState::Missing => "MISSING",
            F1CertState::Invalid => "INVALID",
        }
    }
}

/// GOP extension field value when not enforced.
pub const NOT_ENFORCED: &str = "NOT_ENFORCED";

/// Inputs required to build the /status response.
///
/// All fields correspond directly to CONTRACT.md §7.0 required status fields.
#[derive(Debug, Clone)]
pub struct StatusInputs {
    // Identity
    pub build_id: String,
    pub runtime_config_hash: String,
    pub supported_profiles: Vec<String>,
    pub enforced_profile: String,

    // Trading state
    pub trading_mode: String,
    pub risk_state: String,
    pub bunker_mode_active: bool,
    pub mode_reasons: Vec<String>,

    // Open permission latch
    pub open_permission_blocked_latch: bool,
    pub open_permission_reason_codes: Vec<String>,

    // Policy
    pub python_policy_generated_ts_ms: u64,
    pub now_ms: u64,

    // F1 cert (AT-003, PL-5)
    pub f1_cert_state: F1CertState,
    /// f1_cert.generated_ts_ms + freshness_window_s * 1000 when parseable; None when missing/unparseable.
    pub f1_cert_expires_at: Option<u64>,

    // Disk (§2.2.1.1)
    pub disk_used_pct: f64,
    pub disk_used_last_update_ts_ms: u64,
    pub disk_used_pct_secondary: f64,
    pub disk_used_secondary_last_update_ts_ms: u64,

    // Margin (§2.2.1.1)
    pub mm_util: f64,
    pub mm_util_last_update_ts_ms: u64,

    // Loop
    pub loop_tick_last_ts_ms: u64,

    // WAL (§2.4.1)
    pub wal_queue_depth: u64,
    pub wal_queue_capacity: u64,
    pub wal_queue_enqueue_failures: u64,

    // Metrics
    pub atomic_naked_events_24h: u64,
    pub count_429_5m: u64,
    pub count_10028_5m: u64,
    pub deribit_http_p95_ms: f64,
    pub ws_event_lag_ms: u64,

    // GOP extension keys (required when enforced_profile != CSP per AT-967)
    pub evidence_chain_state: Option<String>,
    pub snapshot_coverage_pct: Option<f64>,
    pub replay_quality: Option<String>,
    pub replay_apply_mode: Option<String>,
    pub open_haircut_mult: Option<f64>,
}

impl StatusInputs {
    /// Compute connectivity_degraded per CONTRACT.md §7.0.
    ///
    /// True iff bunker_mode_active OR any open_permission_reason_codes is a connectivity code.
    pub fn connectivity_degraded(&self) -> bool {
        const CONNECTIVITY_CODES: &[&str] = &[
            "RESTART_RECONCILE_REQUIRED",
            "WS_BOOK_GAP_RECONCILE_REQUIRED",
            "WS_TRADES_GAP_RECONCILE_REQUIRED",
            "WS_DATA_STALE_RECONCILE_REQUIRED",
            "INVENTORY_MISMATCH_RECONCILE_REQUIRED",
            "SESSION_TERMINATION_RECONCILE_REQUIRED",
        ];
        if self.bunker_mode_active {
            return true;
        }
        self.open_permission_reason_codes
            .iter()
            .any(|code| CONNECTIVITY_CODES.contains(&code.as_str()))
    }

    /// open_permission_requires_reconcile per CONTRACT.md §7.0.
    ///
    /// MUST equal open_permission_blocked_latch (all reason codes are reconcile-class in v5.1).
    pub fn open_permission_requires_reconcile(&self) -> bool {
        self.open_permission_blocked_latch
    }

    /// policy_age_sec per CONTRACT.md §7.0.
    pub fn policy_age_sec(&self) -> u64 {
        if self.now_ms >= self.python_policy_generated_ts_ms {
            (self.now_ms - self.python_policy_generated_ts_ms) / 1000
        } else {
            0
        }
    }
}

/// State for the /api/v1/status endpoint.
pub struct StatusState {
    /// Observability counter (http_status_calls_total).
    pub http_status_calls_total: Arc<AtomicU64>,
}

impl StatusState {
    pub fn new() -> Self {
        Self {
            http_status_calls_total: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn status_calls_total(&self) -> u64 {
        self.http_status_calls_total.load(Ordering::Relaxed)
    }
}

impl Default for StatusState {
    fn default() -> Self {
        Self::new()
    }
}

fn escape_json(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn json_str(s: &str) -> String {
    format!(r#""{}""#, escape_json(s))
}

fn json_bool(b: bool) -> &'static str {
    if b { "true" } else { "false" }
}

fn json_f64(v: f64) -> String {
    if !v.is_finite() {
        return "null".to_string();
    }
    if v.fract() == 0.0 {
        format!("{v:.1}")
    } else {
        format!("{v}")
    }
}

fn json_str_array(arr: &[String]) -> String {
    let items: Vec<String> = arr.iter().map(|s| json_str(s)).collect();
    format!("[{}]", items.join(","))
}

/// Build the JSON body for GET /api/v1/status.
///
/// Returns a minimal-dependency serialized JSON string with all required CSP fields
/// and, when enforced_profile != CSP, GOP extension keys.
pub fn build_status_json(inp: &StatusInputs) -> String {
    let policy_age = inp.policy_age_sec();
    let connectivity_degraded = inp.connectivity_degraded();
    let open_requires_reconcile = inp.open_permission_requires_reconcile();

    // f1_cert_expires_at: integer or null.
    let f1_expires_str = match inp.f1_cert_expires_at {
        Some(ts) => ts.to_string(),
        None => "null".to_string(),
    };

    let is_csp = inp.enforced_profile == "CSP";

    // GOP extension fields: actual values when GOP enforced, NOT_ENFORCED when CSP.
    let evidence_chain_state_str = if is_csp {
        json_str(NOT_ENFORCED)
    } else {
        match &inp.evidence_chain_state {
            Some(v) => json_str(v),
            None => json_str(NOT_ENFORCED),
        }
    };
    let snapshot_coverage_pct_str = if is_csp {
        json_str(NOT_ENFORCED)
    } else {
        match inp.snapshot_coverage_pct {
            Some(v) => json_f64(v),
            None => json_str(NOT_ENFORCED),
        }
    };
    let replay_quality_str = if is_csp {
        json_str(NOT_ENFORCED)
    } else {
        match &inp.replay_quality {
            Some(v) => json_str(v),
            None => json_str(NOT_ENFORCED),
        }
    };
    let replay_apply_mode_str = if is_csp {
        json_str(NOT_ENFORCED)
    } else {
        match &inp.replay_apply_mode {
            Some(v) => json_str(v),
            None => json_str(NOT_ENFORCED),
        }
    };
    let open_haircut_mult_str = if is_csp {
        json_str(NOT_ENFORCED)
    } else {
        match inp.open_haircut_mult {
            Some(v) => json_f64(v),
            None => json_str(NOT_ENFORCED),
        }
    };

    format!(
        concat!(
            "{{",
            r#""status_schema_version":{schema_ver},"#,
            r#""contract_version":{contract_ver},"#,
            r#""build_id":{build_id},"#,
            r#""runtime_config_hash":{runtime_config_hash},"#,
            r#""supported_profiles":{supported_profiles},"#,
            r#""enforced_profile":{enforced_profile},"#,
            r#""trading_mode":{trading_mode},"#,
            r#""risk_state":{risk_state},"#,
            r#""bunker_mode_active":{bunker_mode_active},"#,
            r#""connectivity_degraded":{connectivity_degraded},"#,
            r#""mode_reasons":{mode_reasons},"#,
            r#""open_permission_blocked_latch":{open_permission_blocked_latch},"#,
            r#""open_permission_reason_codes":{open_permission_reason_codes},"#,
            r#""open_permission_requires_reconcile":{open_permission_requires_reconcile},"#,
            r#""policy_age_sec":{policy_age_sec},"#,
            r#""last_policy_update_ts":{last_policy_update_ts},"#,
            r#""f1_cert_state":{f1_cert_state},"#,
            r#""f1_cert_expires_at":{f1_cert_expires_at},"#,
            r#""disk_used_pct":{disk_used_pct},"#,
            r#""disk_used_last_update_ts_ms":{disk_used_last_update_ts_ms},"#,
            r#""disk_used_pct_secondary":{disk_used_pct_secondary},"#,
            r#""disk_used_secondary_last_update_ts_ms":{disk_used_secondary_last_update_ts_ms},"#,
            r#""mm_util":{mm_util},"#,
            r#""mm_util_last_update_ts_ms":{mm_util_last_update_ts_ms},"#,
            r#""loop_tick_last_ts_ms":{loop_tick_last_ts_ms},"#,
            r#""wal_queue_depth":{wal_queue_depth},"#,
            r#""wal_queue_capacity":{wal_queue_capacity},"#,
            r#""wal_queue_enqueue_failures":{wal_queue_enqueue_failures},"#,
            r#""atomic_naked_events_24h":{atomic_naked_events_24h},"#,
            r#""429_count_5m":{count_429_5m},"#,
            r#""10028_count_5m":{count_10028_5m},"#,
            r#""deribit_http_p95_ms":{deribit_http_p95_ms},"#,
            r#""ws_event_lag_ms":{ws_event_lag_ms},"#,
            r#""evidence_chain_state":{evidence_chain_state},"#,
            r#""snapshot_coverage_pct":{snapshot_coverage_pct},"#,
            r#""replay_quality":{replay_quality},"#,
            r#""replay_apply_mode":{replay_apply_mode},"#,
            r#""open_haircut_mult":{open_haircut_mult}"#,
            "}}"
        ),
        schema_ver = STATUS_SCHEMA_VERSION,
        contract_ver = json_str(CONTRACT_VERSION),
        build_id = json_str(&inp.build_id),
        runtime_config_hash = json_str(&inp.runtime_config_hash),
        supported_profiles = json_str_array(&inp.supported_profiles),
        enforced_profile = json_str(&inp.enforced_profile),
        trading_mode = json_str(&inp.trading_mode),
        risk_state = json_str(&inp.risk_state),
        bunker_mode_active = json_bool(inp.bunker_mode_active),
        connectivity_degraded = json_bool(connectivity_degraded),
        mode_reasons = json_str_array(&inp.mode_reasons),
        open_permission_blocked_latch = json_bool(inp.open_permission_blocked_latch),
        open_permission_reason_codes = json_str_array(&inp.open_permission_reason_codes),
        open_permission_requires_reconcile = json_bool(open_requires_reconcile),
        policy_age_sec = policy_age,
        last_policy_update_ts = inp.python_policy_generated_ts_ms,
        f1_cert_state = json_str(inp.f1_cert_state.as_str()),
        f1_cert_expires_at = f1_expires_str,
        disk_used_pct = json_f64(inp.disk_used_pct),
        disk_used_last_update_ts_ms = inp.disk_used_last_update_ts_ms,
        disk_used_pct_secondary = json_f64(inp.disk_used_pct_secondary),
        disk_used_secondary_last_update_ts_ms = inp.disk_used_secondary_last_update_ts_ms,
        mm_util = json_f64(inp.mm_util),
        mm_util_last_update_ts_ms = inp.mm_util_last_update_ts_ms,
        loop_tick_last_ts_ms = inp.loop_tick_last_ts_ms,
        wal_queue_depth = inp.wal_queue_depth,
        wal_queue_capacity = inp.wal_queue_capacity,
        wal_queue_enqueue_failures = inp.wal_queue_enqueue_failures,
        atomic_naked_events_24h = inp.atomic_naked_events_24h,
        count_429_5m = inp.count_429_5m,
        count_10028_5m = inp.count_10028_5m,
        deribit_http_p95_ms = json_f64(inp.deribit_http_p95_ms),
        ws_event_lag_ms = inp.ws_event_lag_ms,
        evidence_chain_state = evidence_chain_state_str,
        snapshot_coverage_pct = snapshot_coverage_pct_str,
        replay_quality = replay_quality_str,
        replay_apply_mode = replay_apply_mode_str,
        open_haircut_mult = open_haircut_mult_str,
    )
}

/// Handle a request to GET /api/v1/status.
///
/// - GET → 200 JSON with all CSP-minimum fields (AT-023) and GOP keys (AT-967).
/// - Non-GET → 405 (AT-407).
/// - Increments http_status_calls_total on success.
pub fn handle_status(
    req: &HttpRequest,
    state: &StatusState,
    inputs: &StatusInputs,
) -> HttpResponse {
    if req.method != HttpMethod::Get {
        return HttpResponse {
            status: 405,
            body: r#"{"error":"method not allowed"}"#.to_string(),
        };
    }

    // Increment http_status_calls_total observability counter.
    state
        .http_status_calls_total
        .fetch_add(1, Ordering::Relaxed);

    let body = build_status_json(inputs);

    HttpResponse { status: 200, body }
}
