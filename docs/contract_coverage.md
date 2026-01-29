# Contract Coverage Matrix

Generated: 2026-01-29 01:53:13Z

## Anchors

- ✅ **Anchor-001** — PolicyGuard Mode Precedence → S1-010, S2-003
- ✅ **Anchor-002** — Runtime F1 Certification Gate → S1-010
- ✅ **Anchor-003** — EvidenceGuard Blocks Opens on Evidence Chain Failure → S1-010
- ✅ **Anchor-004** — TruthCapsule Timing (RecordedBeforeDispatch) → S4-000
- ✅ **Anchor-005** — Decision Snapshots Required for Replay → S4-000
- ✅ **Anchor-006** — WAL Durability (Record Before Dispatch) → S4-000, S4-003
- ✅ **Anchor-007** — Trade-ID Registry Deduplication → S4-002
- ✅ **Anchor-008** — Disk Watermark Actions → S1-010
- ✅ **Anchor-009** — AGGRESSIVE Patches Require Human Approval → S1-010
- ✅ **Anchor-010** — Bunker Mode on Network Jitter → S1-010
- ✅ **Anchor-011** — TLSM Never Panics on Out-of-Order Events → S4-001
- ✅ **Anchor-012** — Canary Rollout Abort Triggers Rollback → S1-010
- ✅ **Anchor-013** — No Market Orders Policy → S3-000
- ✅ **Anchor-014** — Emergency Close Has Hedge Fallback → S3-000
- ✅ **Anchor-015** — Watchdog Triggers ReduceOnly via POST Endpoint → S1-010
- ✅ **Anchor-016** — Exchange Health Monitor Blocks Opens Before Maintenance → S1-010
- ✅ **Anchor-017** — Atomic Churn Circuit Breaker Prevents Fee Death-Spiral → S2-001
- ✅ **Anchor-018** — Pending Exposure Reservation Prevents Double-Spend → S5-002
- ✅ **Anchor-019** — WS Continuity Breaks Trigger Degraded + Snapshot Rebuild → S2-003
- ✅ **Anchor-020** — Rate Limit Session Kill Triggers Immediate Kill Mode → S1-010
- ✅ **Anchor-021** — Status Endpoint Required Fields → S0-004, S1-008, S1-009
- ✅ **Anchor-022** — Cortex WS Gap Blocks Risk-Increasing Actions → S1-010
- ✅ **Anchor-023** — Order-Type Preflight Guards (Artifact-Backed) → S3-000, S3-002

## Validation Rules

- ✅ **VR-001** — F1 Certification Gate → S1-010
- ✅ **VR-002** — EvidenceGuard Gate → S1-010
- ✅ **VR-003** — Policy Staleness Gate → S1-010
- ✅ **VR-004a** — Watchdog Heartbeat Kill Gate → S1-010
- ✅ **VR-004b** — Watchdog Silence ReduceOnly Trigger → S1-010
- ✅ **VR-005** — Bunker Mode (Network Jitter) Gate → S1-010
- ✅ **VR-006** — Disk Watermark Gates → S1-010
- ✅ **VR-007** — Fee Model Staleness Gate → S5-001
- ✅ **VR-008** — Cortex Override Gate → S1-010
- ✅ **VR-009** — Margin Headroom Gate → S1-010
- ✅ **VR-010** — Replay Gatekeeper Coverage Gate → S4-000
- ✅ **VR-011** — Liquidity Gate → S5-000
- ✅ **VR-012** — Net Edge Gate → S5-002
- ✅ **VR-013** — Instrument Cache Staleness Gate → S1-003, S1-006
- ✅ **VR-014** — WAL Record-Before-Dispatch Gate → S4-000, S4-003
- ✅ **VR-015** — AGGRESSIVE Patch Human Approval Gate → S1-010
- ✅ **VR-016** — Exchange Health Monitor Gate → S1-010
- ✅ **VR-017** — Atomic Churn Circuit Breaker → S2-001
- ✅ **VR-018** — Pending Exposure Reservation Gate → S5-002
- ✅ **VR-019** — Global Exposure Budget Gate → S5-002
- ✅ **VR-020** — Inventory Skew Gate → S5-002
- ✅ **VR-021** — Orderbook Continuity Gate → S2-003
- ✅ **VR-022** — Trades Continuity Gate → S2-003, S4-002
- ✅ **VR-023** — Rate Limit Brownout Gate → S1-010
- ✅ **VR-024** — Status Endpoint Response Gate → S0-004, S1-008, S1-009
- ✅ **VR-025** — No Market Orders Gate → S3-000
- ✅ **VR-026** — Options Stop Orders Forbidden Gate → S3-000, S3-002
- ✅ **VR-027** — Stop Orders Require Trigger Gate → S3-000, S3-002
- ✅ **VR-028** — Linked/OCO Orders Gate → S3-002
