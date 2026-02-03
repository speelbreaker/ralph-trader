# GLOBAL_INVARIANTS (starter v0.2)

Purpose: a short list of global invariants (cross-flow, cross-module) that must never be violated.
Each invariant declares: name, scope, forbidden states, fail-closed behavior, enforcement point, observability hook, and proof hooks.

Scope note: Only numbered sections, Definitions, and Appendix A are normative.

## Enforcement Points
- EP-001: Hot-path dispatch chokepoint (PolicyGuard)
- EP-002: Intent classification function
- EP-003: EvidenceGuard open gate
- EP-004: WAL enqueue gate (RecordedBeforeDispatch)
- EP-005: TruthCapsule first-dispatch gate
- EP-006: Replay gatekeeper and snapshot retention policy
- EP-007: PolicyGuard staleness rule
- EP-008: PolicyGuard F1_CERT gate
- EP-009: PolicyGuard critical input freshness gate
- EP-010: CP-001 open permission latch
- EP-011: Cancel/Replace canonical rules
- EP-012: Kill Mode Semantics evaluator
- EP-013: GroupState serializer and first-failure seed
- EP-014: Atomic group containment algorithm (Step A/B)
- EP-015: Emergency close price source selector
- EP-016: Cortex override aggregation
- EP-017: Network jitter monitor (bunker mode)
- EP-018: Idempotency dispatcher (WAL dedupe)

## Invariants (20)

### GI-001 - OPEN dispatch requires Active
- **Name:** OPEN dispatch requires Active
- **Scope:** Global
- **Forbidden states:** OPEN dispatch when TradingMode != Active
- **Fail-closed:** If TradingMode missing or unparseable at dispatch, treat as != Active and block OPEN; record mode_reasons.
- **Enforcement point:** EP-001
- **Observability:** /status.trading_mode, /status.mode_reasons, event: dispatch_blocked_open
- **Contract refs:** §2.2.3
- **AT coverage:** AT-201, AT-416, AT-417, AT-931

### GI-002 - Intent classification fail-closed
- **Name:** Intent classification fail-closed
- **Scope:** Global
- **Forbidden states:** Unknown or unparseable intent classified as CLOSE/HEDGE/CANCEL
- **Fail-closed:** If classification inputs missing or unparseable, classify as OPEN and apply OPEN gates.
- **Enforcement point:** EP-002
- **Observability:** event: intent_classified, event: dispatch_blocked_open
- **Contract refs:** §2.2.3, Definitions
- **AT coverage:** AT-201

### GI-003 - Evidence gate blocks opens
- **Name:** Evidence gate blocks opens
- **Scope:** Global
- **Forbidden states:** OPEN dispatch while EvidenceChainState != GREEN
- **Fail-closed:** If EvidenceChainState missing or unparseable, treat as not GREEN and block OPEN.
- **Enforcement point:** EP-003
- **Observability:** /status.evidence_chain_state, metric: evidence_guard_blocked_opens_count
- **Contract refs:** §2.2.2
- **AT coverage:** AT-107, AT-334, AT-214, AT-215, AT-415

### GI-004 - WAL enqueue required for OPEN
- **Name:** WAL enqueue required for OPEN
- **Scope:** Global
- **Forbidden states:** OPEN dispatch without RecordedBeforeDispatch WAL entry
- **Fail-closed:** If WAL enqueue fails or status unknown, block OPEN and force ReduceOnly.
- **Enforcement point:** EP-004
- **Observability:** metric: wal_write_errors, event: wal_enqueue_failed
- **Contract refs:** §2.4, §2.4.1
- **AT coverage:** AT-906

### GI-005 - TruthCapsule before first leg
- **Name:** TruthCapsule before first leg
- **Scope:** Global
- **Forbidden states:** First leg dispatch without TruthCapsule
- **Fail-closed:** If TruthCapsule missing or write fails, set RiskState=Degraded and force ReduceOnly; block OPEN.
- **Enforcement point:** EP-005
- **Observability:** metric: truth_capsule_write_errors, /status.risk_state
- **Contract refs:** §4.3.2
- **AT coverage:** AT-046

### GI-006 - Decision snapshot retention
- **Name:** Decision snapshot retention
- **Scope:** Global
- **Forbidden states:** Replay window lacks required Decision Snapshots
- **Fail-closed:** If snapshot coverage missing or below required window, block replay and force ReduceOnly.
- **Enforcement point:** EP-006
- **Observability:** metric: snapshot_coverage_pct, event: replay_gate_blocked
- **Contract refs:** §7.2
- **AT coverage:** AT-257, AT-258

