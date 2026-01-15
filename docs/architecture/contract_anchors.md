# Contract Anchors (Provable Claims)

> **Source of Truth:** [CONTRACT.md](file:///Users/admin/Desktop/ralph/CONTRACT.md)  
> **Last audited:** 2026-01-15

Every anchor claim is proved by a contract citation. Unproved claims have been removed or rewritten.

---

## Anchor-001: PolicyGuard Mode Precedence

**Anchor ID:** Anchor-001  
**Claim:** PolicyGuard resolves TradingMode each tick using a strict precedence: Kill > ReduceOnly > Active.  
**Proof:** §2.2 (lines 688–703) — "Precedence (Highest → Lowest): 1. Kill if any… 2. ReduceOnly if any… 3. Active only if"  
**Implication:** TradingMode is never stored; it's recomputed every loop tick via `get_effective_mode()`.

---

## Anchor-002: Runtime F1 Certification Gate

**Anchor ID:** Anchor-002  
**Claim:** Missing, stale, or FAIL F1_CERT blocks all OPEN intents via ReduceOnly enforcement.  
**Proof:** §2.2.1 (line 648) — "missing OR stale OR FAIL => TradingMode MUST be ReduceOnly"  
**Implication:** Certification freshness window defaults to 24h; no caching last-known-good and no grace periods.

---

## Anchor-003: EvidenceGuard Blocks Opens on Evidence Chain Failure

**Anchor ID:** Anchor-003  
**Claim:** If the evidence chain is not GREEN, the system blocks all OPEN intents while allowing closes/hedges/cancels.  
**Proof:** §2.2.2 (line 667) — "If Evidence Chain is not GREEN → block ALL new OPEN intents"  
**Implication:** System enters `RiskState::Degraded` and forces ReduceOnly until GREEN recovers for cooldown.

---

## Anchor-004: TruthCapsule Timing (RecordedBeforeDispatch)

**Anchor ID:** Anchor-004  
**Claim:** TruthCapsule must be recorded before first dispatch of any leg in an AtomicGroup.  
**Proof:** §4.3.2 (line 1156) — "TruthCapsule MUST be recorded before first dispatch of any leg"  
**Implication:** Write failure blocks opens and enters Degraded/ReduceOnly.

---

## Anchor-005: Decision Snapshots Required for Replay

**Anchor ID:** Anchor-005  
**Claim:** Decision Snapshots are required replay inputs; Replay Gatekeeper fails if coverage < 95%.  
**Proof:** §5.2 (line 1290) — "Replay Gatekeeper MUST HARD FAIL if snapshot_coverage_pct < 95%"  
**Implication:** Decision Snapshots continue even when heavy archives are paused at 80% disk watermark.

---

## Anchor-006: WAL Durability (Record Before Dispatch)

**Anchor ID:** Anchor-006  
**Claim:** Intent must be recorded in WAL before network dispatch.  
**Proof:** §2.4 (line 787) — "Write intent record BEFORE network dispatch"  
**Implication:** Prevents double-send on crash recovery; reconciliation uses WAL as truth source.

---

## Anchor-007: Trade-ID Registry Deduplication

**Anchor ID:** Anchor-007  
**Claim:** WS fill handler must check trade_id first; if seen, NOOP; else append trade_id then apply.  
**Proof:** §2.4 (lines 813–814) — "if trade_id already in WAL → NOOP… else: append trade_id to WAL first"  
**Implication:** Prevents ghost-race fills and duplicate position updates.

---

## Anchor-008: Disk Watermark Actions

**Anchor ID:** Anchor-008  
**Claim:** At 80% disk, stop heavy archives but continue Decision Snapshots + WAL + TruthCapsule; at 85%, Degraded; at 92%, Kill.  
**Proof:** §7.2 (lines 1496–1502) — "80%: stop writing full tick/L2… 85%: force RiskState::Degraded… 92%: hard-stop trading loop (Kill switch)"  
**Implication:** Replay remains valid even under disk pressure because Decision Snapshots continue.

---

## Anchor-009: AGGRESSIVE Patches Require Human Approval

**Anchor ID:** Anchor-009  
**Claim:** AGGRESSIVE patches must not apply without explicit human approval artifact.  
**Proof:** §7.1.3 (line 1463) — "AGGRESSIVE always requires HUMAN_APPROVAL.json"  
**Implication:** Only SAFE patches may auto-apply (if replay + canary pass and no incidents).

---

## Anchor-010: Bunker Mode on Network Jitter

**Anchor ID:** Anchor-010  
**Claim:** Network jitter triggers Bunker Mode which forces ReduceOnly and blocks opens.  
**Proof:** §2.3.2 (lines 773–777) — "If deribit_http_p95_ms > 750ms for 3 consecutive windows… Force TradingMode::ReduceOnly"  
**Implication:** Exit Bunker Mode only after all metrics below threshold for stable period (120s).

---

## Anchor-011: TLSM Never Panics on Out-of-Order Events

**Anchor ID:** Anchor-011  
**Claim:** TLSM handles fill-before-ack and out-of-order WS events without panic.  
**Proof:** §2.1 (lines 621–622) — "Never panic on out-of-order WS events. Fill-before-Ack is valid reality"  
**Implication:** Every transition is appended to WAL immediately; anomalies are logged, not crashed.

---

## Anchor-012: Canary Rollout Abort Triggers Rollback

**Anchor ID:** Anchor-012  
**Claim:** Canary abort conditions trigger immediate rollback to previous policy plus ReduceOnly cooldown.  
**Proof:** §5.3 (lines 1333–1338) — "Abort Conditions (Immediate rollback to previous policy + ReduceOnly cooldown)"  
**Implication:** Abort triggers include atomic_naked_events, p95 slippage blowout, low fill rate, pnl floor breach.

---

## Anchor-013: No Market Orders Policy

**Anchor ID:** Anchor-013  
**Claim:** Market orders are forbidden by policy for all instrument types; rejected without normalization.  
**Proof:** §1.4.4 (lines 551–554, 562–563) — "Market orders: forbidden by policy… If type == market → REJECT"  
**Implication:** Strategies must emit limit orders only; violations are hard rejects at preflight.

---

## Anchor-014: Emergency Close Has Hedge Fallback

**Anchor ID:** Anchor-014  
**Claim:** If close retries fail, submit reduce-only perp hedge to neutralize delta.  
**Proof:** §3.1 (lines 835–836) — "If still exposed after retries: submit reduce-only perp hedge to neutralize delta"  
**Implication:** System logs `AtomicNakedEvent` with exposure and time-to-delta-neutral.

---

## Anchor-015: Watchdog Triggers ReduceOnly via POST Endpoint

**Anchor ID:** Anchor-015  
**Claim:** Watchdog triggers on silence > 5s and calls `POST /api/v1/emergency/reduce_only`.  
**Proof:** §3.2 (line 847) — "Watchdog triggers on silence > 5s → calls POST /api/v1/emergency/reduce_only"  
**Implication:** ReduceOnly persists until cooldown expiry and reconciliation confirms safe.

---

## Anchor-016: Exchange Health Monitor Blocks Opens Before Maintenance

**Anchor ID:** Anchor-016  
**Claim:** When exchange maintenance is ≤60 minutes away, system sets RiskState::Maintenance and blocks opens.  
**Proof:** §2.3.1 (lines 751–756) — "If a maintenance window start is ≤ 60 minutes away: Set RiskState::Maintenance; Force TradingMode = ReduceOnly; Block all new opens"  
**Implication:** Closes/hedges allowed; polling `/public/get_announcements` every 60s.

---

## Anchor-017: Atomic Churn Circuit Breaker Prevents Fee Death-Spiral

**Anchor ID:** Anchor-017  
**Claim:** Repeated emergency flattens for same structure trigger a 15-minute blacklist for that key.  
**Proof:** §1.2.2 (lines 384–386) — "If EmergencyFlattenGroup triggers >2 times in 5 minutes for the same key → Blacklist that key for 15 minutes"  
**Implication:** Prevents death-by-fees churn while allowing reduces/hedges.

---

## Anchor-018: Pending Exposure Reservation Prevents Double-Spend

**Anchor ID:** Anchor-018  
**Claim:** Before dispatching an AtomicGroup, Soldier must reserve projected exposure impact atomically.  
**Proof:** §1.4.2.1 (lines 489–502) — "Before dispatching any new AtomicGroup, the Soldier must reserve the projected exposure impact"  
**Implication:** Prevents concurrent signals from over-allocating risk budget.

---

## Anchor-019: WS Continuity Breaks Trigger Degraded + Snapshot Rebuild

**Anchor ID:** Anchor-019  
**Claim:** Book changeId mismatch or trade_seq gap immediately sets Degraded and pauses opens.  
**Proof:** §3.4 (lines 930–938, 940–947) — "If prevChangeId != last_change_id: Set RiskState::Degraded and pause opens"  
**Implication:** Recovery requires REST snapshot + reconciliation before resuming.

---

## Anchor-020: Rate Limit Session Kill Triggers Immediate Kill Mode

**Anchor ID:** Anchor-020  
**Claim:** On 10028/too_many_requests or session termination, set Kill immediately and require full reconcile.  
**Proof:** §3.3 (lines 896–900) — "Set RiskState::Degraded and TradingMode = Kill immediately… Run 3-way reconciliation"  
**Implication:** Resume only when stable and Cortex override is None.

---

## Anchor-021: Status Endpoint Required Fields

**Anchor ID:** Anchor-021  
**Claim:** `/api/v1/status` must return trading_mode, risk_state, evidence_chain_state, and other health metrics.  
**Proof:** §7.0 (lines 1397–1404) — "/status response MUST include (minimum): trading_mode, risk_state, evidence_chain_state…"  
**Implication:** Required endpoint-level test for deployment gate.

---

## Anchor-022: Cortex WS Gap Blocks Risk-Increasing Actions

**Anchor ID:** Anchor-022  
**Claim:** When ws_gap_flag is true, Cortex blocks risk-increasing cancels/replaces in addition to opens.  
**Proof:** §2.3 (lines 734–739) — "If ws_gap_flag == true: opens are already frozen, but Cortex must also block any risk-increasing cancels/replaces"  
**Implication:** Only reduce-only closes/hedges proceed during WS gap.

---

## Anchor-023: Order-Type Preflight Guards (Artifact-Backed)

**Anchor ID:** Anchor-023  
**Claim:** Preflight guards reject market orders, stop orders on options, stop orders without trigger, and linked/OCO orders.  
**Proof:** §1.4.4 (lines 548–582) — "Preflight Rules (MUST implement)… type == market → REJECT; Stop orders: forbidden (F-01a); trigger is mandatory; Reject any non-null linked_order_type"  
**Implication:** Violations are hard rejects before API call; no normalization or rewrite allowed.
