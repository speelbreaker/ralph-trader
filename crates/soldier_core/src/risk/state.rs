#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RiskState {
    Healthy,
    Degraded,
    Maintenance,
    Kill,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TradingMode {
    Active,
    ReduceOnly,
    Kill,
}

impl TradingMode {
    pub fn allows_open(self) -> bool {
        matches!(self, TradingMode::Active)
    }

    pub fn allows_close(self) -> bool {
        !matches!(self, TradingMode::Kill)
    }

    pub fn allows_hedge(self) -> bool {
        self.allows_close()
    }

    pub fn allows_cancel(self) -> bool {
        self.allows_close()
    }
}

pub struct PolicyGuard;

impl PolicyGuard {
    pub fn get_effective_mode(risk_state: RiskState) -> TradingMode {
        match risk_state {
            RiskState::Kill => TradingMode::Kill,
            RiskState::Degraded | RiskState::Maintenance => TradingMode::ReduceOnly,
            RiskState::Healthy => TradingMode::Active,
        }
    }
}
