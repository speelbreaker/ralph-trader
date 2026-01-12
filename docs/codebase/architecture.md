# Codebase Map: Architecture

## High-level overview
- Rust workspace with core domain logic in `soldier_core` and exchange-facing types in `soldier_infra`.
- Planning and verification harness lives in `plans/`.

## Core components
- `soldier_core::execution` - order sizing and dispatch amount mapping.
- `soldier_core::venue` - instrument kind derivation and instrument cache.
- `soldier_core::risk` - risk state and policy guard.
- `soldier_infra::deribit::public` - Deribit instrument types.

## Data flow
- `DeribitInstrument` -> `InstrumentKind` derivation.
- `InstrumentCache::get` returns metadata + `RiskState` based on TTL.
- `OrderSize` + `InstrumentKind` -> Deribit order amount mapping.

## Boundaries and responsibilities
- `soldier_core` owns domain behavior and safety decisions.
- `soldier_infra` owns exchange-specific types and adapters.

## Critical paths
- Order size canonicalization and dispatch amount mapping.
- Instrument cache TTL affecting `RiskState::Degraded`.

## Known invariants
- Unit mismatch rejects map to `RiskState::Degraded`.
- Stale instrument cache reads mark `RiskState::Degraded`.

## Notes
- TBD
