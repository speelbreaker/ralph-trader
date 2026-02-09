use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

use soldier_infra::{TradeIdInsertOutcome, TradeIdRecord, TradeIdRegistry};

static REGISTRY_COUNTER: AtomicUsize = AtomicUsize::new(0);

fn temp_registry_path(label: &str) -> std::path::PathBuf {
    let mut path = std::env::temp_dir();
    let idx = REGISTRY_COUNTER.fetch_add(1, Ordering::Relaxed);
    path.push(format!(
        "soldier_infra_trade_id_registry_{}_{}.log",
        label, idx
    ));
    let _ = std::fs::remove_file(&path);
    path
}

fn sample_record(trade_id: &str) -> TradeIdRecord {
    TradeIdRecord {
        trade_id: trade_id.to_string(),
        group_id: "group-1".to_string(),
        leg_idx: 2,
        ts: 1_702_000_123,
        qty: 1.25,
        price: 42001.5,
    }
}

#[test]
fn test_trade_id_registry_dedupes_ws_trade() {
    let path = temp_registry_path("dedupe");
    let registry = TradeIdRegistry::open(&path).expect("open registry");
    let record = sample_record("trade-123");

    let first = registry.record_trade(record.clone()).expect("insert trade");
    assert_eq!(first, TradeIdInsertOutcome::Inserted);

    let second = registry
        .record_trade(record.clone())
        .expect("duplicate trade");
    assert_eq!(second, TradeIdInsertOutcome::Duplicate);
    assert_eq!(registry.trade_id_duplicates_total(), 1);

    let contents = std::fs::read_to_string(&path).expect("read registry file");
    let lines: Vec<&str> = contents
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    assert_eq!(lines.len(), 1);
}

#[test]
fn test_trade_id_registry_persists_across_restart() {
    let path = temp_registry_path("restart");
    let record = sample_record("trade-456");

    {
        let registry = TradeIdRegistry::open(&path).expect("open registry");
        let first = registry.record_trade(record.clone()).expect("insert trade");
        assert_eq!(first, TradeIdInsertOutcome::Inserted);
    }

    let registry = TradeIdRegistry::open(&path).expect("reopen registry");
    let second = registry.record_trade(record).expect("duplicate trade");
    assert_eq!(second, TradeIdInsertOutcome::Duplicate);
    assert_eq!(registry.trade_id_duplicates_total(), 1);
}

#[test]
fn test_trade_id_registry_appends_before_apply() {
    let path = temp_registry_path("append");
    let registry = TradeIdRegistry::open(&path).expect("open registry");
    let record = sample_record("trade-789");

    let outcome = registry.record_trade(record).expect("insert trade");
    assert_eq!(outcome, TradeIdInsertOutcome::Inserted);

    let contents = std::fs::read_to_string(&path).expect("read registry file");
    assert!(contents.contains("trade_id=trade-789"));
}

#[test]
fn test_trade_id_registry_concurrent_insert() {
    let path = temp_registry_path("concurrent");
    let registry = Arc::new(TradeIdRegistry::open(&path).expect("open registry"));
    let record = sample_record("trade-999");

    let mut handles = Vec::new();
    for _ in 0..8 {
        let registry = Arc::clone(&registry);
        let record = record.clone();
        handles.push(thread::spawn(move || {
            registry.record_trade(record).expect("record trade")
        }));
    }

    let mut inserted = 0;
    let mut duplicates = 0;
    for handle in handles {
        match handle.join().expect("join") {
            TradeIdInsertOutcome::Inserted => inserted += 1,
            TradeIdInsertOutcome::Duplicate => duplicates += 1,
        }
    }

    assert_eq!(inserted, 1);
    assert_eq!(duplicates, 7);
    assert_eq!(registry.trade_id_duplicates_total(), 7);

    let contents = std::fs::read_to_string(&path).expect("read registry file");
    let lines: Vec<&str> = contents
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    assert_eq!(lines.len(), 1);
}
