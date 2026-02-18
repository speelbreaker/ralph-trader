//! PolicyGuard bunker mode wrapper + F1 certification gate.
//! Per CONTRACT.md §2.3.2, §2.2.3, §2.2.1.
//!
//! When `bunker_mode_active == true`, PolicyGuard returns TradingMode::ReduceOnly
//! and OPEN intents are blocked. CLOSE/HEDGE/CANCEL remain allowed (§2.2.5).
//!
//! F1Gate (§2.2.1): missing/stale/FAIL/INVALID cert → ReduceOnly. No last-known-good bypass.
//!
//! Self-contained: no dependency on crate module tree; safe to include via #[path] in tests.

// NOTE: items in this module that are not yet wired into the integration (Slice 9+)
// will produce dead_code warnings. That is intentional — remove the old module-wide
// suppression so the compiler can flag unintegrated API surface.

// ─── SHA-256 (pure Rust, no external deps) ────────────────────────────────────

/// Round constants (first 32 bits of fractional parts of cube roots of primes 23–311).
const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Initial hash values (first 32 bits of fractional parts of square roots of primes 2–19).
const H0: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// Compute SHA-256 of `data` and return 32-byte digest.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h = H0;
    let bit_len = (data.len() as u64).wrapping_mul(8);

    // Pre-processing: add padding.
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0x00);
    }
    // Append length as big-endian 64-bit.
    msg.extend_from_slice(&bit_len.to_be_bytes());

    // Process each 512-bit (64-byte) block.
    for block in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, chunk) in block.chunks(4).enumerate().take(16) {
            w[i] = u32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..(i + 1) * 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

/// Encode a byte slice to lowercase hex string.
pub fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

// ─── Canonical JSON serializer (sorted keys, no whitespace, AT-113) ───────────

/// Serialize a JSON-like value to canonical bytes: sorted keys, no insignificant whitespace.
/// Supports: null, bool, number (integer/float), string, array, object.
/// This is used to compute `runtime_config_hash` (PL-2).
pub fn canonical_json_bytes(value: &JsonValue) -> Vec<u8> {
    let mut buf = Vec::new();
    write_canonical(&mut buf, value);
    buf
}

/// Minimal JSON value type for canonical hashing.
#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

fn write_canonical(buf: &mut Vec<u8>, val: &JsonValue) {
    match val {
        JsonValue::Null => buf.extend_from_slice(b"null"),
        JsonValue::Bool(b) => {
            if *b {
                buf.extend_from_slice(b"true");
            } else {
                buf.extend_from_slice(b"false");
            }
        }
        JsonValue::Int(n) => buf.extend_from_slice(n.to_string().as_bytes()),
        JsonValue::Float(f) => {
            // Match Python's json.dumps behavior: whole-number floats get ".0" suffix (e.g. 1.0
            // → "1.0"), fractional floats keep full precision (e.g. 1.5 → "1.5"). Without this,
            // Rust's format!("{f}") produces "1" for 1.0_f64, causing a hash divergence vs Python.
            let s = if f.is_finite() && f.fract() == 0.0 {
                format!("{f:.1}")
            } else {
                format!("{f}")
            };
            buf.extend_from_slice(s.as_bytes());
        }
        JsonValue::Str(s) => {
            buf.push(b'"');
            for ch in s.chars() {
                match ch {
                    '"' => buf.extend_from_slice(b"\\\""),
                    '\\' => buf.extend_from_slice(b"\\\\"),
                    '\n' => buf.extend_from_slice(b"\\n"),
                    '\r' => buf.extend_from_slice(b"\\r"),
                    '\t' => buf.extend_from_slice(b"\\t"),
                    c if (c as u32) < 0x20 => {
                        buf.extend_from_slice(format!("\\u{:04x}", c as u32).as_bytes());
                    }
                    c => {
                        let mut tmp = [0u8; 4];
                        let s = c.encode_utf8(&mut tmp);
                        buf.extend_from_slice(s.as_bytes());
                    }
                }
            }
            buf.push(b'"');
        }
        JsonValue::Array(arr) => {
            buf.push(b'[');
            for (i, v) in arr.iter().enumerate() {
                if i > 0 {
                    buf.push(b',');
                }
                write_canonical(buf, v);
            }
            buf.push(b']');
        }
        JsonValue::Object(pairs) => {
            // Sort by key (canonical ordering).
            let mut sorted: Vec<(&String, &JsonValue)> =
                pairs.iter().map(|(k, v)| (k, v)).collect();
            sorted.sort_by(|a, b| a.0.cmp(b.0));
            buf.push(b'{');
            for (i, (k, v)) in sorted.iter().enumerate() {
                if i > 0 {
                    buf.push(b',');
                }
                write_canonical(buf, &JsonValue::Str((*k).clone()));
                buf.push(b':');
                write_canonical(buf, v);
            }
            buf.push(b'}');
        }
    }
}

/// Compute runtime_config_hash: sha256(canonical_json_bytes(config)) as hex string.
/// Per CONTRACT.md §2.2.1 and PL-2.
pub fn compute_runtime_config_hash(config: &JsonValue) -> String {
    let bytes = canonical_json_bytes(config);
    hex_encode(&sha256(&bytes))
}

// ─── F1 certification gate (§2.2.1) ──────────────────────────────────────────

/// Runtime bindings for F1 cert validation.
pub struct F1RuntimeBindings {
    /// Runtime contract version string (must equal "5.2"; no "v" prefix allowed). AT-012.
    pub contract_version: String,
    /// Runtime build identifier (e.g., git commit SHA).
    pub build_id: String,
    /// Runtime config hash: sha256(canonical_json(runtime_config)).
    pub runtime_config_hash: String,
}

/// Configuration for the F1Gate.
pub struct F1GateConfig {
    /// Path to `artifacts/F1_CERT.json`. Loaded fresh each evaluation.
    pub cert_path: String,
    /// Freshness window in seconds. Default 86400 (24h). Per Appendix A.2.1.
    pub f1_cert_freshness_window_s: u64,
}

impl Default for F1GateConfig {
    fn default() -> Self {
        Self {
            cert_path: "artifacts/F1_CERT.json".to_string(),
            f1_cert_freshness_window_s: 86_400,
        }
    }
}

/// F1 certification status as evaluated by F1Gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum F1CertStatus {
    /// Cert is valid: status=PASS, fresh, and all bindings match runtime.
    Valid,
    /// Cert file missing, unreadable, or unparseable.
    Missing,
    /// Cert present but status field != "PASS".
    Fail,
    /// Cert present and status=PASS, but stale (age > freshness window).
    Stale,
    /// Cert present and status=PASS, but binding mismatch (build_id/runtime_config_hash/contract_version).
    Invalid,
}

