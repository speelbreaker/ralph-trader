use std::sync::{Arc, Mutex};

use soldier_core::execution::{
    Tlsm, TlsmError, TlsmEvent, TlsmIntent, TlsmLedger, TlsmLedgerEntry, TlsmLedgerError, TlsmSide,
    TlsmState,
};

#[derive(Clone, Default)]
struct TestLedger {
    entries: Arc<Mutex<Vec<TlsmLedgerEntry>>>,
}

impl TestLedger {
    fn len(&self) -> usize {
        self.entries.lock().expect("lock ledger entries").len()
    }

    fn entries(&self) -> Vec<TlsmLedgerEntry> {
        self.entries.lock().expect("lock ledger entries").clone()
    }
}

impl TlsmLedger for TestLedger {
    fn append_transition(&self, entry: &TlsmLedgerEntry) -> Result<(), TlsmLedgerError> {
        self.entries
            .lock()
            .expect("lock ledger entries")
            .push(entry.clone());
        Ok(())
    }
}

struct FailingLedger;

impl TlsmLedger for FailingLedger {
    fn append_transition(&self, _entry: &TlsmLedgerEntry) -> Result<(), TlsmLedgerError> {
        Err(TlsmLedgerError::new("append failed"))
    }
}

fn sample_intent() -> TlsmIntent {
    TlsmIntent {
        intent_hash: 0xdeadbeef,
        group_id: "group-1".to_string(),
        leg_idx: 0,
        instrument: "BTC-PERP".to_string(),
        side: TlsmSide::Buy,
        qty_steps: Some(10),
        qty_q: Some(1.0),
        limit_price_q: Some(100.0),
        price_ticks: Some(1000),
        created_ts: 1,
    }
}

#[test]
fn test_tlsm_fill_before_ack_no_panic() {
    let ledger = TestLedger::default();
    let mut tlsm = Tlsm::new(sample_intent());

    tlsm.apply_event(&ledger, TlsmEvent::Filled { ts_ms: 200 })
        .expect("apply fill");
    assert_eq!(ledger.len(), 1);

    tlsm.apply_event(&ledger, TlsmEvent::Acked { ts_ms: 150 })
        .expect("apply ack");
    assert_eq!(ledger.len(), 2);
    assert_eq!(tlsm.state(), TlsmState::Filled);

    let entries = ledger.entries();
    assert_eq!(entries[0].tls_state, TlsmState::Filled);
    assert_eq!(entries[0].last_fill_ts, Some(200));
    assert_eq!(entries[0].ack_ts, None);
    assert_eq!(entries[1].tls_state, TlsmState::Filled);
    assert_eq!(entries[1].ack_ts, Some(150));
}

#[test]
fn test_tlsm_out_of_order_converges() {
    let ordered = vec![
        TlsmEvent::Sent { ts_ms: 10 },
        TlsmEvent::Acked { ts_ms: 20 },
        TlsmEvent::Filled { ts_ms: 30 },
    ];
    let out_of_order = vec![
        TlsmEvent::Filled { ts_ms: 30 },
        TlsmEvent::Acked { ts_ms: 20 },
        TlsmEvent::Sent { ts_ms: 10 },
    ];

    let ordered_state = apply_events(ordered);
    let out_of_order_state = apply_events(out_of_order);

    assert_eq!(ordered_state, TlsmState::Filled);
    assert_eq!(out_of_order_state, TlsmState::Filled);
}

#[test]
fn test_tlsm_ledger_append_failure_is_atomic() {
    let ledger = FailingLedger;
    let mut tlsm = Tlsm::new(sample_intent());

    let err = tlsm
        .apply_event(&ledger, TlsmEvent::Sent { ts_ms: 10 })
        .expect_err("append should fail");
    assert!(matches!(err, TlsmError::Ledger(_)));

    assert_eq!(tlsm.state(), TlsmState::Created);
    assert_eq!(tlsm.sent_ts(), None);
    assert_eq!(tlsm.ack_ts(), None);
    assert_eq!(tlsm.last_fill_ts(), None);
}

fn apply_events(events: Vec<TlsmEvent>) -> TlsmState {
    let ledger = TestLedger::default();
    let mut tlsm = Tlsm::new(sample_intent());
    for event in events {
        tlsm.apply_event(&ledger, event).expect("apply event");
    }
    tlsm.state()
}
