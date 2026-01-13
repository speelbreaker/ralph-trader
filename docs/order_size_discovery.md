# OrderSize Discovery (S1-008)

## Current implementation
- Location: `crates/soldier_core/src/execution/order_size.rs`
- Struct fields:
  - `contracts: Option<i64>`
  - `qty_coin: Option<f64>`
  - `qty_usd: Option<f64>`
  - `notional_usd: f64`
- Constructor: `OrderSize::new(instrument_kind, contracts, qty_coin, qty_usd, index_price)`
  - `Option | LinearFuture`: requires `qty_coin` (panics if missing), sets `notional_usd = qty_coin * index_price`, clears `qty_usd`.
  - `Perpetual | InverseFuture`: requires `qty_usd` (panics if missing), sets `notional_usd = qty_usd`, clears `qty_coin`.
  - Emits `eprintln!` with `instrument_kind` and `notional_usd`.

## Call sites / usage
- Exported from `crates/soldier_core/src/execution/mod.rs`.
- Used directly in tests only:
  - `crates/soldier_core/tests/test_order_size.rs`
  - `crates/soldier_core/tests/test_dispatch_map.rs`
- Dispatcher mapping uses `OrderSize` in `crates/soldier_core/src/execution/dispatch_map.rs`:
  - Rejects if both `qty_coin` and `qty_usd` are set.
  - For USD-sized instruments, derives `derived_qty_coin = qty_usd / index_price` in the outbound amount mapping.

## Gaps vs contract
- Contract requires derived `qty_coin = qty_usd / index_price` for USD-sized instruments; `OrderSize::new` currently leaves `qty_coin` as `None`.
- Contract says never mix coin and USD sizing for the same intent; `OrderSize::new` does not reject when both are supplied (it silently ignores the non-canonical field).
- Constructor panics on missing canonical fields (`expect`), but the contract implies a fail-closed rejection rather than a panic.
- No explicit guard for `index_price <= 0.0` when computing `notional_usd` for coin-sized instruments.

## Required tests to add (canonical sizing)
- USD-sized instruments populate `qty_coin` as `qty_usd / index_price` (and remain consistent with `notional_usd`).
- Reject (error result) when both `qty_coin` and `qty_usd` are provided for a single intent.
- Reject (error result) when the canonical field is missing instead of panicking.
- Reject when `index_price <= 0.0` for any path that needs it (coin-sized notional or derived qty).

## Minimal implementation diff to align with contract
- Change `OrderSize::new` to return `Result<OrderSize, OrderSizeError>` instead of panicking.
- Enforce the "never mix units" rule by rejecting if both `qty_coin` and `qty_usd` are set.
- For `Perpetual | InverseFuture`, set `qty_coin = Some(qty_usd / index_price)` with an `index_price > 0.0` guard.
- Add an `index_price > 0.0` guard for coin-sized `notional_usd` computation (fail-closed on invalid).
