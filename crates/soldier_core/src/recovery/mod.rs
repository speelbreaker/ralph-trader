pub mod label_match;

pub use label_match::{
    label_match_ambiguity_total, match_label, match_label_with_metrics, LabelMatchCandidate,
    LabelMatchDecision, LabelMatchError, LabelMatchMetrics, LabelMatchOrder,
};
