# Contract Coverage Matrix

Generated: 2026-01-17 12:30:17Z

## Anchors

- ✅ **Anchor-001** — Repository Layout & Module Mapping (Contract §0.X) → S1-001
- ✅ **Anchor-002** — Verification Harness (Contract §0.Y) → S1-000
- ✅ **Anchor-010** — Instrument Units & Notional Invariants (Contract §1.0) → S1-002, S1-005, S1-007, S1-009
- ✅ **Anchor-011** — Instrument Metadata Freshness (Instrument Cache TTL) (Contract §1.0.X) → S1-003, S1-006
- ✅ **Anchor-012** — OrderSize Struct & Canonical Units (Contract §1.0) → S1-004, S1-008
- ✅ **Anchor-020** — Labeling & Idempotency Contract (Contract §1.1) → S2-001, S2-002
- ✅ **Anchor-021** — Canonical Quantization (Pre-Hash & Pre-Dispatch) (Contract §1.1.1) → S2-000
- ✅ **Anchor-022** — Label Parse + Disambiguation (Collision-Safe) (Contract §1.1.2) → S2-003
- ✅ **Anchor-030** — Order-Type Preflight Guard (Contract §1.4.4) → S3-000, S3-001
- ✅ **Anchor-031** — Linked Orders Gate (Contract §1.4.4) → S3-002
- ✅ **Anchor-040** — Trade Lifecycle State Machine (TLSM) (Contract §2.1) → S4-001
- ✅ **Anchor-041** — Durable Intent Ledger (WAL Truth Source) (Contract §2.4) → S4-000
- ✅ **Anchor-042** — RecordedBeforeDispatch (Contract §2.4) → S4-000, S4-003
- ✅ **Anchor-043** — Trade-ID Idempotency Registry (Ghost-Race Hardening) (Contract §2.4) → S4-002

## Validation Rules

- ✅ **VR-001** — Verification Harness Runs Workspace Tests → S1-000
- ✅ **VR-010** — Instrument Units & Notional Invariants Enforced → S1-002, S1-004, S1-005, S1-007
- ✅ **VR-011** — Instrument Metadata TTL Fail-Closed → S1-003, S1-006
- ✅ **VR-020** — Quantization Before Hash/Dispatch → S2-000, S2-001
- ✅ **VR-021** — Compact Label Schema ≤64 → S2-002
- ✅ **VR-022** — Label Disambiguation is Collision-Safe → S2-003
- ✅ **VR-030** — Order-Type Preflight Rejects Illegal Orders → S3-000, S3-001, S3-002
- ✅ **VR-040** — RecordedBeforeDispatch Required → S4-000, S4-003
- ✅ **VR-041** — Replay Does Not Resend → S4-000
- ✅ **VR-042** — Trade-ID Registry Prevents Duplicate Applies → S4-002
