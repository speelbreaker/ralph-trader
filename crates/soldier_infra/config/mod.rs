use std::fmt;

/// Appendix A safety-critical defaults (centralized table).
pub const INSTRUMENT_CACHE_TTL_S_DEFAULT: u64 = 3600;
pub const EVIDENCEGUARD_GLOBAL_COOLDOWN_DEFAULT: u64 = 120;
pub const MM_UTIL_KILL_DEFAULT: f64 = 0.95;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamKind {
    U64,
    F64,
}

impl ParamKind {
    fn as_str(self) -> &'static str {
        match self {
            ParamKind::U64 => "u64",
            ParamKind::F64 => "f64",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DefaultValue {
    U64(u64),
    F64(f64),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    MissingSafetyCritical {
        key: &'static str,
    },
    TypeMismatch {
        key: &'static str,
        expected: ParamKind,
    },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::MissingSafetyCritical { key } => {
                write!(
                    f,
                    "missing safety-critical config value: {} (no Appendix A default)",
                    key
                )
            }
            ConfigError::TypeMismatch { key, expected } => write!(
                f,
                "type mismatch for safety-critical config value: {} (expected {})",
                key,
                expected.as_str()
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppendixADefaults {
    pub instrument_cache_ttl_s: u64,
    pub evidenceguard_global_cooldown: u64,
    pub mm_util_kill: f64,
}

impl Default for AppendixADefaults {
    fn default() -> Self {
        Self {
            instrument_cache_ttl_s: INSTRUMENT_CACHE_TTL_S_DEFAULT,
            evidenceguard_global_cooldown: EVIDENCEGUARD_GLOBAL_COOLDOWN_DEFAULT,
            mm_util_kill: MM_UTIL_KILL_DEFAULT,
        }
    }
}

impl AppendixADefaults {
    pub fn lookup(&self, key: &str) -> Option<DefaultValue> {
        match key {
            "instrument_cache_ttl_s" => Some(DefaultValue::U64(self.instrument_cache_ttl_s)),
            "evidenceguard_global_cooldown" => {
                Some(DefaultValue::U64(self.evidenceguard_global_cooldown))
            }
            "mm_util_kill" => Some(DefaultValue::F64(self.mm_util_kill)),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SafetyConfigInput {
    pub instrument_cache_ttl_s: Option<u64>,
    pub evidenceguard_global_cooldown: Option<u64>,
    pub mm_util_kill: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SafetyConfig {
    pub instrument_cache_ttl_s: u64,
    pub evidenceguard_global_cooldown: u64,
    pub mm_util_kill: f64,
}

pub fn apply_defaults(input: SafetyConfigInput) -> Result<SafetyConfig, ConfigError> {
    let defaults = AppendixADefaults::default();
    let instrument_cache_ttl_s = resolve_required_u64_with_defaults(
        "instrument_cache_ttl_s",
        input.instrument_cache_ttl_s,
        &defaults,
    )?;
    let evidenceguard_global_cooldown = resolve_required_u64_with_defaults(
        "evidenceguard_global_cooldown",
        input.evidenceguard_global_cooldown,
        &defaults,
    )?;
    let mm_util_kill =
        resolve_required_f64_with_defaults("mm_util_kill", input.mm_util_kill, &defaults)?;

    Ok(SafetyConfig {
        instrument_cache_ttl_s,
        evidenceguard_global_cooldown,
        mm_util_kill,
    })
}

pub fn resolve_required_u64(key: &'static str, provided: Option<u64>) -> Result<u64, ConfigError> {
    let defaults = AppendixADefaults::default();
    resolve_required_u64_with_defaults(key, provided, &defaults)
}

pub fn resolve_required_f64(key: &'static str, provided: Option<f64>) -> Result<f64, ConfigError> {
    let defaults = AppendixADefaults::default();
    resolve_required_f64_with_defaults(key, provided, &defaults)
}

fn resolve_required_u64_with_defaults(
    key: &'static str,
    provided: Option<u64>,
    defaults: &AppendixADefaults,
) -> Result<u64, ConfigError> {
    if let Some(value) = provided {
        return Ok(value);
    }

    match defaults.lookup(key) {
        Some(DefaultValue::U64(value)) => Ok(value),
        Some(DefaultValue::F64(_)) => Err(ConfigError::TypeMismatch {
            key,
            expected: ParamKind::U64,
        }),
        None => Err(ConfigError::MissingSafetyCritical { key }),
    }
}

fn resolve_required_f64_with_defaults(
    key: &'static str,
    provided: Option<f64>,
    defaults: &AppendixADefaults,
) -> Result<f64, ConfigError> {
    if let Some(value) = provided {
        return Ok(value);
    }

    match defaults.lookup(key) {
        Some(DefaultValue::F64(value)) => Ok(value),
        Some(DefaultValue::U64(_)) => Err(ConfigError::TypeMismatch {
            key,
            expected: ParamKind::F64,
        }),
        None => Err(ConfigError::MissingSafetyCritical { key }),
    }
}
