//! Durable trade-id registry for idempotent fill handling.
//!
//! Contract: trade_id must be appended to durable storage before any TLSM/position updates.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Clone, PartialEq)]
pub struct TradeIdRecord {
    pub trade_id: String,
    pub group_id: String,
    pub leg_idx: u32,
    pub ts: u64,
    pub qty: f64,
    pub price: f64,
}

impl TradeIdRecord {
    pub fn validate(&self) -> Result<(), TradeIdRegistryError> {
        if self.trade_id.trim().is_empty() {
            return Err(TradeIdRegistryError::RecordSchema(
                "trade_id must be non-empty".to_string(),
            ));
        }
        if self.group_id.trim().is_empty() {
            return Err(TradeIdRegistryError::RecordSchema(
                "group_id must be non-empty".to_string(),
            ));
        }
        if self.ts == 0 {
            return Err(TradeIdRegistryError::RecordSchema(
                "ts must be non-zero".to_string(),
            ));
        }
        if !self.qty.is_finite() {
            return Err(TradeIdRegistryError::RecordSchema(
                "qty must be finite".to_string(),
            ));
        }
        if !self.price.is_finite() {
            return Err(TradeIdRegistryError::RecordSchema(
                "price must be finite".to_string(),
            ));
        }
        Ok(())
    }

    fn to_line(&self) -> String {
        format!(
            "trade_id={}|group_id={}|leg_idx={}|ts={}|qty={}|price={}",
            escape_field(&self.trade_id),
            escape_field(&self.group_id),
            self.leg_idx,
            self.ts,
            self.qty,
            self.price,
        )
    }

    fn from_line(line: &str) -> Result<Self, TradeIdRegistryError> {
        let mut fields: HashMap<&str, &str> = HashMap::new();
        for part in line.split('|') {
            if part.trim().is_empty() {
                continue;
            }
            let mut iter = part.splitn(2, '=');
            let key = iter
                .next()
                .ok_or_else(|| TradeIdRegistryError::Parse("missing key".to_string()))?;
            let value = iter
                .next()
                .ok_or_else(|| TradeIdRegistryError::Parse("missing value".to_string()))?;
            fields.insert(key, value);
        }

        let record = TradeIdRecord {
            trade_id: unescape_required(fields.get("trade_id"), "trade_id")?,
            group_id: unescape_required(fields.get("group_id"), "group_id")?,
            leg_idx: parse_required_u32(fields.get("leg_idx"), "leg_idx")?,
            ts: parse_required_u64(fields.get("ts"), "ts")?,
            qty: parse_required_f64(fields.get("qty"), "qty")?,
            price: parse_required_f64(fields.get("price"), "price")?,
        };
        record.validate()?;
        Ok(record)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TradeIdInsertOutcome {
    Inserted,
    Duplicate,
}

#[derive(Debug)]
pub enum TradeIdRegistryError {
    Io(std::io::Error),
    Parse(String),
    RecordSchema(String),
    State(String),
}

impl From<std::io::Error> for TradeIdRegistryError {
    fn from(err: std::io::Error) -> Self {
        TradeIdRegistryError::Io(err)
    }
}

struct RegistryState {
    file: File,
    records: HashMap<String, TradeIdRecord>,
}

pub struct TradeIdRegistry {
    path: PathBuf,
    state: Mutex<RegistryState>,
    trade_id_duplicates: AtomicU64,
}

impl TradeIdRegistry {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, TradeIdRegistryError> {
        let path = path.as_ref().to_path_buf();
        ensure_parent_dir(&path)?;
        ensure_registry_file(&path)?;

        let records = load_records(&path)?;
        let file = OpenOptions::new().create(true).append(true).open(&path)?;

        Ok(Self {
            path,
            state: Mutex::new(RegistryState { file, records }),
            trade_id_duplicates: AtomicU64::new(0),
        })
    }

    pub fn trade_id_duplicates_total(&self) -> u64 {
        self.trade_id_duplicates.load(Ordering::Relaxed)
    }

    pub fn contains(&self, trade_id: &str) -> Result<bool, TradeIdRegistryError> {
        let state = self
            .state
            .lock()
            .map_err(|_| TradeIdRegistryError::State("registry lock poisoned".to_string()))?;
        Ok(state.records.contains_key(trade_id))
    }

    pub fn record_for(
        &self,
        trade_id: &str,
    ) -> Result<Option<TradeIdRecord>, TradeIdRegistryError> {
        let state = self
            .state
            .lock()
            .map_err(|_| TradeIdRegistryError::State("registry lock poisoned".to_string()))?;
        Ok(state.records.get(trade_id).cloned())
    }

    /// Append trade_id to durable storage before applying any updates.
    pub fn record_trade(
        &self,
        record: TradeIdRecord,
    ) -> Result<TradeIdInsertOutcome, TradeIdRegistryError> {
        record.validate()?;

        let mut state = self
            .state
            .lock()
            .map_err(|_| TradeIdRegistryError::State("registry lock poisoned".to_string()))?;

        if state.records.contains_key(&record.trade_id) {
            self.trade_id_duplicates.fetch_add(1, Ordering::Relaxed);
            return Ok(TradeIdInsertOutcome::Duplicate);
        }

        write_record(&mut state.file, &record)?;
        state.records.insert(record.trade_id.clone(), record);
        Ok(TradeIdInsertOutcome::Inserted)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

fn load_records(path: &Path) -> Result<HashMap<String, TradeIdRecord>, TradeIdRegistryError> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let mut records = HashMap::new();
    for (idx, line) in reader.lines().enumerate() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let record = TradeIdRecord::from_line(&line)
            .map_err(|err| TradeIdRegistryError::Parse(format!("line {}: {:?}", idx + 1, err)))?;
        records.insert(record.trade_id.clone(), record);
    }
    Ok(records)
}

fn write_record(file: &mut File, record: &TradeIdRecord) -> Result<(), TradeIdRegistryError> {
    let line = record.to_line();
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.flush()?;
    file.sync_data()?;
    Ok(())
}

fn ensure_parent_dir(path: &Path) -> Result<(), TradeIdRegistryError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

fn ensure_registry_file(path: &Path) -> Result<(), TradeIdRegistryError> {
    OpenOptions::new().create(true).append(true).open(path)?;
    Ok(())
}

fn required_field<'a>(
    value: Option<&'a &str>,
    name: &str,
) -> Result<&'a str, TradeIdRegistryError> {
    value
        .copied()
        .ok_or_else(|| TradeIdRegistryError::Parse(format!("missing field: {name}")))
}

