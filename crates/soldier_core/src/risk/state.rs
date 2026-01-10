#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RiskState {
    Healthy,
    Degraded,
    Maintenance,
    Kill,
}
