This is the canonical contract path. Do not edit other copies.

# **Version: 4.9 (The "Antifragile" Standard)**
**Status**: FINAL ARCHITECTURE **Objective**: Net Profit via Structural Arbitrage using **Atomic Group Execution**, **Fee-Aware IOC Limits**, and **Closed-Loop Optimization**. **Architecture**: "The Iron Monolith v4.0" (Rust Execution/Risk \+ Python Policy \+ **Automated Policy Tuner**)

---

## Patch Summary (Contract Patch Set)

- **Patch A — Replay Gatekeeper ↔ Disk Watermarks:** Make **Decision Snapshots the REQUIRED replay input**; full tick/L2 archives are **optional** and pausable without forcing Degraded.
- **Patch B — EvidenceGuard:** Add a hard runtime invariant: **no evidence chain → no opens** (ReduceOnly until green + cooldown).
- **Patch C — Bunker Mode:** Add **network jitter** safety override that forces ReduceOnly and blocks opens until comms stabilize.
- **Patch D — Owner /status Endpoint:** Add a read-only `GET /api/v1/status` endpoint + **endpoint-level test requirement** for any new endpoint.

## Definitions

- **instrument_kind**: one of `option | linear_future | inverse_future | perpetual` (derived from venue metadata).
  - **Linear Perpetuals (USDC‑margined)**: treat as `linear_future` for sizing (canonical `qty_coin`), even if their venue symbol says "PERPETUAL".
- **order_type** (Deribit `type`): `limit | market | stop_limit | stop_market | ...` (venue-specific).
- **linked_order_type**: Deribit linked/OCO semantics (venue-specific; gated off for this bot).
- **Aggressive IOC Limit**: a `limit` order with `time_in_force=immediate_or_cancel` and a *bounded* limit price computed from L2 + safety clamps.

- **RiskState** (health/cause layer): `Healthy | Degraded | Maintenance | Kill`
- **TradingMode** (enforcement layer): `Active | ReduceOnly | Kill`  
  Resolved by PolicyGuard each tick from RiskState, policy staleness, watchdog, exchange health, fee cache staleness, and Cortex overrides.
  **Runtime F1 Gate in PolicyGuard (HARD, runtime enforcement):**
  - PolicyGuard MUST read `artifacts/F1_CERT.json`.
  - Freshness window: default 24h (configurable). If missing OR stale OR FAIL => TradingMode MUST be ReduceOnly.
  - While in ReduceOnly due to F1 failure: allow only closes/hedges/cancels; block all opens.
  - This rule is strict: no caching last-known-good and no grace periods.


## Deribit Venue Facts Addendum (Artifact-Backed)

This contract is **venue-bound**: any behavior marked **VERIFIED** below is backed by artifacts under `artifacts/` and is enforced by code + regression tests.  
CI guardrail: `python scripts/check_vq_evidence.py` must pass, or **build fails**.

| Fact ID | Status | Enforcement point in engine | Evidence path under `artifacts/` |
|---|---|---|---|
| **F-01a** | **VERIFIED** | §1.4.4 **Options Order-Type Guard** → reject stop orders on options preflight | `artifacts/T-TRADE-02_response.json` |
| **F-01b** | **DOC-CONFLICT** (POLICY-DISALLOWED) | §1.4 **No Market Orders** + §1.4.4 **Options Order-Type Guard** → market on options forbidden (reject only; no normalization) | `artifacts/deribit_testnet_trade_20260103_015804.log` |
| **F-03** | **VERIFIED** | §1.1.1 **Canonical Quantization** → tick/step rounding before hash + dispatch | `artifacts/deribit_testnet_trade_final_20260103_020002.log` |
| **F-05** | **VERIFIED** | §5 **Rate Limiting** → do **not** rely on rate-limit headers; enforce local throttle + retry/backoff | `artifacts/deribit_testnet_trade_final_20260103_020002.log` |
| **F-06** | **VERIFIED** | §1.4.4 **Post-Only Guard** → never send `post_only` that would cross; treat venue reject as deterministic, not “random” | `artifacts/deribit_testnet_trade_final_20260103_020002.log` |
| **F-07** | **VERIFIED** | §2.2/§5.4 **Reduce-Only Mode** → when effective mode is ReduceOnly/Kill, outbound orders must include venue `reduce_only=true` | `artifacts/deribit_testnet_trade_final_20260103_020002.log` |
| **F-08** | **VERIFIED** (NOT SUPPORTED) | §1.4.4 **Linked Orders Gate** → `linked_order_type` rejected unless explicitly certified (not currently) | `artifacts/T-OCO-01_response.json` |
| **F-09** | **VERIFIED** | §1.4.4 **Stop Order Guard** → perps/futures stops allowed *only* with `trigger` set; options stops always rejected | `artifacts/T-STOP-01_response.json`, `artifacts/T-STOP-02_response.json` |
| **F-10** | **VERIFIED** (observed metric) | §5.5 **Timeouts & Circuit Breakers** → use conservative timeouts; do not treat latency as invariant | `artifacts/T-PM-01_latency_testnet.json` |
| **A-03** | **VERIFIED** | §3.2 **Data Plane / Heartbeat** → websocket silence triggers ReduceOnly/Kill | `artifacts/deribit_testnet_trade_final_20260103_020002.log` |

### Policy decision for DOC-CONFLICT (F-01b)

Even if **testnet** accepts market orders on options, this bot treats them as **DISALLOWED**.

**Rule:** For `instrument_kind == option`, the engine MUST:
- **Reject** `type=market` (or any payload lacking a limit price).  
  **No normalization/rewrite** is allowed; strategies must never emit market orders.

This policy is enforced in §1.4 (**No Market Orders**) and §1.4.4 (**Options Order-Type Guard**).

## **1\. Execution Architecture: The "Atomic Group" (Real-Time Repair)**

**Constraint**: We do not rely on API atomicity. We rely on **Runtime Atomicity**. If Leg A fills and Leg B dies, the system detects the "Mixed State" and neutralizes it immediately, without waiting for a restart.

### **1.0 Instrument Units & Notional Invariants (Deribit Quantity Contract) — MUST implement**

**Why this exists:** Unit mismatches are silent PnL killers. Deribit uses **different sizing semantics** across instruments. If we don’t encode these invariants, we will eventually ship a “correct-looking” trade that is 10–100× the intended exposure.

**Canonical internal units (single source of truth):**
- `qty_coin` (BTC/ETH): **options + linear futures** sizing.
- `qty_usd` (USD notional): **perpetual + inverse futures** sizing (Deribit `amount` is USD units for these).
- `notional_usd`:
  - For coin-sized instruments: `notional_usd = qty_coin * index_price`
  - For USD-sized instruments: `notional_usd = qty_usd`

**Hard Rules (Non‑Negotiable):**
1. **Never mix** coin sizing and USD sizing for the *same* intent. One is canonical; the other is derived.
2. If both `contracts` and `amount` are provided (internally or via strategy output), they **must match** within tolerance:
   - `amount ≈ contracts * contract_multiplier`  
   - `contract_multiplier` is instrument-specific (e.g., inverse futures contract size in USD; options contract multiplier in coin).
3. If a mismatch is detected: **reject the intent** and set `RiskState::Degraded` (this is a wiring bug, not “market noise”).

**OrderSize struct (MUST implement):**
```rust
pub struct OrderSize {
  pub contracts: Option<i64>,     // integer contracts when applicable
  pub qty_coin: Option<f64>,      // BTC/ETH amount when applicable
  pub qty_usd: Option<f64>,       // USD amount when applicable
  pub notional_usd: f64,          // always populated (derived)
}
```

**Dispatcher Rules (Deribit request mapping):**
- Determine `instrument_kind` from instrument metadata (`option | linear_future | inverse_future | perpetual`).
- Compute size fields:
  - `option | linear_future`: canonical = `qty_coin`; derive `contracts` if contract multiplier is defined.
    - **Linear Perpetuals (USDC‑margined)** are treated as `linear_future`.
  - `perpetual | inverse_future`: canonical = `qty_usd`; derive `contracts = round(qty_usd / contract_size_usd)` (if defined) and `qty_coin = qty_usd / index_price`.
- **Deribit outbound order size field:** always send exactly one canonical “amount” value:
  - coin instruments → send `amount = qty_coin`
  - USD-sized instruments → send `amount = qty_usd`
- If `contracts` exists, it must be consistent with the canonical amount before dispatch (reject if not).

**Acceptance Test (Units + Dispatcher):**
- Given:
  1) `instrument_kind=option` with `qty_coin=0.3` at `index_price=100_000`  
  2) `instrument_kind=perpetual` with `qty_usd=30_000` at `index_price=100_000`
- Expect:
  - outbound option uses `amount=0.3` (coin), `notional_usd=30_000`
  - outbound perp uses `amount=30_000` (USD), `qty_coin=0.3`, `notional_usd=30_000`
  - if both `contracts` and `amount` are supplied and mismatch → **reject + degrade**.

---

### **1.1 Labeling & Idempotency Contract**

**Requirement**: Every order must be uniquely identifiable and deduplicable across restarts, socket reconnections, and race conditions.

**Specification: The Label Schema** Format: `stoic:v4:{strat_id}:{group_id}:{leg_idx}:{intent_hash}`

**Deribit Constraint:** `label` must be <= 64 chars. (Hard limit)

**Compact Label Schema (must implement):**
Format: `s4:{sid8}:{gid12}:{li}:{ih16}`

- `sid8` = first 8 chars of stable strategy id hash (e.g., base32(xxhash(strat_id)))
- `gid12` = first 12 chars of group_id (uuid without dashes, truncated)
- `li` = leg_idx (0/1)
- `ih16` = 16-hex (or base32) intent hash

**Rule:** If label would exceed 64, truncate only hashed components, never truncate structural fields.

### **1.1.2 Label Parse + Disambiguation (Collision-Safe)**

**Requirement:** Label truncation can collide. The Soldier must deterministically map exchange orders to local intents.

**Where:** `soldier/core/recovery/label_match.rs`

**Algorithm:**
1) Parse label → extract `{sid8, gid12, leg_idx, ih16}`.
2) Candidate set = all local intents where:
   - `gid12` matches AND `leg_idx` matches.
3) If candidate set size == 1 → match.
4) Else disambiguate using the following tie-breakers in order:
   A) `ih16` match (first 16 chars of intent_hash)
   B) instrument match
   C) side match
   D) qty_q match
5) If still ambiguous → mark `RiskState::Degraded`, block opens, and require REST trade/order snapshot reconcile.

**Acceptance Test:**
- Construct two intents with same gid12. Ensure matcher resolves using `ih16` + instrument + side.
- If ambiguity remains, verify system enters Degraded and stops opening.



