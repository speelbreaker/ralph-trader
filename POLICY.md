# POLICY.md — Stoic Trader Safety Policy, Gates, and Invariants

This file contains the **contract‑critical runtime policy** (gates, thresholds, venue facts).  
**Fail closed** is the default: if uncertain → treat as unsafe.

> CLAUDE.md is the high‑signal harness.  
> POLICY.md is the detailed truth you **must not casually edit**.

---

## 0) Core invariants
- **Safety‑critical trading engine. Fail closed.**
- **EvidenceGuard:** *No evidence → no opens.* (closes/hedges may still be allowed per TradingMode)
- **Never bypass WAL write‑before‑send**
- **No policy staleness grace periods** (no “cache last good”)

---

## 1) TradingMode precedence (enforced every tick)

### A) KILL if ANY
- watchdog stale **OR** `risk_state == Kill`
- `mm_util` in **Kill** band (see §5)

### B) REDUCE_ONLY if ANY
- `F1_CERT` missing/stale (>24h)/FAIL
- `EvidenceChainState != GREEN`
- `bunker_mode_active` (network jitter / bunker mode)
- `mm_util` in **ReduceOnly** band (see §5)
- `fee_model_age_sec` missing or in stale band (see §5)

### C) ACTIVE only if none of the above triggers

---

## 2) EvidenceChainState + EvidenceGuard (HARD)

### EvidenceChainState GREEN (operational definition)
`EvidenceChainState` is GREEN **only if**:
- `python scripts/check_vq_evidence.py` exits **0**

This checker is **policy‑critical**:
- MUST be fast (target <2s)
- MUST be deterministic
- MUST NOT depend on external network calls or LLM heuristics
- If uncertain → exit non‑zero (fail closed)

### EvidenceGuard (hard invariant)
Evidence Chain requires:
- WAL entry
- TruthCapsule
- DecisionSnapshot
- Attribution

If any component fails → **block ALL opens** (closes/hedges allowed).  
Recovery requires a cooldown after GREEN returns (implementation-defined, but must be enforced).

---

## 3) F1 Certification (release/runtime gate)
- Evaluate via: `python scripts/check_f1_cert.py` (reads `artifacts/F1_CERT.json`)
- `F1_CERT.json` MUST include a generation timestamp (ISO8601 or equivalent).
  - Missing timestamp → treat as **stale** (fail closed)
- Missing/stale/FAIL → **ReduceOnly** (strict; no grace periods)

---

## 4) Pre‑dispatch gates (reject before sending)

| Gate | Reject condition |
|---|---|
| Liquidity | `slippage_bps > MaxSlippageBps` |
| Net edge | `net_edge_usd < min_edge_usd` |
| Margin | Reject **NEW opens** when `mm_util` is in the Block‑opens band (§5) |
| Order type | Market orders, options stops, linked orders |

---

## 5) Key thresholds (quick reference)

| Metric | Threshold | Action |
|---|---|---|
| `atomic_naked_events` | > 0 | Block opens, incident |
| `429_count / 10028_count` | > 0 | Kill mode, reconcile |
| `mm_util` | ≥ 0.70 / 0.85 / 0.95 | Block NEW opens (closes/hedges ok) / ReduceOnly / Kill |
| `fee_model_age_sec` | missing OR > 24h | ReduceOnly |
| `disk_used_pct` | ≥ 0.80 / 0.85 / 0.92 | Stop archives / ReduceOnly / Kill |
| `f1_cert_age` | > 24h | ReduceOnly |
| `snapshot_coverage_pct` | < 95% | Block replay |

---

## 6) Disk watermarks (ops safety)
- ≥80%: stop tick archives; continue Snapshots/WAL/TruthCapsules
- ≥85%: force ReduceOnly until <80%
- ≥92%: Kill trading loop

---

## 7) Deribit venue facts (artifact‑backed)

| Fact | Status | Enforcement |
|---|---|---|
| F‑01a | VERIFIED | Options reject stops |
| F‑01b | POLICY‑DISALLOWED | Options market forbidden |
| F‑03/5/6/7/9 | VERIFIED | Quantize/throttle/post‑only/reduce‑only/stops |
| F‑08 | NOT SUPPORTED | Linked OCO gated off |

**Policy:** Options = **limit only**. NO market/stop/linked (reject; no rewrite).

---

## 8) Do‑Not‑Dos (anti‑regression hard stops)

### Execution safety
- ❌ Do NOT weaken fail‑closed behavior or safety gates
- ❌ Do NOT allow opens when `EvidenceChainState != GREEN`
- ❌ Do NOT send market orders (any instrument)
- ❌ Do NOT send options stop orders (F‑01a)
- ❌ Do NOT bypass WAL write‑before‑send

### Idempotency & atomicity
- ❌ Do NOT include timestamps in `intent_hash`
- ❌ Do NOT mark `GroupState::Complete` before all legs are terminal
- ❌ Do NOT cache last‑known‑good F1 cert (no grace periods)

### Testing & CI
- ❌ Do NOT delete tests to make CI green
- ❌ Do NOT loosen assertions just to pass tests

### Hot path protection
- ❌ Do NOT introduce threads/timers in `crates/` without explicit approval
- ❌ Do NOT refactor hot path while “fixing lint”

---

## 9) Workflow rules (operational)

### Session protocol
1) One PRD item per session (keep changes minimal)
2) Small commits (e.g., `PRD #12: <short title>`)
3) Update progress (append‑only): `plans/progress.txt`
4) Verify before marking complete

### When stuck
1) Read `plans/progress.txt` and `git log`
2) If verify fails → fix verify first
3) If uncertain about safety → stop and ask

### Ask for approval before
- Adding threads/timers in hot path
- Changing TradingMode precedence or gate semantics
- Changing WAL/idempotency semantics
- Loosening any threshold

---

## 10) Prevention rules (append‑only)
When a CI failure or incident happens:
1) Fix the issue
2) Add **ONE** prevention rule here (specific, testable)
3) Add/adjust a test or verify gate when possible

Template:
- [YYYY‑MM‑DD] Failure: <what happened>  
  Prevention: <one‑line constraint>  
  Evidence: <test/command that catches it>