impl F1CertStatus {
    /// True if this status requires ReduceOnly (blocks OPEN intents).
    pub fn requires_reduce_only(self) -> bool {
        !matches!(self, F1CertStatus::Valid)
    }
}

/// F1Gate — runtime F1 certification gate (CONTRACT.md §2.2.1).
///
/// - Missing/unparseable cert → Missing (ReduceOnly).
/// - status != "PASS" → Fail (ReduceOnly).
/// - Stale (now_ms - generated_ts_ms > freshness_window) → Stale (ReduceOnly). No bypass.
/// - Binding mismatch (build_id/runtime_config_hash/contract_version) → Invalid (ReduceOnly).
/// - contract_version with "v" prefix → Invalid (AT-012).
pub struct F1Gate {
    /// Observability: age of cert in seconds at last evaluation (0 if cert missing).
    pub f1_cert_age_s: u64,
    /// Observability: total count of times gate blocked OPEN due to cert invalidity.
    pub f1_cert_gate_block_opens_total: u64,
    /// Last evaluated cert status.
    pub last_status: F1CertStatus,
}

impl F1Gate {
    pub fn new() -> Self {
        Self {
            f1_cert_age_s: 0,
            f1_cert_gate_block_opens_total: 0,
            last_status: F1CertStatus::Missing,
        }
    }

    /// Evaluate F1 cert from `cert_json` string (pre-read from file).
    /// `now_ms` is current wall-clock time in milliseconds.
    /// Returns `F1CertStatus`.
    pub fn evaluate(
        &mut self,
        cert_json: Option<&str>,
        now_ms: u64,
        config: &F1GateConfig,
        runtime: &F1RuntimeBindings,
    ) -> F1CertStatus {
        let status = self.compute_status(cert_json, now_ms, config, runtime);
        self.last_status = status;
        status
    }

    /// Record that an OPEN was blocked by the F1 gate.
    pub fn record_blocked_open(&mut self) {
        self.f1_cert_gate_block_opens_total += 1;
    }

    fn compute_status(
        &mut self,
        cert_json: Option<&str>,
        now_ms: u64,
        config: &F1GateConfig,
        runtime: &F1RuntimeBindings,
    ) -> F1CertStatus {
        // 1. Missing/unparseable → Missing.
        let json_str = match cert_json {
            Some(s) if !s.trim().is_empty() => s,
            _ => {
                self.f1_cert_age_s = 0;
                return F1CertStatus::Missing;
            }
        };

        let cert = match parse_f1_cert(json_str) {
            Some(c) => c,
            None => {
                self.f1_cert_age_s = 0;
                return F1CertStatus::Missing;
            }
        };

        // 2. status field check.
        if cert.status != "PASS" {
            let age_ms = now_ms.saturating_sub(cert.generated_ts_ms);
            self.f1_cert_age_s = age_ms / 1_000;
            return F1CertStatus::Fail;
        }

        // 3. Staleness check — no last-known-good bypass (AT-021).
        let age_ms = now_ms.saturating_sub(cert.generated_ts_ms);
        self.f1_cert_age_s = age_ms / 1_000;
        let freshness_ms = config.f1_cert_freshness_window_s * 1_000;
        if age_ms > freshness_ms {
            return F1CertStatus::Stale;
        }

        // 4. contract_version format: must not have "v" prefix (AT-012).
        if cert.contract_version.starts_with('v') || cert.contract_version.starts_with('V') {
            return F1CertStatus::Invalid;
        }

        // 5. Binding checks: contract_version, build_id, runtime_config_hash.
        if cert.contract_version != runtime.contract_version
            || cert.build_id != runtime.build_id
            || cert.runtime_config_hash != runtime.runtime_config_hash
        {
            return F1CertStatus::Invalid;
        }

        F1CertStatus::Valid
    }
}

impl Default for F1Gate {
    fn default() -> Self {
        Self::new()
    }
}

/// Minimal parsed F1_CERT fields.
struct F1CertFields {
    status: String,
    generated_ts_ms: u64,
    build_id: String,
    runtime_config_hash: String,
    contract_version: String,
}

/// Parse only the required fields from F1_CERT JSON string.
/// Returns None if any required field is missing or unparseable.
fn parse_f1_cert(json: &str) -> Option<F1CertFields> {
    let status = extract_json_str(json, "status")?;
    let generated_ts_ms = extract_json_u64(json, "generated_ts_ms")?;
    let build_id = extract_json_str(json, "build_id")?;
    let runtime_config_hash = extract_json_str(json, "runtime_config_hash")?;
    let contract_version = extract_json_str(json, "contract_version")?;
    Some(F1CertFields {
        status,
        generated_ts_ms,
        build_id,
        runtime_config_hash,
        contract_version,
    })
}