* `strat_id`: Static ID of the running strategy (e.g., `strangle_btc_low_vol`).  
* `group_id`: UUIDv4 (Shared by all legs in a single atomic attempt).  
* `leg_idx`: `0` or `1` (Identity within the group).  
* `intent_hash`: `xxhash64(instrument + side + qty + limit_price + group_id + leg_idx)`
  **Hard rule:** Do NOT include wall-clock timestamps in the idempotency hash.


### **1.1.1 Canonical Quantization (Pre-Hash & Pre-Dispatch)**

**Requirement:** All idempotency keys and order payloads MUST use canonical, exchange-valid rounded values.

**Where:** `soldier/core/execution/quantize.rs`

**Inputs:** `instrument_id`, `raw_qty`, `raw_limit_price`  
**Outputs:** `qty_q`, `limit_price_q` (quantized)

**Rules (Deterministic):**
- Fetch instrument constraints: `tick_size`, `amount_step`, `min_amount`.
- `qty_q = round_down(raw_qty, amount_step)` (never round up size).
- `limit_price_q = round_to_nearest_tick(raw_limit_price, tick_size)` (or round in the safer direction; see below).
- If `qty_q < min_amount` → Reject(intent=TooSmallAfterQuantization).
- Idempotency hash must be computed ONLY from quantized fields:
  `intent_hash = xxhash64(instrument + side + qty_q + limit_price_q + group_id + leg_idx)`

**Safer rounding direction:**
- For BUY: round `limit_price_q` DOWN (never pay extra).
- For SELL: round `limit_price_q` UP (never sell cheaper).

**Acceptance Tests:**
1) Same intent computed from two codepaths yields identical `intent_hash`.
2) BUY price rounding never increases price; SELL rounding never decreases price.

**Idempotency Rules (Non-Negotiable):**
1. **Dedupe-on-Send (Local):** Before dispatch, check `intent_hash` in the WAL. If exists → NOOP.
2. **Dedupe-on-Send (Remote):** Use Deribit `label` as the idempotency key. If WS reconnect occurs, re-fetch open orders and match by `group_id`.
3. **Replay Safe:** On restart, rebuild “in-flight intents” from WAL, then reconcile with exchange orders/trades. Never resend an intent unless WAL state says it is unsent.
4. **Attribution-Keyed:** Every fill must map to `group_id` + `leg_idx`, so we can compute “atomic slippage” per group.


### **1.2 Atomic Group Executor**

**Requirement:** Manage multi-leg intent as a single atomic unit under messy reality (rejects, partials, WS gaps). We do **Runtime Atomicity**: detect atomicity breaks and deterministically contain/flatten.

### **1.2.1 GroupState Serialization Invariant (Seed “First Fail”)**
**Council Weakness Covered:** Premature “Complete” + naked events under concurrency.

**Hard Invariant (Non‑Negotiable):**
- A Group may be marked `Complete` **only if** every leg has reached a terminal TLSM state `{Filled, Canceled, Rejected}` **AND**
  - the group has **no partial fills** and **no fill mismatch** beyond `epsilon` (atomicity restored or no-trade), **AND**
  - **no containment/rescue action is pending**.
- The **first observed failure** (reject/cancel/unfilled/partial mismatch) must “seed” the group into `MixedFailed` and **must not be overwritten** by later async updates.

**Serialization Rule:**
- GroupState transitions must be **single-writer** (AtomicGroupExecutor owns state) or protected by a **group‑level lock**.
- Leg TLSM events may arrive concurrently; **only** the executor decides when/if the group can advance to `Complete`.

**Where:** `soldier/core/execution/atomic_group_executor.rs`

**Acceptance Test:**
- Simulate leg events arriving out of order (A fills fast, B rejects late). Verify: group is **never** recorded `Complete` before B reaches terminal, and the first failure deterministically triggers containment → flatten.

**Implementation (Rust Skeleton):** `soldier/core/execution/group.rs`

```rust
pub enum GroupState { New, Dispatched, Complete, MixedFailed, Flattening, Flattened }

pub struct AtomicGroup {
  pub group_id: Uuid,
  pub legs: Vec<OrderIntent>,
  pub state: GroupState,
}

pub struct LegResult {
  pub leg_idx: u8,
  pub requested_qty: f64,
  pub filled_qty: f64,     // 0.0 .. requested_qty
  pub rejected: bool,
  pub unfilled: bool,
}

pub async fn execute_atomic_group(&self, group: AtomicGroup) -> Result<()> {
  // 0) Persist group intent BEFORE network
  self.ledger.append_group_intent(&group)?;

  // 1) Dispatch legs concurrently as IOC limits (never market)
  let futs = group.legs.iter().map(|leg| self.dispatch_ioc_limit(leg));
  let mut results: Vec<LegResult> = join_all(futs).await;

  // 2) Classify outcomes (qty-aware)
  let filled_qtys: Vec<f64> = results.iter().map(|r| r.filled_qty).collect();
  let max_f = filled_qtys.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
  let min_f = filled_qtys.iter().cloned().fold(f64::INFINITY, f64::min);
  let any_partial = results.iter().any(|r| r.filled_qty > 0.0 && r.filled_qty < r.requested_qty);

  // New rule: partials are common; treat mismatch as atomicity break
  let group_fill_mismatch = max_f - min_f;
  let epsilon = self.cfg.atomic_qty_epsilon;

  // 3) Atomicity broken ⇒ enter MixedFailed and run Containment
  if any_partial || group_fill_mismatch > epsilon {
    self.ledger.mark_group_state(group.group_id, GroupState::MixedFailed)?;

    // Containment Step A: bounded rescue (ONLY to remove naked risk)
    // Try up to 2 IOC rescue orders for the missing qty, at cross_spread_by_ticks(2),
    // but ONLY if Liquidity Gate passes AND NetEdge remains ≥ min_edge.
    for _attempt in 0..2 {
      if !self.liquidity_gate_passes(&group)? { break; }
      if !self.net_edge_gate_passes(&group)? { break; }

      let rescue = self.build_rescue_intents(&group, &results, self.cross_spread_by_ticks(2))?;
      if rescue.is_empty() { break; }

      let rescue_results = self.dispatch_rescue_ioc(rescue).await?;
      results = self.merge_results(results, rescue_results);
      let filled_qtys2: Vec<f64> = results.iter().map(|r| r.filled_qty).collect();
      // Spec hardening: never seed min/max folds with 0.0 (pins wrong). Use ±INFINITY or iter::min/max.
      let max2 = filled_qtys2.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
      let min2 = filled_qtys2.iter().cloned().fold(f64::INFINITY, f64::min);
      if (max2 - min2) <= epsilon && !results.iter().any(|r| r.filled_qty > 0.0 && r.filled_qty < r.requested_qty) {
        // Containment succeeded: atomicity restored (or no-trade) and legs are terminal
        if self.is_group_safe_complete(&results, epsilon) {
          self.ledger.mark_group_state(group.group_id, GroupState::Complete)?;
          return Ok(());
        }
      }
    }

    // Containment Step B: bounded unwind using §3.1 Deterministic Emergency Close (single implementation).
    // Deterministically contain the group by closing ONLY the filled legs.
    // Hard rule: if option unwind fails after bounded attempts, delta-neutralize via reduce-only hedge per §3.1 fallback.
    let filled_legs = self.extract_filled_legs(group.group_id, &results)?;
    self.emergency_close_algorithm(group.group_id, filled_legs).await?; // MUST call the same implementation as §3.1
    return Err(Error::AtomicLeggingFailure);
  }

  // 4) Clean completion (terminal + no partial/mismatch)
  if self.is_group_safe_complete(&results, epsilon) {
    self.ledger.mark_group_state(group.group_id, GroupState::Complete)?;
    return Ok(());
  }

  // Defensive fallback: any mismatch here is naked risk
  self.ledger.mark_group_state(group.group_id, GroupState::MixedFailed)?;
  let filled_legs = self.extract_filled_legs(group.group_id, &results)?;
  self.emergency_close_algorithm(group.group_id, filled_legs).await?; // §3.1 bounded close + hedge fallback
  Err(Error::AtomicLeggingFailure)
}
```

**Acceptance Tests (must add):**
1) Simulate: Leg A filled, Leg B rejected. Expect: `GroupState::MixedFailed` then `Flattened`, and no new opens until exposure is neutral.
2) Simulate: Leg A fills `0.6`, Leg B fills `0.0`. Expect: **≤ 2** rescue IOC attempts, then deterministic flatten if still mismatched. Verify: no infinite chase loop.
3) Mixed-state (one leg filled, other rejected) triggers §3.1 flow: tries close up to 3 times, then opens delta hedge if still not delta-neutral, then halts (ReduceOnly).



### **1.2.2 Atomic Churn Circuit Breaker (Flatten Storm Guard)**
**Goal:** Prevent “death‑by‑fees” churn when a strategy repeatedly legs, partially fills, then emergency‑flattens.

**Rule (Deterministic):**
- Maintain a rolling counter keyed by `{strategy_id, structure_fingerprint}` where `structure_fingerprint` can be `(instrument_kind, tenor_bucket, delta_bucket, legs_signature)`.
- If `EmergencyFlattenGroup` triggers **> 2 times in 5 minutes** for the same key → **Blacklist** that key for **15 minutes**:
  - block new opens for that key (return `Rejected(ChurnBreakerActive)`),
  - allow closes/hedges (ReduceOnly) as normal.

**Where:** `soldier/core/risk/churn_breaker.rs`

**Acceptance Test:**
- Trigger 3 emergency flattens for the same key within 5 minutes → verify the 4th attempt is rejected and logged (`ChurnBreakerTrip`), with blacklist TTL enforced.

### **1.3 Pre-Trade Liquidity Gate (Do Not Sweep the Book)**

**Council Weakness Covered:** No Liquidity Gate (Low) \+ Taker Bleed (Critical). **Requirement:** Before any order is sent (including IOC), the Soldier must estimate book impact for the requested size and reject trades that exceed max slippage. **Where:** `soldier/core/execution/gate.rs` **Input:** `OrderQty`, `L2BookSnapshot`, `MaxSlippageBps`

**Output:** `Allowed | Rejected(reason=ExpectedSlippageTooHigh)`

**Algorithm (Deterministic):**

1. Walk the L2 book on the correct side (asks for buy, bids for sell).  
2. Compute the Weighted Avg Price (WAP) for `OrderQty`.  
3. Compute expected slippage: `slippage_bps = (WAP - BestPrice) / BestPrice * 10_000` (sign adjusted)  
4. Reject if `slippage_bps > MaxSlippageBps`.  
5. If rejected, log `LiquidityGateReject` with computed WAP \+ slippage.

