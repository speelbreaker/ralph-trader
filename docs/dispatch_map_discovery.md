# Dispatch Map Discovery Report (S1-009)

## Scope
Dispatcher amount mapping for Deribit requests (canonical amount selection + mismatch rejection). No changes outside the dispatch mapping helper.

## Current implementation
- `crates/soldier_core/src/execution/dispatch_map.rs`
  - `map_order_size_to_deribit_amount(instrument_kind, order_size, contract_multiplier, index_price)` returns `DeribitOrderAmount { amount, derived_qty_coin }` or `DispatchReject`.
  - Rejects with `RiskState::Degraded` when both `qty_coin` and `qty_usd` are set on `OrderSize`.
  - Canonical amount selection:
    - `InstrumentKind::Option | LinearFuture` uses `order_size.qty_coin`.
    - `InstrumentKind::Perpetual | InverseFuture` uses `order_size.qty_usd` and derives `derived_qty_coin = qty_usd / index_price` (rejects `index_price <= 0`).
  - Rejects if canonical amount is missing (`missing_canonical`).
  - If `order_size.contracts` is present, checks `contracts * contract_multiplier` against the canonical amount using `UNIT_MISMATCH_EPSILON = 1e-9` and rejects on mismatch.
  - Missing `contract_multiplier` with `contracts` present is treated as a unit mismatch.
  - Rejections increment a local `order_intent_reject_unit_mismatch_total` counter and log via `eprintln!`.
- `crates/soldier_core/src/execution/mod.rs` re-exports `map_order_size_to_deribit_amount` and related types.

## Call sites
- `crates/soldier_core/tests/test_dispatch_map.rs` exercises mapping for option/linear/perp/inverse and mismatch rejection.
- `crates/soldier_core/tests/test_order_size.rs` uses the mapping for a mismatch rejection check.
- No production call sites in `crates/soldier_core/src` yet (mapping helper only).

## Contract requirements (brief)
- Canonical amount selection for outbound Deribit `amount`:
  - Option/linear_future -> `amount = qty_coin`.
  - Perpetual/inverse_future -> `amount = qty_usd`.
- For USD-sized instruments, derive `qty_coin = qty_usd / index_price`.
- If `contracts` exists, it must be consistent with the canonical amount before dispatch (mismatch -> reject + Degraded).
- Derive `contracts` from canonical amount when contract size/multiplier is defined (rounding rule specified in contract).

## Gaps vs contract
- Dispatcher mapping is not wired into a production dispatch path yet (helper used only by tests).
- No derivation of `contracts` when `contract_multiplier`/contract size is known; only validates if `contracts` is already provided.
- No rounding rule for derived `contracts` is implemented; only a strict epsilon comparison when `contracts` is present.
- Mismatch tolerance is hard-coded to `1e-9`; contract calls for a defined tolerance/rounding rule.
- `OrderSize` for USD-sized instruments does not persist the derived `qty_coin` (only returned in `DeribitOrderAmount`).

## Proposed tests to add (canonical amount selection)
- `test_dispatch_map_rejects_both_qty_fields`: rejects when both `qty_coin` and `qty_usd` are set on `OrderSize`.
- `test_dispatch_map_rejects_missing_canonical_amount`: rejects when the canonical amount is missing for the instrument kind.
- `test_dispatch_map_rejects_invalid_index_price`: rejects when `index_price <= 0` for USD-sized instruments.
- `test_dispatch_map_rejects_missing_multiplier`: rejects when `contracts` is present but `contract_multiplier` is missing.
- `test_dispatch_map_accepts_contracts_match_with_tolerance`: accepts when `contracts * contract_multiplier` matches the canonical amount within the defined tolerance.
- `test_dispatch_map_sets_derived_qty_coin_for_usd`: asserts `derived_qty_coin` is set for USD-sized instruments and matches `qty_usd / index_price`.

## Minimal diff to align with contract
- Wire `map_order_size_to_deribit_amount` into the real Deribit request build path so exactly one `amount` field is sent.
- Add contract-size/multiplier-aware `contracts` derivation (with rounding) when a multiplier is available.
- Replace the hard-coded epsilon with a shared tolerance/rounding rule aligned to the contract.
- Decide whether derived `qty_coin` should live in `OrderSize` or remain only in the outbound mapping, but make it consistently available to downstream callers.
