//! PolicyGuard bunker mode wrapper + F1 certification gate.
//! Per CONTRACT.md §2.3.2, §2.2.3, §2.2.1.
//!
//! When `bunker_mode_active == true`, PolicyGuard returns TradingMode::ReduceOnly
//! and OPEN intents are blocked. CLOSE/HEDGE/CANCEL remain allowed (§2.2.5).
//!
//! F1Gate (§2.2.1): missing/stale/FAIL/INVALID cert → ReduceOnly. No last-known-good bypass.
//!
//! Self-contained: no dependency on crate module tree; safe to include via #[path] in tests.

#![allow(dead_code)]

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
            // Use repr that matches Python's json.dumps for numeric types.
            let s = format!("{f}");
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

/// Extract a string value from a flat JSON object by key. Handles basic escaping.
fn extract_json_str(json: &str, key: &str) -> Option<String> {
    let search = format!("\"{}\"", key);
    let pos = json.find(&search)?;
    let after_key = &json[pos + search.len()..];
    // Find the colon.
    let colon = after_key.find(':')? + 1;
    let after_colon = after_key[colon..].trim_start();
    if !after_colon.starts_with('"') {
        return None;
    }
    // Find the closing quote (simple: no nested escape complexity needed for our fields).
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
    Some(result)
}

/// Extract a u64 value from a flat JSON object by key.
fn extract_json_u64(json: &str, key: &str) -> Option<u64> {
    let search = format!("\"{}\"", key);
    let pos = json.find(&search)?;
    let after_key = &json[pos + search.len()..];
    let colon = after_key.find(':')? + 1;
    let after_colon = after_key[colon..].trim_start();
    // Read digits.
    let digits: String = after_colon
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    if digits.is_empty() {
        return None;
    }
    digits.parse().ok()
}

/// Configuration for the BunkerModeGuard.
pub struct BunkerModeGuardConfig {
    /// ws_event_lag_ms threshold for bunker entry (default 2000 ms)
    pub bunker_jitter_threshold_ms: u64,
    /// Stable period required before bunker exit (default 120 s)
    pub bunker_exit_stable_s: u64,
    /// deribit_http_p95_ms threshold (default 750 ms)
    pub http_p95_threshold_ms: u64,
    /// Consecutive http_p95 windows above threshold to trigger (default 3)
    pub http_p95_consecutive_windows: u32,
    /// request_timeout_rate threshold (default 0.02 = 2%)
    pub timeout_rate_threshold: f64,
}

impl Default for BunkerModeGuardConfig {
    fn default() -> Self {
        Self {
            bunker_jitter_threshold_ms: 2_000,
            bunker_exit_stable_s: 120,
            http_p95_threshold_ms: 750,
            http_p95_consecutive_windows: 3,
            timeout_rate_threshold: 0.02,
        }
    }
}

/// Jitter inputs for the BunkerModeGuard.
pub struct BunkerJitterInputs {
    pub ws_event_lag_ms: Option<u64>,
    pub http_p95_ms: Option<u64>,
    pub request_timeout_rate: Option<f64>,
}

/// BunkerModeGuard — PolicyGuard-compatible bunker mode evaluator (§2.3.2).
///
/// When `evaluate()` returns `true`:
///   - PolicyGuard computes TradingMode::ReduceOnly (§2.2.3)
///   - OPEN intents are blocked
///   - CLOSE/HEDGE/CANCEL remain allowed (per §2.2.5)
pub struct BunkerModeGuard {
    bunker_mode_active: bool,
    stable_start_ms: Option<u64>,
    http_p95_consecutive: u32,
    trip_total: u64,
}

impl BunkerModeGuard {
    pub fn new() -> Self {
        Self {
            bunker_mode_active: false,
            stable_start_ms: None,
            http_p95_consecutive: 0,
            trip_total: 0,
        }
    }

    /// Evaluate bunker mode for the current tick. Returns true if bunker_mode_active.
    pub fn evaluate(
        &mut self,
        inputs: BunkerJitterInputs,
        now_ms: u64,
        config: &BunkerModeGuardConfig,
    ) -> bool {
        let (ws_lag, http_p95, timeout_rate) = match (
            inputs.ws_event_lag_ms,
            inputs.http_p95_ms,
            inputs.request_timeout_rate,
        ) {
            (Some(w), Some(h), Some(t)) => (w, h, t),
            _ => {
                let was_active = self.bunker_mode_active;
                self.bunker_mode_active = true;
                self.stable_start_ms = None;
                if !was_active {
                    self.trip_total += 1;
                }
                return true;
            }
        };

        let ws_trip = ws_lag > config.bunker_jitter_threshold_ms;
        let timeout_trip = timeout_rate > config.timeout_rate_threshold;

        if http_p95 > config.http_p95_threshold_ms {
            self.http_p95_consecutive = self.http_p95_consecutive.saturating_add(1);
        } else {
            self.http_p95_consecutive = 0;
        }
        let http_trip = self.http_p95_consecutive >= config.http_p95_consecutive_windows;

        let any_trip = ws_trip || http_trip || timeout_trip;

        if any_trip {
            let was_active = self.bunker_mode_active;
            self.bunker_mode_active = true;
            self.stable_start_ms = None;
            if !was_active {
                self.trip_total += 1;
            }
            return true;
        }

        if self.bunker_mode_active {
            let start = self.stable_start_ms.get_or_insert(now_ms);
            let stable_ms = now_ms.saturating_sub(*start);
            let required_ms = config.bunker_exit_stable_s * 1_000;
            if stable_ms >= required_ms {
                self.bunker_mode_active = false;
                self.stable_start_ms = None;
            }
        }

        self.bunker_mode_active
    }

    pub fn is_active(&self) -> bool {
        self.bunker_mode_active
    }

    pub fn trip_total(&self) -> u64 {
        self.trip_total
    }
}

impl Default for BunkerModeGuard {
    fn default() -> Self {
        Self::new()
    }
}