**Acceptance Test (Reject Sweeping):**
- Given an L2 book where `OrderQty` requires consuming multiple levels causing `slippage_bps > MaxSlippageBps`,
- Expect: `Rejected(ExpectedSlippageTooHigh)`, and a `LiquidityGateReject` log with WAP + slippage.
- Verify: no `OrderIntent` is emitted (i.e., pricer/NetEdge gate never runs).



### **1.4 Fee-Aware IOC Limit Pricer (No Market Orders)**
**Council Weakness Covered:** Taker Bleed (Critical) + Fee Blindness (High)

**Where:** `soldier/core/execution/pricer.rs`  
**Input:** `fair_price`, `gross_edge_usd`, `min_edge_usd`, `fee_estimate_usd`, `qty`, `side`  
**Output:** `limit_price`

**Rule:**
- `net_edge = gross_edge - fees`
- If `net_edge < min_edge` ⇒ reject.
- `net_edge_per_unit = net_edge / qty`
- Compute per-unit bounds:
  - `fee_per_unit = fee_estimate_usd / qty`
  - `min_edge_per_unit = min_edge_usd / qty`
  - `max_price_for_min_edge`:
    - BUY: `fair_price - (min_edge_per_unit + fee_per_unit)`
    - SELL: `fair_price + (min_edge_per_unit + fee_per_unit)`
- Proposed limit from fill aggressiveness:  
  `proposed_limit = fair_price ± 0.5 * net_edge_per_unit` (sign depends on buy/sell)
- Final limit **clamped** to guarantee min edge at the limit price:
  - BUY: `limit_price = min(proposed_limit, max_price_for_min_edge)`
  - SELL: `limit_price = max(proposed_limit, max_price_for_min_edge)`
- If IOC returns unfilled/partial: **do not chase**. The missed trade is the cost of not dying.

**Test:**
- Force spread widen. Ensure system never fills worse than `limit_price` and that `Realized Edge >= Min_Edge` at the limit price.


### **1.4.1 Net Edge Gate (Fees + Expected Slippage)**
**Why this exists:** Prevent “gross edge” hallucinations from bypassing execution safety.

**Where:** `soldier/core/execution/gates.rs`  
**Input:** `gross_edge_usd`, `fee_usd`, `expected_slippage_usd`, `min_edge_usd`  
**Output:** `Allowed | Rejected(reason=NetEdgeTooLow)`

**Rule (Non-Negotiable):**
- `net_edge_usd = gross_edge_usd - fee_usd - expected_slippage_usd`
- Reject if `net_edge_usd < min_edge_usd`.

**Hard Rule:**
- This gate MUST run **before** any `OrderIntent` is eligible for dispatch (before AtomicGroup creation).


### **1.4.2 Inventory Skew Gate (Execution Bias vs Current Exposure)**
**Why this exists:** Prevent “good trades” from compounding the *wrong* inventory when already near limits.

**Input:** `current_delta`, `delta_limit`, `side`, `min_edge_usd`, `limit_price`, `fair_price`  
**Output:** `Allowed | Rejected(reason=InventorySkew)` and **adjusted** `{min_edge_usd, limit_price}`

**Rule:**
- `inventory_bias = clamp(current_delta / delta_limit, -1, +1)`  
  (positive = already long delta; negative = already short delta)

**Biasing behavior (deterministic):**
- **BUY intents when `inventory_bias > 0` (already long):**
  - Require higher edge: `min_edge_usd := min_edge_usd * (1 + k * inventory_bias)`
  - Be less aggressive: shift `limit_price` **away** from the touch by `bias_ticks(inventory_bias)`
- **SELL intents when `inventory_bias > 0` (already long):**
  - Allow slightly lower edge (within bounds) and/or be more aggressive to **flatten** inventory
- Mirror the above for `inventory_bias < 0` (already short).

**Hard Rule:**
- Inventory Skew runs **after** Net Edge Gate and **before** pricer dispatch. It may *tighten* requirements for risk-increasing trades and *loosen* requirements only for risk-reducing trades.
- Inventory Skew must be computed using **current + pending** exposure, or it must run **after** PendingExposure reservation (see §1.4.2.1). This prevents concurrent risk-budget double-spend.

**Acceptance Test:**
- Set `current_delta ≈ 0.9 * delta_limit` (near limit).
- A BUY intent that previously passed Net Edge now **rejects** (InventorySkew).
- A SELL intent for the same instrument still **passes** (risk-reducing).

### **1.4.2.1 PendingExposure Reservation (Anti Over‑Fill)**
**Why:** Without reservation, multiple concurrent signals can all observe the same “free delta” and over‑allocate risk.

**Requirement:** Before dispatching any new `AtomicGroup`, the Soldier must **reserve** the projected exposure impact of the intent, atomically, against a shared budget.

**Where:** `soldier/core/risk/pending_exposure.rs`

**Model (Minimum Viable):**
- Maintain `pending_delta` (and optionally pending vega/gamma) per instrument + global.
- For each candidate group:
  1. Compute `delta_impact_est` from proposal greeks (or worst‑case delta bound).
  2. Attempt `reserve(delta_impact_est)`:
     - If reservation would breach limits → reject the intent.
  3. On terminal outcome:
     - Filled → release reservation and convert to realized exposure.
     - Rejected/Canceled/Failed → release reservation.

**Hard Rule:** Reservation must occur **before** any network dispatch; release must be triggered from TLSM terminal transitions.

**Acceptance Test:**
- Fire 5 concurrent opens with identical pre‑trade `current_delta=0`. Verify only the subset that fits the budget reserves; the rest reject, and no over‑fill occurs.

### **1.4.2.2 Global Exposure Budget (Cross‑Instrument, Correlation‑Aware)**
**Goal:** Prevent “safe per‑instrument” trades from stacking into unsafe portfolio exposure.

**Where:** `soldier/core/risk/exposure_budget.rs`

**Budget Model (Pragmatic MVP):**
- Track exposures per instrument and portfolio aggregate:
  - `delta_usd` (required), `vega_usd` (optional v1), `gamma_usd` (optional v1).
- Portfolio aggregation uses conservative correlation buckets:
  - `corr(BTC,ETH)=0.8`, `corr(BTC,alts)=0.6`, `corr(ETH,alts)=0.6`.
- Gate new opens if portfolio exposure breaches limits even if single‑instrument gates pass.

**Integration Rule:** The Global Budget must be checked using **current + pending** exposure (see §1.4.2.1).

**Acceptance Test:**
- With BTC and ETH both near limits, a new BTC trade that passes local delta gate must still reject if portfolio budget would breach after correlation adjustment.

### **1.4.3 Margin Headroom Gate (Liquidation Shield) — MUST implement**

**Why this exists:** Delta-neutral ≠ safe. Deribit can hike maintenance margin; margin liquidation is the silent killer.

**Where:**
- Gate: `soldier/core/risk/margin_gate.rs`
- Fetcher: `soldier/infra/deribit/account_summary.rs`

**Inputs:** `/private/get_account_summary` → `maintenance_margin`, `initial_margin`, `equity`  
**Computed:** `mm_util = maintenance_margin / max(equity, epsilon)`

**Rules (deterministic):**
- If `mm_util >= 0.70` → **Reject** any **NEW opens**
- If `mm_util >= 0.85` → Force `TradingMode = ReduceOnly` (override Python)
- If `mm_util >= 0.95` → Force `TradingMode = Kill` + trigger deterministic emergency flatten (existing §3.1/§1.2 containment applies)

**Acceptance Test:**
- Mock `equity=100k`, `maintenance_margin=72k` → opens rejected.
- Mock `maintenance_margin=90k` → ReduceOnly forced.

### **1.4.4 Deribit Order-Type Preflight Guard (Artifact-Backed)**

**Purpose:** Freeze the engine against *verified* Deribit behavior and prevent “market order roulette.”

**Preflight Rules (MUST implement):**

**A) Options (`instrument_kind == option`)**
- Allowed `type`: **`limit` only**
- **Market orders:** forbidden by policy (F-01b)  
  - If `type == market` → **REJECT** (no rewrite/normalization).
- **Stop orders:** forbidden (F-01a)  
  - Reject any `type in {stop_market, stop_limit}` or any presence of `trigger` / `trigger_price`.
- **Linked/OCO orders:** forbidden (F-08)  
  - Reject any non-null `linked_order_type`.
- Execution policy: use **Aggressive IOC Limit** with bounded `limit_price_q` (see §1.4.1).

**B) Futures/Perps (`instrument_kind in {linear_future, inverse_future, perpetual}`)**
- Allowed `type`: **`limit` only** (policy forbids market orders even if the venue allows them).
- **Market orders:** forbidden by policy  
  - If `type == market` → **REJECT** (no rewrite/normalization).
- **Stop orders require trigger** (F-09)  
  - If `type in {stop_market, stop_limit}` → `trigger` is **mandatory** and must be one of Deribit-allowed triggers (e.g., index/mark/last).
- **Linked/OCO orders:** forbidden unless explicitly certified (F-08 currently indicates NOT SUPPORTED)  
  - Reject any non-null `linked_order_type` unless `linked_orders_supported == true` **and** feature flag `ENABLE_LINKED_ORDERS_FOR_BOT == true`.

**C) Post-only behavior**
- If `post_only == true` and order would cross the book, Deribit rejects (F-06).  
  - Preflight must ensure post-only prices are non-crossing (or disable post_only).

**Enforcement points (code):**
- Centralize in a single function called by the trade dispatch path (`private/buy` + `private/sell`) before any API call.
- Violations must be **hard rejects** (do not “try anyway”).

**Regression tests (MUST):**
- `options_market_order_is_rejected`
- `perp_market_order_is_rejected`
- `options_stop_order_is_rejected_preflight`
- `linked_orders_oco_is_gated_off`
- `perp_stop_requires_trigger`


### **1.5 Position-Aware Execution Sequencer (Council D3)**
**Goal:** Prevent creating *new* naked risk while repairing, hedging, or closing.

**Where:** `soldier/core/execution/sequencer.rs`  
**Input:** `intent_kind(Open|Close|Repair)`, `current_positions`, `desired_legs`, `risk_limits`  
**Output:** An ordered list of **ExecutionSteps** with enforced prerequisites (confirmations).

**Deterministic Sequencing Rules:**
1. **Closing (Reduce-Only):** `Close -> Confirm -> Hedge (reduce-only)`
   - Place reduce-only closes first.
   - Do **not** open hedges until the close step has a terminal confirmation (Filled/Canceled/Failed) and residual exposure is computed.
2. **Opening:** `Open -> Confirm -> Hedge`
   - Place opening legs first (AtomicGroup allowed).
   - Hedge only after opens reach terminal confirmation (Filled/Failed/Canceled) and exposure is measured.
