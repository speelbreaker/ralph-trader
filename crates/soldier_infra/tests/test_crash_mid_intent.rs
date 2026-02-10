use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use soldier_infra::store::{Ledger, LedgerRecord, ReplayOutcome, Side};

fn temp_wal_path(test_name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    path.push(format!(
        "soldier_infra_{}_{}_{}.wal",
        test_name,
        std::process::id(),
        nanos
    ));
    path
}

fn sample_record(intent_hash: u64) -> LedgerRecord {
    LedgerRecord {
        intent_hash,
        group_id: "group-1".to_string(),
        leg_idx: 0,
        instrument: "BTC-PERP".to_string(),
        side: Side::Buy,
        qty_steps: Some(10),
        qty_q: None,
        limit_price_q: Some(100.5),
        price_ticks: None,
        tls_state: "Open".to_string(),
        created_ts: 1,
        sent_ts: None,
        ack_ts: None,
        last_fill_ts: None,
        exchange_order_id: None,
        last_trade_id: None,
    }
}

#[test]
fn test_crash_mid_intent_no_duplicate_dispatch() {
    let path = temp_wal_path("crash_mid_intent");
    let record = sample_record(4242);

    let ledger = Ledger::open(&path).expect("open ledger");
    ledger
        .record_before_dispatch(record.clone())
        .expect("record before dispatch");
    ledger.flush().expect("flush before crash");
    drop(ledger);

    let ledger = Ledger::open(&path).expect("reopen ledger");
    let replay = ledger.replay_latest().expect("replay after crash");
    let pending = replay.pending_dispatches();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].intent_hash, record.intent_hash);

    let mut dispatch_count = 0u64;
    for pending_record in pending {
        dispatch_count += 1;
        ledger
            .record_replay_outcome(pending_record, ReplayOutcome::Sent { sent_ts: 200 })
            .expect("mark sent");
    }
    assert_eq!(dispatch_count, 1);
    ledger.flush().expect("flush sent record");
    drop(ledger);

    let ledger = Ledger::open(&path).expect("reopen ledger again");
    let replay = ledger.replay_latest().expect("replay after sent");
    let pending = replay.pending_dispatches();
    assert!(pending.is_empty());
    let latest = replay
        .record_by_intent_hash(record.intent_hash)
        .expect("latest record");
    assert_eq!(latest.sent_ts, Some(200));
}
