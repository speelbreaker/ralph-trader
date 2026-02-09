//! Integration tests for Appendix A config defaults (PRD S1-010).

use soldier_infra::config::{
    ConfigError, EVIDENCEGUARD_GLOBAL_COOLDOWN_DEFAULT, INSTRUMENT_CACHE_TTL_S_DEFAULT,
    MM_UTIL_KILL_DEFAULT, SafetyConfigInput, apply_defaults, resolve_required_f64,
};

/// GIVEN config omits instrument_cache_ttl_s and evidenceguard_global_cooldown
/// WHEN defaults are applied
/// THEN Appendix A defaults are used.
#[test]
fn test_defaults_applied_for_instrument_cache_and_evidenceguard_cooldown() {
    let input = SafetyConfigInput {
        instrument_cache_ttl_s: None,
        evidenceguard_global_cooldown: None,
        mm_util_kill: Some(0.90),
    };

    let config =
        apply_defaults(input).expect("defaults should apply for missing Appendix A values");

    assert_eq!(
        config.instrument_cache_ttl_s, INSTRUMENT_CACHE_TTL_S_DEFAULT,
        "instrument_cache_ttl_s MUST use Appendix A default"
    );
    assert_eq!(
        config.evidenceguard_global_cooldown, EVIDENCEGUARD_GLOBAL_COOLDOWN_DEFAULT,
        "evidenceguard_global_cooldown MUST use Appendix A default"
    );
    assert!(
        (config.mm_util_kill - 0.90).abs() < f64::EPSILON,
        "provided mm_util_kill should be preserved"
    );
}

/// GIVEN config omits mm_util_kill
/// WHEN defaults are applied
/// THEN Appendix A default is used.
#[test]
fn test_default_applied_for_mm_util_kill() {
    let input = SafetyConfigInput {
        instrument_cache_ttl_s: Some(10),
        evidenceguard_global_cooldown: Some(5),
        mm_util_kill: None,
    };

    let config = apply_defaults(input).expect("mm_util_kill should default when missing");

    assert!(
        (config.mm_util_kill - MM_UTIL_KILL_DEFAULT).abs() < f64::EPSILON,
        "mm_util_kill MUST use Appendix A default"
    );
}

/// GIVEN a safety-critical gate references a parameter without an Appendix A default
/// WHEN the parameter is missing
/// THEN the gate fails closed with a deterministic reason.
#[test]
fn test_missing_non_appendix_a_parameter_fails_closed() {
    let err = resolve_required_f64("dd_limit", None)
        .expect_err("missing non-Appendix A parameter must fail closed");

    assert!(
        matches!(err, ConfigError::MissingSafetyCritical { key: "dd_limit" }),
        "error MUST identify the missing key"
    );
    assert_eq!(
        err.to_string(),
        "missing safety-critical config value: dd_limit (no Appendix A default)",
        "error message MUST be deterministic"
    );
}
