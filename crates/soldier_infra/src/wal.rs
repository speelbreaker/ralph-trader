//! WAL durability barrier for dispatch gating.
//!
//! RecordedBeforeDispatch remains non-blocking (enqueue only). If the config flag
//! `require_wal_fsync_before_dispatch` is enabled, callers can await a durability
//! barrier that completes only after fsync (or equivalent) finishes.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::store::{LedgerError, LedgerRecord, RecordOutcome, Side};

pub type WalRecord = LedgerRecord;
pub type WalSide = Side;

#[derive(Debug, Clone, Copy)]
pub struct WalConfig {
    pub queue_capacity: usize,
    pub writer_pause_on_start: bool,
    /// When true, callers awaiting the durability barrier will wait for fsync
    /// before dispatch (config flag: require_wal_fsync_before_dispatch).
    pub require_wal_fsync_before_dispatch: bool,
    pub durability_timeout: Duration,
}

impl Default for WalConfig {
    fn default() -> Self {
        Self {
            queue_capacity: 1024,
            writer_pause_on_start: false,
            require_wal_fsync_before_dispatch: false,
            durability_timeout: Duration::from_secs(5),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DurableAppendOutcome {
    pub outcome: RecordOutcome,
    pub barrier_wait_ms: u64,
}

#[derive(Debug)]
pub enum WalError {
    QueueFull,
    WriterUnavailable(String),
    RecordSchema(String),
    Io(std::io::Error),
    BarrierTimeout,
}

impl From<std::io::Error> for WalError {
    fn from(err: std::io::Error) -> Self {
        WalError::Io(err)
    }
}

enum WalWrite {
    Record {
        record: Box<WalRecord>,
        barrier: Option<mpsc::Sender<Result<(), WalError>>>,
    },
    Shutdown,
}

pub struct Wal {
    writer_tx: SyncSender<WalWrite>,
    writer_handle: Mutex<Option<thread::JoinHandle<()>>>,
    writer_paused: Arc<AtomicBool>,
    queue_depth: Arc<AtomicUsize>,
    queue_capacity: usize,
    wal_write_errors: Arc<AtomicU64>,
    require_wal_fsync_before_dispatch: bool,
    durability_timeout: Duration,
    last_barrier_wait_ms: AtomicU64,
}

impl Wal {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, WalError> {
        Self::open_with_config(path, WalConfig::default())
    }

    pub fn open_with_config(path: impl AsRef<Path>, config: WalConfig) -> Result<Self, WalError> {
        if config.queue_capacity == 0 {
            return Err(WalError::WriterUnavailable(
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
            writer_tx: tx,
            writer_handle: Mutex::new(Some(handle)),
            writer_paused,
            queue_depth,
            queue_capacity: config.queue_capacity,
            wal_write_errors,
            require_wal_fsync_before_dispatch: config.require_wal_fsync_before_dispatch,
            durability_timeout: config.durability_timeout,
            last_barrier_wait_ms: AtomicU64::new(0),
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

    pub fn wal_durability_barrier_wait_ms(&self) -> u64 {
        self.last_barrier_wait_ms.load(Ordering::Relaxed)
    }

    pub fn resume_writer(&self) {
        self.writer_paused.store(false, Ordering::Relaxed);
    }

    pub fn record_before_dispatch(&self, record: WalRecord) -> Result<RecordOutcome, WalError> {
        record.validate_minimum().map_err(map_record_error)?;
        self.enqueue_record(record, None)
    }

    pub fn record_before_dispatch_with_barrier(
        &self,
        record: WalRecord,
    ) -> Result<DurableAppendOutcome, WalError> {
        record.validate_minimum().map_err(map_record_error)?;
        if !self.require_wal_fsync_before_dispatch {
            let outcome = self.enqueue_record(record, None)?;
            self.last_barrier_wait_ms.store(0, Ordering::Relaxed);
            return Ok(DurableAppendOutcome {
                outcome,
                barrier_wait_ms: 0,
            });
        }

        let (tx, rx) = mpsc::channel();
        let outcome = self.enqueue_record(record, Some(tx))?;
        let start = Instant::now();
        let result = rx.recv_timeout(self.durability_timeout);
        let wait_ms = start.elapsed().as_millis() as u64;
        self.last_barrier_wait_ms.store(wait_ms, Ordering::Relaxed);
        match result {
            Ok(Ok(())) => Ok(DurableAppendOutcome {
                outcome,
                barrier_wait_ms: wait_ms,
            }),
            Ok(Err(err)) => Err(err),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.wal_write_errors.fetch_add(1, Ordering::Relaxed);
                Err(WalError::BarrierTimeout)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                self.wal_write_errors.fetch_add(1, Ordering::Relaxed);
                Err(WalError::WriterUnavailable(
                    "durability barrier channel closed".to_string(),
                ))
            }
        }
    }

    fn enqueue_record(
        &self,
        record: WalRecord,
        barrier: Option<mpsc::Sender<Result<(), WalError>>>,
    ) -> Result<RecordOutcome, WalError> {
        match self.writer_tx.try_send(WalWrite::Record {
            record: Box::new(record),
            barrier,
        }) {
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
}

impl Drop for Wal {
    fn drop(&mut self) {
        self.writer_paused.store(false, Ordering::Relaxed);
        let _ = self.writer_tx.send(WalWrite::Shutdown);
        if let Ok(mut handle_opt) = self.writer_handle.lock()
            && let Some(handle) = handle_opt.take()
        {
            let _ = handle.join();
        }
    }
}

fn writer_loop(
    rx: Receiver<WalWrite>,
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
        match rx.recv() {
            Ok(WalWrite::Record { record, barrier }) => {
                while writer_paused.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(10));
                }
                let write_result = write_record(&mut file, &record);
                let mut write_error = None;
                if let Err(err) = write_result {
                    wal_write_errors.fetch_add(1, Ordering::Relaxed);
                    write_error = Some(err);
                }
                if let Some(reply) = barrier {
                    let result = match write_error {
                        Some(err) => Err(err),
                        None => {
                            let sync_result = file.sync_data().map_err(WalError::Io);
                            if sync_result.is_err() {
                                wal_write_errors.fetch_add(1, Ordering::Relaxed);
                            }
                            sync_result
                        }
                    };
                    let _ = reply.send(result);
                }
                queue_depth.fetch_sub(1, Ordering::Relaxed);
            }
            Ok(WalWrite::Shutdown) => break,
            Err(_) => break,
        }
    }
}

fn map_send_error(err: TrySendError<WalWrite>) -> WalError {
    match err {
        TrySendError::Full(_) => WalError::QueueFull,
        TrySendError::Disconnected(_) => {
            WalError::WriterUnavailable("writer channel closed".to_string())
        }
    }
}

fn map_record_error(err: LedgerError) -> WalError {
    match err {
        LedgerError::QueueFull => WalError::QueueFull,
        LedgerError::WriterUnavailable(msg) => WalError::WriterUnavailable(msg),
        LedgerError::RecordSchema(msg) => WalError::RecordSchema(msg),
        LedgerError::Parse(msg) => WalError::RecordSchema(msg),
        LedgerError::Io(err) => WalError::Io(err),
        LedgerError::Config(msg) => WalError::WriterUnavailable(msg),
    }
}

fn write_record(file: &mut File, record: &WalRecord) -> Result<(), WalError> {
    let line = record_to_line(record);
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    Ok(())
}

fn record_to_line(record: &WalRecord) -> String {
    format!(
        "intent_hash={}|group_id={}|leg_idx={}|instrument={}|side={}|qty_steps={}|qty_q={}|limit_price_q={}|price_ticks={}|tls_state={}|created_ts={}|sent_ts={}|ack_ts={}|last_fill_ts={}|exchange_order_id={}|last_trade_id={}",
        record.intent_hash,
        escape_field(&record.group_id),
        record.leg_idx,
        escape_field(&record.instrument),
        side_as_str(record.side),
        format_opt_i64(record.qty_steps),
        format_opt_f64(record.qty_q),
        format_opt_f64(record.limit_price_q),
        format_opt_i64(record.price_ticks),
        escape_field(&record.tls_state),
        record.created_ts,
        format_opt_u64(record.sent_ts),
        format_opt_u64(record.ack_ts),
        format_opt_u64(record.last_fill_ts),
        format_opt_string(&record.exchange_order_id),
        format_opt_string(&record.last_trade_id),
    )
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

fn side_as_str(side: WalSide) -> &'static str {
    match side {
        WalSide::Buy => "Buy",
        WalSide::Sell => "Sell",
    }
}

fn ensure_parent_dir(path: &Path) -> Result<(), WalError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

fn ensure_wal_file(path: &Path) -> Result<(), WalError> {
    OpenOptions::new().create(true).append(true).open(path)?;
    Ok(())
}
