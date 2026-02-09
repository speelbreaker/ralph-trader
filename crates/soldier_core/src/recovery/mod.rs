pub mod label_match;

pub use label_match::{
    LabelMatchCandidate, LabelMatchDecision, LabelMatchError, LabelMatchMetrics, LabelMatchOrder,
    label_match_ambiguity_total, match_label, match_label_with_metrics,
};
