# Phase 1 Critical Config Keys

This list captures Phase 1 critical configuration inputs required for
`build_order_intent()` to proceed. Missing or invalid values for any key
must fail closed with an enumerated reason code (`CONFIG_MISSING`) and no
side effects (no WAL record, orders, or position deltas).

## Keys (Phase 1)
- `INSTRUMENT_TICK_SIZE` — `InstrumentQuantization.tick_size` must be > 0; missing/invalid triggers `QuantizeRejectReason::InstrumentMetadataMissing`.
- `INSTRUMENT_AMOUNT_STEP` — `InstrumentQuantization.amount_step` must be > 0; missing/invalid triggers `QuantizeRejectReason::InstrumentMetadataMissing`.
- `INSTRUMENT_MIN_AMOUNT` — `InstrumentQuantization.min_amount` must be >= 0; missing/invalid triggers `QuantizeRejectReason::InstrumentMetadataMissing`.
- `L2_BOOK_SNAPSHOT` — L2 snapshot required for LiquidityGate; missing triggers `LiquidityGateRejectReason::LiquidityGateNoL2`.
- `FEE_MODEL_CACHED_AT_TS_MS` — fee model timestamp required for staleness evaluation; missing triggers `BuildOrderIntentRejectReason::DispatchAuth(RiskState::Degraded)` for OPEN intents.
- `NET_EDGE_MIN_USD` — net edge minimum required for NetEdge gate; missing/invalid triggers `NetEdgeRejectReason::NetEdgeInputMissing`.

## Evidence
- `crates/soldier_core/tests/test_missing_config.rs` writes
  `evidence/phase1/config_fail_closed/missing_keys_matrix.json` with reason
  code `CONFIG_MISSING` per key.
