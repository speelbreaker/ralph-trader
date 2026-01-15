# Validation Rules (Canonical IDs)

Purpose
- Provide stable, machine-matchable IDs for enforceable rules.
- Keep IDs stable; append new rules, do not renumber.

Format
- Rule IDs are referenced in PRD contract_refs as `VR-XYZ` (and optional suffix letters).
- Each rule points to a specific contract section.

## VR-001: Verification Harness Runs Workspace Tests
**Contract ref:** CONTRACT.md §0.Y Verification Harness (Non-Negotiable)  
**Rule:** plans/verify.sh runs `cargo test --workspace`.

## VR-010: Instrument Units & Notional Invariants Enforced
**Contract ref:** CONTRACT.md §1.0 Instrument Units & Notional Invariants  
**Rule:** Canonical sizing rules are enforced and mismatches reject.

## VR-011: Instrument Metadata TTL Fail-Closed
**Contract ref:** CONTRACT.md §1.0.X Instrument Metadata Freshness  
**Rule:** Stale instrument metadata forces degrade/reduce-only behavior.

## VR-020: Quantization Before Hash/Dispatch
**Contract ref:** CONTRACT.md §1.1.1 Canonical Quantization  
**Rule:** Quantization occurs before intent hashing and dispatch.

## VR-021: Compact Label Schema ≤64
**Contract ref:** CONTRACT.md §1.1 Labeling & Idempotency Contract  
**Rule:** Order labels follow the compact schema and enforce length limits.

## VR-022: Label Disambiguation is Collision-Safe
**Contract ref:** CONTRACT.md §1.1.2 Label Parse + Disambiguation  
**Rule:** Tie-breaker ordering is deterministic; ambiguity degrades.

## VR-030: Order-Type Preflight Rejects Illegal Orders
**Contract ref:** CONTRACT.md §1.4.4 Deribit Order-Type Preflight Guard  
**Rule:** Market/stop/linked orders are rejected per contract rules.

## VR-040: RecordedBeforeDispatch Required
**Contract ref:** CONTRACT.md §2.4 Durable Intent Ledger (WAL Truth Source)  
**Rule:** Intent record exists before any dispatch.

## VR-041: Replay Does Not Resend
**Contract ref:** CONTRACT.md §2.4 Durable Intent Ledger (WAL Truth Source)  
**Rule:** Replay reconstructs state without duplicate sends.

## VR-042: Trade-ID Registry Prevents Duplicate Applies
**Contract ref:** CONTRACT.md §2.4 Trade-ID Idempotency Registry  
**Rule:** Duplicate trade IDs are ignored deterministically.
