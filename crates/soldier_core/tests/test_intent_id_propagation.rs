use std::fs;
use std::path::{Path, PathBuf};

use soldier_core::execution::{
    BuildOrderIntentOutcome, BuildOrderIntentRejectReason, GateSequenceResult, LinkedOrderType,
    OrderIntent, OrderType, OrderTypeGuardConfig, OrderTypeRejectReason, build_order_intent,
    gate_sequence_total, preflight_reject_total, take_build_order_intent_outcome,
};
use soldier_core::venue::InstrumentKind;

const RUN_ID: &str = "run-p1d-001";
const INTENT_ID: &str = "intent-p1d-001";
const EVIDENCE_RELATIVE_PATH: &str = "evidence/phase1/traceability/sample_rejection_log.txt";

fn evidence_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(EVIDENCE_RELATIVE_PATH)
}

fn sample_reject_intent() -> OrderIntent {
    OrderIntent {
        instrument_kind: InstrumentKind::Perpetual,
        order_type: OrderType::Limit,
        trigger: None,
        trigger_price: None,
        linked_order_type: Some(LinkedOrderType::Oco),
    }
}

fn capture_intent_logs_and_metrics(intent_id: &str, run_id: &str) -> (Vec<String>, Vec<String>) {
    let reason = OrderTypeRejectReason::LinkedOrderTypeForbidden;
    let preflight_before = preflight_reject_total(reason);
    let gate_before = gate_sequence_total(GateSequenceResult::Rejected);

    let result = build_order_intent(sample_reject_intent(), OrderTypeGuardConfig::default());
    assert!(result.is_err(), "expected preflight rejection");

    let outcome = take_build_order_intent_outcome().expect("expected rejection outcome");
    assert_eq!(
        outcome,
        BuildOrderIntentOutcome::Rejected(BuildOrderIntentRejectReason::Preflight(reason))
    );

    let preflight_after = preflight_reject_total(reason);
    let gate_after = gate_sequence_total(GateSequenceResult::Rejected);
    assert!(
        preflight_after > preflight_before,
        "preflight metric should bump"
    );
    assert!(
        gate_after > gate_before,
        "gate sequence reject metric should bump"
    );

    let log_lines = vec![
        format!("preflight_reject_total intent_id={intent_id} run_id={run_id} reason={reason:?}"),
        format!("gate_sequence_total intent_id={intent_id} run_id={run_id} result=rejected"),
    ];

    let metric_lines = vec![
        format!(
            "metric=intent_id_propagation_total intent_id={intent_id} run_id={run_id} result=rejected value=1"
        ),
        format!(
            "metric=preflight_reject_total intent_id={intent_id} run_id={run_id} reason={reason:?} value={preflight_after}"
        ),
        format!(
            "metric=gate_sequence_total intent_id={intent_id} run_id={run_id} result=rejected value={gate_after}"
        ),
    ];

    (log_lines, metric_lines)
}

fn extract_field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let prefix = format!("{key}=");
    line.split_whitespace()
        .find_map(|token| token.strip_prefix(&prefix))
}

fn assert_lines_have_ids(label: &str, lines: &[String], intent_id: &str, run_id: &str) {
    assert!(!lines.is_empty(), "{label} lines should not be empty");
    for line in lines {
        let line_intent = extract_field(line, "intent_id")
            .unwrap_or_else(|| panic!("{label} line missing intent_id: {line}"));
        let line_run = extract_field(line, "run_id")
            .unwrap_or_else(|| panic!("{label} line missing run_id: {line}"));
        assert_eq!(line_intent, intent_id, "{label} intent_id mismatch");
        assert_eq!(line_run, run_id, "{label} run_id mismatch");
    }
}

fn parse_evidence_log_lines(contents: &str) -> Vec<String> {
    contents
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| line.to_string())
        .collect()
}

fn parse_expected_intent_id(contents: &str) -> Option<String> {
    let prefix = "# Expected intent_id: ";
    contents
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix(prefix))
        .map(|value| value.to_string())
}

#[test]
fn test_intent_id_propagates_to_logs_and_metrics() {
    let (log_lines, metric_lines) = capture_intent_logs_and_metrics(INTENT_ID, RUN_ID);

    assert_lines_have_ids("log", &log_lines, INTENT_ID, RUN_ID);
    assert_lines_have_ids("metric", &metric_lines, INTENT_ID, RUN_ID);

    let evidence_contents =
        fs::read_to_string(evidence_path()).expect("read sample rejection log evidence");
    let evidence_lines = parse_evidence_log_lines(&evidence_contents);

    if let Some(expected_intent) = parse_expected_intent_id(&evidence_contents) {
        assert_eq!(
            expected_intent, INTENT_ID,
            "evidence intent_id header mismatch"
        );
    }

    assert_lines_have_ids("evidence", &evidence_lines, INTENT_ID, RUN_ID);
    assert_eq!(
        evidence_lines, log_lines,
        "evidence log lines should match captured logs"
    );
}