3. **Repairs (Mixed Failed / Zombies):**
   - **Flatten filled legs first** using the §3.1 Emergency Close implementation (`emergency_close_algorithm`).
   - Hedge **only if** flatten retries fail and exposure remains above limit (fallback reduce-only hedge).

**Invariant:**  
- No step may increase exposure while `RiskState != Healthy` or while a prior step is unresolved.



---


## **2\. State Management: The Panic-Free Soldier**

### **2.1 Trade Lifecycle State Machine (TLSM)**

**Requirement**: Never panic. Handle real-world messiness (e.g., receiving a Fill message before the Acknowledgement message).

**Where:** `soldier/core/execution/state.rs`

**States:** `Created -> Sent -> Acked -> PartiallyFilled -> Filled | Canceled | Failed`

**Hard Rules:**
- Never panic on out-of-order WS events.
- “Fill-before-Ack” is valid reality: accept fill, log anomaly, reconcile later.
- Every transition is appended to WAL immediately.

**Acceptance Test:**
- Feed event order: Fill arrives before Ack. Expect: final state Filled, no crash, WAL contains both events.


### **2.2 PolicyGuard (Single Authoritative TradingMode Resolver)**
**Goal:** Eliminate conflicting “mode sources” and prevent stale/late policy pushes from re‑enabling risk.

**Where:** `soldier/core/policy/guard.rs`

**Inputs:**
- `python_policy` (latest policy payload)
- `python_policy_generated_ts_ms` (timestamp from Commander when policy was computed)
- `watchdog_last_heartbeat_ts_ms`
- `cortex_override` (from §2.3)
- `exchange_health_state` (from §2.3.1)
- `f1_cert` (from `artifacts/F1_CERT.json`: `{status, generated_ts_ms}`)
- `fee_model_cache_age_s` (from §4.2)
- `risk_state` (Healthy | Degraded | Maintenance | Kill)


#### **2.2.1 Runtime F1 Certification Gate (HARD, runtime enforcement)**
- PolicyGuard MUST read `artifacts/F1_CERT.json`.
- Freshness window: default 24h (configurable). If missing OR stale OR FAIL => TradingMode MUST be ReduceOnly.
- While in ReduceOnly due to F1 failure: allow only closes/hedges/cancels; block all opens.
- This rule is strict: no caching last-known-good and no grace periods.


#### **2.2.2 EvidenceGuard (No Evidence → No Opens) — HARD RUNTIME INVARIANT**

**Purpose (TOC constraint relief):** Close the missing enforcement link: if the evidence chain is not green, the system MUST NOT open new risk. “Nice architecture” is meaningless unless it is unbreakable in production.

**Definition (Evidence Chain = required artifacts):**
The following MUST be writable + joinable for every dispatched open-intent:
- WAL intent entry (durable)
- TruthCapsule (with decision_snapshot_id)
- Decision Snapshot payload (L2 top-N at decision time)
- Attribution row for fills (fees/slippage/net pnl)

**Invariant (Non-Negotiable):**
- If Evidence Chain is not GREEN → **block ALL new OPEN intents**.
- CLOSE / HEDGE / CANCEL intents are still allowed (risk-reducing).
- EvidenceGuard triggers `RiskState::Degraded` and forces `TradingMode::ReduceOnly` until GREEN recovers AND remains stable for a cooldown window.

**GREEN/RED criteria (minimum):**
EvidenceChainState = GREEN iff ALL are true (rolling window, e.g. last 60s):
- `truth_capsule_write_errors == 0`
- `decision_snapshot_write_errors == 0`
- `parquet_queue_overflow_count` not increasing
- `wal_write_errors == 0` (if present)
- `snapshot_coverage_pct` not dropping (for replay window; still enforced in §5.2)

**Where enforced (must be explicit):**
- PolicyGuard `get_effective_mode()` MUST include EvidenceGuard in precedence.
- Hot-path execution gate MUST check EvidenceChainState before dispatching OPEN orders.

**Acceptance Tests (REQUIRED):**
1) If Decision Snapshot writer fails (simulate write error) → OPEN intents blocked; CLOSE intents allowed.
2) If TruthCapsule writes fail → OPEN intents blocked; system enters ReduceOnly within 1 cycle.
3) Recovery: when errors stop, system remains ReduceOnly for cooldown (e.g., 120s) then may return to Active.

**Hard Rule:** The Soldier never “stores” TradingMode as authoritative state. It recomputes it every loop tick via `PolicyGuard.get_effective_mode()`.

**Precedence (Highest → Lowest):**
1. `TradingMode::Kill` if any:
   - watchdog heartbeat stale (`now - watchdog_last_heartbeat > watchdog_kill_s`)
   - `risk_state == Kill`
2. `TradingMode::ReduceOnly` if any:
   - `risk_state == Maintenance` (maintenance window)
   - `bunker_mode_active == true` (Network Jitter Monitor; see §2.3.2)
   - `F1_CERT` missing OR stale OR FAIL (runtime gate; see §2.2.1)
   - EvidenceChainState != GREEN (EvidenceGuard; see §2.2.2)
   - `cortex_override == ForceReduceOnly`
   - fee model stale beyond hard limit (see §4.2)
   - `risk_state == Degraded` (optional: degrade may map to ReduceOnly)
3. `TradingMode::Active` only if:
   - `risk_state == Healthy`, and
   - policy staleness is within limits, and
   - no override is active.

**Policy Staleness Rule (Anti “late update” bug):**
- Compute staleness using Commander time, not local receive time:
  - `policy_age_s = now - python_policy_generated_ts_ms`
- If `policy_age_s > max_policy_age_s` → force ReduceOnly (even if an old update arrives late).

**Watchdog Semantics (Single Source):**
- Watchdog triggers reduce-only via `POST /api/v1/emergency/reduce_only`.
- PolicyGuard enforces that reduce-only persists until cooldown expiry and reconciliation confirms exposure is safe.

**Acceptance Tests:**
1) **Late Policy Update:** receive a delayed policy update with old `python_policy_generated_ts_ms` → effective mode stays ReduceOnly.
2) **Override Priority:** maintenance window active → effective mode ReduceOnly even if python_policy says Active.
3) **Heartbeat Kill:** watchdog heartbeat stops → effective mode Kill within one loop tick.
4) **F1_CERT Missing:** `artifacts/F1_CERT.json` missing → effective mode ReduceOnly; any OPEN intent is rejected/blocked.
5) **F1_CERT FAIL:** `artifacts/F1_CERT.json.status == FAIL` → effective mode ReduceOnly; any OPEN intent is rejected/blocked.
6) **F1_CERT Stale:** `now - F1_CERT.generated_ts_ms > f1_cert_max_age_s` → effective mode ReduceOnly; any OPEN intent is rejected/blocked.

### 2.3 Reflexive Cortex (Hot-Loop Safety Override)

**Where:** `soldier/core/reflex/cortex.rs`

**Inputs:** `MarketData(dvol, spread_bps, depth_topN, last_1m_return, ws_gap_flag)`  
**Output:** `SafetyOverride::{None, ForceReduceOnly{cooldown_s}, ForceKill}`

**Why this exists:** Policy staleness is one problem; volatility shock and microstructure collapse are a different one. The Cortex runs in Rust *inside the hot loop* and can override Python even when Python is “alive” but slow.

**Rules (deterministic):**
- If **DVOL jumps ≥ +10% within ≤ 60s** → `ForceReduceOnly{cooldown_s=300}`
- If `spread_bps > spread_max_bps` **OR** `depth_topN < depth_min` → `ForceReduceOnly{cooldown_s=120}`
- If `ws_gap_flag == true`: opens are already frozen, but Cortex must also block any **risk-increasing cancels/replaces**.

**Behavior when override is active:**
- `EffectivePolicy.mode = ReduceOnly`
- Cancel **only** non-reduce-only opens; keep closes/hedges alive.
- Reject any `Cancel/Replace` that increases exposure while `ws_gap_flag == true`.

**Acceptance Test:**
- Feed `MarketData` where DVOL jumps by +10% in one minute.
- Expect: opens are blocked and mode flips to `ReduceOnly` within one loop tick.

### **2.3.1 Exchange Health Monitor (Maintenance Mode Override) — MUST implement**

**Why this exists:** You don’t trade into a known exchange outage window. Maintenance is a separate risk state from “Python is alive.”

**Rules:**
- Poll `/public/get_announcements` every **60s**
- If a maintenance window start is ≤ **60 minutes** away:
  - Set `RiskState::Maintenance`
  - Force `TradingMode = ReduceOnly`
  - Block all **new opens** even if NetEdge is positive
  - Allow closes/hedges (reduce-only)

**Where:** `soldier/core/risk/exchange_health.rs`

**Acceptance Test:**
- Mock announcement with maintenance starting in 30m → opens blocked, closes allowed.


#### **2.3.2 Network Jitter Monitor (Bunker Mode Override)**

**Purpose:** VPS tail latency is a first-class risk driver. If network jitter spikes, “cancel/replace/repair” becomes unreliable, increasing legging tail risk. Bunker Mode reduces exposure by blocking new risk until comms stabilize.

**Inputs (export as metrics):**
- `deribit_http_p95_ms` over last 30s
- `ws_event_lag_ms` (now - last_ws_msg_ts)
- `request_timeout_rate` over last 60s

**Rules (Non-Negotiable):**
- If `deribit_http_p95_ms > 750ms` for 3 consecutive windows OR `ws_event_lag_ms > 2000ms` OR `request_timeout_rate > 2%`:
  - Force `TradingMode::ReduceOnly` (Bunker Mode)
  - Block OPEN intents
  - Allow CLOSE/HEDGE/CANCEL
- Exit Bunker Mode only after all metrics are below thresholds for a stable period (e.g., 120s).

**Acceptance Tests (REQUIRED):**
1) Simulate ws_event_lag_ms breach → OPEN intents blocked; CLOSE allowed.
2) Simulate recovery → remains ReduceOnly during cooldown then returns to normal.

### **2.4 Durable Intent Ledger (WAL Truth Source)**

**Council Weakness Covered:** TLSM duplication \+ messy middle \+ restart correctness. **Requirement:** Redis is not a source of truth. All intents \+ state transitions must be persisted to a crash-safe local WAL (Sled or SQLite). **Where:** `soldier/infra/store/ledger.rs` **Rules:**

* Write intent record BEFORE network dispatch.  
* Write every TLSM transition immediately (append-only).  
* On startup, replay ledger into in-memory state and reconcile with exchange.

**Persistence levels (latency-aware):**
- **RecordedBeforeDispatch:** intent is recorded (e.g., in-memory WAL buffer) before dispatch.
- **DurableBeforeDispatch:** durability barrier reached (fsync marker or equivalent) before dispatch.

