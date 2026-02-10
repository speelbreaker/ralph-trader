//! Durable intent ledger (WAL) for RecordedBeforeDispatch.
//!
//! Initialization: use `Ledger::open` with a WAL file path. The file is created if missing
//! and a writer thread is started for append-only persistence.
//!
//! Recording: `record_before_dispatch` enqueues a record into a bounded in-memory queue.
//! Success means RecordedBeforeDispatch. If the queue is full, the call returns immediately
//! with an error (hot loop is not blocked) and `wal_write_errors` increments.
//!
//! Replay: `replay_latest` reads the WAL file and returns the latest record per intent_hash.
//! The caller must reconcile with the exchange before dispatch. To mark replay outcomes
//! (sent/ack/fill), append an updated record (see `record_replay_outcome`). A record with
//! `sent_ts` set is treated as already dispatched and must not be resent.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::thread;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Buy,
    Sell,
}

impl Side {
    fn as_str(self) -> &'static str {
        match self {
            Side::Buy => "Buy",
            Side::Sell => "Sell",
        }
    }

    fn parse(value: &str) -> Result<Self, LedgerError> {
        match value {
            "Buy" => Ok(Side::Buy),
            "Sell" => Ok(Side::Sell),
            other => Err(LedgerError::Parse(format!("invalid side: {other}"))),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct LedgerRecord {
    pub intent_hash: u64,
    pub group_id: String,
    pub leg_idx: u32,
    pub instrument: String,
    pub side: Side,
    pub qty_steps: Option<i64>,
    pub qty_q: Option<f64>,
    pub limit_price_q: Option<f64>,
    pub price_ticks: Option<i64>,
    pub tls_state: String,
    pub created_ts: u64,
    pub sent_ts: Option<u64>,
    pub ack_ts: Option<u64>,
    pub last_fill_ts: Option<u64>,
    pub exchange_order_id: Option<String>,
    pub last_trade_id: Option<String>,
}

impl LedgerRecord {
    /// Minimum persisted intent schema (contract §2.4):
    /// intent_hash, group_id, leg_idx, instrument, side, qty_steps or qty_q,
    /// limit_price_q or price_ticks, tls_state, created_ts, sent_ts, ack_ts,
    /// last_fill_ts, exchange_order_id (if known), last_trade_id (if known).
    pub fn validate_minimum(&self) -> Result<(), LedgerError> {
        if self.group_id.trim().is_empty() {
            return Err(LedgerError::RecordSchema(
                "group_id must be non-empty".to_string(),
            ));
        }
        if self.instrument.trim().is_empty() {
            return Err(LedgerError::RecordSchema(
                "instrument must be non-empty".to_string(),
            ));
        }
        if self.tls_state.trim().is_empty() {
            return Err(LedgerError::RecordSchema(
                "tls_state must be non-empty".to_string(),
            ));
        }
        if self.created_ts == 0 {
            return Err(LedgerError::RecordSchema(
                "created_ts must be non-zero".to_string(),
            ));
        }
        if self.qty_steps.is_none() && self.qty_q.is_none() {
            return Err(LedgerError::RecordSchema(
                "qty_steps or qty_q is required".to_string(),
            ));
        }
        if self.limit_price_q.is_none() && self.price_ticks.is_none() {
            return Err(LedgerError::RecordSchema(
                "limit_price_q or price_ticks is required".to_string(),
            ));
        }
        Ok(())
    }

    pub fn with_sent_ts(&self, sent_ts: u64) -> Self {
        let mut record = self.clone();
        record.sent_ts = Some(sent_ts);
        record
    }

    pub fn with_ack_ts(&self, ack_ts: u64) -> Self {
        let mut record = self.clone();
        record.ack_ts = Some(ack_ts);
        record
    }

    pub fn with_last_fill_ts(&self, last_fill_ts: u64) -> Self {
        let mut record = self.clone();
        record.last_fill_ts = Some(last_fill_ts);
        record
    }

    fn to_line(&self) -> String {
        format!(
            "intent_hash={}|group_id={}|leg_idx={}|instrument={}|side={}|qty_steps={}|qty_q={}|limit_price_q={}|price_ticks={}|tls_state={}|created_ts={}|sent_ts={}|ack_ts={}|last_fill_ts={}|exchange_order_id={}|last_trade_id={}",
            self.intent_hash,
            escape_field(&self.group_id),
            self.leg_idx,
            escape_field(&self.instrument),
            self.side.as_str(),
            format_opt_i64(self.qty_steps),
            format_opt_f64(self.qty_q),
            format_opt_f64(self.limit_price_q),
            format_opt_i64(self.price_ticks),
            escape_field(&self.tls_state),
            self.created_ts,
            format_opt_u64(self.sent_ts),
            format_opt_u64(self.ack_ts),
            format_opt_u64(self.last_fill_ts),
            format_opt_string(&self.exchange_order_id),
            format_opt_string(&self.last_trade_id),
        )
    }

    fn from_line(line: &str) -> Result<Self, LedgerError> {
        let mut fields: HashMap<&str, &str> = HashMap::new();
        for part in line.split('|') {
            if part.trim().is_empty() {
                continue;
            }
            let mut iter = part.splitn(2, '=');
            let key = iter
                .next()
                .ok_or_else(|| LedgerError::Parse("missing key".to_string()))?;
            let value = iter
                .next()
                .ok_or_else(|| LedgerError::Parse("missing value".to_string()))?;
            fields.insert(key, value);
        }

        let record = LedgerRecord {
            intent_hash: parse_required_u64(fields.get("intent_hash"), "intent_hash")?,
            group_id: unescape_required(fields.get("group_id"), "group_id")?,
            leg_idx: parse_required_u32(fields.get("leg_idx"), "leg_idx")?,
            instrument: unescape_required(fields.get("instrument"), "instrument")?,
            side: Side::parse(required_field(fields.get("side"), "side")?)?,
            qty_steps: parse_opt_i64(fields.get("qty_steps"))?,
            qty_q: parse_opt_f64(fields.get("qty_q"))?,
            limit_price_q: parse_opt_f64(fields.get("limit_price_q"))?,
            price_ticks: parse_opt_i64(fields.get("price_ticks"))?,
            tls_state: unescape_required(fields.get("tls_state"), "tls_state")?,
            created_ts: parse_required_u64(fields.get("created_ts"), "created_ts")?,
            sent_ts: parse_opt_u64(fields.get("sent_ts"))?,
            ack_ts: parse_opt_u64(fields.get("ack_ts"))?,
            last_fill_ts: parse_opt_u64(fields.get("last_fill_ts"))?,
            exchange_order_id: parse_opt_string(fields.get("exchange_order_id"))?,
            last_trade_id: parse_opt_string(fields.get("last_trade_id"))?,
        };
        record.validate_minimum()?;
        Ok(record)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordOutcome {
    RecordedBeforeDispatch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayOutcome {
    Sent { sent_ts: u64 },
    Acked { ack_ts: u64 },
    Filled { last_fill_ts: u64 },
}

#[derive(Debug, Clone, PartialEq)]
pub struct LedgerReplay {
    pub records: Vec<LedgerRecord>,
}

impl LedgerReplay {
    pub fn pending_dispatches(&self) -> Vec<LedgerRecord> {
        self.records
            .iter()
            .filter(|record| record.sent_ts.is_none())
            .cloned()
            .collect()
    }

    pub fn record_by_intent_hash(&self, intent_hash: u64) -> Option<&LedgerRecord> {
        self.records
            .iter()
            .find(|record| record.intent_hash == intent_hash)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct LedgerConfig {
    pub queue_capacity: usize,
    pub writer_pause_on_start: bool,
}

impl Default for LedgerConfig {
    fn default() -> Self {
        Self {
            queue_capacity: 1024,
            writer_pause_on_start: false,
        }
    }
}

#[derive(Debug)]
pub enum LedgerError {
    QueueFull,
    WriterUnavailable(String),
    RecordSchema(String),
    Parse(String),
    Io(std::io::Error),
    Config(String),
}

impl From<std::io::Error> for LedgerError {
    fn from(err: std::io::Error) -> Self {
        LedgerError::Io(err)
    }
}

enum LedgerWrite {
    Record(Box<LedgerRecord>),
    Flush(mpsc::Sender<Result<(), LedgerError>>),
    Shutdown,
}

pub struct Ledger {
    path: PathBuf,
    writer_tx: SyncSender<LedgerWrite>,
    writer_handle: Option<thread::JoinHandle<()>>,
    writer_paused: Arc<AtomicBool>,
    queue_depth: Arc<AtomicUsize>,
    queue_capacity: usize,
    wal_write_errors: Arc<AtomicU64>,
}

impl Ledger {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, LedgerError> {
        Self::open_with_config(path, LedgerConfig::default())
    }

    pub fn open_with_config(
        path: impl AsRef<Path>,
        config: LedgerConfig,
    ) -> Result<Self, LedgerError> {
        if config.queue_capacity == 0 {
            return Err(LedgerError::Config(
                "queue_capacity must be >= 1".to_string(),
            ));
        }

        let path = path.as_ref().to_path_buf();
        ensure_parent_dir(&path)?;
        ensure_wal_file(&path)?;

        let (tx, rx) = mpsc::sync_channel(config.queue_capacity);
        let queue_depth = Arc::new(AtomicUsize::new(0));
        let wal_write_errors = Arc::new(AtomicU64::new(0));
        let writer_paused = Arc::new(AtomicBool::new(config.writer_pause_on_start));

        let writer_path = path.clone();
        let writer_depth = Arc::clone(&queue_depth);
        let writer_errors = Arc::clone(&wal_write_errors);
        let writer_pause = Arc::clone(&writer_paused);

        let handle = thread::spawn(move || {
            writer_loop(rx, writer_path, writer_depth, writer_errors, writer_pause);
        });

        Ok(Self {
            path,
            writer_tx: tx,
            writer_handle: Some(handle),
            writer_paused,
            queue_depth,
            queue_capacity: config.queue_capacity,
            wal_write_errors,
        })
    }

    pub fn wal_queue_capacity(&self) -> usize {
        self.queue_capacity
    }

    pub fn wal_queue_depth(&self) -> usize {
        self.queue_depth.load(Ordering::Relaxed)
    }

    pub fn wal_write_errors_total(&self) -> u64 {
        self.wal_write_errors.load(Ordering::Relaxed)
    }

    pub fn resume_writer(&self) {
        self.writer_paused.store(false, Ordering::Relaxed);
    }

    pub fn record_before_dispatch(
        &self,
        record: LedgerRecord,
    ) -> Result<RecordOutcome, LedgerError> {
        record.validate_minimum()?;
        match self
            .writer_tx
            .try_send(LedgerWrite::Record(Box::new(record)))
        {
            Ok(()) => {
                self.queue_depth.fetch_add(1, Ordering::Relaxed);
                Ok(RecordOutcome::RecordedBeforeDispatch)
            }
            Err(err) => {
                self.wal_write_errors.fetch_add(1, Ordering::Relaxed);
                Err(map_send_error(err))
            }
        }
    }

    pub fn record_replay_outcome(
        &self,
        record: LedgerRecord,
        outcome: ReplayOutcome,
    ) -> Result<RecordOutcome, LedgerError> {
        let updated = match outcome {
            ReplayOutcome::Sent { sent_ts } => record.with_sent_ts(sent_ts),
            ReplayOutcome::Acked { ack_ts } => record.with_ack_ts(ack_ts),
            ReplayOutcome::Filled { last_fill_ts } => record.with_last_fill_ts(last_fill_ts),
        };
        self.record_before_dispatch(updated)
    }

    pub fn flush(&self) -> Result<(), LedgerError> {
        let (tx, rx) = mpsc::channel();
        self.writer_tx
            .send(LedgerWrite::Flush(tx))
            .map_err(|_| LedgerError::WriterUnavailable("writer channel closed".to_string()))?;

        rx.recv_timeout(Duration::from_secs(5))
            .map_err(|_| LedgerError::WriterUnavailable("flush timeout".to_string()))?
    }

    pub fn replay_latest(&self) -> Result<LedgerReplay, LedgerError> {
        ensure_wal_file(&self.path)?;
        let file = File::open(&self.path)?;
        let reader = BufReader::new(file);
        let mut ordered: Vec<LedgerRecord> = Vec::new();
        for (idx, line) in reader.lines().enumerate() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let record = LedgerRecord::from_line(&line)
                .map_err(|err| LedgerError::Parse(format!("line {}: {:?}", idx + 1, err)))?;
            ordered.push(record);
        }

        let mut latest_by_intent: HashMap<u64, LedgerRecord> = HashMap::new();
        let mut order: Vec<u64> = Vec::new();
        for record in ordered {
            if let Some(pos) = order.iter().position(|hash| *hash == record.intent_hash) {
                order.remove(pos);
            }
            order.push(record.intent_hash);
            latest_by_intent.insert(record.intent_hash, record);
        }

        let mut latest = Vec::with_capacity(order.len());
        for intent_hash in order {
            if let Some(record) = latest_by_intent.remove(&intent_hash) {
                latest.push(record);
            }
        }

        Ok(LedgerReplay { records: latest })
    }
}

impl Drop for Ledger {
    fn drop(&mut self) {
        let _ = self.writer_tx.send(LedgerWrite::Shutdown);
        if let Some(handle) = self.writer_handle.take() {
            let _ = handle.join();
        }
    }
}

fn writer_loop(
    rx: Receiver<LedgerWrite>,
    path: PathBuf,
    queue_depth: Arc<AtomicUsize>,
    wal_write_errors: Arc<AtomicU64>,
    writer_paused: Arc<AtomicBool>,
) {
    let mut file = match OpenOptions::new().create(true).append(true).open(&path) {
        Ok(file) => file,
        Err(_) => {
            wal_write_errors.fetch_add(1, Ordering::Relaxed);
            return;
        }
    };

    loop {
        if writer_paused.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        match rx.recv() {
            Ok(LedgerWrite::Record(record)) => {
                let result = write_record(&mut file, &record);
                if result.is_err() {
                    wal_write_errors.fetch_add(1, Ordering::Relaxed);
                }
                queue_depth.fetch_sub(1, Ordering::Relaxed);
            }
            Ok(LedgerWrite::Flush(reply)) => {
                let result = file.sync_data().map_err(LedgerError::Io);
                let _ = reply.send(result);
            }
            Ok(LedgerWrite::Shutdown) => break,
            Err(_) => break,
        }
    }
}

fn write_record(file: &mut File, record: &LedgerRecord) -> Result<(), LedgerError> {
    let line = record.to_line();
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    Ok(())
}

fn map_send_error(err: TrySendError<LedgerWrite>) -> LedgerError {
    match err {
        TrySendError::Full(_) => LedgerError::QueueFull,
        TrySendError::Disconnected(_) => {
            LedgerError::WriterUnavailable("writer channel closed".to_string())
        }
    }
}

fn ensure_parent_dir(path: &Path) -> Result<(), LedgerError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

fn ensure_wal_file(path: &Path) -> Result<(), LedgerError> {
    OpenOptions::new().create(true).append(true).open(path)?;
    Ok(())
}

fn required_field<'a>(value: Option<&'a &str>, name: &str) -> Result<&'a str, LedgerError> {
    value
        .copied()
        .ok_or_else(|| LedgerError::Parse(format!("missing field: {name}")))
}

fn unescape_required(value: Option<&&str>, name: &str) -> Result<String, LedgerError> {
    let raw = required_field(value, name)?;
    unescape_field(raw)
}

fn parse_required_u64(value: Option<&&str>, name: &str) -> Result<u64, LedgerError> {
    required_field(value, name)?
        .parse()
        .map_err(|_| LedgerError::Parse(format!("invalid {name}")))
}

fn parse_required_u32(value: Option<&&str>, name: &str) -> Result<u32, LedgerError> {
    required_field(value, name)?
        .parse()
        .map_err(|_| LedgerError::Parse(format!("invalid {name}")))
}

fn parse_opt_i64(value: Option<&&str>) -> Result<Option<i64>, LedgerError> {
    match value {
        Some(raw) if !raw.is_empty() => raw
            .parse()
            .map(Some)
            .map_err(|_| LedgerError::Parse("invalid i64".to_string())),
        _ => Ok(None),
    }
}

fn parse_opt_u64(value: Option<&&str>) -> Result<Option<u64>, LedgerError> {
    match value {
        Some(raw) if !raw.is_empty() => raw
            .parse()
            .map(Some)
            .map_err(|_| LedgerError::Parse("invalid u64".to_string())),
        _ => Ok(None),
    }
}

fn parse_opt_f64(value: Option<&&str>) -> Result<Option<f64>, LedgerError> {
    match value {
        Some(raw) if !raw.is_empty() => raw
            .parse()
            .map(Some)
            .map_err(|_| LedgerError::Parse("invalid f64".to_string())),
        _ => Ok(None),
    }
}

fn parse_opt_string(value: Option<&&str>) -> Result<Option<String>, LedgerError> {
    match value {
        Some(raw) if !raw.is_empty() => Ok(Some(unescape_field(raw)?)),
        _ => Ok(None),
    }
}

fn format_opt_i64(value: Option<i64>) -> String {
    value.map(|v| v.to_string()).unwrap_or_default()
}

fn format_opt_u64(value: Option<u64>) -> String {
    value.map(|v| v.to_string()).unwrap_or_default()
}

fn format_opt_f64(value: Option<f64>) -> String {
    value.map(|v| v.to_string()).unwrap_or_default()
}

fn format_opt_string(value: &Option<String>) -> String {
    value.as_ref().map(|v| escape_field(v)).unwrap_or_default()
}

fn escape_field(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '%' => out.push_str("%25"),
            '|' => out.push_str("%7C"),
            '=' => out.push_str("%3D"),
            '\n' => out.push_str("%0A"),
            '\r' => out.push_str("%0D"),
            _ => out.push(ch),
        }
    }
    out
}

fn unescape_field(value: &str) -> Result<String, LedgerError> {
    let mut out = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut idx = 0;
    while idx < bytes.len() {
        if bytes[idx] == b'%' {
            if idx + 2 >= bytes.len() {
                return Err(LedgerError::Parse("invalid escape".to_string()));
            }
            let code = &value[idx + 1..idx + 3];
            let ch = match code {
                "25" => '%',
                "7C" => '|',
                "3D" => '=',
                "0A" => '\n',
                "0D" => '\r',
                other => return Err(LedgerError::Parse(format!("invalid escape: %{other}"))),
            };
            out.push(ch);
            idx += 3;
        } else {
            out.push(bytes[idx] as char);
            idx += 1;
        }
    }
    Ok(out)
}
