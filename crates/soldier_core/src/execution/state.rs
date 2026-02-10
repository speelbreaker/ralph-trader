#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TlsmState {
    Created,
    Sent,
    Acked,
    PartiallyFilled,
    Filled,
    Canceled,
    Failed,
}

impl TlsmState {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            TlsmState::Filled | TlsmState::Canceled | TlsmState::Failed
        )
    }

    pub fn as_str(self) -> &'static str {
        match self {
            TlsmState::Created => "Created",
            TlsmState::Sent => "Sent",
            TlsmState::Acked => "Acked",
            TlsmState::PartiallyFilled => "PartiallyFilled",
            TlsmState::Filled => "Filled",
            TlsmState::Canceled => "Canceled",
            TlsmState::Failed => "Failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TlsmSide {
    Buy,
    Sell,
}

impl TlsmSide {
    pub fn as_str(self) -> &'static str {
        match self {
            TlsmSide::Buy => "Buy",
            TlsmSide::Sell => "Sell",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TlsmIntent {
    pub intent_hash: u64,
    pub group_id: String,
    pub leg_idx: u32,
    pub instrument: String,
    pub side: TlsmSide,
    pub qty_steps: Option<i64>,
    pub qty_q: Option<f64>,
    pub limit_price_q: Option<f64>,
    pub price_ticks: Option<i64>,
    pub created_ts: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TlsmEvent {
    Sent { ts_ms: u64 },
    Acked { ts_ms: u64 },
    PartiallyFilled { ts_ms: u64 },
    Filled { ts_ms: u64 },
    Canceled { ts_ms: u64 },
    Failed { ts_ms: u64 },
}

impl TlsmEvent {
    pub fn ts_ms(&self) -> u64 {
        match self {
            TlsmEvent::Sent { ts_ms }
            | TlsmEvent::Acked { ts_ms }
            | TlsmEvent::PartiallyFilled { ts_ms }
            | TlsmEvent::Filled { ts_ms }
            | TlsmEvent::Canceled { ts_ms }
            | TlsmEvent::Failed { ts_ms } => *ts_ms,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TlsmLedgerEntry {
    pub intent_hash: u64,
    pub group_id: String,
    pub leg_idx: u32,
    pub instrument: String,
    pub side: TlsmSide,
    pub qty_steps: Option<i64>,
    pub qty_q: Option<f64>,
    pub limit_price_q: Option<f64>,
    pub price_ticks: Option<i64>,
    pub tls_state: TlsmState,
    pub created_ts: u64,
    pub sent_ts: Option<u64>,
    pub ack_ts: Option<u64>,
    pub last_fill_ts: Option<u64>,
    pub exchange_order_id: Option<String>,
    pub last_trade_id: Option<String>,
}