/// Count unescaped double-quote characters in `s` (for JSON context detection).
fn count_unescaped_quotes(s: &str) -> usize {
    let mut count = 0;
    let mut escaped = false;
    for ch in s.chars() {
        if escaped {
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else if ch == '"' {
            count += 1;
        }
    }
    count
}

/// Extract a string value from a flat JSON object by key. Handles basic escaping.
///
/// Uses unescaped-quote counting to verify that the found `"key"` is at an object-key
/// position (even number of preceding quotes) rather than inside a string value.
fn extract_json_str(json: &str, key: &str) -> Option<String> {
    let search = format!("\"{}\"", key);
    let mut start = 0;
    loop {
        let rel = json[start..].find(&search)?;
        let pos = start + rel;
        // If an even number of unescaped quotes precede `pos`, we are outside a string.
        if count_unescaped_quotes(&json[..pos]) % 2 == 0 {
            let after_key = &json[pos + search.len()..];
            let colon = after_key.find(':')? + 1;
            let after_colon = after_key[colon..].trim_start();
            if !after_colon.starts_with('"') {
                return None;
            }
            let inner = &after_colon[1..];
            let mut result = String::new();
            let mut chars = inner.chars();
            loop {
                match chars.next()? {
                    '"' => break,
                    '\\' => match chars.next()? {
                        '"' => result.push('"'),
                        '\\' => result.push('\\'),
                        'n' => result.push('\n'),
                        'r' => result.push('\r'),
                        't' => result.push('\t'),
                        c => result.push(c),
                    },
                    c => result.push(c),
                }
            }
            return Some(result);
        }
        // Found inside a string value — skip past this match and keep searching.
        start = pos + 1;
    }
}

/// Extract a u64 value from a flat JSON object by key.
///
/// Parses the raw JSON numeric token as `f64` first, then converts to `u64`.
/// This handles scientific notation (e.g. `1.7e12`) that a digit-only scan would
/// misparse, which could cause `generated_ts_ms` to appear as epoch-ms = 1 and
/// permanently trigger `F1CertStatus::Stale`.
fn extract_json_u64(json: &str, key: &str) -> Option<u64> {
    let search = format!("\"{}\"", key);
    let mut start = 0;
    loop {
        let rel = json[start..].find(&search)?;
        let pos = start + rel;
        if count_unescaped_quotes(&json[..pos]) % 2 == 0 {
            let after_key = &json[pos + search.len()..];
            let colon = after_key.find(':')? + 1;
            let after_colon = after_key[colon..].trim_start();
            // Accept digits, '.', 'e', 'E', '+', '-' to cover scientific notation.
            let raw: String = after_colon
                .chars()
                .take_while(|c| c.is_ascii_digit() || matches!(c, '.' | 'e' | 'E' | '+' | '-'))
                .collect();
            if raw.is_empty() {
                return None;
            }
            // Parse as f64 first to handle e-notation, then cast to u64.
            return raw.parse::<f64>().ok().map(|f| f as u64);
        }
        start = pos + 1;
    }
}

// ─── PolicyGuard Axis Resolver (§2.2.3) ──────────────────────────────────────
// NOTE: The BunkerModeGuard (§2.3.2) lives in crates/soldier_core/src/risk/network_jitter.rs
// as NetworkJitterMonitor. Use that canonical implementation; the duplicate that
// previously lived here has been removed to prevent maintenance divergence.

/// Profile for enforcement scoping (§0.Z.7).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnforcedProfile {
    /// Contract Safety Profile only — GOP inputs nonexistent.
    Csp,
    /// General Operational Profile + CSP.
    Gop,
    /// Full (both CSP and GOP).
    Full,
}

impl EnforcedProfile {
    pub fn is_csp_only(self) -> bool {
        self == EnforcedProfile::Csp
    }
}

/// CapitalRiskAxis (§2.2.3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum CapitalRiskAxis {
    Safe,
    Warning,
    Critical,
}

/// MarketIntegrityAxis (§2.2.3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MarketIntegrityAxis {
    Stable,
    Stressed,
    Broken,
}

/// SystemIntegrityAxis (§2.2.3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SystemIntegrityAxis {
    Healthy,
    Degraded,
    Failing,
}

/// TradingMode: the canonical output of the Axis Resolver (§2.2.3.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum PolicyTradingMode {
    Active,
    ReduceOnly,
    Kill,
}

impl PolicyTradingMode {
    /// Returns true iff OPEN intents are allowed.
    pub fn allows_open(self) -> bool {
        self == PolicyTradingMode::Active
    }

    /// Returns true iff the mode is non-Active (cancel loop required).
    pub fn requires_open_cancellation(self) -> bool {
        self != PolicyTradingMode::Active
    }

    pub fn restrictiveness(self) -> u8 {
        match self {
            PolicyTradingMode::Active => 0,
            PolicyTradingMode::ReduceOnly => 1,
            PolicyTradingMode::Kill => 2,
        }
    }
}

/// RiskState input to PolicyGuard (mirrors risk::RiskState for self-containment).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyRiskState {
    Healthy,
    Degraded,
    Maintenance,
    Kill,
}

/// CortexOverride input (from Cortex monitor §2.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CortexOverride {
    None,
    ForceReduceOnly,
    ForceKill,
}

/// EvidenceChainState input (from §2.2.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyEvidenceState {
    Green,
    NotGreen,
}

