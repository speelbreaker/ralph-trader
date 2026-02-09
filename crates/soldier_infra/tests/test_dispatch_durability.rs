use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use soldier_infra::store::RecordOutcome;
use soldier_infra::{Wal, WalConfig, WalError, WalRecord, WalSide};

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

fn sample_record(intent_hash: u64) -> WalRecord {
    WalRecord {
        intent_hash,
        group_id: "group-1".to_string(),
        leg_idx: 0,
        instrument: "BTC-PERP".to_string(),
        side: WalSide::Buy,
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
fn test_dispatch_requires_wal_durable_append() {
    let path = temp_wal_path("durable_append");
    let wal = Arc::new(
        Wal::open_with_config(
            &path,
            WalConfig {
                queue_capacity: 4,
                writer_pause_on_start: true,
                require_wal_fsync_before_dispatch: true,
                ..WalConfig::default()
            },
        )
        .expect("open wal"),
    );

    let record = sample_record(1);
    let wal_clone = Arc::clone(&wal);
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = wal_clone.record_before_dispatch_with_barrier(record);
        let _ = tx.send(result);
    });

    match rx.recv_timeout(Duration::from_millis(50)) {
        Err(mpsc::RecvTimeoutError::Timeout) => {}
        other => panic!("barrier returned early: {other:?}"),
    }

    wal.resume_writer();

    let result = rx
        .recv_timeout(Duration::from_secs(2))
        .expect("barrier result");
    let outcome = result.expect("barrier ok");
    assert_eq!(outcome.outcome, RecordOutcome::RecordedBeforeDispatch);
    assert!(outcome.barrier_wait_ms > 0);
    assert!(wal.wal_durability_barrier_wait_ms() >= outcome.barrier_wait_ms);
}

#[test]
fn test_dispatch_durable_barrier_disabled_returns_immediately() {
    let path = temp_wal_path("barrier_disabled");
    let wal = Arc::new(
        Wal::open_with_config(
            &path,
            WalConfig {
                queue_capacity: 4,
                writer_pause_on_start: true,
                require_wal_fsync_before_dispatch: false,
                ..WalConfig::default()
            },
        )
        .expect("open wal"),
    );

    let record = sample_record(2);
    let wal_clone = Arc::clone(&wal);
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = wal_clone.record_before_dispatch_with_barrier(record);
        let _ = tx.send(result);
    });

    let result = rx
        .recv_timeout(Duration::from_millis(50))
        .expect("barrier result");
    let outcome = result.expect("barrier ok");
    assert_eq!(outcome.outcome, RecordOutcome::RecordedBeforeDispatch);
    assert_eq!(outcome.barrier_wait_ms, 0);
    assert_eq!(wal.wal_durability_barrier_wait_ms(), 0);

    wal.resume_writer();
}

#[test]
fn test_open_blocked_when_wal_enqueue_fails() {
    let path = temp_wal_path("queue_full");
    let wal = Wal::open_with_config(
        &path,
        WalConfig {
            queue_capacity: 1,
            writer_pause_on_start: true,
            require_wal_fsync_before_dispatch: false,
            ..WalConfig::default()
        },
    )
    .expect("open wal");

    wal.record_before_dispatch(sample_record(3))
        .expect("first enqueue");
    let err = wal
        .record_before_dispatch_with_barrier(sample_record(4))
        .expect_err("queue full");
    assert!(matches!(err, WalError::QueueFull));
    assert_eq!(wal.wal_write_errors_total(), 1);

    wal.resume_writer();
}
