# OrderSize Discovery Report (S1-008)

## 1. Current Implementation Overview

### Struct Definition
Location: `crates/soldier_core/src/execution/order_size.rs`
```rust
pub struct OrderSize {
    pub contracts: Option<i64>,
    pub qty_coin: Option<f64>,
    pub qty_usd: Option<f64>,
    pub notional_usd: f64,
}
```

### Construction Logic
Currently uses a `new()` function that enforces field presence via `expect()`:
- `InstrumentKind::Option | InstrumentKind::LinearFuture` -> Requires `qty_coin`.
- `InstrumentKind::Perpetual | InstrumentKind::InverseFuture` -> Requires `qty_usd`.

## 2. Gaps vs. Contract (§1.0)

| Gap | Description | Risk |
|---|---|---|
| **Safety** | Uses `.expect()`, causing panics on invalid input. | **CRITICAL** (Violates "Panic-Free" foundation) |
| **Derivation** | `contracts` is passed as an optional input but never derived from `qty` if missing. | **MINOR** (Friction in strategy implementation) |
| **Derivation** | `qty_coin` is not derived for USD-sized instruments in the constructor. | **MEDIUM** (Inconsistency between `qty_usd` and `qty_coin`) |
| **Interface** | Returns `Self` instead of `Result`. | **MEDIUM** (Prevents graceful error handling in hot loop) |

## 3. Call Sites
- `crates/soldier_core/src/execution/order_size.rs`: Definition and implementation.
- `crates/soldier_core/src/execution/dispatch_map.rs`: Consumes `OrderSize` for Deribit mapping.
- `crates/soldier_core/tests/test_order_size.rs`: Happy path and mismatch tests.
- `crates/soldier_core/tests/test_dispatch_map.rs`: Indirect usage through tests.

## 4. Required Test Gaps
- **Unhappy Path:** No test exists for missing mandatory `qty` fields (currently causes panic).
- **Consistency:** No test verifying that `contracts` matches `canonical_qty` within the constructor itself.

## 5. Minimal Implementation Diff (Proposed)
1. Rename `new` to `try_new`.
2. Return `Result<Self, Error>`.
3. Implement derivation logic:
   - For `qty_usd` instruments: `qty_coin = qty_usd / index_price`.
   - For `qty_coin` instruments: `qty_usd = qty_coin * index_price`.
4. Validate `contracts` if provided vs. `canonical_qty`.
5. Remove all `expect()` calls.