/// BasisDecision input to PolicyGuard (from BasisMonitor §2.3.3).
///
/// The BasisMonitor emits a decision each tick. PolicyGuard consumes it:
/// - `Normal`           → no contribution to axis
/// - `ForceReduceOnly`  → SystemIntegrityAxis::Degraded (→ ReduceOnly)
/// - `ForceKill`        → CapitalRiskAxis::Critical (→ Kill)
///
/// Integration pathway: call `BasisMonitor::evaluate()` each tick and map the result:
/// ```ignore
/// let bd = match basis_monitor.evaluate(prices, now_ms, &config) {
///     BasisDecision::Normal               => PolicyBasisDecision::Normal,
///     BasisDecision::ForceReduceOnly {..} => PolicyBasisDecision::ForceReduceOnly,
///     BasisDecision::ForceKill            => PolicyBasisDecision::ForceKill,
/// };
/// inputs.basis_decision = bd;
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyBasisDecision {
    Normal,
    ForceReduceOnly,
    ForceKill,
}

/// ModeReasonCode — all valid reason codes (§2.2.3.5, deterministic order).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModeReasonCode {
    // Kill-tier (in canonical order):
    KillWatchdogHeartbeatStale,
    KillRiskstateKill,
    KillMarginMmUtilCritical,
    KillRateLimitSessionTermination,
    KillDiskWatermarkKill,
    KillCortexForceKill,
    // ReduceOnly-tier (in canonical order):
    ReduceOnlyRiskstateMaintenance,
    ReduceOnlyEmergencyReduceOnlyActive,
    ReduceOnlyOpenPermissionLatched,
    ReduceOnlyBunkerModeActive,
    ReduceOnlyF1CertInvalid,
    ReduceOnlyEvidenceChainNotGreen,
    ReduceOnlyCortexForceReduceOnly,
    ReduceOnlyFeeModelHardStale,
    ReduceOnlyRiskstateDegraded,
    ReduceOnlyPolicyStale,
    ReduceOnlyMarginMmUtilHigh,
    ReduceOnlyInputMissingOrStale,
    ReduceOnlyWatchdogUnconfirmed,
    ReduceOnlyDiskKillUnconfirmed,
    ReduceOnlySessionKillUnconfirmed,
}

impl ModeReasonCode {
    pub fn is_kill_tier(self) -> bool {
        matches!(
            self,
            ModeReasonCode::KillWatchdogHeartbeatStale
                | ModeReasonCode::KillRiskstateKill
                | ModeReasonCode::KillMarginMmUtilCritical
                | ModeReasonCode::KillRateLimitSessionTermination
                | ModeReasonCode::KillDiskWatermarkKill
                | ModeReasonCode::KillCortexForceKill
        )
    }

    pub fn is_reduceonly_tier(self) -> bool {
        !self.is_kill_tier()
    }

    /// Canonical ordering index (used for deterministic sort).
    pub fn canonical_index(self) -> u8 {
        match self {
            ModeReasonCode::KillWatchdogHeartbeatStale => 0,
            ModeReasonCode::KillRiskstateKill => 1,
            ModeReasonCode::KillMarginMmUtilCritical => 2,
            ModeReasonCode::KillRateLimitSessionTermination => 3,
            ModeReasonCode::KillDiskWatermarkKill => 4,
            ModeReasonCode::KillCortexForceKill => 5,
            ModeReasonCode::ReduceOnlyRiskstateMaintenance => 6,
            ModeReasonCode::ReduceOnlyEmergencyReduceOnlyActive => 7,
            ModeReasonCode::ReduceOnlyOpenPermissionLatched => 8,
            ModeReasonCode::ReduceOnlyBunkerModeActive => 9,
            ModeReasonCode::ReduceOnlyF1CertInvalid => 10,
            ModeReasonCode::ReduceOnlyEvidenceChainNotGreen => 11,
            ModeReasonCode::ReduceOnlyCortexForceReduceOnly => 12,
            ModeReasonCode::ReduceOnlyFeeModelHardStale => 13,
            ModeReasonCode::ReduceOnlyRiskstateDegraded => 14,
            ModeReasonCode::ReduceOnlyPolicyStale => 15,
            ModeReasonCode::ReduceOnlyMarginMmUtilHigh => 16,
            ModeReasonCode::ReduceOnlyInputMissingOrStale => 17,
            ModeReasonCode::ReduceOnlyWatchdogUnconfirmed => 18,
            ModeReasonCode::ReduceOnlyDiskKillUnconfirmed => 19,
            ModeReasonCode::ReduceOnlySessionKillUnconfirmed => 20,
        }
    }
}

/// Result of PolicyGuard.get_effective_mode().
#[derive(Debug, Clone)]
pub struct PolicyGuardResult {
    pub trading_mode: PolicyTradingMode,
    pub mode_reasons: Vec<ModeReasonCode>,
    pub capital_axis: CapitalRiskAxis,
    pub market_axis: MarketIntegrityAxis,
    pub system_axis: SystemIntegrityAxis,
    /// policy_age_sec gauge value at evaluation time.
    pub policy_age_sec: u64,
    /// policy_stale_reduceonly_total counter increment (1 if stale this tick).
    pub policy_stale_this_tick: bool,
}

/// Configuration for PolicyGuard axis resolver (§2.2 + Appendix A).
pub struct PolicyGuardConfig {
    // §2.2.1.1 freshness
    pub mm_util_max_age_ms: u64,
    pub disk_used_max_age_ms: u64,
    // §2.2.3
    pub max_policy_age_sec: u64,
    pub watchdog_kill_s: u64,
    pub disk_kill_pct: f64,
    pub mm_util_kill: f64,
    pub mm_util_reduceonly: f64,
    pub rate_limit_kill_min_10028: u64,
    // §2.2.3.4.1
    pub cancel_open_batch_max: u32,
    pub cancel_open_budget_ms: u64,
    // §4.2 fee model
    pub fee_model_hard_stale_s: u64,
}