### GI-007 - Policy staleness forces ReduceOnly
- **Name:** Policy staleness forces ReduceOnly
- **Scope:** Global
- **Forbidden states:** TradingMode Active when policy stale
- **Fail-closed:** If policy timestamp missing or unparseable, treat as stale and force ReduceOnly.
- **Enforcement point:** EP-007
- **Observability:** /status.trading_mode, /status.mode_reasons
- **Contract refs:** §2.2.3
- **AT coverage:** AT-336

### GI-008 - F1_CERT binding gate
- **Name:** F1_CERT binding gate
- **Scope:** Global
- **Forbidden states:** TradingMode Active when F1_CERT missing, stale, or invalid
- **Fail-closed:** If F1_CERT missing or invalid, force ReduceOnly and block OPEN.
- **Enforcement point:** EP-008
- **Observability:** /status.f1_cert.status, /status.trading_mode
- **Contract refs:** §2.2.1, Definitions
- **AT coverage:** AT-020, AT-021, AT-423

### GI-009 - Critical input freshness gate
- **Name:** Critical input freshness gate
- **Scope:** Global
- **Forbidden states:** TradingMode Active when a critical input is missing or stale
- **Fail-closed:** If any critical input missing or unparseable, force ReduceOnly and set REDUCEONLY_INPUT_MISSING_OR_STALE.
- **Enforcement point:** EP-009
- **Observability:** /status.trading_mode, /status.mode_reasons
- **Contract refs:** §2.2.1.1
- **AT coverage:** AT-001, AT-112, AT-349, AT-350, AT-413

### GI-010 - OpenPermission latch semantics
- **Name:** OpenPermission latch semantics
- **Scope:** Global
- **Forbidden states:** OPEN dispatch while latch true; latch true with empty reason_codes; requires_reconcile != latch
- **Fail-closed:** If latch state or reason codes missing or unparseable, treat latch as true and block OPEN.
- **Enforcement point:** EP-010
- **Observability:** /status.open_permission_blocked_latch, /status.open_permission_reason_codes, /status.open_permission_requires_reconcile
- **Contract refs:** §2.2.4, §7.0
- **AT coverage:** AT-010, AT-011, AT-027

### GI-011 - Latch blocks risk-increasing replace
- **Name:** Latch blocks risk-increasing replace
- **Scope:** Global
- **Forbidden states:** Risk-increasing cancel/replace while latch true
- **Fail-closed:** If risk classification or latch state unknown, treat as risk-increasing and reject.
- **Enforcement point:** EP-011
- **Observability:** event: cancel_replace_rejected, /status.open_permission_blocked_latch
- **Contract refs:** §2.2.5
- **AT coverage:** AT-402, AT-917

### GI-012 - Evidence gate blocks risk-increasing replace
- **Name:** Evidence gate blocks risk-increasing replace
- **Scope:** Global
- **Forbidden states:** Risk-increasing cancel/replace while EvidenceChainState != GREEN
- **Fail-closed:** If EvidenceChainState missing or unparseable, treat as not GREEN and reject.
- **Enforcement point:** EP-011
- **Observability:** event: cancel_replace_rejected, /status.evidence_chain_state
- **Contract refs:** §2.2.2, §2.2.5
- **AT coverage:** AT-404, AT-917

### GI-013 - Kill hard-stop forbids dispatch
- **Name:** Kill hard-stop forbids dispatch
- **Scope:** Global
- **Forbidden states:** Any dispatch when TradingMode == KillHardStop
- **Fail-closed:** If Kill cause missing or unparseable, or eligibility false, enter KillHardStop and block dispatch.
- **Enforcement point:** EP-012
- **Observability:** /status.trading_mode, /status.mode_reasons, event: dispatch_blocked_kill
- **Contract refs:** §2.2.3
- **AT coverage:** AT-339, AT-346, AT-347

### GI-014 - Kill containment eligibility
- **Name:** Kill containment eligibility
- **Scope:** Global
- **Forbidden states:** Containment dispatch when eligibility predicates are not all true
- **Fail-closed:** If any eligibility input missing or unparseable, enter KillHardStop and block dispatch.
- **Enforcement point:** EP-012
- **Observability:** /status.trading_mode, /status.mode_reasons
- **Contract refs:** §2.2.3
- **AT coverage:** AT-338, AT-340

### GI-015 - MixedFailed seed immutable
- **Name:** MixedFailed seed immutable
- **Scope:** Global
- **Forbidden states:** First failure seed overwritten; GroupState marked Complete before seed
- **Fail-closed:** If serialization conflict occurs or seed data missing, reject update and keep first failure seed.
- **Enforcement point:** EP-013
- **Observability:** event: group_state_update_rejected, metric: group_state_conflict_count
- **Contract refs:** §1.2.1
- **AT coverage:** AT-220

