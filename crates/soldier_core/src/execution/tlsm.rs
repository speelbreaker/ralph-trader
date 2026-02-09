use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};

use super::state::{TlsmEvent, TlsmIntent, TlsmLedgerEntry, TlsmState};

pub struct TlsmMetrics {
    out_of_order_total: AtomicU64,
}

impl TlsmMetrics {
    pub const fn new() -> Self {
        Self {
            out_of_order_total: AtomicU64::new(0),
        }
    }

    pub fn out_of_order_total(&self) -> u64 {
        self.out_of_order_total.load(Ordering::Relaxed)
    }
}

static TLSM_METRICS: TlsmMetrics = TlsmMetrics::new();

pub fn tlsm_out_of_order_total() -> u64 {
    TLSM_METRICS.out_of_order_total()
}

#[derive(Debug, Clone, PartialEq)]
pub struct TlsmTransition {
    pub from: TlsmState,
    pub to: TlsmState,
    pub event: TlsmEvent,
    pub entry: TlsmLedgerEntry,
}

#[derive(Debug, Clone)]
pub struct TlsmLedgerError {
    pub message: String,
}

impl TlsmLedgerError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for TlsmLedgerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for TlsmLedgerError {}

#[derive(Debug)]
pub enum TlsmError {
    Ledger(TlsmLedgerError),
}

impl From<TlsmLedgerError> for TlsmError {
    fn from(err: TlsmLedgerError) -> Self {
        TlsmError::Ledger(err)
    }
}

pub trait TlsmLedger {
    fn append_transition(&self, entry: &TlsmLedgerEntry) -> Result<(), TlsmLedgerError>;
}

pub struct Tlsm {
    intent: TlsmIntent,
    state: TlsmState,
    sent_ts: Option<u64>,
    ack_ts: Option<u64>,
    last_fill_ts: Option<u64>,
    exchange_order_id: Option<String>,
    last_trade_id: Option<String>,
}

impl Tlsm {
    pub fn new(intent: TlsmIntent) -> Self {
        Self {
            intent,
            state: TlsmState::Created,
            sent_ts: None,
            ack_ts: None,
            last_fill_ts: None,
            exchange_order_id: None,
            last_trade_id: None,
        }
    }

    pub fn state(&self) -> TlsmState {
        self.state
    }

    pub fn sent_ts(&self) -> Option<u64> {
        self.sent_ts
    }

    pub fn ack_ts(&self) -> Option<u64> {
        self.ack_ts
    }

    pub fn last_fill_ts(&self) -> Option<u64> {
        self.last_fill_ts
    }

    pub fn apply_event<L: TlsmLedger>(
        &mut self,
        ledger: &L,
        event: TlsmEvent,
    ) -> Result<TlsmTransition, TlsmError> {
        let from = self.state;
        if self.is_out_of_order(&event) {
            TLSM_METRICS
                .out_of_order_total
                .fetch_add(1, Ordering::Relaxed);
        }
        self.apply_event_ts(&event);
        let to = self.next_state(from, &event);
        self.state = to;
        let entry = self.build_ledger_entry();
        ledger.append_transition(&entry)?;
        Ok(TlsmTransition {
            from,
            to,
            event,
            entry,
        })
    }

    fn next_state(&self, current: TlsmState, event: &TlsmEvent) -> TlsmState {
        if matches!(event, TlsmEvent::Filled { .. }) {
            return TlsmState::Filled;
        }
        if current.is_terminal() {
            return current;
        }
        match event {
            TlsmEvent::Sent { .. } => match current {
                TlsmState::Created => TlsmState::Sent,
                _ => current,
            },
            TlsmEvent::Acked { .. } => match current {
                TlsmState::Created | TlsmState::Sent => TlsmState::Acked,
                _ => current,
            },
            TlsmEvent::PartiallyFilled { .. } => TlsmState::PartiallyFilled,
            TlsmEvent::Canceled { .. } => TlsmState::Canceled,
            TlsmEvent::Failed { .. } => TlsmState::Failed,
            TlsmEvent::Filled { .. } => TlsmState::Filled,
        }
    }

    fn apply_event_ts(&mut self, event: &TlsmEvent) {
        match event {
            TlsmEvent::Sent { ts_ms } => {
                if self.sent_ts.is_none() {
                    self.sent_ts = Some(*ts_ms);
                }
            }
            TlsmEvent::Acked { ts_ms } => {
                if self.ack_ts.is_none() {
                    self.ack_ts = Some(*ts_ms);
                }
            }
            TlsmEvent::PartiallyFilled { ts_ms } | TlsmEvent::Filled { ts_ms } => {
                self.last_fill_ts = Some(match self.last_fill_ts {
                    Some(existing) => existing.max(*ts_ms),
                    None => *ts_ms,
                });
            }
            TlsmEvent::Canceled { .. } | TlsmEvent::Failed { .. } => {}
        }
    }

    fn is_out_of_order(&self, event: &TlsmEvent) -> bool {
        match event {
            TlsmEvent::Sent { .. } => {
                self.sent_ts.is_some()
                    || self.ack_ts.is_some()
                    || self.last_fill_ts.is_some()
                    || self.state.is_terminal()
            }
            TlsmEvent::Acked { .. } => {
                self.sent_ts.is_none()
                    || self.last_fill_ts.is_some()
                    || matches!(self.state, TlsmState::Canceled | TlsmState::Failed)
            }
            TlsmEvent::PartiallyFilled { .. } => {
                self.ack_ts.is_none()
                    || matches!(
                        self.state,
                        TlsmState::Canceled | TlsmState::Failed | TlsmState::Filled
                    )
            }
            TlsmEvent::Filled { .. } => {
                self.ack_ts.is_none()
                    || matches!(
                        self.state,
                        TlsmState::Canceled | TlsmState::Failed | TlsmState::Filled
                    )
            }
            TlsmEvent::Canceled { .. } => {
                self.sent_ts.is_none() || matches!(self.state, TlsmState::Filled)
            }
            TlsmEvent::Failed { .. } => {
                self.sent_ts.is_none() || matches!(self.state, TlsmState::Filled)
            }
        }
    }

    fn build_ledger_entry(&self) -> TlsmLedgerEntry {
        TlsmLedgerEntry {
            intent_hash: self.intent.intent_hash,
            group_id: self.intent.group_id.clone(),
            leg_idx: self.intent.leg_idx,
            instrument: self.intent.instrument.clone(),
            side: self.intent.side,
            qty_steps: self.intent.qty_steps,
            qty_q: self.intent.qty_q,
            limit_price_q: self.intent.limit_price_q,
            price_ticks: self.intent.price_ticks,
            tls_state: self.state,
            created_ts: self.intent.created_ts,
            sent_ts: self.sent_ts,
            ack_ts: self.ack_ts,
            last_fill_ts: self.last_fill_ts,
            exchange_order_id: self.exchange_order_id.clone(),
            last_trade_id: self.last_trade_id.clone(),
        }
    }
}
