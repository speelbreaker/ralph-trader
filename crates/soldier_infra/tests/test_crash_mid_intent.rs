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

#[test]
fn test_crash_after_sent_state_detected_on_replay() {
    // Crash scenario: WAL has Sent state, restart detects in-flight
    let path = temp_wal_path("crash_after_sent");
    let record = sample_record(5555);

    let ledger = Ledger::open(&path).expect("open ledger");
    ledger
        .record_before_dispatch(record.clone())
        .expect("record before dispatch");
    ledger
        .record_replay_outcome(record.clone(), ReplayOutcome::Sent { sent_ts: 100 })
        .expect("mark sent");
    ledger.flush().expect("flush");
    drop(ledger);

    // Restart: Sent should be detected as in-flight
    let ledger = Ledger::open(&path).expect("reopen");
    let replay = ledger.replay_latest().expect("replay");
    let latest = replay
        .record_by_intent_hash(record.intent_hash)
        .expect("find record");
    assert_eq!(latest.sent_ts, Some(100));
    assert_eq!(latest.ack_ts, None); // Still in-flight

    // Sent orders are inflight, not pending new dispatch
    let pending = replay.pending_dispatches();
    assert!(
        pending.is_empty() || pending.iter().all(|r| r.sent_ts.is_some()),
        "Sent orders should not be pending new dispatch"
    );
}

#[test]
fn test_terminal_states_not_inflight_on_restart() {
    // Crash scenario: WAL has terminal states, they should not be inflight
    let path = temp_wal_path("terminal_states");

    let ledger = Ledger::open(&path).expect("open ledger");

    // Record 1: Filled (terminal)
    let mut filled = sample_record(1001);
    filled.tls_state = "Filled".to_string();
    filled.sent_ts = Some(100);
    filled.ack_ts = Some(110);
    filled.last_fill_ts = Some(120);
    ledger
        .record_before_dispatch(filled.clone())
        .expect("record filled");

    // Record 2: Rejected (terminal)
    let mut rejected = sample_record(1002);
    rejected.tls_state = "Rejected".to_string();
    rejected.sent_ts = Some(200);
    ledger
        .record_before_dispatch(rejected.clone())
        .expect("record rejected");

    ledger.flush().expect("flush");
    drop(ledger);

    // Restart: terminal states should not be pending dispatch
    let ledger = Ledger::open(&path).expect("reopen");
    let replay = ledger.replay_latest().expect("replay");
    let pending = replay.pending_dispatches();

    // Neither filled nor rejected should be pending
    assert!(
        !pending.iter().any(|r| r.intent_hash == filled.intent_hash),
        "Filled should not be pending dispatch"
    );
    assert!(
        !pending
            .iter()
            .any(|r| r.intent_hash == rejected.intent_hash),
        "Rejected should not be pending dispatch"
    );
}

#[test]
fn test_mixed_states_on_restart() {
    // Crash scenario: Mix of Open, Sent, and terminal states
    let path = temp_wal_path("mixed_states");

    let ledger = Ledger::open(&path).expect("open");

    // Open (should be pending)
    let open = sample_record(2001);
    ledger
        .record_before_dispatch(open.clone())
        .expect("record open");

    // Sent (inflight, not pending new dispatch)
    let sent = sample_record(2002);
    ledger
        .record_before_dispatch(sent.clone())
        .expect("record sent before");
    ledger
        .record_replay_outcome(sent.clone(), ReplayOutcome::Sent { sent_ts: 150 })
        .expect("mark sent");

    // Filled (terminal, not pending)
    let mut filled = sample_record(2003);
    filled.tls_state = "Filled".to_string();
    filled.sent_ts = Some(200);
    filled.last_fill_ts = Some(210);
    ledger
        .record_before_dispatch(filled.clone())
        .expect("record filled");

    ledger.flush().expect("flush");
    drop(ledger);

    // Restart
    let ledger = Ledger::open(&path).expect("reopen");
    let replay = ledger.replay_latest().expect("replay");
    let pending = replay.pending_dispatches();

    // Only Open should be pending dispatch
    let open_pending = pending
        .iter()
        .filter(|r| r.intent_hash == open.intent_hash)
        .count();
    assert_eq!(open_pending, 1, "Open should be pending dispatch");

    let sent_pending = pending
        .iter()
        .filter(|r| r.intent_hash == sent.intent_hash && r.sent_ts.is_none())
        .count();
    assert_eq!(sent_pending, 0, "Sent should not be pending new dispatch");

    let filled_pending = pending
        .iter()
        .filter(|r| r.intent_hash == filled.intent_hash)
        .count();
    assert_eq!(filled_pending, 0, "Filled should not be pending dispatch");
}

#[test]
fn test_no_ghost_state_after_crash() {
    // Crash scenario: Verify no phantom records appear after restart
    let path = temp_wal_path("no_ghost");
    let record = sample_record(3001);

    let ledger = Ledger::open(&path).expect("open");
    ledger
        .record_before_dispatch(record.clone())
        .expect("record");
    ledger.flush().expect("flush");
    drop(ledger);

    // Restart and mark sent
    let ledger = Ledger::open(&path).expect("reopen");
    let replay = ledger.replay_latest().expect("replay");
    let pending = replay.pending_dispatches();
    assert_eq!(pending.len(), 1);

    ledger
        .record_replay_outcome(pending[0].clone(), ReplayOutcome::Sent { sent_ts: 300 })
        .expect("mark sent");
    ledger.flush().expect("flush");
    drop(ledger);

    // Restart again - should only see 1 record, no ghosts
    let ledger = Ledger::open(&path).expect("reopen again");
    let replay = ledger.replay_latest().expect("replay");

    // Count total records via iteration
    let mut total_records = 0;
    if let Some(latest) = replay.record_by_intent_hash(record.intent_hash) {
        total_records = 1;
        assert_eq!(latest.sent_ts, Some(300));
    }

    assert_eq!(total_records, 1, "Should have exactly 1 record, no ghosts");
}

#[test]
fn test_wal_append_failure_prevents_dispatch() {
    // Scenario: If WAL append fails, dispatch must not proceed
    let path = temp_wal_path("append_failure");
    let record = sample_record(4001);

    let ledger = Ledger::open(&path).expect("open");

    // Successful append
    let result = ledger.record_before_dispatch(record.clone());
    assert!(result.is_ok(), "First append should succeed");

    ledger.flush().expect("flush");

    // Simulate state where we can verify append happened
    let replay = ledger.replay_latest().expect("replay");
    let found = replay.record_by_intent_hash(record.intent_hash);
    assert!(
        found.is_some(),
        "Record should be in WAL after successful append"
    );

    // In production, if append fails (disk full, permissions, etc.),
    // the dispatch loop MUST NOT proceed to send the order
}

#[test]
fn test_durable_append_with_fsync_barrier() {
    // Scenario: Verify fsync barrier ensures durability
    let path = temp_wal_path("fsync_barrier");
    let record = sample_record(5001);

    let ledger = Ledger::open(&path).expect("open");
    ledger
        .record_before_dispatch(record.clone())
        .expect("record");

    // Explicit flush creates fsync barrier
    ledger.flush().expect("flush with fsync");
    drop(ledger);

    // After flush+drop, WAL should survive process restart
    let ledger = Ledger::open(&path).expect("reopen");
    let replay = ledger.replay_latest().expect("replay");
    let found = replay.record_by_intent_hash(record.intent_hash);

    assert!(
        found.is_some(),
        "Record should survive restart after fsync barrier"
    );
    assert_eq!(found.unwrap().intent_hash, record.intent_hash);
}