### GI-016 - Bounded rescue attempts
- **Name:** Bounded rescue attempts
- **Scope:** Global
- **Forbidden states:** Unbounded rescue attempts; MixedFailed without emergency close
- **Fail-closed:** If rescue counter missing or unparseable, treat as limit reached and trigger emergency close.
- **Enforcement point:** EP-014
- **Observability:** event: containment_step_b_started, metric: rescue_attempt_count
- **Contract refs:** §1.2.1, §3.1
- **AT coverage:** AT-117, AT-118

### GI-017 - Emergency close bypasses profitability gates
- **Name:** Emergency close bypasses profitability gates
- **Scope:** Global
- **Forbidden states:** Emergency close blocked by LiquidityGate or NetEdge
- **Fail-closed:** If price source invalid or missing, abort emergency close and force ReduceOnly.
- **Enforcement point:** EP-015
- **Observability:** event: emergency_close_started, /status.trading_mode
- **Contract refs:** §1.3, §1.4.1, §3.1
- **AT coverage:** AT-236, AT-327, AT-938

### GI-018 - Cortex override aggregation
- **Name:** Cortex override aggregation
- **Scope:** Global
- **Forbidden states:** Override less severe than max producer; missing producer input allows Active
- **Fail-closed:** If any producer input missing or unparseable, set override ForceReduceOnly.
- **Enforcement point:** EP-016
- **Observability:** /status.cortex_override, /status.trading_mode
- **Contract refs:** §2.3
- **AT coverage:** AT-418

### GI-019 - Bunker mode fail-closed
- **Name:** Bunker mode fail-closed
- **Scope:** Global
- **Forbidden states:** TradingMode Active when required network metrics missing
- **Fail-closed:** If required metrics missing or uncomputable, set bunker_mode_active true and force ReduceOnly.
- **Enforcement point:** EP-017
- **Observability:** /status.bunker_mode_active, /status.trading_mode
- **Contract refs:** §2.3.2
- **AT coverage:** AT-205

### GI-020 - Intent idempotency
- **Name:** Intent idempotency
- **Scope:** Global
- **Forbidden states:** Intent resend without WAL unsent flag
- **Fail-closed:** If WAL send state missing or unparseable, treat as sent and block resend.
- **Enforcement point:** EP-018
- **Observability:** metric: wal_duplicate_send_blocked, event: intent_resend_blocked
- **Contract refs:** §1.1.1, §2.4
- **AT coverage:** AT-928, AT-233

---

## Appendix A (Normative) — Risk Gate + State Machine Summary

This appendix summarizes contract-required safety behavior for risk gating,
reconciliation, and idempotency. It is not a full policy spec; it is a
fail-closed baseline that MUST hold for every dispatch path.

### A.1 Risk gate inputs (fail-closed)
- Required inputs for any OPEN intent evaluation:
  - balances/collateral snapshot
  - positions snapshot
  - open orders snapshot
  - market data (mark/last/bid/ask as required by instrument)
  - instrument metadata (tick size, min amount, amount step, contract multiplier)
- If any required input is missing or stale, DENY new OPENs and allow only
  risk-reducing actions (ReduceOnly/CLOSE/HEDGE) per TradingMode rules.
- If staleness cannot be computed, treat as stale and degrade.
- **Contract refs:** §2.2.1.1 (critical input freshness), Appendix A defaults

### A.2 RiskState ladder (fail-closed)
- Allowed values: `Healthy`, `Degraded`, `Maintenance`, `Kill`.
- Unknown or unparseable RiskState MUST map to `Degraded`.
- When RiskState != `Healthy`, PolicyGuard MUST compute TradingMode
  `ReduceOnly` or `Kill` and block OPENs.
- **Contract refs:** §2.2.3, §3.4

### A.3 Reconciliation and unknown exchange state
- On restart, WS sequencing gap, session termination, or ambiguity in order
  truth, the open-permission latch MUST be set with reconcile-class reason codes.
- OPENs remain blocked until reconciliation clears all reason codes.
- Reconcile MUST verify open orders/trades before any new OPENs are allowed.
- **Contract refs:** §2.2.4, §3.4

### A.4 Idempotency and no blind resend
- `client_order_id` (or equivalent) MUST be stable for a given intent.
- Do NOT resend unless the WAL marks the intent unsent AND reconcile proves the
  order does not exist on the exchange.
- **Contract refs:** §2.4, §3.4

### A.5 Rate limits and session termination
- On 429/10028 or explicit session termination, enter a degraded state and block
  OPENs until reconnect + reconcile succeed.
- **Contract refs:** §3.3, §2.2.4
