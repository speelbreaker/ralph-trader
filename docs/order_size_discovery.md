# OrderSize Discovery Report (S1-008)

## Scope
OrderSize struct, sizing invariants, and mapping to contract sizing rules. No dispatcher or policy changes.

## Out of scope (contract refs)
- Anchor-021 / VR-024 are status endpoint requirements; this discovery report makes no `/api/v1/status` changes or tests.

## Current implementation
- `crates/soldier_core/src/execution/order_size.rs`
  - `OrderSize { contracts, qty_coin, qty_usd, notional_usd }`.
  - Field types: `contracts: Option<i64>`, `qty_coin: Option<f64>`, `qty_usd: Option<f64>`, `notional_usd: f64`.
  - `OrderSize::new(...)` selects canonical unit by `InstrumentKind`:
    - `Option | LinearFuture`: requires `qty_coin` via `expect`, sets `qty_usd=None`, computes `notional_usd = qty_coin * index_price`.
    - `Perpetual | InverseFuture`: requires `qty_usd` via `expect`, sets `qty_coin=None`, sets `notional_usd = qty_usd`.
  - `contracts` is stored but not derived or validated in `OrderSize::new`.
  - No validation on `index_price` when computing `notional_usd` for coin-sized instruments.
  - Logs `OrderSizeComputed instrument_kind=... notional_usd=...` via `eprintln!`.
- `crates/soldier_core/src/execution/dispatch_map.rs`
  - `map_order_size_to_deribit_amount{,_with_metrics}` enforces sizing checks.
  - Rejects when both `qty_coin` and `qty_usd` are set (`both_qty`), when canonical amount is missing (`missing_canonical`), or when `index_price <= 0` for USD-sized instruments (`invalid_index_price`).
  - Derives `contracts` as `round(canonical_amount / contract_multiplier)` when `contract_multiplier > 0`.
  - If `contracts` is provided, validates `contracts * contract_multiplier` vs canonical amount using `UNIT_MISMATCH_EPSILON = 1e-9` (absolute epsilon). Missing multiplier rejects (`missing_multiplier_for_validation`).
  - For USD-sized instruments, derives `qty_coin = qty_usd / index_price` in the outbound mapping.
  - Reject path increments `order_intent_reject_unit_mismatch_total` and returns `DispatchReject { risk_state: RiskState::Degraded, reason: UnitMismatch }`.
- Re-exports in `crates/soldier_core/src/execution/mod.rs`.

## Call sites
- `crates/soldier_core/tests/test_order_size.rs`
  - Constructs `OrderSize::new` for option/perp and asserts `notional_usd`.
  - Exercises contract mismatch rejection via `map_order_size_to_deribit_amount`.
- `crates/soldier_core/tests/test_dispatch_map.rs`
  - Constructs `OrderSize::new` for option/linear/perp/inverse mapping tests.
  - Asserts derived contracts and unit mismatch counter increments.
- No production call sites in `crates/soldier_core/src` beyond the `dispatch_map` helper (only tests currently call it).

## Contract requirements (brief)
- `OrderSize` struct fields are required as shown in `CONTRACT.md` §1.0.
- Canonical units and notional rules:
  - `option | linear_future`: canonical = `qty_coin`; `qty_usd` must be unset; `notional_usd = qty_coin * index_price`.
  - `perpetual | inverse_future`: canonical = `qty_usd`; derive `qty_coin = qty_usd / index_price`; `notional_usd = qty_usd`.
- Never mix coin sizing and USD sizing for the same intent; one is canonical and the other is derived.
- Derive `contracts` when contract multiplier/contract_size is defined:
  - For USD-sized instruments: `contracts = round(qty_usd / contract_size_usd)`.
  - For coin-sized instruments: derive contracts from `qty_coin / contract_multiplier`.
- If `contracts` and canonical amount are both provided, they must match within tolerance:
  - `abs(amount - contracts * contract_multiplier) / max(abs(amount), epsilon) <= contracts_amount_match_tolerance`.
  - Defaults: `contracts_amount_match_tolerance = 0.001` and `epsilon = 1e-9`.
- Mismatch must reject and degrade with reason `Rejected(ContractsAmountMismatch)` (AT-920).
- AT-277 requires option/perp mapping (amount + derived qty_coin + notional) and mismatch rejection.
- `index_price` is defined in the contract as a positive market-data input (`index_price > 0`).

## Gaps vs contract
- `OrderSize::new` panics on missing canonical fields (`expect`) instead of returning a deterministic reject.
- `OrderSize::new` silently discards non-canonical inputs, so supplying both `qty_coin` and `qty_usd` is not rejected (contract forbids mixing).
- `DispatchRejectReason::UnitMismatch` does not match the contract-required `Rejected(ContractsAmountMismatch)` for sizing mismatches.
- Contract tolerance is relative (`contracts_amount_match_tolerance = 0.001` with epsilon `1e-9`); current code uses absolute epsilon only (`UNIT_MISMATCH_EPSILON = 1e-9`).
- No use of `contracts_amount_match_tolerance` in code today; current checks only use `UNIT_MISMATCH_EPSILON`.
- `index_price > 0` is required by contract market-data definitions, but `OrderSize::new` does not validate for coin-sized instruments (dispatch_map only checks USD-sized mapping).
- Current mapping logic is only exercised by tests; production dispatch path is not yet using `OrderSize` helpers.

## Proposed tests to add (canonical sizing)
- AT-277 wrapper: option/perp mapping asserts `amount`, `qty_coin` derived for USD-sized, `qty_usd` unset for options, and `notional_usd` values.
- AT-920 / AT-280 wrapper: rejects mismatches above `contracts_amount_match_tolerance = 0.001` with reason `ContractsAmountMismatch` and `RiskState::Degraded`.
- Rejects when both `qty_coin` and `qty_usd` are provided (no silent drop).
- Rejects when canonical amount is missing without panicking.
- Validates contracts match within tolerance (accepts within tolerance, rejects beyond).
- Derives `contracts` via `round(qty_usd / contract_size_usd)` for USD-sized instruments and via multiplier for coin-sized.
- Rejects when `contract_multiplier` is missing but `contracts` are provided (fail closed).
- Enforces `index_price > 0` when deriving `notional_usd` / `qty_coin` (if enforced at sizing layer).

## Minimal diff to align with contract
- Change `OrderSize::new` to return `Result<OrderSize, Reject>` (or add `try_new`) and remove `expect` panics.
- Validate exactly one canonical amount is provided; reject if both or neither are set.
- Introduce a contract-aligned reject reason (e.g., `ContractsAmountMismatch`) and use it for sizing mismatches.
- Implement the relative tolerance check using `contracts_amount_match_tolerance` (default 0.001) with epsilon 1e-9.
- Enforce `index_price > 0` when computing derived values (or document/centralize the guard if it belongs in preflight).
- Ensure derived contracts use contract size/multiplier from instrument metadata and are applied consistently for both USD- and coin-sized instruments.
- Defer wiring OrderSize into build_order_intent until sizing invariants are enforced; current call sites remain tests only.

## Open questions
- Should `contracts_amount_match_tolerance` be config-driven (vs hard-coded 0.001 per contract) before wiring OrderSize into production?