impl Default for PolicyGuardConfig {
    fn default() -> Self {
        Self {
            mm_util_max_age_ms: 30_000,
            disk_used_max_age_ms: 30_000,
            max_policy_age_sec: 300,
            watchdog_kill_s: 10,
            disk_kill_pct: 0.92,
            mm_util_kill: 0.95,
            mm_util_reduceonly: 0.85,
            rate_limit_kill_min_10028: 3,
            cancel_open_batch_max: 50,
            cancel_open_budget_ms: 200,
            // Default: 1 hour. Set to u64::MAX to disable (not recommended in production
            // — a stale fee model means economics assumptions are wrong; 3600s gives a
            // 1-hour grace period before ReduceOnly is forced per §4.2).
            fee_model_hard_stale_s: 3_600,
        }
    }
}

/// Coherent input snapshot for PolicyGuard axis resolver (§2.2).
pub struct PolicyGuardInputs {
    /// Current monotonic timestamp (ms).
    pub now_ms: u64,

    // ─── Capital risk inputs ───────────────────────────────────────
    /// mm_util: maintenance_margin / max(equity, ε). None = missing (fail-closed).
    pub mm_util: Option<f64>,
    /// Freshness timestamp for mm_util (ms). None = missing (fail-closed).
    pub mm_util_last_update_ts_ms: Option<u64>,
    /// RiskState from the risk layer.
    pub risk_state: PolicyRiskState,
    /// Cortex override (ForceKill → CapitalRiskAxis::Critical, ForceReduceOnly → SystemIntegrity DEGRADED).
    pub cortex_override: CortexOverride,

    // ─── Market integrity inputs ───────────────────────────────────
    /// Bunker mode active flag (from §2.3.2).
    pub bunker_mode_active: bool,

    // ─── System integrity inputs ───────────────────────────────────
    /// Watchdog heartbeat timestamp (ms). None = missing (fail-closed).
    pub watchdog_last_heartbeat_ts_ms: Option<u64>,
    /// Loop tick timestamp for watchdog corroboration (ms). None = missing (fail-closed).
    pub loop_tick_last_ts_ms: Option<u64>,
    /// Primary disk utilization [0,1]. None = missing (fail-closed).
    pub disk_used_pct: Option<f64>,
    /// Freshness timestamp for disk_used_pct (ms). None = missing (fail-closed).
    pub disk_used_last_update_ts_ms: Option<u64>,
    /// Secondary disk utilization (corroboration). None = unconfirmed.
    pub disk_used_pct_secondary: Option<f64>,
    /// Freshness timestamp for disk_used_pct_secondary (ms).
    pub disk_used_secondary_last_update_ts_ms: Option<u64>,
    /// Session kill flag. None = missing/unparseable (fail-closed).
    pub rate_limit_session_kill_active: Option<bool>,
    /// Rolling 5m count of 10028 errors (corroboration). None = missing/unconfirmed.
    pub count_10028_5m: Option<u64>,
    /// Emergency reduce-only active flag.
    pub emergency_reduceonly_active: bool,
    /// Open permission latch.
    pub open_permission_blocked_latch: bool,
    /// EvidenceChainState (GOP-only; ignored when enforced_profile == CSP).
    pub evidence_chain_state: PolicyEvidenceState,
    /// F1 cert status from F1Gate.
    pub f1_cert_status: F1CertStatus,
    /// BasisMonitor decision (§2.3.3): Normal | ForceReduceOnly | ForceKill.
    /// ForceReduceOnly → SystemIntegrityAxis::Degraded; ForceKill → CapitalRiskAxis::Critical.
    pub basis_decision: PolicyBasisDecision,
    /// Fee model cache age in seconds (§4.2). None = not tracked.
    pub fee_model_cache_age_s: Option<u64>,
    /// Policy age in seconds (derived from python_policy_generated_ts_ms).
    pub policy_age_sec: u64,

    // ─── Profile ──────────────────────────────────────────────────
    pub enforced_profile: EnforcedProfile,
}

/// Pure function: resolve TradingMode from axis values (§2.2.3.3).
///
/// This is the canonical 27-state resolver. It has no hidden state.
pub fn resolve_trading_mode(
    capital: CapitalRiskAxis,
    market: MarketIntegrityAxis,
    system: SystemIntegrityAxis,
) -> PolicyTradingMode {
    // Rule 1: Kill
    if system == SystemIntegrityAxis::Failing || capital == CapitalRiskAxis::Critical {
        return PolicyTradingMode::Kill;
    }
    // Rule 2: ReduceOnly
    if system == SystemIntegrityAxis::Degraded
        || market != MarketIntegrityAxis::Stable
        || capital == CapitalRiskAxis::Warning
    {
        return PolicyTradingMode::ReduceOnly;
    }
    // Rule 3: Active
    PolicyTradingMode::Active
}

/// Compute the CapitalRiskAxis from inputs (§2.2.3.2).
fn compute_capital_axis(inputs: &PolicyGuardInputs, config: &PolicyGuardConfig) -> CapitalRiskAxis {
    // CRITICAL: mm_util >= mm_util_kill OR risk_state == Kill OR cortex/basis ForceKill
    let mm_util_kill = inputs
        .mm_util
        .map(|v| v >= config.mm_util_kill)
        .unwrap_or(false);
    if mm_util_kill
        || inputs.risk_state == PolicyRiskState::Kill
        || inputs.cortex_override == CortexOverride::ForceKill
        || inputs.basis_decision == PolicyBasisDecision::ForceKill
    {
        return CapitalRiskAxis::Critical;
    }
    // WARNING: mm_util >= mm_util_reduceonly AND < mm_util_kill
    let mm_util_reduceonly = inputs
        .mm_util
        .map(|v| v >= config.mm_util_reduceonly)
        .unwrap_or(false);
    if mm_util_reduceonly {
        return CapitalRiskAxis::Warning;
    }
    CapitalRiskAxis::Safe
}

