use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use soldier_infra::store::{Ledger, LedgerConfig, LedgerError, LedgerRecord, ReplayOutcome, Side};

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
fn test_ledger_replay_no_resend_after_crash() {
    let path = temp_wal_path("no_resend");
    let ledger = Ledger::open_with_config(&path, LedgerConfig::default()).expect("open ledger");

    let record = sample_record(42);
    ledger
        .record_before_dispatch(record.clone())
        .expect("record before dispatch");
    ledger.flush().expect("flush");
    drop(ledger);

    let ledger = Ledger::open(&path).expect("reopen ledger");
    let replay = ledger.replay_latest().expect("replay");
    let pending = replay.pending_dispatches();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].intent_hash, record.intent_hash);

    ledger
        .record_replay_outcome(pending[0].clone(), ReplayOutcome::Sent { sent_ts: 200 })
        .expect("mark sent");
    ledger.flush().expect("flush after sent");
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

#[test]
fn test_ledger_append_queue_full_increments_error() {
    let path = temp_wal_path("queue_full");
    let ledger = Ledger::open_with_config(
        &path,
        LedgerConfig {
            queue_capacity: 1,
            writer_pause_on_start: true,
        },
    )
    .expect("open ledger");

    ledger
        .record_before_dispatch(sample_record(1))
        .expect("first enqueue");
    let err = ledger
        .record_before_dispatch(sample_record(2))
        .expect_err("queue full");
    assert!(matches!(err, LedgerError::QueueFull));
    assert_eq!(ledger.wal_write_errors_total(), 1);

    ledger.resume_writer();
    ledger.flush().expect("flush to drain");
    drop(ledger);
}

#[test]
fn test_ledger_record_schema_requires_qty_and_price() {
    let path = temp_wal_path("schema");
    let ledger = Ledger::open(&path).expect("open ledger");

    let mut record = sample_record(7);
    record.qty_steps = None;
    record.qty_q = None;
    let err = ledger
        .record_before_dispatch(record)
        .expect_err("schema error");
    assert!(matches!(err, LedgerError::RecordSchema(_)));

    let mut record = sample_record(8);
    record.limit_price_q = None;
    record.price_ticks = None;
    let err = ledger
        .record_before_dispatch(record)
        .expect_err("schema error");
    assert!(matches!(err, LedgerError::RecordSchema(_)));
}
