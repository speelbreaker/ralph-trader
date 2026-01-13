# OrderSize Discovery Report (S1-008)

## Scope
OrderSize struct, sizing invariants, and mapping to contract sizing rules. No dispatcher or policy changes.

## Current implementation
- `crates/soldier_core/src/execution/order_size.rs`
  - `OrderSize { contracts, qty_coin, qty_usd, notional_usd }`.
  - Field types: `contracts: Option<i64>`, `qty_coin: Option<f64>`, `qty_usd: Option<f64>`, `notional_usd: f64`.
  - `OrderSize::new(...)` chooses canonical unit by `InstrumentKind`:
    - Option/LinearFuture: requires `qty_coin`, sets `qty_usd=None`, computes `notional_usd = qty_coin * index_price`.
    - Perpetual/InverseFuture: requires `qty_usd`, sets `qty_coin=None`, computes `notional_usd = qty_usd`.
  - Logs `OrderSizeComputed instrument_kind=... notional_usd=...` via `eprintln!`.
  - `contracts` is stored but not validated or derived in `OrderSize::new`.
- `crates/soldier_core/src/execution/dispatch_map.rs`
  - Consumes `OrderSize` to map to `DeribitOrderAmount`.
  - Rejects when `OrderSize` has both `qty_coin` and `qty_usd` set (reason `both_qty`).
  - Rejects unit mismatches and sets `RiskState::Degraded` (increments `order_intent_reject_unit_mismatch_total`).
  - `DispatchRejectReason` currently only includes `UnitMismatch` and is always paired with `RiskState::Degraded`.
  - Uses `UNIT_MISMATCH_EPSILON = 1e-9` when comparing contracts * multiplier to canonical amount.
  - For USD-sized instruments, derives `qty_coin = qty_usd / index_price` in the outbound mapping.
  - Rejects non-positive `index_price` for USD-sized instruments.
  - Treats missing canonical amount or missing contract multiplier as a unit mismatch and logs the reason string.

## Call sites
- `crates/soldier_core/tests/test_order_size.rs`
  - Constructs `OrderSize::new` for option/perp and asserts `notional_usd`.
  - Exercises contract mismatch rejection via `map_order_size_to_deribit_amount`.
- `crates/soldier_core/tests/test_dispatch_map.rs`
  - Constructs `OrderSize::new` for option/linear/perp/inverse mapping tests.
  - Asserts `order_intent_reject_unit_mismatch_total()` increments on mismatch.
- No production call sites in `crates/soldier_core/src` beyond the `dispatch_map` helper.
- `crates/soldier_core/src/execution/mod.rs` re-exports `OrderSize` (no additional usage).

## Contract requirements (brief)
- `OrderSize` struct fields: `contracts`, `qty_coin`, `qty_usd`, `notional_usd`.
- Canonical units:
  - `option | linear_future` -> `qty_coin` canonical; `notional_usd = qty_coin * index_price`.
  - `perpetual | inverse_future` -> `qty_usd` canonical; `notional_usd = qty_usd`.
- If both `contracts` and canonical amount are provided and mismatch -> reject intent and set `RiskState::Degraded`.
- Dispatcher rules require deriving `contracts` from canonical amount when contract size/multiplier is defined.
- Dispatcher rules derive `qty_coin = qty_usd / index_price` for USD-sized instruments.

## Gaps vs contract
- `OrderSize::new` uses `expect(...)` for missing canonical fields (panic) instead of a reject path with `RiskState::Degraded`.
- `OrderSize::new` drops non-canonical inputs (including passing both `qty_coin` and `qty_usd`) instead of rejecting the intent; only `dispatch_map` rejects when both fields are set on the `OrderSize`.
- `contracts` is passed through but not derived from canonical amounts; no rounding or contract_size_usd handling.
- Contracts mismatch validation only occurs in `dispatch_map` when a multiplier is supplied; `OrderSize::new` does not enforce contract matching.
- Mismatch tolerance is implicit: `dispatch_map` uses `UNIT_MISMATCH_EPSILON = 1e-9`, but the contract only says "within tolerance" (needs a defined threshold).
- No validation for non-positive `index_price` when computing `notional_usd` for coin-sized instruments.
- `OrderSize` is not wired into a production dispatch path yet (tests only).

## Proposed tests to add
- Rejects when both `qty_coin` and `qty_usd` are provided.
- Rejects when a non-canonical field is provided for the instrument kind.
- Returns a deterministic reject (no panic) when the canonical amount is missing for the instrument kind.
- Derives `contracts` from canonical amount when multiplier/contract size is available.
- Rejects when `contracts` is provided but multiplier/contract size is missing.
- Handles invalid `index_price` for coin-sized instruments (if required by contract).

## Minimal diff to align with contract
- Change `OrderSize::new` to return a `Result` with a deterministic error instead of panicking.
- Validate exactly one canonical amount is provided and matches `InstrumentKind`.
- Add optional multiplier/contract size inputs to derive `contracts` consistently.
- Decide whether to enforce contract mismatch inside `OrderSize` or keep it in `dispatch_map`, but ensure it is always applied.
- Define a shared mismatch tolerance (or rounding rule) aligned with the contract's "within tolerance" requirement.
- Wire creation into the execution path once build_order_intent exists (future story).