/// Compute the MarketIntegrityAxis from inputs (§2.2.3.2).
fn compute_market_axis(inputs: &PolicyGuardInputs) -> MarketIntegrityAxis {
    if inputs.bunker_mode_active {
        MarketIntegrityAxis::Stressed
    } else {
        MarketIntegrityAxis::Stable
    }
    // BROKEN is reserved for future; never produced here (v5.2).
}

/// Check if critical inputs are missing or stale (§2.2.1.1).
/// Returns true if any critical input is missing or stale.
fn critical_inputs_missing_or_stale(
    inputs: &PolicyGuardInputs,
    config: &PolicyGuardConfig,
) -> bool {
    // mm_util must be present with a fresh timestamp
    match (inputs.mm_util, inputs.mm_util_last_update_ts_ms) {
        (None, _) => return true,
        (_, None) => return true,
        (Some(_), Some(ts)) => {
            if inputs.now_ms.saturating_sub(ts) > config.mm_util_max_age_ms {
                return true;
            }
        }
    }
    // disk_used_pct must be present with a fresh timestamp
    match (inputs.disk_used_pct, inputs.disk_used_last_update_ts_ms) {
        (None, _) => return true,
        (_, None) => return true,
        (Some(_), Some(ts)) => {
            if inputs.now_ms.saturating_sub(ts) > config.disk_used_max_age_ms {
                return true;
            }
        }
    }
    // rate_limit_session_kill_active must be explicit (not None)
    if inputs.rate_limit_session_kill_active.is_none() {
        return true;
    }
    // watchdog_last_heartbeat_ts_ms must be present
    if inputs.watchdog_last_heartbeat_ts_ms.is_none() {
        return true;
    }
    false
}

// ─── Shared staleness predicate helpers ─────────────────────────────────────
// These are extracted to avoid the duplication between compute_system_axis and
// collect_mode_reasons, which previously re-derived the same values independently,
// creating a risk of mode/reason divergence when thresholds changed.

struct KillPredicates {
    watchdog_heartbeat_stale: bool,
    loop_tick_stale: bool,
    disk_primary_trip: bool,
    disk_secondary_confirmed: bool,
    session_kill_active: bool,
    count_10028_sufficient: bool,
}

impl KillPredicates {
    fn watchdog_kill_confirmed(&self) -> bool {
        self.watchdog_heartbeat_stale && self.loop_tick_stale
    }
    fn disk_kill_confirmed(&self) -> bool {
        self.disk_primary_trip && self.disk_secondary_confirmed
    }
    fn session_kill_confirmed(&self) -> bool {
        self.session_kill_active && self.count_10028_sufficient
    }
    fn watchdog_unconfirmed(&self) -> bool {
        self.watchdog_heartbeat_stale && !self.loop_tick_stale
    }
    fn disk_unconfirmed(&self) -> bool {
        self.disk_primary_trip && !self.disk_secondary_confirmed
    }
    fn session_unconfirmed(&self) -> bool {
        self.session_kill_active && !self.count_10028_sufficient
    }
}

fn compute_kill_predicates(inputs: &PolicyGuardInputs, config: &PolicyGuardConfig) -> KillPredicates {
    let watchdog_heartbeat_stale = inputs
        .watchdog_last_heartbeat_ts_ms
        .map(|ts| inputs.now_ms.saturating_sub(ts) > config.watchdog_kill_s * 1_000)
        .unwrap_or(true); // missing = stale
    let loop_tick_stale = inputs
        .loop_tick_last_ts_ms
        .map(|ts| inputs.now_ms.saturating_sub(ts) > config.watchdog_kill_s * 1_000)
        .unwrap_or(true); // missing = stale
    let disk_primary_trip = inputs
        .disk_used_pct
        .map(|v| v >= config.disk_kill_pct)
        .unwrap_or(false);
    let disk_secondary_confirmed = match (
        inputs.disk_used_pct_secondary,
        inputs.disk_used_secondary_last_update_ts_ms,
    ) {
        (Some(v), Some(ts)) => {
            let fresh = inputs.now_ms.saturating_sub(ts) <= config.disk_used_max_age_ms;
            fresh && v >= config.disk_kill_pct
        }
        // No timestamp: treat as stale/unconfirmed (requires explicit freshness).
        _ => false,
    };
    let session_kill_active = inputs.rate_limit_session_kill_active.unwrap_or(false);
    let count_10028_sufficient = inputs
        .count_10028_5m
        .map(|c| c >= config.rate_limit_kill_min_10028)
        .unwrap_or(false);
    KillPredicates {
        watchdog_heartbeat_stale,
        loop_tick_stale,
        disk_primary_trip,
        disk_secondary_confirmed,
        session_kill_active,
        count_10028_sufficient,
    }
}