**Dispatch rule:** RecordedBeforeDispatch is **mandatory**. DurableBeforeDispatch is required when the
durability barrier is configured/required by the subsystem.

**Persisted Record (Minimum):**
- intent_hash, group_id, leg_idx, instrument, side, qty, limit_price
- tls_state, created_ts, sent_ts, ack_ts, last_fill_ts
- exchange_order_id (if known), last_trade_id (if known)

**Acceptance Tests:**
1) Crash after send, before ACK → restart must NOT resend; must reconcile and proceed.
2) Crash after fill, before local update → restart must detect fill from exchange trades and update TLSM + trigger sequencer.


**Trade-ID Idempotency Registry (Ghost-Race Hardening) — MUST implement:**
- Persist a set/table: `processed_trade_ids`
- Record mapping: `trade_id -> {group_id, leg_idx, ts, qty, price}`

**WS Fill Handler rule (idempotent):**
1) On trade/fill event: if `trade_id` already in WAL → **NOOP**
2) Else: append `trade_id` to WAL **first**, then apply TLSM/positions/attribution updates.

**Acceptance Tests (Ghost Race):**
- Simulate: order fills during WS disconnect; on reconnect, Sweeper runs before WS replay:
  - Sweeper finds trade via REST → updates ledger
  - Later WS trade arrives → ignored due to `processed_trade_ids`
- Simulate duplicate WS trade event → second one ignored.

---

## **3\. Safety & Recovery**

### **3.1 Deterministic Emergency Close**

**Requirement**: When an atomic group fails, we must exit the position *immediately* and *safely*.

**Where:** `soldier/core/execution/emergency_close.rs`

**Algorithm (Deterministic, 3 tries):**
1. Attempt **IOC limit close** at `best ± close_buffer`.
2. If partial fill: repeat for remaining qty (max 3 loops, exponential buffer).
3. If still exposed after retries: submit **reduce-only perp hedge** to neutralize delta (bounded size).
4. Log `AtomicNakedEvent` with group_id + exposure + time-to-delta-neutral.

**Test:**
- Inject: one leg filled, book thins. Expect: close attempts then fallback hedge; exposure goes to ~0.


### **3.2 Smart Watchdog**

**Goal:** Watchdog must not cancel hedges/closing orders.

**Protocol:**
- Watchdog triggers on silence > 5s → calls `POST /api/v1/emergency/reduce_only`.

**Soldier behavior on reduce_only:**
1. Force `TradingMode = ReduceOnly` immediately.
2. Cancel orders where `reduce_only == false`.
3. KEEP all reduce-only closing/hedging orders alive.
4. If exposure breaches limit: submit emergency reduce-only hedge.

**Test:**
- Simulate network hiccup mid-hedge. Watchdog triggers. Verify hedge stays alive.




### **3.3 Local Rate Limit Circuit Breaker (Deribit Credits + 429/10028 Survival)**

**Council Weakness Covered:** Rate Limit Exhaustion (Medium) + Session Termination (High).

**Where:** `soldier/infra/api/rate_limit.rs`

**Deribit Reality (MUST implement):**
- Deribit uses a **credit-based / tiered** limit system. Limits are **dynamic per account/subaccount**.
- When credits are depleted, Deribit can respond with `too_many_requests` (`code 10028`) and **terminate the session**.

**Limit Source of Truth (Runtime):**
- On startup and periodically (e.g., every 60s), call `/private/get_account_summary` and read the `limits.matching_engine` groups (rate + burst per group).
- Update the local limiter parameters at runtime:
  - `tokens_per_sec = rate`
  - `burst = burst`
- Keep conservative defaults if the endpoint is unavailable, but treat repeated inability to fetch limits as `RiskState::Degraded`.

**Limiter Model (Local):**
- Token bucket (parameterized by the account’s current credits/rate), not hardcoded.
- **Priority Queue (Preemption):** emergency_close, reduce-only hedges, and cancels preempt data refresh tasks.

**Brownout Controller (Pressure Shedding — MUST implement):**
- Classify every request into one of: `EMERGENCY_CLOSE`, `CANCEL`, `HEDGE`, `OPEN`, `DATA`.
- Under limiter pressure OR a 429 burst:
  - shed `DATA` first (skip noncritical refreshes)
  - block `OPEN` next (treat as ReduceOnly)
  - preserve `CANCEL`/`HEDGE`/`EMERGENCY_CLOSE`
- On `too_many_requests` / `code 10028` (maintenance/session termination):
  - Immediately block `OPEN`
  - Enter ReduceOnly or Kill per existing strict safety rules
  - Reconnect/backoff and run full reconcile before any trading resumes

**Hard Rules:**
1. If bucket empty: wait required time (async sleep). Never panic.
2. On observed 429: enter `RiskState::Degraded`, slow loops automatically, and reduce non-critical traffic.
3. On `too_many_requests` / `code 10028` OR “session terminated”:
   - Set `RiskState::Degraded` and `TradingMode = Kill` immediately (no opens, no replaces).
   - Exponential backoff, then **reconnect**.
   - Run **3-way reconciliation** (orders + trades + positions + ledger).
   - Resume only when stable (`RiskState::Healthy`) and Cortex override is None.

**Acceptance Tests:**
1) **Throughput + Priority Preemption:**
   - Configure bucket at `T tokens/sec` and `burst=B`.
   - Fire 100 mixed requests: data refresh + hedges + cancels.
   - Expect:
     1) Aggregate throughput never exceeds `T` and burst never exceeds `B`.
     2) Hedges/cancels are serviced **before** data refresh under contention.
2) **Brownout Under Pressure (Token Exhaustion):**
   - Exhaust the token bucket using `DATA` requests.
   - Then submit `OPEN`, `CANCEL`, `HEDGE`, `EMERGENCY_CLOSE`.
   - Expect: `DATA` is shed first; `OPEN` is blocked; `CANCEL`/`HEDGE`/`EMERGENCY_CLOSE` continue to be serviced.
3) **10028 Session Termination / Maintenance:**
   - Simulate API returning `too_many_requests` (`code 10028`) mid-run.
   - Expect: `OPEN` blocked immediately; `TradingMode=Kill` + Degraded immediately → reconnect with backoff → full reconcile → resume only after stable.

### **3.4 Continuous 3-Way Reconciliation (Partials \+ WS Gaps \+ Zombies)**

**Council Weakness Covered:** Missing TLSM lifecycle handling \+ messy middle (partials, sequence gaps, zombie states). **Authoritative Sources (in order):**

1. Exchange Trades/Fills (truth of what executed)  
2. Exchange Orders (truth of what is open)  
3. Exchange Positions (truth of exposure)  
4. Local Ledger (intent/state history)

**WS Continuity & Gap Handling (Channel-Specific, Deterministic) — MUST implement:**

> **Non-negotiable principle:** There is **no single global WS sequence** you can trust across all streams. Continuity rules are **per channel**, and recovery always flows through **REST snapshots + reconciliation**.

**A) Order Book feeds (`book.*`) — changeId/prevChangeId continuity (per instrument):**
- Track `last_change_id[instrument]`.
- On each incremental event:
  - If `prevChangeId == last_change_id[instrument]`: accept; set `last_change_id = changeId`.
  - Else (mismatch/gap):
    1) Set `RiskState::Degraded` and **pause opens**.
    2) **Resubscribe** to the book channel for that instrument.
    3) Fetch a **full REST snapshot** for the instrument and rebuild the book.
    4) Run reconciliation, then only resume trading when `RiskState::Healthy`.

**B) Trades feeds (`trades.*`) — trade_seq continuity (per instrument):**
- Track `last_trade_seq[instrument]`.
- On each trade:
  - If `trade_seq == last_trade_seq + 1` (or strictly increasing where the feed batches): accept; update.
  - Else (gap or non-monotonic):
    1) Set `RiskState::Degraded` and **pause opens**.
    2) Pull recent trades via REST for that instrument and reconcile to the ledger.
    3) Resume only when reconciliation confirms no missing fills.

**C) Private orders/positions/portfolio streams — no “global monotonic seq”:**
- Do **not** invent a `last_seq` for private state.
- Use:
  - **heartbeat / ping** to detect liveness
  - WS disconnect / session termination detection
- On disconnect OR session-level errors:
  1) Set `RiskState::Degraded` and **pause opens**.
  2) Force REST snapshot reconciliation (open orders + positions + recent trades).
  3) Resume only after reconciliation passes.

**Safety rule during Degraded:** allow reduce-only closes/hedges to proceed; block any risk-increasing cancels/replaces/opens.

**Acceptance Tests (WS Continuity):**
1) **Orderbook continuity break:** feed an incremental book update where `prevChangeId != last_changeId`.  
   Expect: immediate Degraded → resubscribe + full snapshot rebuild → opens remain paused until rebuild completes.
2) **Trades continuity break:** feed trades with `trade_seq` jumping (gap) for an instrument.  
   Expect: Degraded → REST trade pull + reconcile → no duplicate processing; only then resume.


**Triggers:**
- startup
- timer every 5–10s
- WS gap event
- orphan fill event (fill/trade seen with no local Sent/Ack)

**CorrectiveActions (must enumerate):**
- CancelStaleOrder(order_id)
- ReplaceIOC(intent_hash, new_limit_price)
- EmergencyFlattenGroup(group_id)
- ReduceOnlyDeltaHedge(target_delta=0, max_size=cap)

**Acceptance Test (Orphan Fill):**
- Simulate: local state = Sent, exchange trades show Filled, ACK missing.
- Expect: TLSM transitions to Filled (panic-free), no duplicate order, sequencer runs hedge/close as needed.


 **Mixed-State Rule:**  
* If AtomicGroup has mixed leg outcomes (filled \+ rejected/none), issue immediate flatten NOW (runtime) and also during startup reconciliation.

---


### **3.5 Zombie Sweeper (Ghost Orders & Forgotten Intents)**

**Cadence:** Every 10s (independent of WS)  
**Inputs (authoritative):** `REST get_open_orders`, `REST get_user_trades`, `ledger inflight intents`

**Corrective rules (deterministic):**
- If an exchange open order has label `s4:` but **no matching ledger intent** → `CancelStaleOrder` + log `GhostOrderCanceled`.
- Before marking `Sent|Acked` as `Failed` due to “no open order”:
  1) Query `get_user_trades` filtered by `{label_prefix=s4:, instrument, last N minutes}`
  2) If a trade exists → transition TLSM to `Filled|PartiallyFilled` accordingly (panic-free), update WAL, and run sequencer as needed.
  3) Only if **no open order AND no trade** → mark `Failed` and unblock sequencer.
- If open order age `> stale_order_sec` and `reduce_only == false`:
  - cancel
  - optionally replace **only if** `RiskState == Healthy` (never replace while Degraded).

