# Dispatcher Mapping Discovery Report (S1-009)

## Scope
Dispatch mapping for outbound Deribit order sizing (canonical amount selection, contract validation, and derived fields). No dispatcher wiring changes or status endpoint work.

## Out of scope (contract refs)
- Anchor-021 / VR-024 are `/api/v1/status` requirements (see `docs/architecture/contract_anchors.md` + `docs/architecture/validation_rules.md`). This discovery report makes no status endpoint changes or tests.

## Current implementation
- `crates/soldier_core/src/execution/dispatch_map.rs`
  - `map_order_size_to_deribit_amount{,_with_metrics}` accepts `InstrumentKind`, `OrderSize`, `contract_multiplier`, and `index_price` and returns `DeribitOrderAmount { amount, contracts, derived_qty_coin }`.
  - Rejects when both `qty_coin` and `qty_usd` are set (`both_qty`), when canonical amount is missing (`missing_canonical`), or when `index_price <= 0` for USD-sized instruments (`invalid_index_price`).
  - Canonical amount selection:
    - `Option | LinearFuture` -> `amount = order_size.qty_coin` and `derived_qty_coin = qty_coin`.
    - `Perpetual | InverseFuture` -> `amount = order_size.qty_usd` and `derived_qty_coin = qty_usd / index_price`.
  - Derives `contracts = round(amount / contract_multiplier)` when `contract_multiplier > 0`.
  - If `order_size.contracts` is provided, validates `contracts * contract_multiplier` against canonical amount using absolute epsilon `UNIT_MISMATCH_EPSILON = 1e-9`.
  - Missing `contract_multiplier` while validating contracts rejects (`missing_multiplier_for_validation`).
  - Reject path increments `order_intent_reject_unit_mismatch_total` and returns `DispatchReject { risk_state: RiskState::Degraded, reason: UnitMismatch }`.
- `crates/soldier_core/src/execution/mod.rs` re-exports dispatch mapping types/functions.

## Call sites
- `crates/soldier_core/tests/test_dispatch_map.rs` exercises option/perp mapping, derived contracts, mismatch rejection, and metrics increment.
- `crates/soldier_core/tests/test_order_size.rs` exercises mismatch rejection via dispatch mapping.
- No production dispatch code calls `map_order_size_to_deribit_amount` yet; usage is test-only.

## Contract requirements (brief)
- From `CONTRACT.md` "Dispatcher Rules (Deribit request mapping)":
  - Determine `instrument_kind` from instrument metadata (`option | linear_future | inverse_future | perpetual`), with linear perpetuals treated as `linear_future`.
  - Canonical amount selection:
    - `option | linear_future`: canonical = `qty_coin`; derive `contracts` if contract multiplier defined.
    - `perpetual | inverse_future`: canonical = `qty_usd`; derive `contracts = round(qty_usd / contract_size_usd)` and `qty_coin = qty_usd / index_price`.
  - Outbound Deribit request must send exactly one canonical "amount" value (coin instruments use `qty_coin`, USD-sized instruments use `qty_usd`).
  - If `contracts` exists, it must be consistent with the canonical amount before dispatch (reject if not).
- AT-277: option/perp mapping and mismatch rejection expectations.
- AT-920: `contracts`/`amount` mismatches reject with `Rejected(ContractsAmountMismatch)` and no dispatch; `RiskState==Degraded`.

## Gaps vs contract
- USD-sized contract derivation uses a single `contract_multiplier` input today; the contract requires `contract_size_usd` for USD-sized instruments, which is not represented explicitly.
- Mismatch validation uses absolute epsilon `1e-9` only; contract specifies relative tolerance with `contracts_amount_match_tolerance = 0.001` (plus epsilon).
- Rejection reason is `DispatchRejectReason::UnitMismatch`; contract requires `Rejected(ContractsAmountMismatch)` for sizing mismatches.
- Mapping helper returns canonical `amount` but there is no production dispatch wiring yet that guarantees only the canonical amount is sent.

## Proposed tests to add (canonical amount selection)
- AT-277 wrapper: verify option uses `amount=qty_coin`, USD-sized uses `amount=qty_usd`, and USD-sized derives `qty_coin = qty_usd / index_price`.
- AT-920 wrapper: mismatched `contracts` vs canonical amount rejects with `ContractsAmountMismatch` and `RiskState::Degraded` (no dispatch).
- Rejects when both `qty_coin` and `qty_usd` are provided (fail closed).
- Rejects when canonical amount is missing (no panic).
- Validates contracts within tolerance (accept within tolerance, reject beyond `contracts_amount_match_tolerance`).

## Minimal diff to align with contract
- Replace absolute epsilon check with contract-aligned tolerance (`contracts_amount_match_tolerance = 0.001` with epsilon `1e-9`).
- Introduce a contract-specific reject reason for sizing mismatch (`ContractsAmountMismatch`) and use it in dispatch mapping.
- Accept contract size inputs that distinguish coin-sized multiplier vs USD `contract_size_usd`, and apply the correct one by `instrument_kind`.
- Ensure production dispatch path uses this mapping helper so only the canonical amount is emitted on outbound Deribit requests.

## Open questions
- Should `contracts_amount_match_tolerance` be configurable in runtime config or hard-coded to the contract default before wiring mapping into production dispatch?