/// Compute the SystemIntegrityAxis from inputs (§2.2.3.2).
fn compute_system_axis(
    inputs: &PolicyGuardInputs,
    config: &PolicyGuardConfig,
) -> SystemIntegrityAxis {
    let kp = compute_kill_predicates(inputs, config);

    if kp.watchdog_kill_confirmed() || kp.disk_kill_confirmed() || kp.session_kill_confirmed() {
        return SystemIntegrityAxis::Failing;
    }

    // DEGRADED checks (§2.2.3.2)
    let risk_degraded = matches!(
        inputs.risk_state,
        PolicyRiskState::Degraded | PolicyRiskState::Maintenance
    );
    let evidence_not_green = !inputs.enforced_profile.is_csp_only()
        && inputs.evidence_chain_state == PolicyEvidenceState::NotGreen;
    let f1_invalid = inputs.f1_cert_status.requires_reduce_only();
    let cortex_reduce = inputs.cortex_override == CortexOverride::ForceReduceOnly;
    let fee_stale = inputs
        .fee_model_cache_age_s
        .map(|age| age > config.fee_model_hard_stale_s)
        .unwrap_or(false);
    let policy_stale = inputs.policy_age_sec > config.max_policy_age_sec;
    let critical_missing = critical_inputs_missing_or_stale(inputs, config);
    let basis_trips = matches!(
        inputs.basis_decision,
        PolicyBasisDecision::ForceReduceOnly | PolicyBasisDecision::ForceKill
    );

    if risk_degraded
        || inputs.emergency_reduceonly_active
        || inputs.open_permission_blocked_latch
        || evidence_not_green
        || f1_invalid
        || cortex_reduce
        || basis_trips
        || fee_stale
        || policy_stale
        || critical_missing
        || kp.watchdog_unconfirmed()
        || kp.disk_unconfirmed()
        || kp.session_unconfirmed()
    {
        return SystemIntegrityAxis::Degraded;
    }

    SystemIntegrityAxis::Healthy
}

/// Collect all active mode reason codes for the winning tier (§2.2.3.5).
///
/// Reasons are tier-pure and deterministically ordered.
fn collect_mode_reasons(
    mode: PolicyTradingMode,
    inputs: &PolicyGuardInputs,
    config: &PolicyGuardConfig,
) -> Vec<ModeReasonCode> {
    let mut reasons: Vec<ModeReasonCode> = Vec::new();
    // Use the shared predicate helper to avoid re-deriving the same values independently
    // (which previously risked mode/reason divergence when threshold logic changed).
    let kp = compute_kill_predicates(inputs, config);

    match mode {
        PolicyTradingMode::Active => {
            // Active → mode_reasons MUST be []
        }
        PolicyTradingMode::Kill => {
            // 1. KILL_WATCHDOG_HEARTBEAT_STALE (confirmed: both stale)
            if kp.watchdog_kill_confirmed() {
                reasons.push(ModeReasonCode::KillWatchdogHeartbeatStale);
            }
            // 2. KILL_RISKSTATE_KILL
            if inputs.risk_state == PolicyRiskState::Kill {
                reasons.push(ModeReasonCode::KillRiskstateKill);
            }
            // 3. KILL_MARGIN_MM_UTIL_CRITICAL
            if inputs
                .mm_util
                .map(|v| v >= config.mm_util_kill)
                .unwrap_or(false)
            {
                reasons.push(ModeReasonCode::KillMarginMmUtilCritical);
            }
            // 4. KILL_RATE_LIMIT_SESSION_TERMINATION
            if kp.session_kill_confirmed() {
                reasons.push(ModeReasonCode::KillRateLimitSessionTermination);
            }
            // 5. KILL_DISK_WATERMARK_KILL
            if kp.disk_kill_confirmed() {
                reasons.push(ModeReasonCode::KillDiskWatermarkKill);
            }
            // 6. KILL_CORTEX_FORCE_KILL
            if inputs.cortex_override == CortexOverride::ForceKill
                || inputs.basis_decision == PolicyBasisDecision::ForceKill
            {
                reasons.push(ModeReasonCode::KillCortexForceKill);
            }
        }
        PolicyTradingMode::ReduceOnly => {
            // 1. REDUCEONLY_RISKSTATE_MAINTENANCE
            if inputs.risk_state == PolicyRiskState::Maintenance {
                reasons.push(ModeReasonCode::ReduceOnlyRiskstateMaintenance);
            }
            // 2. REDUCEONLY_EMERGENCY_REDUCEONLY_ACTIVE
            if inputs.emergency_reduceonly_active {
                reasons.push(ModeReasonCode::ReduceOnlyEmergencyReduceOnlyActive);
            }
            // 3. REDUCEONLY_OPEN_PERMISSION_LATCHED
            if inputs.open_permission_blocked_latch {
                reasons.push(ModeReasonCode::ReduceOnlyOpenPermissionLatched);
            }
            // 4. REDUCEONLY_BUNKER_MODE_ACTIVE
            if inputs.bunker_mode_active {
                reasons.push(ModeReasonCode::ReduceOnlyBunkerModeActive);
            }
            // 5. REDUCEONLY_F1_CERT_INVALID
            if inputs.f1_cert_status.requires_reduce_only() {
                reasons.push(ModeReasonCode::ReduceOnlyF1CertInvalid);
            }
            // 6. REDUCEONLY_EVIDENCE_CHAIN_NOT_GREEN
            if !inputs.enforced_profile.is_csp_only()
                && inputs.evidence_chain_state == PolicyEvidenceState::NotGreen
            {
                reasons.push(ModeReasonCode::ReduceOnlyEvidenceChainNotGreen);
            }
            // 7. REDUCEONLY_CORTEX_FORCE_REDUCE_ONLY (also covers basis ForceReduceOnly)
            if inputs.cortex_override == CortexOverride::ForceReduceOnly
                || inputs.basis_decision == PolicyBasisDecision::ForceReduceOnly
            {
                reasons.push(ModeReasonCode::ReduceOnlyCortexForceReduceOnly);
            }
            // 8. REDUCEONLY_FEE_MODEL_HARD_STALE
            if inputs
                .fee_model_cache_age_s
                .map(|age| age > config.fee_model_hard_stale_s)
                .unwrap_or(false)
            {
                reasons.push(ModeReasonCode::ReduceOnlyFeeModelHardStale);
            }
            // 9. REDUCEONLY_RISKSTATE_DEGRADED
            if inputs.risk_state == PolicyRiskState::Degraded {
                reasons.push(ModeReasonCode::ReduceOnlyRiskstateDegraded);
            }
            // 10. REDUCEONLY_POLICY_STALE
            if inputs.policy_age_sec > config.max_policy_age_sec {
                reasons.push(ModeReasonCode::ReduceOnlyPolicyStale);
            }
            // 11. REDUCEONLY_MARGIN_MM_UTIL_HIGH
            let mm_warning = inputs
                .mm_util
                .map(|v| v >= config.mm_util_reduceonly && v < config.mm_util_kill)
                .unwrap_or(false);
            if mm_warning {
                reasons.push(ModeReasonCode::ReduceOnlyMarginMmUtilHigh);
            }
            // 12. REDUCEONLY_INPUT_MISSING_OR_STALE
            if critical_inputs_missing_or_stale(inputs, config) {
                reasons.push(ModeReasonCode::ReduceOnlyInputMissingOrStale);
            }
            // 13. REDUCEONLY_WATCHDOG_UNCONFIRMED
            if kp.watchdog_unconfirmed() {
                reasons.push(ModeReasonCode::ReduceOnlyWatchdogUnconfirmed);
            }
            // 14. REDUCEONLY_DISK_KILL_UNCONFIRMED
            if kp.disk_unconfirmed() {
                reasons.push(ModeReasonCode::ReduceOnlyDiskKillUnconfirmed);
            }
            // 15. REDUCEONLY_SESSION_KILL_UNCONFIRMED
            if kp.session_unconfirmed() {
                reasons.push(ModeReasonCode::ReduceOnlySessionKillUnconfirmed);
            }
        }
    }

    // Enforce canonical ordering (deterministic)
    reasons.sort_by_key(|r| r.canonical_index());
    reasons.dedup();
    reasons
}