**Acceptance Test:**
- Simulate: order fills during WS disconnect; on reconnect, Sweeper runs before WS replay.
- Expect: Sweeper finds trade via REST → updates ledger; later WS trade is ignored via `processed_trade_ids`.


## **4\. Quantitative Logic: The "Truth" Engine**

### **4.1 SVI Stability Gates**

**Gate 0 (Liquidity-Aware Thresholds):**
SVI behavior must adapt to liquidity conditions. If `depth_topN < depth_min` (same metric used by Liquidity Gate / Cortex):
- Drift threshold: **20% → 40%**
- RMSE gate: **0.05 → 0.08**
Still enforce **SVI Math Guard** and **Arb-Guards** (those do NOT loosen).

**Gate 1 (RMSE):**
- If `rmse > rmse_max` → reject calibration.
- Where `rmse_max = 0.05` (healthy depth) or `0.08` (low depth per Gate 0).

**Gate 2 (Parameter Drift):**
- If params move > `drift_max` vs last valid fit in one tick → reject new fit and hold previous params.
- Where `drift_max = 0.20` (healthy depth) or `0.40` (low depth per Gate 0).
**Action:** set `RiskState::Degraded` if drift repeats N times in M minutes.

**SVI Math Guard (Hard NaN / Blow-Up Shield):**
- If any fitted parameter is non-finite (`NaN` / `Inf`) → return `None` and hold last valid fit.
- If any derived implied vol is non-finite OR exceeds **500%** (`iv > 5.0`) → return `None`.
- On any guard trip: increment `svi_guard_trips`; if it repeats N times in M minutes → set `RiskState::Degraded`.

#### **4.1.1 SVI Arb-Guards (No-Arb Validity)**

**Why this exists:** RMSE/drift gates can pass while the curve is financially nonsense. We must reject **arbitrageable** surfaces.

**Where:** `soldier/core/quant/svi_arb.rs` (invoked from `validate_svi_fit(...)`)

**Guards (minimum viable):**
- **Butterfly convexity:** across a grid of strikes, call prices must be convex in strike  
  (second difference ≥ `-ε`).
- **Calendar monotonicity:** total variance should be non-decreasing with maturity for the same `k`  
  (allow small inversion ≤ `ε`).
- **No negative densities:** implied density proxy ≥ 0 across grid (within tolerance).

**Action:**
- If any arb-guard fails → invalidate fit, hold last valid, increment `svi_arb_guard_trips`.
- If repeats N times in M minutes → `RiskState::Degraded` and **pause opens**.

**Acceptance Test:**
- Feed a deliberately “wavy” fit that passes RMSE but violates convexity → must reject and hold previous.

#### **4.1.2 Liquidity-Aware Acceptance (Avoid Stale-Fit Paralysis)**

**Rule:**
- In low depth (`depth_topN < depth_min`), accept fits with `drift <= 30%` and `rmse <= 0.07` **as long as Arb-Guards pass**.

**Acceptance Test:**
- Low depth snapshot + `drift=30%` + `rmse=0.07` → accept fit.
- Same fit with arb violation → reject.

### **4.2 Fee-Aware Execution**

**Dynamic Fee Model:**
- Fee depends on instrument type (option/perp), maker/taker, and delivery proximity.
- `fee_usd = Σ(leg.notional_usd * (fee_rate + delivery_buffer))`

**Implementation:** `soldier/core/strategy/fees.rs`
- Provide `estimate_fees(legs, is_maker, is_near_expiry) -> fee_usd`

**Test:**
- Gross edge smaller than fees ⇒ trade rejected.

**Dynamic Fee Fetcher (Tier-Aware) — MUST implement:**
- Poll `/private/get_account_summary` every **5 minutes**
- Track `fee_model_cached_at_ts` (monotonic ms or unix ms).
- If `fee_model_cache_age_s > fee_cache_soft_s` (default 300s): apply conservative buffer  
  `fee_rate_effective = fee_rate * (1 + fee_stale_buffer)` (default `fee_stale_buffer = 0.20`).
- If `fee_model_cache_age_s > fee_cache_hard_s` (default 900s): set `RiskState::Degraded` and **force ReduceOnly** until refreshed.

**Acceptance Tests:**
1) With stale fee cache (age > soft limit), NetEdge gate rejects a trade that would have passed using unbuffered fees.
2) With stale fee cache (age > hard limit), opens are blocked and mode becomes ReduceOnly.

- Update fee tier / maker-taker rates used by:
  - §1.4.1 Net Edge Gate (fees component)
  - §1.4 Pricer (fee-aware edge checks)

**Acceptance Test:**
- If fee tier changes, NetEdge computation changes accordingly within one polling cycle.


### **4.3 Trade Attribution Schema (Realized Friction Truth)**

**Council Weakness Covered:** Self-improving open loop \+ time handling / drift. **Where:** `soldier/core/analytics/attribution.rs` **Requirement:** Every trade must log projected edge vs realized execution friction with timestamps to measure drift. **Key Fields:** `exchange_ts`, `local_send_ts`, `local_recv_ts`, `drift_ms = local_recv_ts - exchange_ts`. **Rules:**

* If `drift_ms` exceeds threshold, force ReduceOnly until time sync is restored.  
* Require **chrony/NTP** running as an operational prerequisite.

**Parquet Row (Minimum):**
- group_id, leg_idx, strategy_id
- truth_capsule_id
- fair_price_at_signal, limit_price_sent, fill_price
- slippage_bps (fill vs fair), fee_usd, gross_edge_usd, net_edge_usd
- exchange_ts, local_send_ts, local_recv_ts, drift_ms, rtt_ms



### **4.3.1 PnL Decomposition Fields (Theta/Delta/Vega/Fee Drag)**

**Why this exists:** Execution friction tells you *how* you traded (slippage/fees/time drift). Decomposition tells you *why* you made or lost money (edge vs luck vs costs).

**Add Parquet fields (minimum viable):**
- `delta_pnl_usd`, `theta_pnl_usd`, `vega_pnl_usd`, `gamma_pnl_usd` (optional)
- `fee_drag_usd`, `residual_pnl_usd`
- `spot_at_signal`, `spot_at_fill`, `iv_at_signal`, `iv_at_fill`, `dt_seconds`
- **Greeks (raw as provided by exchange) + normalized:**
  - `delta_raw`, `theta_raw`, `vega_raw` at signal (and at fill if available)
  - `theta_per_day`, `vega_per_1pct` (normalized interpretations used by our math)
  - `dt_days`, `dIV_pct` (inputs to the PnL approximation)

**Greek Units (MUST define and enforce):**
- `theta_per_day`: theta is treated as **per day**, so `theta_pnl = theta_per_day * dt_days`.
- `vega_per_1pct`: vega is treated as **per 1% IV change**, so `vega_pnl = vega_per_1pct * dIV_pct`.
- Always store:
  1) **raw greeks** as returned by Deribit
  2) **normalized greeks** you used in the calculation  
  This prevents “unit drift” bugs and lets you re-run attribution later.

**Note:** For very short DTE, theta semantics can be quirky; record both raw + normalized and let analytics handle edge cases.

**Python implementation:** `python/analytics/pnl_attribution.py`

**Compute (first-order approximations):**
- `dt_days = dt_seconds / 86400.0`
- `dIV_pct = (IV_fill - IV_signal) * 100.0`  (if IV is stored as fraction)
- `delta_pnl ≈ delta_raw * (S_fill - S_signal)`
- `theta_pnl ≈ theta_per_day * dt_days`
- `vega_pnl ≈ vega_per_1pct * dIV_pct`
- `fee_drag = fee_usd`
- `residual = realized_pnl - (delta_pnl + theta_pnl + vega_pnl + gamma_pnl) - fee_usd - slippage_cost`

**Acceptance Tests:**
1) If `S_fill == S_signal` and `IV_fill == IV_signal`, then `delta_pnl≈0` and `vega_pnl≈0`; residual must not explode.
2) Theta unit sanity: given `theta_per_day = -0.04` and `dt_seconds = 43200` (12h), expect `theta_pnl ≈ -0.02` (all else equal).


### **4.3.2 Truth Capsule (Decision Context Logger) — MUST implement**

**Goal:** Make every *realized* outcome explainable by the *inputs + gates + model state* that produced the order.
Without this, optimization is open-loop and you will “improve” the wrong knobs.

**Write timing (hard rule):**
- TruthCapsule MUST be recorded **before first dispatch** of any leg in an AtomicGroup (RecordedBeforeDispatch).
- TruthCapsule durability may be asynchronous by default; require a durability barrier only when explicitly configured.
- If TruthCapsule recording fails → block opens and enter `RiskState::Degraded` (ReduceOnly).

**Parquet Writer Isolation (Hot Loop Protection) + Fail‑Closed on Writer Errors:**
- Hot loop MUST enqueue TruthCapsule writes to a **bounded queue**; a dedicated writer thread/process drains and batches writes.
- Hot loop MUST NOT stall on disk I/O.
- If the queue overflows OR writer errors occur:
  - increment `parquet_write_errors` / `truth_capsule_write_errors`
  - enter `RiskState::Degraded` (ReduceOnly) until healthy.

**Identity:**
- `truth_capsule_id` = UUIDv4
- Keyed by: `group_id`, `intent_hash` (per-leg), `policy_hash`, `strategy_id`

**Storage:**
- Append-only Parquet table: `truth_capsules.parquet` (or JSONL if Parquet not ready), partitioned by `date` + `exchange`.
- Trade attribution rows add `truth_capsule_id` (foreign key).

**TruthCapsule fields (minimum viable):**
**Decision Snapshot (Decision-time L2 top‑N) — REQUIRED for replay validity:**
- Define “Decision Snapshot” as a compact L2 top‑N snapshot captured at decision time.
- Persist Decision Snapshots in an append-only store (e.g., `decision_snapshots.parquet` or JSONL), keyed by `decision_snapshot_id` and partitioned by date.
- On every trade decision that results in dispatch, the system MUST persist the Decision Snapshot and write `decision_snapshot_id` into the Truth Capsule / decision record.
- If Decision Snapshot persistence fails → treat as a TruthCapsule logging failure: block opens and enter `RiskState::Degraded` (ReduceOnly).
- If heavy tick/L2 stream archives are paused due to disk watermarks, Decision Snapshots MUST still be recorded (they are small and required).

- `truth_capsule_id`, `group_id`, `leg_idx`, `intent_hash`, `strategy_id`, `policy_hash`
- **Snapshot references:**
  - `decision_snapshot_id` (decision-time L2 top‑N; REQUIRED; aka `l2_snapshot_id`)
  - `snapshot_bundle_id` (optional: richer bundle if present)
  - `exchange_ts`, `local_ts`, `drift_ms`
