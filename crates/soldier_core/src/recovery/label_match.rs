use std::sync::atomic::{AtomicU64, Ordering};

use crate::execution::{CompactLabelParts, LabelDecodeError, Side, decode_compact_label};
use crate::risk::RiskState;

#[derive(Debug, Clone)]
pub struct LabelMatchCandidate<'a> {
    pub group_id: &'a str,
    pub leg_idx: u8,
    pub intent_hash: u64,
    pub instrument_id: &'a str,
    pub side: Side,
    pub qty_q: f64,
}

#[derive(Debug, Clone)]
pub struct LabelMatchOrder<'a> {
    pub label: &'a str,
    pub instrument_id: &'a str,
    pub side: Side,
    pub qty_q: f64,
}

#[derive(Debug, Clone)]
pub struct LabelMatchDecision<'a> {
    pub matched: Option<&'a LabelMatchCandidate<'a>>,
    pub risk_state: RiskState,
}

impl<'a> LabelMatchDecision<'a> {
    fn matched(candidate: &'a LabelMatchCandidate<'a>) -> Self {
        Self {
            matched: Some(candidate),
            risk_state: RiskState::Healthy,
        }
    }

    fn no_match() -> Self {
        Self {
            matched: None,
            risk_state: RiskState::Healthy,
        }
    }

    fn ambiguous() -> Self {
        Self {
            matched: None,
            risk_state: RiskState::Degraded,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LabelMatchError {
    InvalidLabel(LabelDecodeError),
}

pub struct LabelMatchMetrics {
    label_match_ambiguity_total: AtomicU64,
}

impl LabelMatchMetrics {
    pub const fn new() -> Self {
        Self {
            label_match_ambiguity_total: AtomicU64::new(0),
        }
    }

    pub fn label_match_ambiguity_total(&self) -> u64 {
        self.label_match_ambiguity_total.load(Ordering::Relaxed)
    }
}

impl Default for LabelMatchMetrics {
    fn default() -> Self {
        Self::new()
    }
}

static LABEL_MATCH_METRICS: LabelMatchMetrics = LabelMatchMetrics::new();

pub fn label_match_ambiguity_total() -> u64 {
    LABEL_MATCH_METRICS.label_match_ambiguity_total()
}

pub fn match_label<'a>(
    order: &LabelMatchOrder<'a>,
    candidates: &'a [LabelMatchCandidate<'a>],
) -> Result<LabelMatchDecision<'a>, LabelMatchError> {
    match_label_with_metrics(&LABEL_MATCH_METRICS, order, candidates)
}

pub fn match_label_with_metrics<'a>(
    metrics: &LabelMatchMetrics,
    order: &LabelMatchOrder<'a>,
    candidates: &'a [LabelMatchCandidate<'a>],
) -> Result<LabelMatchDecision<'a>, LabelMatchError> {
    let parts = decode_compact_label(order.label).map_err(LabelMatchError::InvalidLabel)?;

    let mut matching: Vec<&LabelMatchCandidate<'a>> = candidates
        .iter()
        .filter(|candidate| candidate_matches_gid_leg(candidate, &parts))
        .collect();

    if matching.is_empty() {
        return Ok(LabelMatchDecision::no_match());
    }

    if matching.len() == 1 {
        return Ok(LabelMatchDecision::matched(matching[0]));
    }

    matching = narrow_if_any(&matching, |candidate| {
        intent_hash_prefix(candidate.intent_hash) == parts.ih16
    });
    if matching.len() == 1 {
        return Ok(LabelMatchDecision::matched(matching[0]));
    }

    matching = narrow_if_any(&matching, |candidate| {
        candidate.instrument_id == order.instrument_id
    });
    if matching.len() == 1 {
        return Ok(LabelMatchDecision::matched(matching[0]));
    }

    matching = narrow_if_any(&matching, |candidate| candidate.side == order.side);
    if matching.len() == 1 {
        return Ok(LabelMatchDecision::matched(matching[0]));
    }

    matching = narrow_if_any(&matching, |candidate| candidate.qty_q == order.qty_q);
    if matching.len() == 1 {
        return Ok(LabelMatchDecision::matched(matching[0]));
    }

    metrics
        .label_match_ambiguity_total
        .fetch_add(1, Ordering::Relaxed);
    Ok(LabelMatchDecision::ambiguous())
}

fn candidate_matches_gid_leg(
    candidate: &LabelMatchCandidate<'_>,
    parts: &CompactLabelParts,
) -> bool {
    if candidate.leg_idx != parts.leg_idx {
        return false;
    }

    compact_gid12(candidate.group_id) == parts.gid12
}

fn compact_gid12(group_id: &str) -> String {
    let mut buf = String::with_capacity(12);
    for ch in group_id.chars() {
        if ch == '-' {
            continue;
        }
        if buf.len() >= 12 {
            break;
        }
        buf.push(ch);
    }
    buf
}

fn intent_hash_prefix(intent_hash: u64) -> String {
    format!("{:016x}", intent_hash)
}

fn narrow_if_any<'a, F>(
    candidates: &[&'a LabelMatchCandidate<'a>],
    mut predicate: F,
) -> Vec<&'a LabelMatchCandidate<'a>>
where
    F: FnMut(&LabelMatchCandidate<'a>) -> bool,
{
    let filtered: Vec<&'a LabelMatchCandidate<'a>> = candidates
        .iter()
        .copied()
        .filter(|candidate| predicate(candidate))
        .collect();

    if filtered.is_empty() {
        candidates.to_vec()
    } else {
        filtered
    }
}