/// PolicyGuard axis resolver — computes TradingMode from the coherent input snapshot.
///
/// Per §2.2.3: recomputed every tick via `get_effective_mode()`. No hidden state.
/// Observability: `policy_age_sec` gauge and `policy_stale_reduceonly_total` counter.
pub struct AxisResolver {
    /// Cumulative counter: ticks where policy was stale and ReduceOnly was forced.
    pub policy_stale_reduceonly_total: u64,
}

impl AxisResolver {
    pub fn new() -> Self {
        Self {
            policy_stale_reduceonly_total: 0,
        }
    }

    /// Compute TradingMode + reason codes from the given input snapshot.
    ///
    /// This is the canonical PolicyGuard resolver (§2.2.3).
    pub fn get_effective_mode(
        &mut self,
        inputs: &PolicyGuardInputs,
        config: &PolicyGuardConfig,
    ) -> PolicyGuardResult {
        let capital = compute_capital_axis(inputs, config);
        let market = compute_market_axis(inputs);
        let system = compute_system_axis(inputs, config);

        let trading_mode = resolve_trading_mode(capital, market, system);
        let mode_reasons = collect_mode_reasons(trading_mode, inputs, config);

        let policy_stale_this_tick = trading_mode == PolicyTradingMode::ReduceOnly
            && mode_reasons.contains(&ModeReasonCode::ReduceOnlyPolicyStale);
        if policy_stale_this_tick {
            self.policy_stale_reduceonly_total += 1;
        }

        PolicyGuardResult {
            trading_mode,
            mode_reasons,
            capital_axis: capital,
            market_axis: market,
            system_axis: system,
            policy_age_sec: inputs.policy_age_sec,
            policy_stale_this_tick,
        }
    }
}

impl Default for AxisResolver {
    fn default() -> Self {
        Self::new()
    }
}

/// Non-Active OPEN Cancellation helper (§2.2.3.4.1).
///
/// When TradingMode != Active, the engine MUST attempt to cancel all outstanding
/// OPEN orders with `reduce_only != true`. This is bounded by cancel_open_batch_max
/// and cancel_open_budget_ms.
pub struct OpenCancellationBatch {
    /// Order IDs to cancel (bounded slice from caller's outstanding orders).
    pub order_ids: Vec<String>,
    /// True if more orders remain after this batch (bounded cancel budget).
    pub has_more: bool,
}

/// Compute the bounded cancel batch for Non-Active OPEN Cancellation (§2.2.3.4.1).
///
/// Returns the batch of order IDs to cancel this tick. The caller provides `outstanding_open_ids`
/// (all risk-increasing OPENs, i.e., reduce_only != true). Returns at most `cancel_open_batch_max` IDs.
pub fn compute_cancel_batch(
    outstanding_open_ids: &[String],
    config: &PolicyGuardConfig,
) -> OpenCancellationBatch {
    let max = config.cancel_open_batch_max as usize;
    let total = outstanding_open_ids.len();
    let batch_size = total.min(max);
    OpenCancellationBatch {
        order_ids: outstanding_open_ids[..batch_size].to_vec(),
        has_more: total > max,
    }
}

/// Returns true iff the given intent should be classified as an OPEN (risk-increasing).
///
/// Per §2.2.3.4: `reduce_only == true` means NOT an OPEN. Missing or false means OPEN.
/// Per AT-1055.
pub fn is_open_intent(reduce_only: Option<bool>) -> bool {
    !matches!(reduce_only, Some(true))
}