- **Model state references:**
  - `svi_fit_id` (or `svi_params_hash`)
  - `svi_params` (a,b,rho,m,sigma) OR store hash + pointer
  - `greeks_source` = `deribit|svi|hybrid`
- **Pricing + edge components (the “why”):**
  - `fair_price_at_signal` (must match §4.3)
  - `gross_edge_usd_est`, `fee_usd_est`, `net_edge_usd_est`
  - `edge_components_json` (e.g., vrp/skew/regime terms if used)
- **Execution plan (the “how”):**
- `order_style` = `post_only|ioc_limit`
  - `limit_price_sent`, `max_requotes`, `rescue_ioc_max`, `order_age_cancel_ms`
- **Friction predictions (the “expected pain”):**
  - `predicted_slippage_bps_sim`, `predicted_slippage_usd_sim`
  - `predicted_fill_prob` (if modeled)
  - `spread_bps_at_signal`, `depth_topN_at_signal`
- **Gate decisions (the “permissioning”):**
  - `liquidity_gate_pass`, `net_edge_gate_pass`, `inventory_gate_pass`, `time_drift_gate_pass`
  - `gate_reject_reason` (enum/string)

**Acceptance Tests:**
1) Any dispatched order MUST have an existing `truth_capsule_id` linked by `(group_id, leg_idx, intent_hash)`.
2) If TruthCapsule write fails, opens are blocked and system enters ReduceOnly.
3) Under forced slow disk / slow writer, the hot loop does not block on TruthCapsule I/O (bounded queue); if backpressure occurs, system enters ReduceOnly rather than stalling.
4) If writer thread/process errors OR queue overflows, `truth_capsule_write_errors` increments and trading is forced to ReduceOnly until healthy.
3) Attribution row joins to TruthCapsule and reproduces `limit_price_sent`, `gross_edge_usd_est`, `predicted_slippage_bps_sim`.

### **4.4 Fill Simulator (Shadow Mode Book-Walk)**

**Council Weakness Covered:** Constraint relief — execution reality feedback loop. **Where:** `soldier/core/sim/exchange.rs` **Requirement:** Before live fire, run Shadow Mode that simulates fills by walking L2 depth and applying maker/taker fees. **Algorithm:**

* Walk the book to compute WAP for size.  
* Apply fee model.  
* Persist alongside real attribution logs for comparison.

**Schema Parity Rule:**
Shadow mode must write the SAME Parquet schema as live (§4.3) with `mode = shadow|live`.

**Acceptance Test:**
- Given a fixed L2 snapshot + order size, simulator must output deterministic WAP + slippage_bps.
- Verify: `slippage_bps(size=2x) > slippage_bps(size=1x)` on a thin book.


---

### **4.5 Slippage Calibration (Reality Sync)**

**Why this exists:** Replay + Shadow fills are useless if they assume “fantasy liquidity.” We must continuously measure **Sim vs Live** and penalize simulation optimism.

**Requirement:** For every **live fill**, compute:
- `predicted_slippage_bps_sim`: from **Fill Simulator** on the same L2 snapshot used at decision time.
- `realized_slippage_bps_live`: from attribution logs (fill vs fair/limit).

**Calibrate:** Maintain a rolling penalty:
- `realism_penalty_factor = clamp(p50(realized_slippage_bps_live / max(predicted_slippage_bps_sim, eps)), 1.0, 2.5)`
- Window: last **N fills** (default `N=200`)
- Bucket by: `strategy_id`, `instrument_type`, `liquidity_bucket` (use Liquidity Gate depth buckets)

**Enforce:** Replay Gatekeeper **MUST apply** this penalty (see §5.2).

**Where:**
- Python: `commander/analytics/slippage_calibration.py`
- Rust (optional): `soldier/core/analytics/slippage_calibration.rs`

**Data contract (minimum):**
- Persist `predicted_slippage_bps_sim` alongside each live decision so the ratio is well-defined.
- Persist the factor used in every policy proposal.

**Acceptance Test:**
- Create 50 synthetic fills where `realized = sim * 1.2`.
- Expect: `realism_penalty_factor → ~1.2` and stable (±0.05).
- If factor is missing/uninitialized → default factor = **1.3** and tighten opens (fail-safe).

## **5\. Self-Improvement: The Closed-Loop Control**

### **5.1 The Optimization Cycle (Python)**

A daily cron job ingests Parquet data to calculate realized friction and generate policy patches.

**Closed-Loop Rules (Example):**
1. If `avg_slippage_bps > target_bps` → increase `min_edge_usd` by 10%.
2. If `fill_rate < 5%` → decrease `limit_distance_bps` slightly.
3. If `atomic_naked_events > 0` → tighten max size + force ReduceOnly for cooldown window.

**Governor (Safety):**
- Clamp changes within bounds (e.g., min_edge_usd ∈ [X, Y]).
- Require “dry-run” mode first: logs patch, does not apply.

**Implementation:** `python/optimizer/closed_loop.py`


---


### **5.2 Replay Gatekeeper (48h Policy Regression Test)**

**Requirement:** No policy patch may be applied unless it passes replay simulation over the last 48h.

**Prereq (must implement):**
- **Decision Snapshots (required):** Every dispatched intent MUST reference a decision-time snapshot via `decision_snapshot_id` (see §4.3.2).
- Track `snapshot_coverage_pct` over the replay window (48h): `% of dispatched intents with a valid `decision_snapshot_id` AND snapshot payload available`.
- **Replay Required Inputs (Non-Negotiable):**
  - **Decision Snapshots are REQUIRED** for replay validity (see §4.3.3).
  - Replay Gatekeeper MUST HARD FAIL if `snapshot_coverage_pct < 95%` (fail-closed; no patch may apply).
- **Full tick/L2 archives are OPTIONAL (diagnostics/research), not required for the gate:**
  - If full tick/L2 archives are paused due to disk watermarks (§7.2), Replay Gatekeeper continues using Decision Snapshots.
  - Archive pause MUST NOT, by itself, force `RiskState::Degraded`.
  - If Decision Snapshots cannot be written/read OR coverage drops below threshold, THEN fail-closed and enter Degraded (ReduceOnly).
- Maintain `realism_penalty_factor` from §4.5 (fail-safe default if missing).

**Where:** `python/governor/replay_gatekeeper.py`

**Validation rules (hard gates):**
- `replay_atomic_naked_events == 0`
- `replay_max_drawdown_usd <= dd_limit`

**Realism penalty enforcement (non-negotiable):**
Replay uses FillSimulator impact costs; **penalize** them using the calibrated factor:
- Option A (simple): `impact_cost_usd := impact_cost_usd * realism_penalty_factor`
- Option B (explicit):  
  `replay_net_pnl_penalized = replay_net_pnl_raw - (abs(replay_slippage_cost_usd) * (realism_penalty_factor - 1.0))`

**Profitability gate (hard release gate):**
- Reject if `replay_net_pnl_penalized <= 0`

**Decision:**
- If **fail** → reject patch, log reason; keep current policy.
- If **pass** → approve patch for rollout (still subject to canary staging §5.3).

**Acceptance Tests:**
1) Any dispatched order/intent MUST join to a Decision Snapshot via `decision_snapshot_id`.
2) Replay Gatekeeper MUST fail if `snapshot_coverage_pct < 95%`.
3) Disk watermark pausing of full tick/L2 archives does NOT invalidate replay inputs by itself: Replay Gatekeeper continues using Decision Snapshots and MUST NOT force `RiskState::Degraded` solely due to archive pause.
4) A policy that passes replay pre-penalty MUST fail if `realism_penalty_factor = 1.3` makes `replay_net_pnl_penalized` ≤ 0.

**Why this exists:** This closes the TOC constraint of “open-loop” policy pushes and prevents the system from training on fantasy liquidity.

### **5.3 Policy Canary Rollout (Staged Activation)**

**Requirement:** Any new policy that passes Replay Gatekeeper must roll out in stages.

**Stages:**
- Stage 0: Shadow Only (no live orders). Duration: 6–24h or N signals.
- Stage 1: Live Canary (tiny size, e.g., 10–20% of normal). Duration: 2–6h or N fills.
- Stage 2: Full Live.

**Abort Conditions (Immediate rollback to previous policy + ReduceOnly cooldown):**
- `atomic_naked_events > 0`
- `p95_slippage_bps > slippage_limit`
- `fill_rate < fill_rate_floor` AND strategy attempts > threshold
- `net_pnl_usd` below `pnl_floor` for the canary window

**Where:** `python/governor/canary_rollout.py` + Soldier must accept `PolicyStage` field.

**Acceptance Test:**
- Policy passes replay but fails canary due to slippage blowout → automatic rollback and ReduceOnly cooldown.

## **6\. Implementation Roadmap v4.0**

### **Phase 1: The Foundation (Panic-Free)**

* TLSM & `stoic:v4` labeling schema.  
* **Durable intent ledger** (WAL) setup.  
* **Liquidity Gate** implementation.

### **Phase 2: The Guardrails (Safety)**

* Emergency Close & **Rate limiter**.  
* **Continuous reconciliation** \+ WS gap detection.  
* **Policy Fallback Ladder** (Dead Man’s Switch).

### **Phase 3: The Data Loop (Optimization)**

* **Attribution schema** \+ time drift \+ chrony integration.  
* **Fill simulator** \+ shadow mode deployment.
* **Decision Snapshots (required)** + optional Tick/L2 archive writer (rolling 72h) for deeper diagnostics / research replay.

### **Phase 4: Live Fire**

* Mode: `TradingMode::Sniper` (IOC Limits).  
* Monitoring: Watch `Atomic Naked Events` (Grafana).

---

## **7\. External Tools & Ops Cockpit (Lean Trader Stack)**

**Must-Use Now:**

* **Prometheus \+ Grafana:** Dashboards \+ alerts (gamma, delta, atomic\_naked\_events, 429\_count, ws\_gap\_count).  
* **DuckDB:** Query Parquet attribution quickly (hourly slippage, fill-rate, fee drag).  
* **chrony/NTP:** Enforce time correctness for attribution.

**Minimum Alert Set:**

* `atomic_naked_events > 0`  
* `429_count > 0`  
* `policy_age_sec > 300` (force ReduceOnly)
* `decision_snapshot_write_errors > 0`
* `truth_capsule_write_errors > 0`
* `parquet_queue_overflow_count > 0` (or increasing)
* `evidence_guard_blocked_opens_count > 0` (new metric)


### **7.0 Owner Control Plane Endpoints (Read-Only, Owner-Grade)**

**Requirement:** The system MUST provide a read-only status endpoint for human oversight and for external watchdog tooling.

**Endpoints:**
- `GET /api/v1/status` (read-only)

