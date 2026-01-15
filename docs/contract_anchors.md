# Contract Anchors (Canonical IDs)

Purpose
- Provide stable, human-readable IDs for contract sections.
- Keep IDs stable; append new anchors, do not renumber.

Format
- Anchor IDs are referenced in PRD contract_refs as `Anchor-XYZ`.
- Titles should match the corresponding CONTRACT.md section.

## Anchor-001: Repository Layout & Module Mapping (Contract §0.X)
## Anchor-002: Verification Harness (Contract §0.Y)

## Anchor-010: Instrument Units & Notional Invariants (Contract §1.0)
## Anchor-011: Instrument Metadata Freshness (Instrument Cache TTL) (Contract §1.0.X)
## Anchor-012: OrderSize Struct & Canonical Units (Contract §1.0)

## Anchor-020: Labeling & Idempotency Contract (Contract §1.1)
## Anchor-021: Canonical Quantization (Pre-Hash & Pre-Dispatch) (Contract §1.1.1)
## Anchor-022: Label Parse + Disambiguation (Collision-Safe) (Contract §1.1.2)

## Anchor-030: Order-Type Preflight Guard (Contract §1.4.4)
## Anchor-031: Linked Orders Gate (Contract §1.4.4)

## Anchor-040: Trade Lifecycle State Machine (TLSM) (Contract §2.1)
## Anchor-041: Durable Intent Ledger (WAL Truth Source) (Contract §2.4)
## Anchor-042: RecordedBeforeDispatch (Contract §2.4)
## Anchor-043: Trade-ID Idempotency Registry (Ghost-Race Hardening) (Contract §2.4)