fn unescape_required(value: Option<&&str>, name: &str) -> Result<String, TradeIdRegistryError> {
    let raw = required_field(value, name)?;
    unescape_field(raw)
}

fn parse_required_u64(value: Option<&&str>, name: &str) -> Result<u64, TradeIdRegistryError> {
    required_field(value, name)?
        .parse()
        .map_err(|_| TradeIdRegistryError::Parse(format!("invalid {name}")))
}

fn parse_required_u32(value: Option<&&str>, name: &str) -> Result<u32, TradeIdRegistryError> {
    required_field(value, name)?
        .parse()
        .map_err(|_| TradeIdRegistryError::Parse(format!("invalid {name}")))
}

fn parse_required_f64(value: Option<&&str>, name: &str) -> Result<f64, TradeIdRegistryError> {
    required_field(value, name)?
        .parse()
        .map_err(|_| TradeIdRegistryError::Parse(format!("invalid {name}")))
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

fn unescape_field(value: &str) -> Result<String, TradeIdRegistryError> {
    let mut out = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut idx = 0;
    while idx < bytes.len() {
        if bytes[idx] == b'%' {
            if idx + 2 >= bytes.len() {
                return Err(TradeIdRegistryError::Parse("invalid escape".to_string()));
            }
            let code = &value[idx + 1..idx + 3];
            let ch = match code {
                "25" => '%',
                "7C" => '|',
                "3D" => '=',
                "0A" => '\n',
                "0D" => '\r',
                other => {
                    return Err(TradeIdRegistryError::Parse(format!(
                        "invalid escape: %{other}"
                    )));
                }
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