**/status response MUST include (minimum):**
- `trading_mode`, `risk_state`, `evidence_chain_state`, `bunker_mode_active`
- `policy_age_sec`, `last_policy_update_ts`
- `f1_cert_state` + `f1_cert_expires_at`
- `disk_used_pct`
- `snapshot_coverage_pct` (current computed metric / last window)
- `atomic_naked_events_24h`, `429_count_5m`
- `deribit_http_p95_ms`, `ws_event_lag_ms`

**Security:** This endpoint MUST NOT allow changing risk. No “set Active” endpoints in this patch.

**Testing Requirement (Non-Negotiable):**
Any new endpoint introduced by this contract MUST include at least one endpoint-level test.

**Acceptance Test (REQUIRED):**
- `test_status_endpoint_returns_required_fields()` verifies HTTP 200 and required JSON keys.

### **7.1 Review Loop (Autopilot Reviewer + Minimal Human Touch)**

**Purpose (TOC constraint relief):** Close the “open-loop” trap by turning logs into **deterministic review outcomes**.
If nobody (human or machine) is accountable for reading the logs, you still have a lawnmower engine—just with nicer gauges.

#### **7.1.1 What MUST be logged (audit trail)**
The system MUST persist enough to reconstruct every action and policy change:
- **Execution decisions:** order intents, gates evaluated, chosen action (place/cancel/flatten), and reason codes.
- **Lifecycle events:** TLSM transitions for every order/leg.
- **Policy events:** proposed patch, replay result, canary stage result, and final applied/rejected decision.
- **Incidents:** any entry into ReduceOnly/Kill, and why.

**Artifacts (append-only, reviewable):**
- `artifacts/decision_log.jsonl` (one record per decision; small + append-only)
- `artifacts/policy_patches/<ts>_patch.json` + `artifacts/policy_patches/<ts>_result.json`
- `artifacts/reviews/<YYYY-MM-DD>/daily_review.json` + `daily_review.md`
- `artifacts/incidents/<ts>_<type>.json` + `<ts>_<type>.md`

#### **7.1.2 Who reviews (and when)**
**A) AutoReviewer (deterministic, required):**
- Runs **daily** and **on incident trigger**.
- Inputs: Parquet attribution, decision_log, current policy, last 24h metrics (same window as F1 cert).
- Outputs: one of:
  - `NO_ACTION`
  - `AUTO_APPLY_SAFE_PATCH`
  - `REQUIRE_HUMAN_APPROVAL`
  - `FORCE_REDUCEONLY_COOLDOWN`
  - `FORCE_KILL`

**Where:** `python/reviewer/daily_ops_review.py` and `python/reviewer/incident_review.py`

**B) Human (you) — only when the change increases risk:**
You are NOT “reviewing everything.” You only approve **risk-increasing** changes.
Human review is required if:
- Patch loosens gates or increases sizing/frequency/leverage, or
- Any incident fired in the last 24h (atomic naked event, 429/10028 burst, slippage blowout), or
- F1 cert is FAIL.

Human approval is recorded as: `artifacts/HUMAN_APPROVAL.json` (explicit allow-list for the patch id).

#### **7.1.3 Auto-approval rules (what the system may change without you)**
AutoReviewer may **only** auto-apply a patch if ALL are true:
1) Patch is classified as **SAFE** (tightens gates / reduces risk; never increases exposure).
2) Replay Gatekeeper PASS (§5.2) and Canary staging PASS (§5.3).
3) No incident triggers in the last 24h.

Patch classification MUST be embedded in the patch:
`patch_meta.impact = SAFE | NEUTRAL | AGGRESSIVE`

AGGRESSIVE always requires `HUMAN_APPROVAL.json`.

#### **7.1.4 Incident-triggered review (automatic “post-mortem”)**
If any of the following occur, the system MUST generate an incident report and enforce containment:
- `atomic_naked_events > 0`
- `429_count > 0` OR `10028_count > 0`
- canary abort (slippage blowout / pnl floor breach)

**Required actions:**
- Immediate `TradingMode::ReduceOnly` cooldown (duration configured; default 6–24h).
- Produce `artifacts/incidents/<ts>_incident.md` with:
  - Timeline (first bad event → containment → flat)
  - Root cause tag (liquidity / rate limit / WS gap / policy drift / sizing)
  - “What would have prevented this” (which gate failed or was missing)
  - Next patch recommendation (SAFE only unless human approves)

#### **7.1.5 Acceptance Tests**
- Daily review runs → writes `artifacts/reviews/<date>/daily_review.json` and includes:
  `atomic_naked_events`, `p95_slippage_bps`, `fee_drag_usd`, `replay_net_pnl_penalized`, and current `policy_hash`.
- AGGRESSIVE patch without `artifacts/HUMAN_APPROVAL.json` → MUST NOT apply (even if replay/canary pass).
- If `atomic_naked_events > 0` → incident report generated + ReduceOnly cooldown enforced.


### **7.2 Data Retention & Disk Watermarks — MUST implement**

**Goal:** Prevent “disk full → corrupted logs → blind trading decisions.”

**Retention defaults (configurable):**
- Tick/L2 archives: keep **72h** (rolling) (compressed).
- Parquet analytics (attribution + truth capsules): keep **30d** (compressed).
- WAL / intent ledger: keep **indefinitely** (small, critical).

**Disk watermarks (hard rules):**
- `disk_used_pct >= 80%`: stop writing **full** tick/L2 stream archives, BUT continue (required):
  - Decision Snapshots (required; see §4.3.2)
  - WAL / intent ledger (required)
  - Truth Capsule + attribution analytics (required)

- `disk_used_pct >= 85%`: force `RiskState::Degraded` (ReduceOnly) until back under 80%.
- `disk_used_pct >= 92%`: hard-stop trading loop (Kill switch) to protect integrity.

**Acceptance Tests:**
1) Under simulated `disk_used_pct >= 80%`: full tick/L2 archive writing stops; Decision Snapshots continue.
2) Under simulated `disk_used_pct >= 85%`: system enters `RiskState::Degraded` and enforces ReduceOnly until back under 80%.
3) Under simulated `disk_used_pct >= 92%`: trading loop enters Kill.

**Minimum alerts add:**
- `disk_used_pct >= 80`
- `parquet_write_errors > 0`
- `truth_capsule_write_errors > 0`



---

## **8. Release Gates (F1 Certification Checklist — HARD PASS/FAIL)**

This checklist is a **hard release gate**. No version may be promoted
(Shadow → Testnet → Live) unless an automated cert run produces:

- `artifacts/F1_CERT.json` with `"status": "PASS"`
- and a human-readable `artifacts/F1_CERT.md` summary

### **8.1 Measurable Metrics (PASS/FAIL)**
Metrics must be computed over the last **24h** window for Shadow and Testnet.
Production uses rolling 24h once live.

| Metric | Shadow (Sim) | Testnet (Live Testnet) | Live (Prod) | Gate Type |
|---|---:|---:|---:|---|
| Atomic Safety | atomic_naked_events == 0 | 0 | 0 | REQUIRED |
| Rate Limits | N/A | 429_count==0 AND 10028_count==0 | 0 | REQUIRED |
| WS Gap Recovery (book) | N/A | p95 <= 5s | p95 <= 10s | REQUIRED |
| WS Gap Recovery (private) | N/A | p95 <= 10s | p95 <= 20s | PASS |
| Time Drift | N/A | p99_clock_drift <= 50ms | <= 50ms | REQUIRED |
| p95 Slippage | <= 5 bps | <= 8 bps | <= 10 bps | PASS |
| IOC Fill Rate | >= 40% | >= 30% | >= 25% | PASS |
| Emergency Time-to-DeltaNeutral | N/A | <= 2s | <= 3s | REQUIRED |
| Fee Drag Ratio | N/A | fee_drag_usd / gross_edge_usd (rolling 7d) < 0.35 | < 0.35 | REQUIRED |
| Net Edge After Fees | N/A | rolling 7d avg(net_edge_usd) > 0 | > 0 | REQUIRED |
| Zombie Orders | 0 | 0 | 0 | REQUIRED |
| Attribution Completeness | rows == fills | rows == fills | rows == fills | REQUIRED |
| Replay Profit (penalized) | > 0 | > 0 | > 0 | REQUIRED |

**Notes:**
- “Replay Profit (penalized)” uses `realism_penalty_factor` from §4.5 and the hard reject rule from §5.2.

**Acceptance Tests:**
1) If Time-to-DeltaNeutral >= 2s in any incident → block scaling (Sniper-only).
2) If Fee Drag Ratio exceeds threshold → auto-raise min_edge_usd or block opens (policy patch).

### **8.2 Minimum Test Suite (The Torture Chamber)**
All must pass in CI before any deployment:

**A) Deterministic Unit Tests**
- Quantization: bids round down, asks round up; coin-vs-USD size mismatches reject.
- TLSM: fill-before-ack, out-of-order events, orphan fills → no panic, correct final state.
- Gates: GrossEdge > 0 but NetEdge < 0 (fees) → REJECT.
- Arb-Guards: RMSE-pass but convexity fail → REJECT and hold last good fit.


- `test_truth_capsule_written_before_dispatch_and_fk_linked()`
- `test_atomic_containment_calls_emergency_close_algorithm_with_hedge_fallback()`
- `test_disk_watermark_stops_tick_archives_and_forces_reduceonly()`
- `test_release_gate_fee_drag_ratio_blocks_scaling()`

**B) Chaos/Integration Scenarios**
- Hanging Leg: Leg A Filled, Leg B Rejected → EmergencyFlatten within 200ms–1s window.
- Zombie Resurrection: WS drop after send → sweeper cancels orphan within 10s and ledger matches exchange.
- Session Kill: 10028/too_many_requests → TradingMode::Kill, reconnect with backoff, reconcile, resume only stable.

**C) Replay Simulation**
- Vol shock day replay: Reflexive Cortex forces ReduceOnly.
- “Bad policy” must fail due to realism penalty (profit flips ≤ 0).

### **8.3 Canary Rollout Protocol (Hard Gate)**
Policy staging in §5.3 is mandatory. Promotion requires:

- Stage 0 (Shadow) PASS for 6–24h
- Stage 1 (Testnet micro-canary) PASS for 2–6h
- Any abort trigger → rollback + ReduceOnly cooldown

### **8.4 Certification Artifact (Hard Gate Implementation)**
**Where:**
- `python/tools/f1_certify.py`
- outputs `artifacts/F1_CERT.json` and `artifacts/F1_CERT.md`

**Example CI command:**
- Run: `python python/tools/f1_certify.py --window=24h --out=artifacts/F1_CERT.json`
- Block release unless `status == PASS`.

**Acceptance Test:**
- Force atomic_naked_events=1 in a test run → cert status must be FAIL and deployment blocked.
