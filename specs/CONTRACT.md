This is the canonical contract path. Do not edit other copies.

# **Version: 5.2 (The "Antifragile" Standard)**
**Status**: FINAL ARCHITECTURE **Objective**: Net Profit via Structural Arbitrage using **Atomic Group Execution**, **Fee-Aware IOC Limits**, and **Closed-Loop Optimization**. **Architecture**: "The Iron Monolith v4.0" (Rust Execution/Risk \+ Python Policy \+ **Automated Policy Tuner**)

---

## Patch Summary (P0 — TradingMode Canonicalization)

This Patch Summary is non-normative; see §0.0 for normative scope.

**Applied:** 2026-01-15  
**Objective:** Eliminate TradingMode split-brain; canonicalize under PolicyGuard ownership.

- **§2.2.3 Canonical Precedence** — Relocated ladder from EvidenceGuard; expanded to 6 KILL + 11 REDUCEONLY triggers including margin, disk, session termination, and open permission latch.
- **§2.2.3 ModeReasonCode Registry** — Added authoritative reason codes exposed via `/api/v1/status` (prevents "operator lies").
- **§2.2.4 Open Permission Latch (CP-001)** — Blocks opens after restart/WS gaps/session kill until reconciliation clears (5 reconcile-class codes).
- **§2.2 PolicyGuard Inputs** — Extended input list to explicitly include all fields referenced by the precedence ladder (see §2.2).
- **§2.2.2 EvidenceGuard Queue Depth Gate** — Added `parquet_queue_depth_pct <= 0.90` fail-closed gate with hysteresis.
- **§7.0 /status Observability** — Added 4 required fields: `mode_reasons`, `open_permission_blocked_latch`, `open_permission_reason_codes`, `open_permission_requires_reconcile`.
- **§7.2 Decision Snapshot Retention** — Explicit defaults (30d, ≥2d bound) aligned with Replay Gatekeeper 48h window.
- **§1.4.3, §3.3 Wording Cleanup** — "PolicyGuard MUST force" (not "Force TradingMode"); fixed §3.3 10028 Kill contradiction.

**Note:** Patch Summary is informational; requirements and acceptance tests are defined in the referenced sections below.
**Acceptance Test References (informational):**
- Kill containment eligibility: see §2.2.3 Kill Mode Semantics acceptance tests.
- Staleness arithmetic: see §2.2.3 Policy Staleness Rule acceptance tests.
- /status required fields: see §7.0 acceptance tests.

> [!WARNING]
> **v5.2 F1_CERT Binding Requirement:** This version introduces F1_CERT binding validation (§2.2.1). ALL components that produce or consume `contract_version` MUST be updated to `5.2` in lockstep (F1 cert generator, runtime binary, PolicyGuard). Mismatched versions will force `TradingMode::ReduceOnly` until aligned.

## Definitions

### Acceptance Test Isolation Requirements (Normative)

For any **new guard** (a rule, latch, monitor, or gate) that can block an OPEN, change TradingMode, or emit a SafetyOverride:

1) You MUST add a **paired** acceptance test set:
   - **TRIP AT**: the guard activates and is the *sole* reason an otherwise-valid OPEN is blocked / mode changes.
   - **NON-TRIP AT**: the guard does not activate and an otherwise-valid OPEN proceeds to dispatch.

2) Every TRIP/NON-TRIP AT for a guard MUST explicitly declare:
   - **All other gates forced pass** (Liquidity Gate pass, NetEdge pass, quantization pass, no unrelated latches, etc.).
   - Any required “normal” preconditions (fresh feeds, RiskState normal, no other cortex overrides).

3) “Downstream-only” tests (e.g., “if flag is already true…”) do NOT satisfy activation coverage.

4) Pass criteria MUST prove causality via at least one of:
   - dispatch count (0 vs 1),
   - specific reject reason code,
   - specific latch reason code,
   - specific `cortex_override` value.


- **instrument_kind**: one of `option | linear_future | inverse_future | perpetual` (derived from venue metadata).
  - **Linear Perpetuals (USDC‑margined)**: treat as `linear_future` for sizing (canonical `qty_coin`), even if their venue symbol says "PERPETUAL".
- **order_type** (Deribit `type`): `limit | market | stop_limit | stop_market | ...` (venue-specific).
- **linked_order_type**: Deribit linked/OCO semantics (venue-specific; gated off for this bot).
- **Aggressive IOC Limit**: a `limit` order with `time_in_force=immediate_or_cancel` and a *bounded* limit price computed from `fair_price` with fee-aware edge-based clamps (see §1.4).

- **L1TickerSnapshot**: {`instrument_id`, `best_bid`, `best_ask`, `ts_ms`, `source` (REST|WS)} from the ticker feed. Valid only if `best_bid > 0`, `best_ask > 0`, `best_bid <= best_ask`, and `(now_ms - ts_ms) <= l2_book_snapshot_max_age_ms`.

- **contract_version**: canonical version string `5.2` (numeric only; no codename/tagline).

- **RiskState** (health/cause layer): `Healthy | Degraded | Maintenance | Kill`
- **TradingMode** (enforcement layer): `Active | ReduceOnly | Kill`  
  Resolved by PolicyGuard each tick from RiskState, policy staleness, watchdog, exchange health, fee cache staleness, and Cortex overrides.
  **Runtime F1 Gate in PolicyGuard (HARD, runtime enforcement):** See §2.2.1 for canonical specification. Summary: F1_CERT missing/stale/invalid → ReduceOnly (blocks opens; allows closes/hedges/cancels).
- **reduce_only** (venue order flag): boolean on outbound order placement requests.
  - `reduce_only == true` -> classified as CLOSE/HEDGE (risk-reducing) for all "OPEN vs CLOSE/HEDGE/CANCEL" gates in this contract.
  - `reduce_only != true` (false or missing) -> classified as OPEN.
- **CANCEL intent**: cancel-only requests (no new order placement). Replace is treated as cancel + new order placement (classified above).
- **Fail-closed intent classification:** if an intent cannot be classified, it MUST be treated as OPEN.

AT-201
- Given: an OrderIntent with an unknown `action` value (not Place/Cancel/Close/Hedge) OR missing required classification fields.
- When: intent classification is computed.
- Then: classification MUST be OPEN, and OPEN gates (PolicyGuard mode + CP-001 latch + EvidenceGuard) MUST apply.
- Pass criteria: intent is treated as OPEN and blocked when any OPEN gate blocks.
- Fail criteria: intent is treated as CLOSE/HEDGE/CANCEL or bypasses OPEN gates.

## **0.0 Normative Scope (Non-Negotiable)**

The numbered sections, Definitions, and Appendix A are normative. Non-numbered narrative elsewhere is informative and non-binding unless explicitly marked as an acceptance test.

## **0.X Repository Layout & Canonical Module Mapping (Non-Negotiable)**

This repo is a Rust workspace with two required crates:

- `crates/soldier_core`
- `crates/soldier_infra`

Any “Where:” references in this contract that mention `soldier/core/...` or `soldier/infra/...` map to:

- `soldier/core/...` => `crates/soldier_core/...`
- `soldier/infra/...` => `crates/soldier_infra/...`

Contract invariant: any implementation that relocates these crates or breaks this mapping is non-compliant unless `CONTRACT.md` is updated first.

**Contract acceptance criteria (repo-level):**
- `cargo test --workspace` must run from repo root.
- Both crates must exist and be members of the workspace.

**Acceptance Test (REQUIRED):**
AT-905
- Given: repo at root with `Cargo.toml` present.
- When: repo layout is verified.
- Then: `crates/soldier_core` and `crates/soldier_infra` exist and are listed in workspace members.
- Pass criteria: both crate paths exist and are workspace members.
- Fail criteria: missing crate path or missing workspace member entry.

## **0.Y Verification Harness (Non-Negotiable)**

`plans/verify.sh` is the canonical verification entrypoint for this repo.
It MUST be runnable from repo root and MUST invoke `cargo test --workspace`
as part of its core gate.

**Contract acceptance criteria (repo-level):**
- `bash -n plans/verify.sh` exits 0.
- `./plans/verify.sh` runs `cargo test --workspace` from repo root.

**Acceptance Test (REQUIRED):**
AT-901
- Given: repo at root with `plans/verify.sh` present.
- When: `plans/verify.sh` is executed.
- Then: it runs `cargo test --workspace` and exits `0` when tests pass.
- Pass criteria: exit code is `0` and the workspace tests run.
- Fail criteria: exits `0` when tests fail OR does not run workspace tests.



## Deribit Venue Facts Addendum (Artifact-Backed)

This contract is **venue-bound**: any behavior marked **VERIFIED** below is backed by artifacts under `artifacts/` and is enforced by code + regression tests.  
CI guardrail: `python scripts/check_vq_evidence.py` must pass, or **build fails**.

| Fact ID   | Status                               | Enforcement point in engine                                                                                                    | Evidence path under `artifacts/`                                         |
| --------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| **F-01a** | **VERIFIED**                         | §1.4.4 **Options Order-Type Guard** → reject stop orders on options preflight                                                  | `artifacts/T-TRADE-02_response.json`                                     |
| **F-01b** | **DOC-CONFLICT** (POLICY-DISALLOWED) | §1.4 **No Market Orders** + §1.4.4 **Options Order-Type Guard** → market on options forbidden (reject only; no normalization)  | `artifacts/deribit_testnet_trade_20260103_015804.log`                    |
| **F-03**  | **VERIFIED**                         | §1.1.1 **Canonical Quantization** → tick/step rounding before hash + dispatch                                                  | `artifacts/deribit_testnet_trade_final_20260103_020002.log`              |
| **F-05**  | **VERIFIED**                         | §3.3 **Local Rate Limit Circuit Breaker** → do **not** rely on rate-limit headers; enforce local throttle + retry/backoff      | `artifacts/deribit_testnet_trade_final_20260103_020002.log`              |
| **F-06**  | **VERIFIED**                         | §1.4.4 **Post-Only Guard** → never send `post_only` that would cross; treat venue reject as deterministic, not “random”        | `artifacts/deribit_testnet_trade_final_20260103_020002.log`              |
| **F-07**  | **VERIFIED**                         | §2.2/§2.2.3 **TradingMode Computation** → when effective mode is ReduceOnly/Kill, outbound orders must include venue `reduce_only=true` | `artifacts/deribit_testnet_trade_final_20260103_020002.log`              |
| **F-08**  | **VERIFIED** (NOT SUPPORTED)         | §1.4.4 **Linked Orders Gate** → `linked_order_type` rejected unless explicitly certified (not currently)                       | `artifacts/T-OCO-01_response.json`                                       |
| **F-09**  | **VERIFIED** (NOT SUPPORTED) | §1.4.4 **Stop Order Guard** → stop orders rejected for this bot; venue requires trigger if enabled                       | `artifacts/T-STOP-01_response.json`, `artifacts/T-STOP-02_response.json` |
| **F-10**  | **VERIFIED** (observed metric)       | §2.3.2 + §3.3 **Network Jitter Monitor / Rate Limit Circuit Breaker** → use conservative timeouts; do not treat latency as invariant | `artifacts/T-PM-01_latency_testnet.json`                                 |
| **A-03**  | **VERIFIED**                         | §3.2 **Data Plane / Heartbeat** → websocket silence triggers ReduceOnly/Kill                                                   | `artifacts/deribit_testnet_trade_final_20260103_020002.log`              |

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
   - Tolerance: `abs(amount - contracts * contract_multiplier) / max(abs(amount), epsilon) <= contracts_amount_match_tolerance` where `contracts_amount_match_tolerance = 0.001` (0.1%, default) and `epsilon = 1e-9`.
3. If a mismatch is detected: **reject the intent** and set `RiskState::Degraded` (this is a wiring bug, not "market noise").
4. Rejections for contracts/amount mismatch MUST use `Rejected(ContractsAmountMismatch)`.
5. For `instrument_kind == option`, order size MUST use `qty_coin` (Deribit `amount` in base coin units); `qty_usd` MUST be unset.

**Acceptance Tests (References):**
- AT-277 (dispatcher mapping validates option sizing and `qty_usd` unset)

#### **1.0.X Instrument Metadata Freshness (Instrument Cache TTL) — MUST implement**

**Purpose:** Stale instrument metadata can silently break sizing and quantization (tick_size, amount_step, min_amount), causing wrong exposure.

**Source of truth (Non-Negotiable):**
- Instrument metadata MUST be fetched from `/public/get_instruments` and cached (Deribit).
- Hardcoding `tick_size`, `amount_step`, `min_amount`, or `contract_multiplier` is forbidden; all sizing/quantization MUST use the fetched metadata.

**Invariant (Non-Negotiable):**
- The engine MUST track freshness of instrument metadata used for:
  - instrument_kind derivation
  - quantization constraints (tick_size, amount_step, min_amount)
- If instrument metadata age exceeds `instrument_cache_ttl_s`:
  - set `RiskState::Degraded`
  - PolicyGuard MUST compute `TradingMode::ReduceOnly` within one tick (closes/hedges/cancels allowed; see §2.2.3)

**Required observability (contract-bound names):**
- `instrument_cache_age_s` (gauge)
- `instrument_cache_hits_total` (counter)
- `instrument_cache_stale_total` (counter)
- `instrument_cache_refresh_errors_total` (counter, optional but recommended)

**Acceptance tests (REQUIRED):**
- AT-104 below provides comprehensive testing for stale metadata handling (blocks opens, allows closes).

AT-104
- Given: `instrument_cache_age_s > instrument_cache_ttl_s` and an OPEN intent is proposed.
- When: the system evaluates eligibility for dispatch.
- Then: `RiskState==Degraded`, `TradingMode==ReduceOnly`, and the OPEN is rejected before dispatch; CLOSE/HEDGE/CANCEL remain dispatchable (subject to Kill hard-stop rules).
- Pass criteria: OPEN dispatch count remains 0; CLOSE/HEDGE/CANCEL are not blocked solely by stale metadata.
- Fail criteria: any OPEN is dispatched while metadata is stale.

AT-333
- Given: instrument metadata is fetched from `/public/get_instruments`.
- When: quantization/sizing uses `tick_size`, `amount_step`, `min_amount`, and `contract_multiplier`.
- Then: values come from fetched metadata (no hardcoded defaults).
- Pass criteria: quantization/sizing uses fetched values.
- Fail criteria: any hardcoded defaults used.

#### **1.0.Y Instrument Lifecycle & Expiry Safety (Expiry Cliff Guard) — MUST implement**

**Purpose:** Instruments expire/delist. After expiry, venue APIs may return "invalid instrument"/"not_found"/"orderbook_closed".
These are **expected terminal lifecycle events**, not fatal system errors. The Soldier MUST remain panic-free and MUST protect
the rest of the portfolio from a single instrument disappearing.

**Required instrument fields (from venue metadata; cached under §1.0.X):**
- `expiration_timestamp_ms: Option<i64>` (epoch ms; null for perps)
- `is_active: bool` (or equivalent venue state)
- `instrument_state: enum { Active, DelistingSoon, ExpiredOrDelisted }` (derived)

**Delist buffer rule (fail-closed for opens):**
- If `expiration_timestamp_ms` is present and `now_ms >= expiration_timestamp_ms - (expiry_delist_buffer_s * 1000)`:
  - NEW OPEN intents for that instrument MUST be rejected before dispatch with `Rejected(InstrumentExpiredOrDelisted)`.
  - CLOSE/HEDGE/CANCEL intents remain allowed (subject to Kill hard-stop and other gates).

**Terminal error classification (panic-free):**
- Any venue response that semantically maps to {`invalid_instrument`, `not_found`, `orderbook_closed`, `instrument_not_open`}
  for an instrument with `expiration_timestamp_ms` present and `now_ms >= expiration_timestamp_ms` MUST be classified as:
  - `Terminal(InstrumentExpiredOrDelisted)`
  - MUST NOT panic
  - MUST NOT force process restart
  - MUST trigger reconciliation for that instrument only (ledger/orders/trades/positions) and then mark `instrument_state=ExpiredOrDelisted`.

**Idempotent cancel rule (expiry-safe):**
- If a CANCEL is issued for an order on an expired/delisted instrument and the venue returns a terminal lifecycle error,
  the CANCEL MUST be treated as **idempotently successful** (order is considered gone).

**Portfolio-wide reconcile/flatten (expiry-safe):**
- During any portfolio-wide reconcile/flatten procedure (restart reconcile, emergency flatten, operator shutdown flow),
  terminal lifecycle errors for expired/delisted instruments MUST NOT abort the procedure.
- The procedure MUST continue managing other instruments normally.
- If venue truth (positions snapshot) indicates no remaining position for the expired/delisted instrument, the system MUST
  mark `instrument_state=ExpiredOrDelisted` and MUST NOT enter a retry loop for that instrument.

**Acceptance Tests (REQUIRED):**
AT-949
- Given: `expiration_timestamp_ms = Texp`, `now_ms = Texp + 1000`, and a CANCEL is attempted on that instrument.
  - All other gates are configured to pass (this test isolates expiry-safe idempotent cancel handling).
- When: venue returns a terminal lifecycle error (e.g., invalid instrument / not found / orderbook_closed).
- Then: the system does not panic; the cancel is treated as idempotently successful; the instrument is marked `ExpiredOrDelisted`;
  other instruments continue to be managed normally.
- Pass criteria: no crash; instrument_state updated; other instrument loop continues.
- Fail criteria: panic/crash or global trading halted solely due to this instrument error.

AT-950
- Given: `expiration_timestamp_ms = Texp`, `expiry_delist_buffer_s = 60`, and `now_ms = Texp - 30_000`.
  - All other gates are configured to pass (this test isolates the expiry delist OPEN block).
- When: an OPEN intent for that instrument is evaluated.
- Then: the intent is rejected with `Rejected(InstrumentExpiredOrDelisted)` before dispatch; CLOSE/HEDGE/CANCEL remain allowed.
- Pass criteria: OPEN dispatch count remains 0 and reject reason matches.
- Fail criteria: OPEN dispatch occurs or reason missing/mismatched.

AT-965
- Given:
  - `expiration_timestamp_ms = Texp`, `expiry_delist_buffer_s = 60`
  - `now_ms = Texp - 120_000` (outside the delist buffer)
  - instrument is active (not expired/delisted)
  - All other gates are configured to pass (this test isolates the expiry delist OPEN block)
- When: an OPEN intent for that instrument is evaluated.
- Then: it MUST NOT be rejected with `InstrumentExpiredOrDelisted`; it proceeds to dispatch.
- Pass criteria: dispatch count becomes 1 and there is no `Rejected(InstrumentExpiredOrDelisted)`.
- Fail criteria: OPEN rejected/blocked by the lifecycle guard despite being outside the delist buffer.

AT-966
- Given:
  - instrument is active (outside delist buffer; not expired/delisted)
  - a CANCEL intent for an existing order is handled and the venue returns success (or a normal non-terminal “already closed/canceled” response)
  - All other gates are configured to pass (this test isolates expiry-safe idempotent cancel logic)
- When: the CANCEL response is processed.
- Then: the system MUST NOT mark the instrument `ExpiredOrDelisted`; it treats the cancel as a normal success path.
- Pass criteria: instrument_state remains Active (or equivalent non-expired state).
- Fail criteria: instrument is incorrectly marked `ExpiredOrDelisted` from a non-terminal cancel result.


AT-960
- Given: a CANCEL intent on an expired/delisted instrument returns `Terminal(InstrumentExpiredOrDelisted)` at T0.
  - All other gates are configured to pass (this test isolates expiry-safe idempotent cancel handling).
- When: the same CANCEL intent is retried (duplicate) at T0+1.
- Then: the second attempt is a NOOP (idempotent success) and does not change ledger correctness.
- Pass criteria: no extra dispatch; ledger remains consistent.
- Fail criteria: repeated cancels cause errors, state corruption, or repeated network dispatch.

AT-961
- Given: a portfolio-wide reconcile/flatten is invoked with two instruments:
  - Instrument A is expired/delisted (`expiration_timestamp_ms = Texp`, `now_ms = Texp + 1000`)
  - Instrument B is active and has an open position requiring management
  - All other gates are configured to pass (this test isolates expiry-safe portfolio reconciliation).
- When: reconcile attempts cancel/close actions and instrument A returns a terminal lifecycle error, while instrument B proceeds normally.
- Then: the system MUST NOT panic; it MUST continue the procedure for instrument B; and it MUST NOT globally halt solely due to A.
- Pass criteria: B continues to be managed; no crash; A marked `ExpiredOrDelisted`.
- Fail criteria: global halt, crash, or B management stops because A expired.

AT-962
- Given: instrument A returns a terminal lifecycle error as above.
  - All other gates are configured to pass (this test isolates expiry-safe reconcile termination).
- When: a positions snapshot (venue truth) shows no remaining position for instrument A.
- Then: the system marks A `ExpiredOrDelisted` and MUST NOT retry cancel/close in a loop for A.
- Pass criteria: retry count for A remains 0 after reconciliation finalizes; state marked expired.
- Fail criteria: infinite/extended retries or repeated dispatch attempts for A after venue truth indicates no position.





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

**Acceptance Test (REQUIRED):**
AT-277
- Given:
  1) `instrument_kind=option` with `qty_coin=0.3` at `index_price=100_000`
  2) `instrument_kind=perpetual` with `qty_usd=30_000` at `index_price=100_000`
- When: the dispatcher maps request fields.
- Then:
  - outbound option uses `amount=0.3` (coin), `notional_usd=30_000`, and `qty_usd` is unset
  - outbound perp uses `amount=30_000` (USD), `qty_coin=0.3`, `notional_usd=30_000`
  - if both `contracts` and `amount` are supplied and mismatch → reject + degrade
- Pass criteria: mapping rules applied; option `qty_usd` unset; mismatches rejected.
- Fail criteria: incorrect mapping or mismatch allowed.

AT-920
- Given: `contracts` and `amount` are provided and mismatch beyond `contracts_amount_match_tolerance`.
- When: the dispatcher validates sizing before dispatch.
- Then: the intent is rejected with `Rejected(ContractsAmountMismatch)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0; `RiskState==Degraded`.
- Fail criteria: dispatch occurs or reason missing/mismatched.

---

### **1.1 Labeling & Idempotency Contract**

**Requirement**: Every order must be uniquely identifiable and deduplicable across restarts, socket reconnections, and race conditions.

**Specification: The Label Schema**

**Canonical Outbound Format (MUST implement):** `s4:{sid8}:{gid12}:{li}:{ih16}`

- `sid8` = first 8 chars of stable strategy id hash (e.g., base32(xxhash(strat_id)))
- `gid12` = first 12 chars of group_id (uuid without dashes, truncated)
- `li` = leg_idx (0/1)
- `ih16` = 16-hex (or base32) intent hash

**Deribit Constraint:** `label` must be <= 64 chars. (Hard limit)

**Rule:** All outbound orders to Deribit MUST use the `s4:` format. For `s4` labels, truncation MUST NOT occur; if a computed label would exceed 64 chars, the intent MUST be rejected before dispatch and `RiskState` MUST become `Degraded`.
Rejections for label-length overflow MUST use `Rejected(LabelTooLong)`.

**Legacy Documentation Format (non-sent):** `s4:{strat_id}:{group_id}:{leg_idx}:{intent_hash}`  
This expanded format is for human-readable logs and internal documentation only. It MUST NOT be sent to the exchange.

#### **1.1.2 Label Parse + Disambiguation (Collision-Safe)**

**Requirement:** Label collisions can still occur (hash collisions or non-conforming labels). The Soldier must deterministically map exchange orders to local intents.

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

**Acceptance Tests (REQUIRED):**
AT-216
- Given: an outbound order intent is built with a valid `s4:` label.
- When: the label parser runs.
- Then: the label starts with `s4:`, length ≤ 64 chars, and parser extracts `{sid8, gid12, li, ih16}` correctly.
- Pass criteria: parser outputs match expected components and label length is within bounds.
- Fail criteria: label format invalid, length > 64, or parsed components mismatch.

AT-217
- Given: two intents share the same `gid12` and `leg_idx`.
- When: the label matcher disambiguates using tie-breakers.
- Then: it resolves using `ih16` + instrument + side; if still ambiguous, `RiskState::Degraded` and opens blocked.
- Pass criteria: deterministic match when tie-breakers suffice; Degraded + opens blocked on unresolved ambiguity.
- Fail criteria: ambiguous mapping accepted or opens proceed without Degraded on unresolved ambiguity.

AT-041
- Given: a generated `s4` label would exceed 64 chars.
- When: the system attempts to create an OrderIntent.
- Then: the intent is rejected before dispatch and `RiskState==Degraded`.
- Pass criteria: no order is sent; `/status` shows `RiskState::Degraded`; `mode_reasons` includes a label-length reason code if defined.
- Fail criteria: any order dispatch occurs or `RiskState` remains Active.

AT-921
- Given: a generated `s4` label would exceed 64 chars.
- When: the system attempts to create an OrderIntent.
- Then: the intent is rejected with `Rejected(LabelTooLong)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0; `RiskState==Degraded`.
- Fail criteria: dispatch occurs or reason missing/mismatched.



* `strat_id`: Static ID of the running strategy (e.g., `strangle_btc_low_vol`).  
* `group_id`: UUIDv4 (Shared by all legs in a single atomic attempt).  
* `leg_idx`: `0` or `1` (Identity within the group).  
* `intent_hash`: `xxhash64(instrument + side + qty_q + limit_price_q + group_id + leg_idx)` (see §1.1.1 for quantization)  
  **Hard rule:** Do NOT include wall-clock timestamps in the idempotency hash.

AT-343
- Given: two intents with identical canonical fields (instrument, side, qty_q, limit_price_q, group_id, leg_idx) evaluated at different wall-clock times.
- When: `intent_hash` is computed for both.
- Then: the two `intent_hash` values are identical.
- Pass criteria: `intent_hash(t0) == intent_hash(t1)` for identical canonical fields.
- Fail criteria: hash differs solely due to wall-clock time.

AT-933
- Given: a WS reconnect occurs and the exchange still has open orders for an existing `group_id`.
- When: the system re-fetches open orders and matches by `group_id`.
- Then: no duplicate dispatch occurs and the existing orders are treated as in-flight.
- Pass criteria: dispatch count remains 0 for duplicates; reconciliation succeeds.
- Fail criteria: duplicate dispatch occurs or orders are treated as missing.


### **1.1.1 Canonical Quantization (Pre-Hash & Pre-Dispatch)**

**Requirement:** All idempotency keys and order payloads MUST use canonical, exchange-valid rounded values.

**Where:** `soldier/core/execution/quantize.rs`

**Inputs:** `instrument_id`, `raw_qty`, `raw_limit_price`  
**Outputs:** `qty_q`, `limit_price_q` (quantized)

**Rules (Deterministic):**
- Fetch instrument constraints: `tick_size`, `amount_step`, `min_amount`.
- If any of `tick_size`, `amount_step`, or `min_amount` is missing or unparseable -> Reject(intent=InstrumentMetadataMissing) and do not dispatch (fail-closed).
- `qty_q = round_down(raw_qty, amount_step)` (never round up size).
- `limit_price_q = round_to_nearest_tick(raw_limit_price, tick_size)` (or round in the safer direction; see below).
- If `qty_q < min_amount` → Reject(intent=TooSmallAfterQuantization).
- Idempotency hash must be computed ONLY from quantized fields:
  `intent_hash = xxhash64(instrument + side + qty_q + limit_price_q + group_id + leg_idx)`

**Safer rounding direction:**
- For BUY: round `limit_price_q` DOWN (never pay extra).
- For SELL: round `limit_price_q` UP (never sell cheaper).

**Acceptance Tests (REQUIRED):**
AT-218
- Given: two codepaths compute the same intent fields.
- When: `intent_hash` is generated.
- Then: both hashes are identical.
- Pass criteria: `intent_hash` equality across codepaths.
- Fail criteria: hash mismatch for identical inputs.

AT-219
- Given: raw BUY and SELL prices that are not on tick.
- When: quantization runs.
- Then: BUY rounds down and SELL rounds up (never worse price).
- Pass criteria: BUY price never increases; SELL price never decreases.
- Fail criteria: BUY rounds up or SELL rounds down.

AT-908
- Given: `qty_q < min_amount` after quantization for an OPEN intent.
- When: quantization runs.
- Then: intent is rejected with `Rejected(TooSmallAfterQuantization)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-926
- Given: instrument metadata is missing/unparseable (`tick_size` or `amount_step` or `min_amount`).
- When: quantization runs for an OPEN intent.
- Then: the intent is rejected with `Rejected(InstrumentMetadataMissing)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or an implicit default is used.

AT-928
- Given: the WAL already contains `intent_hash` for a pending intent.
- When: the system evaluates a new intent with the same `intent_hash`.
- Then: it is a NOOP (no dispatch; no new WAL entry).
- Pass criteria: dispatch count remains 0; WAL unchanged.
- Fail criteria: a duplicate dispatch occurs or WAL duplicates the intent.

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
- Lock acquisition MUST be bounded (try_lock/timeout) with `group_lock_max_wait_ms` (Appendix A). If not acquired within the bound, the hot loop MUST NOT block and MUST force ReduceOnly until the lock clears.

**Fail-Closed Rule:**
- Group intent MUST be durably recorded before any leg dispatch. If persistence fails, the executor MUST abort and MUST NOT submit any leg orders.

**Where:** `soldier/core/execution/atomic_group_executor.rs`

**Acceptance Test (REQUIRED):**
AT-220
- Given: leg events arrive out of order (A fills fast, B rejects late).
- When: GroupState serialization is evaluated.
- Then: the group is never recorded `Complete` before B reaches terminal, and the first failure deterministically triggers containment → flatten.
- Pass criteria: no premature `Complete`; containment triggers on first failure.
- Fail criteria: `Complete` recorded early or containment not triggered.

AT-924
- Given: the group-level lock is held longer than `group_lock_max_wait_ms`.
- When: AtomicGroupExecutor attempts to acquire the lock in the hot loop.
- Then: the hot loop does not block and TradingMode is forced to ReduceOnly until the lock clears.
- Pass criteria: no stall; ReduceOnly enforced; OPEN blocked.
- Fail criteria: hot loop blocks or OPEN dispatch occurs while lock is unavailable.

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
    // Try up to 2 IOC rescue orders for the missing qty, crossing spread by rescue_cross_spread_ticks,
    // but ONLY if Liquidity Gate passes AND NetEdge remains ≥ min_edge.
    for _attempt in 0..2 {
      if !self.liquidity_gate_passes(&group)? { break; }
      if !self.net_edge_gate_passes(&group)? { break; }

      let rescue = self.build_rescue_intents(&group, &results, self.cfg.rescue_cross_spread_ticks)?;
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

**Acceptance Tests (REQUIRED):**
AT-116
- Given: AtomicGroup with Leg A filled and Leg B rejected.
- When: group result is evaluated.
- Then: `GroupState::MixedFailed` is recorded, containment runs, and no new OPENs are dispatched until exposure is neutral.
- Pass criteria: MixedFailed is recorded and exposure is flattened before any OPEN dispatch.
- Fail criteria: group marked Complete or OPEN dispatch occurs while exposure remains non-neutral.

AT-117
- Given: Leg A fills `0.6`, Leg B fills `0.0`.
- When: rescue IOC attempts execute.
- Then: at most **2** rescue IOC attempts occur; if mismatch persists, deterministic flatten executes.
- Pass criteria: ≤2 rescue attempts and flatten occurs if still mismatched.
- Fail criteria: >2 rescue attempts or mismatch persists without flatten.

AT-118
- Given: mixed-state where one leg is filled and another is rejected.
- When: containment path executes.
- Then: §3.1 emergency close runs with bounded attempts, then reduce-only delta hedge if still not neutral, and TradingMode is ReduceOnly.
- Pass criteria: bounded close attempts then hedge if needed; TradingMode ReduceOnly during exposure.
- Fail criteria: emergency close not executed or OPENs allowed while exposure persists.

AT-935
- Given: `append_group_intent` fails to persist the group intent.
- When: AtomicGroupExecutor attempts to dispatch legs.
- Then: no leg orders are submitted and the failure is surfaced.
- Pass criteria: dispatch count remains 0; failure is logged or returned.
- Fail criteria: any leg dispatch occurs.

AT-936
- Given: a MixedFailed group where LiquidityGate or Net Edge would reject rescue orders.
- When: containment Step A evaluates rescue dispatch.
- Then: no rescue IOC orders are submitted and Step B emergency close runs.
- Pass criteria: rescue dispatch count remains 0 under gate reject; emergency close invoked.
- Fail criteria: rescue orders are submitted when a gate rejects or Step B does not run.



### **1.2.2 Atomic Churn Circuit Breaker (Flatten Storm Guard)**
**Goal:** Prevent “death‑by‑fees” churn when a strategy repeatedly legs, partially fills, then emergency‑flattens.

**Rule (Deterministic):**
- Maintain a rolling counter keyed by `{strategy_id, structure_fingerprint}` where `structure_fingerprint` can be `(instrument_kind, tenor_bucket, delta_bucket, legs_signature)`.
- If `EmergencyFlattenGroup` triggers **> 2 times in 5 minutes** for the same key → **Blacklist** that key for **15 minutes**:
  - block new opens for that key (return `Rejected(ChurnBreakerActive)`),
  - allow closes/hedges (ReduceOnly) as normal.

**Where:** `soldier/core/risk/churn_breaker.rs`

**Acceptance Test (REQUIRED):**
AT-221
- Given: 3 EmergencyFlattenGroup triggers for the same key within 5 minutes.
- When: a 4th attempt is evaluated.
- Then: the 4th attempt is rejected and logged (`ChurnBreakerTrip`), with blacklist TTL enforced.
- Pass criteria: rejection + log + TTL enforcement.
- Fail criteria: 4th attempt proceeds or TTL not enforced.

### **1.2.3 Self-Impact Feedback Loop Guard (Echo Chamber Breaker)**

**Goal:** Prevent the bot from reacting to its own impact and recursively increasing exposure (“echo chamber”).
This is a **safety guard**, not a strategy feature.

**Where:** `soldier/core/risk/self_impact_guard.rs`

**Inputs (minimum):**
- Rolling public market volume estimate over `feedback_loop_window_s` (USD notional): `public_notional_usd`
- Rolling self trade notional over the same window (USD notional): `self_notional_usd`
- `public_trades_last_update_ts_ms` (epoch ms; freshness timestamp for public trade feed aggregation)
- `now_ms`
- Intended action classification (OPEN vs CLOSE/HEDGE/CANCEL)

**Freshness precondition (non-negotiable):**
- If `now_ms - public_trades_last_update_ts_ms > public_trade_feed_max_age_ms` OR the field is missing/unparseable:
  - The Self-Impact guard MUST NOT compute `self_fraction`.
  - Instead, the system MUST treat this as a trades-feed liveness failure:
    - Set `RiskState::Degraded`
    - Set Open Permission Latch reason `WS_TRADES_GAP_RECONCILE_REQUIRED`
    - Block opens until reconciliation clears the latch.

**Computation (only when feed is fresh):**
- `self_fraction = self_notional_usd / max(public_notional_usd, epsilon)`
- Trip condition (any):
  A) `self_fraction >= self_trade_fraction_trip` AND `self_notional_usd >= self_trade_min_self_notional_usd`
  B) `self_notional_usd >= self_trade_notional_trip_usd`
- If trip condition is met for a proposed OPEN in the same direction as recent self trades:
  - Reject the OPEN intent before dispatch with `Rejected(FeedbackLoopGuardActive)`
  - Apply cooldown: block further OPENs for `feedback_loop_cooldown_s` for the affected `{strategy_id, structure_fingerprint}` key.

**Acceptance Tests (REQUIRED):**
AT-953
- Given: `public_trades_last_update_ts_ms` is stale beyond `public_trade_feed_max_age_ms`.
  - All other gates are configured to pass (this test isolates stale-feed handling for the Self-Impact guard).
- When: the Self-Impact guard evaluates a new OPEN intent.
- Then: it does NOT compute `self_fraction`; it sets `RiskState::Degraded` and sets Open Permission Latch reason `WS_TRADES_GAP_RECONCILE_REQUIRED`.
- Pass criteria: OPEN blocked due to latch; no `Rejected(FeedbackLoopGuardActive)` is emitted.
- Fail criteria: FeedbackLoopGuard trips (or computes) while trade feed is stale OR OPEN dispatch occurs.

AT-955
- Given:
  - `feedback_loop_window_s = 10`
  - trade feed is fresh: `public_trades_last_update_ts_ms = now_ms - 1000` and `public_trade_feed_max_age_ms = 5000`
  - `self_trade_fraction_trip = 0.25` and `self_trade_min_self_notional_usd = 10_000`
  - `public_notional_usd = 100_000` and `self_notional_usd = 40_000` (so `self_fraction = 0.40`)
  - Proposed action is an **OPEN** in the same direction as recent self trades
  - All other gates are configured to pass (this test isolates the Self-Impact guard)
- When: an OPEN intent is evaluated.
- Then: the intent is rejected with `Rejected(FeedbackLoopGuardActive)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs, rejection missing/mismatched, or guard fails to compute trip from the provided notional inputs.

AT-956
- Given:
  - trade feed is fresh (as above)
  - `self_trade_notional_trip_usd = 150_000`
  - `public_notional_usd = 10_000_000` and `self_notional_usd = 200_000` (so self_fraction is small but notional is large)
  - Proposed action is an **OPEN** in the same direction as recent self trades
  - All other gates are configured to pass
- When: an OPEN intent is evaluated.
- Then: the intent is rejected with `Rejected(FeedbackLoopGuardActive)` via the notional-trip rule.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or the guard ignores the notional-trip path.

AT-957
- Given:
  - trade feed is fresh (as above)
  - `self_trade_fraction_trip = 0.25` and `self_trade_min_self_notional_usd = 10_000`
  - `self_trade_notional_trip_usd = 150_000`
  - `public_notional_usd = 200_000` and `self_notional_usd = 20_000` (so `self_fraction = 0.10`, below threshold; notional below trip)
  - All other gates are configured to pass (isolate Self-Impact guard)
- When: an OPEN intent is evaluated.
- Then: the Self-Impact guard MUST NOT reject with `FeedbackLoopGuardActive`; the intent proceeds to dispatch.
- Pass criteria: dispatch count becomes 1 and there is no `Rejected(FeedbackLoopGuardActive)`.
- Fail criteria: guard rejects despite being below thresholds.


### **1.3 Pre-Trade Liquidity Gate (Do Not Sweep the Book)**

**Council Weakness Covered:** No Liquidity Gate (Low) \+ Taker Bleed (Critical). **Requirement:** Before any order is sent (including IOC), the Soldier must estimate book impact for the requested size and reject trades that exceed max slippage. **Where:** `soldier/core/execution/gate.rs` **Input:** `OrderQty`, `L2BookSnapshot`, `max_slippage_bps = 10` (default: see Appendix A)

If `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms` (Appendix A), LiquidityGate MUST reject OPEN intents. CLOSE/HEDGE/replace order placement is rejected; CANCEL-only intents remain allowed. Deterministic Emergency Close is exempt from profitability gates, but still requires a valid price source; if L2 is missing/stale it MUST use the §3.1 fallback price source and MUST block only if no fallback source is valid.
Rejections due to missing/unparseable/stale L2 MUST use `Rejected(LiquidityGateNoL2)`.

**Output:** `Allowed | Rejected(reason=ExpectedSlippageTooHigh)`

**Algorithm (Deterministic):**

1. Walk the L2 book on the correct side (asks for buy, bids for sell).  
2. Compute the Weighted Avg Price (WAP) for `OrderQty`.  
3. Compute expected slippage: `slippage_bps = (WAP - BestPrice) / BestPrice * 10_000` (sign adjusted)  
4. Reject if `slippage_bps` > `max_slippage_bps` (default 10bps; `max_slippage_bps` from Appendix A).  
5. If rejected, log `LiquidityGateReject` with computed WAP \+ slippage.

**Scope (explicit):**
- Applies to normal dispatch and containment rescue IOC orders (see §1.1 containment Step A).
- Does NOT apply to Deterministic Emergency Close (§3.1) or containment Step B; emergency close MUST NOT be blocked by profitability gates.
- Emergency close still requires a valid price source; missing/stale L2 MUST use the §3.1 fallback price source and MUST block only if no fallback source is valid.

**Acceptance Test (REQUIRED):**
AT-222
- Given: an L2 book where `OrderQty` requires consuming multiple levels causing `slippage_bps > max_slippage_bps`.
- When: Liquidity Gate evaluates the order.
- Then: intent is rejected with `Rejected(ExpectedSlippageTooHigh)` and a `LiquidityGateReject` log; no `OrderIntent` is emitted.
- Pass criteria: rejection + log; pricer/NetEdge gate does not run.
- Fail criteria: order proceeds or log missing.
- And: emergency close proceeds even if Liquidity Gate would reject under the same slippage conditions.

AT-344
- Given: `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms`.
- When: Liquidity Gate evaluates an OPEN intent.
- Then: the intent is rejected (no dispatch) and a LiquidityGate rejection is logged.
- Pass criteria: no OPEN dispatch occurs; rejection reason recorded.
- Fail criteria: OPEN dispatch proceeds without a valid L2 snapshot.

AT-909
- Given: `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms` for an OPEN.
- When: Liquidity Gate evaluates the order.
- Then: the intent is rejected with `Rejected(LiquidityGateNoL2)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-421
- Given: `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms`.
- When: a CANCEL-only intent and a CLOSE/HEDGE order placement intent are evaluated.
- Then: CANCEL is allowed; CLOSE/HEDGE order placement is rejected (no dispatch).
- Pass criteria: cancel proceeds; close/hedge is rejected.
- Fail criteria: close/hedge proceeds or cancel is blocked.



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

**Acceptance Test (REQUIRED):**
AT-223
- Given: a widened spread and an IOC limit order.
- When: execution occurs.
- Then: the system never fills worse than `limit_price` and `Realized Edge >= Min_Edge` at the limit price.
- Pass criteria: no fills beyond `limit_price`; realized edge meets minimum.
- Fail criteria: fill worse than `limit_price` or realized edge below minimum.


### **1.4.1 Net Edge Gate (Fees + Expected Slippage)**
**Why this exists:** Prevent “gross edge” hallucinations from bypassing execution safety.

**Where:** `soldier/core/execution/gates.rs`  
**Input:** `gross_edge_usd`, `fee_usd`, `expected_slippage_usd`, `min_edge_usd`  
**Output:** `Allowed | Rejected(reason=NetEdgeTooLow)`

**Rule (Non-Negotiable):**
- `net_edge_usd = gross_edge_usd - fee_usd - expected_slippage_usd`
- If any of `gross_edge_usd`, `fee_usd`, `expected_slippage_usd`, or `min_edge_usd` is missing/unparseable -> Reject(intent=NetEdgeInputMissing) and do not dispatch (fail-closed).
- Reject if `net_edge_usd < min_edge_usd`.

**Hard Rule:**
- This gate MUST run **before** any `OrderIntent` is eligible for dispatch (before AtomicGroup creation).

**Scope (explicit):**
- Applies to normal dispatch and containment rescue IOC orders (see §1.1 containment Step A).
- Does NOT apply to Deterministic Emergency Close (§3.1) or reduce-only close/hedge intents.

**Acceptance Tests (REQUIRED):**

AT-015
- Given: `net_edge_usd < min_edge_usd`.
- When: an OPEN intent is evaluated by the Net Edge Gate.
- Then: the OPEN intent is rejected and MUST NOT dispatch.
- Pass criteria: zero dispatch for that OPEN.
- Fail criteria: OPEN dispatch occurs.

AT-327
- Given: Net Edge Gate would reject under net edge conditions.
- When: Deterministic Emergency Close runs.
- Then: emergency close proceeds despite Net Edge Gate rejection.
- Pass criteria: emergency close dispatch occurs.
- Fail criteria: emergency close blocked by Net Edge Gate.

AT-932
- Given: `fee_usd` or `expected_slippage_usd` is missing/unparseable for an OPEN intent.
- When: the Net Edge Gate evaluates the intent.
- Then: the intent is rejected with `Rejected(NetEdgeInputMissing)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or an implicit default is used.


### **1.4.2 Inventory Skew Gate (Execution Bias vs Current Exposure)**
**Why this exists:** Prevent “good trades” from compounding the *wrong* inventory when already near limits.

**Input:** `current_delta`, `delta_limit`, `side`, `min_edge_usd`, `limit_price`, `fair_price`  
**Output:** `Allowed | Rejected(reason=InventorySkew)` and **adjusted** `{min_edge_usd, limit_price}`

**Input Definition:**
`delta_limit` is absolute delta in underlying units (strategy’s delta convention) and MUST be provided by policy/config; missing ⇒ reject OPEN intents (fail-closed).
Rejections for missing `delta_limit` MUST use `Rejected(InventorySkewDeltaLimitMissing)`.

**Rule:**
- `inventory_bias = clamp(current_delta / delta_limit, -1, +1)`  
  (positive = already long delta; negative = already short delta)

**Biasing behavior (deterministic):**
- **BUY intents when `inventory_bias > 0` (already long):**
  - Require higher edge: `min_edge_usd := min_edge_usd * (1 + inventory_skew_k * inventory_bias)` where `inventory_skew_k = 0.5` (default; see Appendix A)
  - Be less aggressive: shift `limit_price` **away** from the touch by `bias_ticks(inventory_bias)` where `bias_ticks(x) = ceil(abs(x) * inventory_skew_tick_penalty_max)` and `inventory_skew_tick_penalty_max = 3` (default; see Appendix A)
- **SELL intents when `inventory_bias > 0` (already long):**
  - Allow slightly lower edge (within bounds) and/or be more aggressive to **flatten** inventory
- Mirror the above for `inventory_bias < 0` (already short).

**Hard Rule:**
- Inventory Skew runs **after** Net Edge Gate and **before** pricer dispatch. If it adjusts `min_edge_usd`, the Net Edge Gate MUST be re-evaluated against the adjusted `min_edge_usd` before dispatch; the adjusted value is authoritative for dispatch eligibility.
- Inventory Skew may *tighten* requirements for risk-increasing trades and *loosen* requirements only for risk-reducing trades.
- Inventory Skew must be computed using **current + pending** exposure, or it must run **after** PendingExposure reservation (see §1.4.2.1). This prevents concurrent risk-budget double-spend.

**Acceptance Test (REQUIRED):**
AT-224
- Given: `current_delta ≈ 0.9 * delta_limit` (near limit).
- When: Inventory Skew evaluates BUY and SELL intents.
- Then: BUY intent that previously passed Net Edge is rejected; SELL intent passes (risk-reducing); SELL intent that initially fails Net Edge passes after `min_edge_usd` adjustment and re-evaluation.
- Pass criteria: BUY rejected; SELL allowed; re-evaluation uses adjusted `min_edge_usd`.
- Fail criteria: BUY allowed or SELL rejected contrary to rules.

AT-043
- Given: `delta_limit` is missing/unparseable.
- When: an OPEN intent enters Inventory Skew Gate evaluation.
- Then: intent is rejected and RiskState is Degraded (or equivalent fail-closed outcome).
- Pass criteria: no OPEN dispatch occurs.
- Fail criteria: OPEN proceeds with an implicit/zero default.

AT-922
- Given: `delta_limit` is missing/unparseable.
- When: an OPEN intent enters Inventory Skew Gate evaluation.
- Then: the intent is rejected with `Rejected(InventorySkewDeltaLimitMissing)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-030
- Given: `inventory_skew_k=0.5` and `inventory_skew_tick_penalty_max=3`.
- When: `inventory_bias=1.0` for BUY.
- Then: limit price shifts 3 ticks below best ask.
- Pass criteria: exactly 3 tick shift.
- Fail criteria: different tick shift.

AT-934
- Given: `pending_delta` is already reserved and `current_delta` alone is below the limit.
- When: Inventory Skew evaluates a new OPEN intent.
- Then: the gate uses `current + pending` exposure (or runs after reservation) and rejects or tightens as required.
- Pass criteria: decision is based on combined exposure; no dispatch when combined exposure breaches limits.
- Fail criteria: decision uses current-only exposure and allows dispatch.


### **1.4.2.1 PendingExposure Reservation (Anti Over‑Fill)**
**Why:** Without reservation, multiple concurrent signals can all observe the same “free delta” and over‑allocate risk.

**Requirement:** Before dispatching any new `AtomicGroup`, the Soldier must **reserve** the projected exposure impact of the intent, atomically, against a shared budget.

**Where:** `soldier/core/risk/pending_exposure.rs`

**Model (Minimum Viable):**
- Maintain `pending_delta` (and optionally pending vega/gamma) per instrument + global.
- For each candidate group:
  1. Compute `delta_impact_est` from proposal greeks (or worst‑case delta bound).
  2. Attempt `reserve(delta_impact_est)`:
     - If reservation would breach limits → reject the intent with `Rejected(PendingExposureBudgetExceeded)`.
  3. On terminal outcome:
     - Filled → release reservation and convert to realized exposure.
     - Rejected/Canceled/Failed → release reservation.

**Hard Rule:** Reservation must occur **before** any network dispatch; release must be triggered from TLSM terminal transitions.

**Acceptance Test (REQUIRED):**
AT-225
- Given: 5 concurrent opens with identical pre-trade `current_delta=0`.
- When: PendingExposure reservation runs.
- Then: only the subset that fits the budget reserves; the rest reject; no over-fill occurs.
- Pass criteria: reservations limited to budget; rejected intents do not dispatch.
- Fail criteria: over-fill or reservations exceed budget.

AT-910
- Given: a reservation would breach the exposure budget.
- When: `reserve(delta_impact_est)` is attempted.
- Then: the intent is rejected with `Rejected(PendingExposureBudgetExceeded)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or reason missing/mismatched.

### **1.4.2.2 Global Exposure Budget (Cross‑Instrument, Correlation‑Aware)**
**Goal:** Prevent “safe per‑instrument” trades from stacking into unsafe portfolio exposure.

**Where:** `soldier/core/risk/exposure_budget.rs`

**Budget Model (Pragmatic MVP):**
- Track exposures per instrument and portfolio aggregate:
  - `delta_usd` (required), `vega_usd` (optional v1), `gamma_usd` (optional v1).
- Portfolio aggregation uses conservative correlation buckets:
  - `corr(BTC,ETH)=0.8`, `corr(BTC,alts)=0.6`, `corr(ETH,alts)=0.6`.
- Gate new opens if portfolio exposure breaches limits even if single‑instrument gates pass.
  - Rejections for portfolio breach MUST use `Rejected(GlobalExposureBudgetExceeded)`.

**Integration Rule:** The Global Budget must be checked using **current + pending** exposure (see §1.4.2.1).

**Acceptance Test (REQUIRED):**
AT-226
- Given: BTC and ETH are both near limits.
- When: a new BTC trade passes the local delta gate.
- Then: the trade is rejected if the portfolio budget would breach after correlation adjustment.
- Pass criteria: portfolio-level rejection triggers.
- Fail criteria: trade proceeds despite portfolio breach.

AT-911
- Given: portfolio exposure would breach after correlation adjustment.
- When: Global Exposure Budget evaluates an OPEN intent.
- Then: the intent is rejected with `Rejected(GlobalExposureBudgetExceeded)` and no dispatch occurs.
- Pass criteria: rejection reason matches; dispatch count remains 0.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-929
- Given: `pending_delta` is already reserved near the limit and `current_delta` is within limits.
- When: Global Exposure Budget evaluates a new OPEN intent.
- Then: the intent is rejected if `current + pending` would breach the portfolio budget.
- Pass criteria: rejection occurs based on combined exposure.
- Fail criteria: intent passes using current-only exposure.

### **1.4.3 Margin Headroom Gate (Liquidation Shield) — MUST implement**

**Why this exists:** Delta-neutral ≠ safe. Deribit can hike maintenance margin; margin liquidation is the silent killer.

**Where:**
- Gate: `soldier/core/risk/margin_gate.rs`
- Fetcher: `soldier/infra/deribit/account_summary.rs`

**Inputs:** `/private/get_account_summary` → `maintenance_margin`, `initial_margin`, `equity`  
**Computed:** `mm_util = maintenance_margin / max(equity, epsilon)`

**Rules (deterministic):**
- If `mm_util` >= `mm_util_reject_opens` (see Appendix A for `mm_util_reject_opens`) → **Reject** any **NEW opens**
- Rejections at `mm_util_reject_opens` MUST use `Rejected(MarginHeadroomRejectOpens)`.
- If `mm_util` >= `mm_util_reduceonly` (see Appendix A for `mm_util_reduceonly`) → PolicyGuard MUST force `TradingMode = ReduceOnly` (block opens; allow close/hedge/cancel)
- If `mm_util` >= `mm_util_kill` (see Appendix A for `mm_util_kill`) → PolicyGuard MUST force `TradingMode = Kill` + trigger deterministic emergency flatten only if eligible per §2.2.3 Kill Mode Semantics (existing §3.1/§1.2 containment applies)

**Acceptance Tests (REQUIRED):**
AT-227
- Given: `equity=100k`, `maintenance_margin=72k`.
- When: Margin Headroom Gate evaluates a new OPEN.
- Then: the OPEN is rejected.
- Pass criteria: OPEN rejected at gate level.
- Fail criteria: OPEN proceeds.

AT-912
- Given: `mm_util >= mm_util_reject_opens` and `< mm_util_reduceonly`.
- When: Margin Headroom Gate evaluates a new OPEN.
- Then: the OPEN is rejected with `Rejected(MarginHeadroomRejectOpens)`.
- Pass criteria: rejection reason matches; no OPEN dispatch.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-228
- Given: `equity=100k`, `maintenance_margin=90k`.
- When: PolicyGuard computes TradingMode.
- Then: `TradingMode = ReduceOnly`.
- Pass criteria: ReduceOnly entered; OPEN blocked.
- Fail criteria: TradingMode remains Active.

AT-206
- Given: `mm_util >= mm_util_reject_opens` but below `mm_util_reduceonly`.
- When: a new OPEN intent is evaluated at the Margin Headroom Gate.
- Then: the OPEN intent is rejected; CLOSE/HEDGE/CANCEL intents remain allowed.
- Pass criteria: OPEN rejected at gate level; TradingMode may still be Active (gate rejection is independent of mode).
- Fail criteria: OPEN intent passes the Margin Headroom Gate while `mm_util >= mm_util_reject_opens`.

AT-207
- Given: `mm_util >= mm_util_reduceonly` but below `mm_util_kill`.
- When: PolicyGuard computes TradingMode.
- Then: `TradingMode = ReduceOnly`; OPEN intents blocked; CLOSE/HEDGE/CANCEL allowed.
- Pass criteria: ReduceOnly entered; opens blocked; closes/hedges allowed.
- Fail criteria: TradingMode is Active while `mm_util >= mm_util_reduceonly`.

AT-208
- Given: `mm_util >= mm_util_kill`.
- When: PolicyGuard computes TradingMode.
- Then: `TradingMode = Kill`; deterministic emergency flatten executes per §3.1/§1.2 containment rules.
- Pass criteria: Kill entered; containment executes (if eligible per §2.2.3); no new orders dispatched except containment.
- Fail criteria: TradingMode is ReduceOnly or Active while `mm_util >= mm_util_kill`.

### **1.4.4 Deribit Order-Type Preflight Guard (Artifact-Backed)**

**Purpose:** Freeze the engine against *verified* Deribit behavior and prevent “market order roulette.”

**Preflight Rules (MUST implement):**

**A) Options (`instrument_kind == option`)**
- Allowed `type`: **`limit` only**
- **Market orders:** forbidden by policy (F-01b)  
  - If `type == market` → **REJECT** with `Rejected(OrderTypeMarketForbidden)` (no rewrite/normalization).
- **Stop orders:** forbidden (F-01a)  
  - Reject any `type in {stop_market, stop_limit}` or any presence of `trigger` / `trigger_price` with `Rejected(OrderTypeStopForbidden)`.
- **Linked/OCO orders:** forbidden (F-08)  
  - Reject any non-null `linked_order_type` with `Rejected(LinkedOrderTypeForbidden)`.
- Execution policy: use **Aggressive IOC Limit** with bounded `limit_price_q` (see §1.4.1).

**B) Futures/Perps (`instrument_kind in {linear_future, inverse_future, perpetual}`)**
- **Allowed `type`:** `limit` (for this bot's execution policy)
- **Market orders:** forbidden by policy  
  - If `type == market` → **REJECT** with `Rejected(OrderTypeMarketForbidden)` (no rewrite/normalization).
- **Stop orders:** **NOT SUPPORTED** for this bot (execution policy is IOC limits only)  
  - Reject any `type in {stop_market, stop_limit}` even if `trigger` is present, with `Rejected(OrderTypeStopForbidden)`.
  - Deribit venue fact (F-09): If stop orders were enabled, venue requires `trigger` to be set.
- **Linked/OCO orders:** forbidden unless explicitly certified (F-08 currently indicates NOT SUPPORTED)  
  - Reject any non-null `linked_order_type` unless `linked_orders_supported == true` **and** feature flag `ENABLE_LINKED_ORDERS_FOR_BOT == true`, with `Rejected(LinkedOrderTypeForbidden)`.

**Linked orders gating variables (contract-bound definitions):**
- `linked_orders_supported` (bool): MUST be `false` for v5.1 (see Deribit Venue Facts Addendum F-08: VERIFIED (NOT SUPPORTED)).
- `ENABLE_LINKED_ORDERS_FOR_BOT` (bool): runtime config feature flag; default `false` (fail-closed if missing/unset).

**Acceptance Test (REQUIRED):**
AT-004
- Given: an intent with `linked_order_type` set (non-null).
- When: preflight validation runs with `linked_orders_supported==false` and `ENABLE_LINKED_ORDERS_FOR_BOT==false` (defaults).
- Then: the intent is rejected before any API call.
- Pass criteria: no outbound order is emitted and a deterministic reject reason is logged.
- Fail criteria: any order with non-null `linked_order_type` is dispatched.


**C) Post-only behavior**
- If `post_only == true` and order would cross the book, Deribit rejects (F-06).  
  - Preflight must ensure post-only prices are non-crossing (or disable post_only). If it would cross, reject with `Rejected(PostOnlyWouldCross)`.

**Enforcement points (code):**
- Centralize in a single function called by the trade dispatch path (`private/buy` + `private/sell`) before any API call.
- Violations must be **hard rejects** (do not “try anyway”).

**Regression tests (MUST):**

AT-016
- Given: an options order intent has `order_type == market`.
- When: Deribit Order-Type Preflight Guard runs.
- Then: intent MUST be rejected before dispatch.
- Pass criteria: no dispatch occurs.
- Fail criteria: market order dispatch occurs.

AT-017
- Given: a perpetual order intent has `order_type == market`.
- When: preflight runs.
- Then: intent MUST be rejected before dispatch.
- Pass criteria: no dispatch occurs.
- Fail criteria: market order dispatch occurs.

AT-018
- Given: an options order intent is `stop_market` or stop with market execution.
- When: preflight runs.
- Then: intent MUST be rejected before dispatch.
- Pass criteria: no dispatch occurs.
- Fail criteria: stop-market dispatch occurs.

AT-019
- Given: a perpetual order intent is `stop_market` or stop with market execution.
- When: preflight runs.
- Then: intent MUST be rejected before dispatch.
- Pass criteria: no dispatch occurs.
- Fail criteria: stop-market dispatch occurs.

AT-913
- Given: an intent with `order_type == market`.
- When: preflight validation runs.
- Then: the intent is rejected with `Rejected(OrderTypeMarketForbidden)`.
- Pass criteria: rejection reason matches; no dispatch occurs.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-914
- Given: an intent with `order_type in {stop_market, stop_limit}`.
- When: preflight validation runs.
- Then: the intent is rejected with `Rejected(OrderTypeStopForbidden)`.
- Pass criteria: rejection reason matches; no dispatch occurs.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-915
- Given: `linked_order_type` is non-null while linked orders are unsupported.
- When: preflight validation runs.
- Then: the intent is rejected with `Rejected(LinkedOrderTypeForbidden)`.
- Pass criteria: rejection reason matches; no dispatch occurs.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-916
- Given: `post_only == true` and the limit price would cross the book.
- When: preflight validation runs.
- Then: the intent is rejected with `Rejected(PostOnlyWouldCross)`.
- Pass criteria: rejection reason matches; no dispatch occurs.
- Fail criteria: dispatch occurs or reason missing/mismatched.

- See AT-004 for linked orders testing (`linked_orders_oco_is_gated_off`).


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

**Acceptance Test (REQUIRED):**
AT-229
- Given: `RiskState::Degraded`.
- When: an Open intent and a Close/Hedge intent are submitted.
- Then: Open is rejected; Close/Hedge is allowed; no exposure-increasing action occurs while `RiskState != Healthy`.
- Pass criteria: Open blocked; Close/Hedge allowed; exposure not increased.
- Fail criteria: Open allowed or exposure increases while Degraded.



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

**Acceptance Test (REQUIRED):**
AT-230
- Given: Fill arrives before Ack.
- When: TLSM processes events.
- Then: final state is Filled, no crash, WAL contains both events.
- Pass criteria: Filled state and WAL contains both events.
- Fail criteria: crash, wrong state, or WAL missing events.


### **2.2 PolicyGuard (Single Authoritative TradingMode Resolver)**
**Goal:** Eliminate conflicting “mode sources” and prevent stale/late policy pushes from re‑enabling risk.

**Where:** `soldier/core/policy/guard.rs`

**Inputs:**
- **Timebase convention:** all `*_ts_ms` values are epoch milliseconds; `now_ms` is current epoch milliseconds (and `now` refers to `now_ms` in this contract); seconds are derived as `(now_ms - *_ts_ms)/1000`.
- `python_policy` (latest policy payload)
- `python_policy_generated_ts_ms` (timestamp from Commander when policy was computed)
- `watchdog_last_heartbeat_ts_ms`
- `now_ms` (local epoch milliseconds used for staleness calculations)
- `cortex_override` (effective max-severity across §2.3 producers; see §2.3)

- `f1_cert` (from `artifacts/F1_CERT.json`: `{status, generated_ts_ms, build_id, runtime_config_hash, contract_version}`)
- `fee_model_cache_age_s` (from §4.2)
- `risk_state` (Healthy | Degraded | Maintenance | Kill)
- `bunker_mode_active` (bool; from §2.3.2 Network Jitter Monitor)
- `evidence_chain_state` (EvidenceChainState; from §2.2.2 EvidenceGuard)
- `policy_age_sec` (derived: `(now_ms - python_policy_generated_ts_ms) / 1000`)
- `mm_util` (float; maintenance margin utilization; from §1.4.3 Margin Headroom Gate)
- `mm_util_last_update_ts_ms` (epoch ms; freshness timestamp for `mm_util`; see §2.2.1.1 and §7.0)
- `disk_used_pct` (float; ratio in [0,1], where 0.80 means 80% used; from §7.2 Disk Watermarks)
- `disk_used_last_update_ts_ms` (epoch ms; freshness timestamp for `disk_used_pct`; see §2.2.1.1 and §7.0)
- `emergency_reduceonly_active` (bool; true if `POST /api/v1/emergency/reduce_only` is latched/cooldown active)
  - Cooldown semantics: Once set to true via endpoint call, remains true for `emergency_reduceonly_cooldown_s` (default: 300s; see Appendix A) after the endpoint call timestamp.
  - State transition: automatically clears to false after cooldown duration expires AND reconciliation confirms exposure is safe (if reconciliation is required by trigger source).
  - Invariant: While true, PolicyGuard MUST compute `TradingMode::ReduceOnly` (see §2.2.3 precedence).
- `open_permission_blocked_latch` (bool; from §2.2.4 CP-001)
- `open_permission_reason_codes` (OpenPermissionReasonCode[]; from §2.2.4 CP-001)
- `rate_limit_session_kill_active` (bool; true if 10028/session termination occurred and reconciliation has not cleared)


#### **2.2.1 Runtime F1 Certification Gate (HARD, runtime enforcement)**
- PolicyGuard MUST read `artifacts/F1_CERT.json`.
- Required schema (minimum keys): `{ status, generated_ts_ms, build_id, runtime_config_hash, contract_version }`.
  - `build_id`: immutable build identifier for the running binary (e.g., git commit SHA).
  - `runtime_config_hash`: `sha256` hex of canonicalized runtime config (see below).
  - `contract_version`: MUST equal the canonical `contract_version` literal in Definitions.
  - `policy_hash_at_cert_time` MAY be included for observability only and MUST NOT be used as a runtime validity gate.
- Freshness window: default 24h (configurable). If missing OR stale OR FAIL => TradingMode MUST be ReduceOnly.
- Binding (Canary hardening): if any of these do not match runtime, F1_CERT MUST be treated as INVALID (ReduceOnly):
  - `F1_CERT.build_id != runtime.build_id`
  - `F1_CERT.runtime_config_hash != runtime.runtime_config_hash`
  - `F1_CERT.contract_version != runtime.contract_version`
- While in ReduceOnly due to F1 invalidity: allow only closes/hedges/cancels; block all opens.
- This rule is strict: no caching last-known-good and no grace periods.

**Acceptance Tests (REQUIRED):**

AT-020
- Given: F1_CERT.status == PASS but `build_id` OR `runtime_config_hash` OR `contract_version` mismatches runtime.
- When: TradingMode is computed.
- Then: TradingMode MUST be ReduceOnly and OPEN must be blocked.
- Pass criteria: `/status.trading_mode == ReduceOnly` and OPEN does not dispatch.
- Fail criteria: `trading_mode` Active or OPEN dispatch occurs.

AT-021
- Given: F1_CERT was valid previously, then becomes missing OR stale OR FAIL.
- When: TradingMode is computed.
- Then: TradingMode MUST be ReduceOnly (no "last-known-good" bypass).
- Pass criteria: `/status.trading_mode == ReduceOnly` and OPEN does not dispatch.
- Fail criteria: `trading_mode` Active while F1_CERT is missing/stale/FAIL.

AT-012
- Given: F1_CERT has `contract_version="5.2"` and runtime `contract_version` is `"5.2"`.
- When: PolicyGuard validates F1_CERT binding checks.
- Then: `contract_version` comparison passes (no ReduceOnly due to formatting mismatch).
- Pass criteria: TradingMode not forced to ReduceOnly due solely to `contract_version` formatting.
- Fail criteria: ReduceOnly occurs due to "header string vs numeric string" mismatch.

AT-410
- Given: F1_CERT.status == PASS with matching build_id/runtime_config_hash/contract_version, but `policy_hash_at_cert_time` differs from current policy hash.
- When: TradingMode is computed.
- Then: TradingMode is not forced to ReduceOnly due solely to `policy_hash_at_cert_time`.
- Pass criteria: TradingMode remains Active if no other gates are active.
- Fail criteria: ReduceOnly occurs with only `policy_hash_at_cert_time` mismatching.

AT-423
- Given: `artifacts/F1_CERT.json` on disk contains a PASS cert with matching build_id/runtime_config_hash/contract_version.
- When: the file is modified on disk to `status="FAIL"` or deleted, and PolicyGuard computes TradingMode on the next tick.
- Then: TradingMode MUST be ReduceOnly and `/status.f1_cert.status` reflects FAIL or MISSING.
- Pass criteria: `/status.trading_mode == ReduceOnly` within one tick and OPEN does not dispatch.
- Fail criteria: `trading_mode` Active or `/status.f1_cert.status` remains PASS after the file change.

**Acceptance Tests (References):**
- AT-003 in §7.0 validates `/status` F1_CERT fields.


**Canonical hashing rule (non-negotiable):**
- `runtime_config_hash` MUST be computed as `sha256(canonical_json_bytes(config))` where `canonical_json_bytes` means:
  - JSON with **stable key ordering** (sorted recursively),
  - no insignificant whitespace,
  - UTF-8 encoding.

AT-113
- Given: two runtime config JSON inputs that are semantically identical but differ only in key order and whitespace.
- When: `runtime_config_hash` is computed for both.
- Then: both hashes MUST be identical.
- Pass criteria: PolicyGuard does not force ReduceOnly due solely to formatting-only differences.
- Fail criteria: formatting-only changes alter the hash and cause F1 binding mismatch.


#### **2.2.1.1 PolicyGuard Critical Input Freshness (Missing/Stale → Fail-Closed for Opens)**

**Rule (non-negotiable):**
PolicyGuard MUST NOT return `TradingMode::Active` if any critical safety input required for Kill/ReduceOnly decisions is missing or stale.

**Critical inputs (minimum):**
**Critical inputs (definition):** any PolicyGuard input referenced by §2.2.3 precedence predicates. Missing/unparseable inputs MUST be treated as missing/stale and force ReduceOnly with `REDUCEONLY_INPUT_MISSING_OR_STALE`.
- `mm_util` (from account summary) must have `mm_util_last_update_ts_ms`
- `disk_used_pct` must have `disk_used_last_update_ts_ms`
- session termination / rate-limit kill flag must be explicit (no "unknown treated as false")

**Freshness defaults (configurable):**
- `mm_util_max_age_ms = 30_000`
- `disk_used_max_age_ms = 30_000`

**Enforcement:**
- If any critical input is missing OR `now_ms - last_update_ts_ms > max_age_ms`:
  - force `TradingMode = ReduceOnly` (block OPEN; allow CLOSE/HEDGE/CANCEL)
  - set `mode_reasons` to include `REDUCEONLY_INPUT_MISSING_OR_STALE`

**Acceptance test (REQUIRED):**
- Simulate `mm_util_last_update_ts_ms` stale > max age → verify OPEN blocked within one tick; CLOSE/HEDGE/CANCEL still allowed.

AT-001
- Given: `mm_util` is present but `mm_util_last_update_ts_ms` is older than `mm_util_max_age_ms`.
- When: PolicyGuard computes `TradingMode`.
- Then: `TradingMode==ReduceOnly` and `mode_reasons` includes `REDUCEONLY_INPUT_MISSING_OR_STALE`.
- Pass criteria: OPEN intents are blocked within one tick; CLOSE/HEDGE/CANCEL remain allowed.
- Fail criteria: PolicyGuard returns Active or allows any OPEN while critical inputs are stale/missing.

AT-112
- Given: `watchdog_last_heartbeat_ts_ms` is missing or unparseable.
- When: PolicyGuard computes `TradingMode`.
- Then: `TradingMode==ReduceOnly` and `mode_reasons` includes `REDUCEONLY_INPUT_MISSING_OR_STALE`.
- Pass criteria: OPEN does not dispatch.
- Fail criteria: TradingMode Active (or OPEN dispatch) when a precedence input is missing/unparseable.

AT-348
- Given: `rate_limit_session_kill_active` is missing or unparseable.
- When: PolicyGuard computes `TradingMode`.
- Then: `TradingMode==ReduceOnly` and `mode_reasons` includes `REDUCEONLY_INPUT_MISSING_OR_STALE`.
- Pass criteria: OPEN does not dispatch.
- Fail criteria: TradingMode Active (or OPEN dispatch) when the session termination flag is missing/unparseable.

AT-349
- Given: `mm_util` is present but `mm_util_last_update_ts_ms` is missing or unparseable, and all other gates would allow `TradingMode::Active`.
- When: PolicyGuard computes `TradingMode`.
- Then: `TradingMode==ReduceOnly` and `mode_reasons` includes `REDUCEONLY_INPUT_MISSING_OR_STALE`.
- Pass criteria: OPEN does not dispatch.
- Fail criteria: TradingMode Active (or OPEN dispatch) when `mm_util_last_update_ts_ms` is missing/unparseable.

AT-350
- Given: `disk_used_pct` is present but `disk_used_last_update_ts_ms` is missing or unparseable, and all other gates would allow `TradingMode::Active`.
- When: PolicyGuard computes `TradingMode`.
- Then: `TradingMode==ReduceOnly` and `mode_reasons` includes `REDUCEONLY_INPUT_MISSING_OR_STALE`.
- Pass criteria: OPEN does not dispatch.
- Fail criteria: TradingMode Active (or OPEN dispatch) when `disk_used_last_update_ts_ms` is missing/unparseable.

AT-413
- Given: each critical input referenced by §2.2.3 is missing or unparseable one at a time, and all other gates allow `TradingMode::Active`.
- When: PolicyGuard computes `TradingMode`.
- Then: `TradingMode==ReduceOnly` and `mode_reasons` includes `REDUCEONLY_INPUT_MISSING_OR_STALE`.
- Pass criteria: every missing/unparseable input forces ReduceOnly within one tick; CLOSE/HEDGE/CANCEL allowed.
- Fail criteria: any missing/unparseable input yields Active or missing reason code.



#### **2.2.2 EvidenceGuard (No Evidence → No Opens) — HARD RUNTIME INVARIANT**

**Purpose (TOC constraint relief):** Close the missing enforcement link: if the evidence chain is not green, the system MUST NOT open new risk. “Nice architecture” is meaningless unless it is unbreakable in production.

**Definition (Evidence Chain = required artifacts):**
The following MUST be writable + joinable for every dispatched open-intent:
- WAL intent entry (durable)
- TruthCapsule (with decision_snapshot_id)
- Decision Snapshot payload (L2 top-N at decision time)
- Attribution row for any fill(s) that occur (fees/slippage/net pnl)
  - NOTE: An open-intent that produces zero fills is NOT required to have an attribution row.

**Invariant (Non-Negotiable):**
- If Evidence Chain is not GREEN → **block ALL new OPEN intents**.
- CLOSE / HEDGE / CANCEL intents are allowed only if the cancel/replace is NOT risk-increasing per §2.2.5, and only when not superseded by §2.2.3 Kill hard-stop semantics.
- Risk-increasing CANCEL/REPLACE MUST be rejected while `EvidenceChainState != GREEN` (see §2.2.5 definition).
- EvidenceGuard triggers `RiskState::Degraded`; PolicyGuard computes `TradingMode::ReduceOnly` via the canonical precedence ladder while `EvidenceChainState != GREEN`, and until GREEN recovers and remains stable for the cooldown window.

**GREEN/RED criteria (minimum):**
EvidenceChainState = GREEN iff ALL are true (rolling window; default `evidenceguard_window_s = 60` seconds, safety-critical; configurable in Appendix A):
- **All required EvidenceGuard counters MUST be defined and parseable** (fail-closed).
  - Missing/unparseable required counter(s) => EvidenceChainState MUST be not GREEN.
  - Required counters (minimum): `truth_capsule_write_errors`, `decision_snapshot_write_errors`, `wal_write_errors`, `parquet_queue_overflow_count`.
- Required counters MUST be fresh: if `now_ms - evidenceguard_counters_last_update_ts_ms` > `evidenceguard_counters_max_age_ms` (default 60000; see Appendix A for `evidenceguard_counters_max_age_ms`), EvidenceChainState MUST be not GREEN and OPEN intents MUST be blocked.
- `wal_write_errors` MUST increment on any failure to satisfy RecordedBeforeDispatch for an OPEN intent, including WAL enqueue failure (bounded queue full) and any persistence/write failure.
- `truth_capsule_write_errors` has not increased within the last `evidenceguard_window_s`
- `decision_snapshot_write_errors` has not increased within the last `evidenceguard_window_s`
- `parquet_queue_overflow_count` not increasing
- `wal_write_errors` has not increased within the last `evidenceguard_window_s`

- `parquet_queue_depth_pct` is defined AND below thresholds (fail-closed if metrics unavailable):
  - Metrics MUST exist: `parquet_queue_depth` (gauge, count), `parquet_queue_capacity` (gauge, count).
  - Derived: `parquet_queue_depth_pct = parquet_queue_depth / max(parquet_queue_capacity, 1)`
  - Trip (breach window): if `parquet_queue_depth_pct > parquet_queue_trip_pct` for >= `parquet_queue_trip_window_s` seconds → EvidenceChainState != GREEN
  - Clear (hysteresis): require `parquet_queue_depth_pct < parquet_queue_clear_pct` for >= `queue_clear_window_s` seconds before GREEN (cleared only after max(queue_clear_window_s, evidenceguard_global_cooldown) with all criteria satisfied)

**Where enforced (must be explicit):**
- PolicyGuard `get_effective_mode()` MUST include EvidenceGuard in precedence.
- Hot-path execution gate MUST check EvidenceChainState before dispatching OPEN orders.

**Acceptance Tests (REQUIRED):**

AT-005
- Given: Evidence writers are healthy (WAL + TruthCapsule + Decision Snapshot succeed) and an OPEN intent results in zero fills.
- When: EvidenceGuard evaluates EvidenceChainState over the window.
- Then: EvidenceChainState does not flip to not-GREEN solely due to missing attribution rows.
- Pass criteria: EvidenceChainState can remain GREEN (assuming other writers are healthy).
- Fail criteria: EvidenceGuard blocks opens because an attribution row is absent when no fills occurred.

AT-105
- Given: `evidenceguard_window_s=60` and `truth_capsule_write_errors` increases by 1 at T0 and does not increase afterward.
- When: EvidenceGuard evaluates at `now_ms=T0+59_000` and again at `now_ms=T0+61_000`.
- Then: at +59s EvidenceChainState is not GREEN due to the window; at +61s it may become GREEN only if other criteria + cooldown/hysteresis are satisfied.
- Pass criteria: the 60s window boundary affects GREEN eligibility deterministically.
- Fail criteria: GREEN eligibility ignores the window or uses an unspecified duration.

AT-107
- Given: `wal_write_errors` increments (unable to write intent to WAL).
- When: EvidenceGuard evaluates EvidenceChainState.
- Then: EvidenceChainState MUST be not GREEN (fail-closed); OPEN intents blocked.
- Pass criteria: WAL write failure forces ReduceOnly/blocking of Opens.
- Fail criteria: System remains GREEN despite WAL write failures (fail-open).

AT-414
- Given: an OPEN intent fills and the attribution row is missing or fails to write.
- When: EvidenceGuard evaluates EvidenceChainState.
- Then: EvidenceChainState MUST be not GREEN (fail-closed); OPEN intents blocked.
- Pass criteria: EvidenceChainState not GREEN; OPEN does not dispatch.
- Fail criteria: EvidenceChainState remains GREEN or OPEN dispatch occurs.

AT-334
- Given: `decision_snapshot_write_errors` increments within the `evidenceguard_window_s`.
- When: EvidenceGuard evaluates EvidenceChainState.
- Then: EvidenceChainState MUST be not GREEN (fail-closed); OPEN intents blocked; CLOSE/HEDGE/CANCEL allowed unless Kill hard-stop applies.
- Pass criteria: OPEN does not dispatch while `decision_snapshot_write_errors` increases.
- Fail criteria: EvidenceChainState remains GREEN or OPEN dispatch occurs while `decision_snapshot_write_errors` increases.

AT-335
- Given: `parquet_queue_depth` or `parquet_queue_capacity` is missing or unparseable.
- When: EvidenceGuard evaluates `parquet_queue_depth_pct`.
- Then: EvidenceChainState MUST be not GREEN (fail-closed); OPEN intents blocked; CLOSE/HEDGE/CANCEL allowed unless Kill hard-stop applies.
- Pass criteria: OPEN does not dispatch while required parquet queue metrics are missing/unparseable.
- Fail criteria: EvidenceChainState remains GREEN or OPEN dispatch occurs while required parquet queue metrics are missing/unparseable.

AT-422
- Given: config overrides are set to `parquet_queue_trip_pct = 0.80`, `parquet_queue_trip_window_s = 5`, `parquet_queue_clear_pct = 0.75`, `queue_clear_window_s = 10`, and `evidenceguard_global_cooldown = 0`, and all other EvidenceGuard criteria are satisfied.
- When: `parquet_queue_depth_pct` is 0.85 for 6s, then 0.72 for 9s, then 0.72 for 10s.
- Then: after 6s, EvidenceChainState != GREEN and TradingMode == ReduceOnly; after 9s, EvidenceChainState != GREEN; after 10s, EvidenceChainState == GREEN and EvidenceGuard no longer forces ReduceOnly.
- Pass criteria: trip/clear behavior follows overridden config values, not defaults.
- Fail criteria: no trip, no clear, or behavior matches hard-coded defaults instead of config.

AT-404
- Given: `EvidenceChainState != GREEN`, a cancel/replace that increases exposure, and no Kill hard-stop is active.
- When: EvidenceGuard evaluates permissions.
- Then: the cancel/replace is rejected; non-risk-increasing cancels may proceed; OPEN remains blocked.
- Pass criteria: risk-increasing cancel/replace rejected while EvidenceChainState is not GREEN.
- Fail criteria: risk-increasing cancel/replace allowed.

AT-214
- Given: `wal_write_errors` is missing or unparseable while EvidenceGuard evaluates EvidenceChainState.
- When: EvidenceGuard computes EvidenceChainState for this tick/window.
- Then: EvidenceChainState MUST be not GREEN (fail-closed) and OPEN intents MUST be blocked.
- Pass criteria: OPEN does not dispatch because a required counter is missing/unparseable.
- Fail criteria: EvidenceChainState becomes GREEN or any OPEN dispatch occurs while `wal_write_errors` is missing/unparseable.

AT-215
- Given: `decision_snapshot_write_errors` is missing or unparseable while EvidenceGuard evaluates EvidenceChainState.
- When: EvidenceGuard computes EvidenceChainState for this tick/window.
- Then: EvidenceChainState MUST be not GREEN (fail-closed) and OPEN intents MUST be blocked.
- Pass criteria: OPEN does not dispatch because a required counter is missing/unparseable.
- Fail criteria: EvidenceChainState becomes GREEN or any OPEN dispatch occurs while `decision_snapshot_write_errors` is missing/unparseable.

AT-415
- Given: `truth_capsule_write_errors` is missing/unparseable OR `parquet_queue_overflow_count` is missing/unparseable.
- When: EvidenceGuard computes EvidenceChainState for this tick/window.
- Then: EvidenceChainState MUST be not GREEN (fail-closed) and OPEN intents MUST be blocked.
- Pass criteria: OPEN does not dispatch because a required counter is missing/unparseable.
- Fail criteria: EvidenceChainState becomes GREEN or any OPEN dispatch occurs while required counters are missing/unparseable.

AT-923
- Given: `evidenceguard_counters_last_update_ts_ms` is older than `evidenceguard_counters_max_age_ms`.
- When: EvidenceGuard computes EvidenceChainState for this tick/window.
- Then: EvidenceChainState MUST be not GREEN (fail-closed) and OPEN intents MUST be blocked.
- Pass criteria: OPEN does not dispatch because required counters are stale.
- Fail criteria: EvidenceChainState becomes GREEN or any OPEN dispatch occurs while counters are stale.


**Canonical TradingMode computation (precedence + staleness + watchdog semantics + reason codes) is defined in §2.2.3 (PolicyGuard-owned).**

#### **2.2.3 TradingMode Computation (Canonical Precedence + Reason Codes)**

**Hard Rule:** The Soldier never "stores" TradingMode as authoritative state. It recomputes it every loop tick via `PolicyGuard.get_effective_mode()`.


**Config defaults (fail-closed):**
- `watchdog_kill_s = 10` (seconds; see Appendix A for default)
- `max_policy_age_sec = 300` (5min default; aligned with ops alert threshold §7.1)
**Precedence (Highest → Lowest):**
1. `TradingMode::Kill` if any:
   - watchdog heartbeat stale (`now_ms - watchdog_last_heartbeat_ts_ms > watchdog_kill_s * 1000`)
   - `risk_state == Kill`
   - `mm_util` >= `mm_util_kill` (Margin Headroom Gate; see §1.4.3; default `mm_util_kill` in Appendix A)
   - `rate_limit_session_kill_active == true` (session termination / `too_many_requests` code 10028; see §3.3)
   - `disk_used_pct` >= `disk_kill_pct` (Kill switch; see §7.2; default `disk_kill_pct` in Appendix A)
   - `cortex_override == ForceKill` (see §2.3)

2. `TradingMode::ReduceOnly` if any:
   - `risk_state == Maintenance` (maintenance window)
   - `emergency_reduceonly_active == true` (`POST /api/v1/emergency/reduce_only` active)
   - `open_permission_blocked_latch == true` (block OPEN; allow CLOSE/HEDGE/CANCEL; see §2.2.4)
   - `bunker_mode_active == true` (Network Jitter Monitor; see §2.3.2)
   - `F1_CERT` missing OR stale OR FAIL (runtime gate; see §2.2.1)
   - `evidence_chain_state != GREEN` (EvidenceGuard; see §2.2.2)
   - `cortex_override == ForceReduceOnly`
   - fee model stale beyond hard limit (`fee_model_cache_age_s > fee_cache_hard_s`; see §4.2)
   - `risk_state == Degraded` (mandatory ReduceOnly)
   - `policy_age_sec > max_policy_age_sec` (Policy staleness rule)
   - `mm_util` >= `mm_util_reduceonly` (Margin Headroom Gate; see §1.4.3; default `mm_util_reduceonly` in Appendix A)

3. `TradingMode::Active` only if:
   - `risk_state == Healthy`, and
   - policy staleness is within limits, and
   - `evidence_chain_state == GREEN`, and
   - `open_permission_blocked_latch == false`, and
   - no override is active.

**Dispatch Authorization (Hot-Path Chokepoint):**
- Every network dispatch attempt MUST consult `PolicyGuard.get_effective_mode()` immediately before dispatch.
- If `TradingMode != Active`, OPEN intents MUST NOT dispatch.
- If `TradingMode == ReduceOnly`, CLOSE/HEDGE/CANCEL MAY dispatch only as permitted by §2.2.5 and subject to Kill hard-stop rules in §2.2.3.
- If `TradingMode == Kill`, dispatch is forbidden except containment micro-loop actions when eligibility predicates are satisfied per §2.2.3.

**Policy Staleness Rule (Anti "late update" bug):**
- Compute staleness using Commander time, not local receive time:
  - `policy_age_sec = (now_ms - python_policy_generated_ts_ms) / 1000`
- If `policy_age_sec > max_policy_age_sec` → force ReduceOnly (even if an old update arrives late).

**Acceptance Tests (REQUIRED):**
AT-336
- Given: `max_policy_age_sec = 300` and `python_policy_generated_ts_ms = T0`.
- When: PolicyGuard computes `policy_age_sec` at `now_ms = T0 + 300_000` and again at `now_ms = T0 + 301_000` with no other gates active.
- Then: at `T0+300_000`, `policy_age_sec == 300` and ReduceOnly does not trigger; at `T0+301_000`, `policy_age_sec == 301` and ReduceOnly triggers.
- Pass criteria: boundary behavior matches `>` semantics and TradingMode transitions only after threshold is exceeded.
- Fail criteria: ReduceOnly triggers at `policy_age_sec == 300` or fails to trigger at `policy_age_sec == 301`.

AT-337
- Given: `watchdog_kill_s = 10` and `watchdog_last_heartbeat_ts_ms = T0`.
- When: PolicyGuard computes TradingMode at `now_ms = T0 + 10_000` and again at `now_ms = T0 + 10_001` with no other gates active.
- Then: at `T0+10_000`, Kill does not trigger; at `T0+10_001`, TradingMode enters Kill.
- Pass criteria: Kill triggers only when `now_ms - watchdog_last_heartbeat_ts_ms > watchdog_kill_s * 1000`.
- Fail criteria: Kill triggers at the threshold or fails to trigger above the threshold.

AT-918
- Given: `risk_state == Kill` and no other Kill reasons are active.
- When: PolicyGuard computes TradingMode.
- Then: `TradingMode == Kill` and `mode_reasons` includes `KILL_RISKSTATE_KILL`.
- Pass criteria: Kill entered; reason code present.
- Fail criteria: non-Kill mode or missing reason code.

AT-416
- Given: `evidence_chain_state != GREEN` at `T0` with all other gates allowing `TradingMode::Active`, then `evidence_chain_state == GREEN` at `T0+1` tick.
- When: PolicyGuard computes TradingMode at `T0` and `T0+1`.
- Then: `TradingMode==ReduceOnly` at `T0`, then `TradingMode==Active` at `T0+1`.
- Pass criteria: TradingMode follows current inputs each tick.
- Fail criteria: TradingMode remains stale after inputs change.

AT-417
- Given: TradingMode Active at `T0` with no active reasons, then `policy_age_sec > max_policy_age_sec` at `T0+1` with no Kill reasons.
- When: PolicyGuard computes `mode_reasons` and `/status` is fetched at `T0` and `T0+1`.
- Then: `mode_reasons==[]` at `T0` and includes `REDUCEONLY_POLICY_STALE` at `T0+1`.
- Pass criteria: `mode_reasons` update each tick with current inputs.
- Fail criteria: stale or missing `mode_reasons` after inputs change.

AT-931
- Given: an OPEN intent is created when PolicyGuard computes `TradingMode::Active` at `T0`.
- When: immediately before dispatch at `T0+1`, PolicyGuard computes `TradingMode::ReduceOnly`.
- Then: the OPEN intent is blocked (no dispatch).
- Pass criteria: OPEN dispatch count remains 0 for that attempt.
- Fail criteria: any OPEN dispatch occurs despite ReduceOnly at dispatch time.

**Watchdog Semantics (Single Source):**
- Watchdog triggers reduce-only via `POST /api/v1/emergency/reduce_only`.
- PolicyGuard enforces that reduce-only persists until cooldown expiry and reconciliation confirms exposure is safe.

AT-132
- Given: `POST /api/v1/emergency/reduce_only` is called at `T0`, `emergency_reduceonly_cooldown_s=300`, and reconciliation is not required by trigger source OR reconciliation has succeeded.
- When: PolicyGuard computes TradingMode at `now_ms = T0 + 299_000` and again at `now_ms = T0 + 301_000` with all other gates allowing `TradingMode::Active`.
- Then: at `T0+299s`, `emergency_reduceonly_active==true` and `TradingMode==ReduceOnly` (OPEN blocked); at `T0+301s`, `emergency_reduceonly_active==false` and `TradingMode` may return to Active if no other ReduceOnly/Kill causes apply.
- Pass criteria: ReduceOnly persists through the full cooldown window; OPEN does not dispatch while `emergency_reduceonly_active==true`.
- Fail criteria: ReduceOnly clears before cooldown expiry, or OPEN dispatch occurs while `emergency_reduceonly_active==true`.

##### **ModeReasonCode (Authoritative TradingMode Reasons — MUST be complete)**

PolicyGuard MUST compute `mode_reasons: ModeReasonCode[]` every loop tick and MUST expose it via `/api/v1/status`.

**Rules (non-negotiable):**
- `mode_reasons` MUST include all active reasons within the winning precedence tier for this tick:
  - if `trading_mode == Kill`: include all active `KILL_*` reasons (and no `REDUCEONLY_*`)
  - if `trading_mode == ReduceOnly`: include all active `REDUCEONLY_*` reasons (and no `KILL_*`)
  - if `trading_mode == Active`: `mode_reasons` MUST be `[]`
- `mode_reasons` MUST be deterministically ordered: in the same order as the "Allowed values" list below (no per-tick reordering).

**Acceptance Tests (References):**
- AT-023, AT-024, AT-025, AT-026 in §7.0 validate `/status` exposure of `mode_reasons` and ordering/tier rules.

**Allowed values (minimal complete set):**

**Kill reasons**
- `KILL_WATCHDOG_HEARTBEAT_STALE`
- `KILL_RISKSTATE_KILL`
- `KILL_MARGIN_MM_UTIL_HIGH`
- `KILL_RATE_LIMIT_SESSION_TERMINATION`
- `KILL_DISK_WATERMARK_KILL`
- `KILL_CORTEX_FORCE_KILL`

**ReduceOnly reasons**
- `REDUCEONLY_RISKSTATE_MAINTENANCE`
- `REDUCEONLY_EMERGENCY_REDUCEONLY_ACTIVE`  # emergency_reduceonly_active == true (POST /api/v1/emergency/reduce_only is active)
- `REDUCEONLY_OPEN_PERMISSION_LATCHED`
- `REDUCEONLY_BUNKER_MODE_ACTIVE`
- `REDUCEONLY_F1_CERT_INVALID`
- `REDUCEONLY_EVIDENCE_CHAIN_NOT_GREEN`
- `REDUCEONLY_CORTEX_FORCE_REDUCE_ONLY`
- `REDUCEONLY_FEE_MODEL_HARD_STALE`
- `REDUCEONLY_RISKSTATE_DEGRADED`
- `REDUCEONLY_POLICY_STALE`
- `REDUCEONLY_MARGIN_MM_UTIL_HIGH`
- `REDUCEONLY_INPUT_MISSING_OR_STALE`  # critical safety input missing or stale (fail-closed)

#### **Kill Mode Semantics (Hard-Stop vs Containment Micro-Loop) — MUST be explicit**

**Definition:**
- `TradingMode::Kill` stops the strategy/policy loop immediately (no new strategy-generated OrderIntents).
- A limited **Containment Micro-Loop** MAY run in Kill **only** if it is safe to dispatch risk-reducing orders.

**Containment Micro-Loop (allowed actions in Kill when enabled):**
- Cancel only `reduce_only == false` orders.
- Place only risk-reducing orders:
  - EmergencyClose (bounded IOC close attempts per §3.1)
  - Reduce-only hedges (bounded) if still exposed per §3.1

**Containment eligibility (fail-closed):**
Containment is allowed ONLY when ALL are true:
- `disk_used_pct` < `disk_kill_pct` (not in disk Kill switch condition; default `disk_kill_pct` in Appendix A)
- `EvidenceChainState == GREEN` AND WAL writes are succeeding (no unlogged actions)
- Session is healthy (`rate_limit_session_kill_active == false` / no 10028 termination class event)
- `bunker_mode_active == false` (Network Jitter Monitor not active; see §2.3.2 thresholds)

**Containment optionality clarification:**
Containment is optional in Kill unless a cause is listed below as "MUST enable containment" (still subject to eligibility predicates).

**Kill causes that MUST enable containment:**
- `KILL_MARGIN_MM_UTIL_HIGH` (`mm_util >= mm_util_kill`): containment is mandatory ("Kill + emergency flatten").
Containment is mandatory only when the eligibility predicates above are all true; if any predicate is false, containment is forbidden and the system MUST hard-stop.

**Kill causes that MUST hard-stop (containment forbidden):**
- `KILL_DISK_WATERMARK_KILL` (`disk_used_pct >= disk_kill_pct`): containment forbidden (integrity-first).
- `KILL_RATE_LIMIT_SESSION_TERMINATION` (10028 / session termination): containment forbidden (cannot trust connectivity / state).
- `KILL_WATCHDOG_HEARTBEAT_STALE`: containment forbidden (process health unknown).

**Precedence rule (non-negotiable):**
When `disk_used_pct >= disk_kill_pct`, containment is forbidden (hard-stop). No dispatch occurs, including CLOSE/HEDGE/CANCEL, regardless of Open Permission Latch state or other permissions.

**Acceptance Tests (REQUIRED):**
AT-338
- Given: `mm_util >= mm_util_kill`, `disk_used_pct < disk_kill_pct`, `EvidenceChainState == GREEN`, WAL writes succeed, `rate_limit_session_kill_active == false`, `bunker_mode_active == false`, and open exposure exists.
- When: Kill Mode evaluates containment eligibility.
- Then: containment actions run (cancel non-reduce-only orders, emergency close, and reduce-only hedge fallback if still exposed) and no OPEN intents dispatch.
- Pass criteria: only containment actions occur; no OPEN dispatch while Kill is active.
- Fail criteria: OPEN dispatch occurs or containment does not execute while eligible.

AT-339
- Given: `disk_used_pct >= disk_kill_pct` with open exposure (other eligibility predicates may be true).
- When: Kill Mode evaluates containment eligibility.
- Then: containment is forbidden and **no dispatch occurs**, including CLOSE/HEDGE/CANCEL.
- Pass criteria: trading loop hard-stops and emits no dispatches.
- Fail criteria: any cancel/close/hedge or containment dispatch occurs.

AT-340
- Given: `mm_util >= mm_util_kill` but `EvidenceChainState != GREEN` or WAL writes are failing.
- When: Kill Mode evaluates containment eligibility.
- Then: containment is forbidden and the system hard-stops (no dispatch).
- Pass criteria: no containment actions occur while eligibility predicates fail.
- Fail criteria: any containment dispatch occurs despite failed eligibility.

AT-346
- Given: `TradingMode::Kill` triggered by `rate_limit_session_kill_active == true` (session termination) and `disk_used_pct < disk_kill_pct`.
- When: Kill Mode evaluates containment eligibility.
- Then: containment is forbidden and the system hard-stops (no dispatch).
- Pass criteria: no cancel/close/hedge or containment dispatch occurs.
- Fail criteria: any dispatch occurs while session termination Kill is active.

AT-347
- Given: `TradingMode::Kill` triggered by `now_ms - watchdog_last_heartbeat_ts_ms > watchdog_kill_s * 1000` and `disk_used_pct < disk_kill_pct`.
- When: Kill Mode evaluates containment eligibility.
- Then: containment is forbidden and the system hard-stops (no dispatch).
- Pass criteria: no cancel/close/hedge or containment dispatch occurs.
- Fail criteria: any dispatch occurs while watchdog Kill is active.

AT-013
- Given: `TradingMode::Kill` triggered by `mm_util >= mm_util_kill` and `bunker_mode_active == true`.
- When: Kill Mode evaluates containment eligibility.
- Then: containment is forbidden and the system hard-stops (no dispatch).
- Pass criteria: no cancel/close/hedge orders are dispatched while `bunker_mode_active == true`.
- Fail criteria: any containment dispatch occurs while `bunker_mode_active == true`.

#### **2.2.4 Open Permission Latch (Reconcile-Required, Sticky Until Cleared) — CP-001**

**Goal:** Prevent "false-safe opens" after restart, WS gaps, or session termination until reconciliation proves state truth.

**Semantics:**
- If `open_permission_blocked_latch == true`:
  - OPEN intents MUST be blocked.
  - CLOSE / HEDGE / CANCEL intents MUST remain allowed, except risk-increasing cancels/replaces MUST be rejected per §2.2.5.

**State fields:**
- `open_permission_blocked_latch` (bool; `true` means OPEN blocked)
- `open_permission_reason_codes` (`OpenPermissionReasonCode[]`; MUST be `[]` iff `open_permission_blocked_latch == false`)
- `open_permission_requires_reconcile` (bool; MUST equal `open_permission_blocked_latch` for v5.1 - all reason codes are reconcile-class)

**Acceptance Tests (References):**
- AT-027 in §7.0 validates `/status` latch field invariants.

**Deterministic reconstruction (preferred; no persistence):**
- On startup, set `open_permission_blocked_latch = true` with reason `RESTART_RECONCILE_REQUIRED`.
- The latch MUST clear only after reconciliation succeeds.

**Reconciliation success criteria (required):**
- Ledger inflight intents (non-terminal) match exchange open orders by label (all matched within label disambiguation rules per §1.1.2).
- Exchange positions match ledger cumulative fills within `position_reconcile_epsilon` (default: instrument's `min_amount` or `1e-6` if undefined).
- No missing trades over the last `reconcile_trade_lookback_sec` (default: 300s) as determined by REST `/get_user_trades` query.
- All reconcile-class reason codes cleared (no unresolved WS gaps, inventory mismatches, or session termination flags).

**Allowed values (reconcile-only):** `OpenPermissionReasonCode[]`
- `RESTART_RECONCILE_REQUIRED`
- `WS_BOOK_GAP_RECONCILE_REQUIRED`
- `WS_TRADES_GAP_RECONCILE_REQUIRED`
- `WS_DATA_STALE_RECONCILE_REQUIRED`
- `INVENTORY_MISMATCH_RECONCILE_REQUIRED`
- `SESSION_TERMINATION_RECONCILE_REQUIRED`

**Hard rule:** F1_CERT and EvidenceChain failures MUST NOT appear in `open_permission_reason_codes` (they are cleared by cert/evidence recovery, not reconciliation).

**Acceptance Tests (REQUIRED):**
AT-010
- Given: `open_permission_blocked_latch==true` with `open_permission_reason_codes` containing `RESTART_RECONCILE_REQUIRED`.
- When: the system evaluates an OPEN intent for dispatch.
- Then: no OPEN order is dispatched; CLOSE/HEDGE/CANCEL intents remain dispatchable, except risk-increasing cancels/replaces are rejected (per §2.2.5), subject to Kill hard-stop rules in §2.2.3.
- Pass criteria: OPEN dispatch count remains 0; CLOSE/HEDGE/CANCEL dispatch is permitted; risk-increasing cancel/replace is rejected.
- Fail criteria: any OPEN is dispatched while the latch is true.

AT-430
- Given: startup occurs with no persisted latch state.
- When: initialization completes before reconciliation runs.
- Then: `open_permission_blocked_latch == true`, `open_permission_reason_codes` contains `RESTART_RECONCILE_REQUIRED`, and `open_permission_requires_reconcile == true`.
- Pass criteria: latch fields match expected startup values and OPEN remains blocked.
- Fail criteria: latch not set, reason missing, or OPEN allowed before reconciliation.

AT-011
- Given: `open_permission_blocked_latch==true` for a WS gap reason (e.g., `WS_TRADES_GAP_RECONCILE_REQUIRED`).
- When: reconciliation succeeds (all criteria in this section are satisfied).
- Then: the latch clears (`open_permission_blocked_latch==false` and `open_permission_reason_codes==[]`), and opens may proceed only if PolicyGuard computes `TradingMode::Active`.
- Pass criteria: latch fields match the invariants immediately after reconciliation; opens remain blocked unless mode is Active.
- Fail criteria: latch clears without reconciliation success, or opens proceed while latch remains true.

AT-402
- Given: `open_permission_blocked_latch==true` with `open_permission_reason_codes` containing `RESTART_RECONCILE_REQUIRED` and a cancel/replace that increases exposure.
- When: cancel/replace permission is evaluated.
- Then: the cancel/replace is rejected until reconciliation clears the latch.
- Pass criteria: risk-increasing cancel blocked while latch is true; allowed only after latch clears and other gates allow.
- Fail criteria: risk-increasing cancel allowed while latch is true.

AT-110
- Given: `open_permission_blocked_latch==true`.
- When: an order placement intent is evaluated with `reduce_only` missing or null.
- Then: it MUST be treated as OPEN and blocked.
- Pass criteria: no order placement is dispatched.
- Fail criteria: any order placement dispatch occurs while `reduce_only` is missing and latch is true.

AT-411
- Given: F1_CERT is missing/stale/FAIL OR `EvidenceChainState != GREEN`, and no reconcile-class triggers are active.
- When: `open_permission_reason_codes` are computed.
- Then: `open_permission_reason_codes` does not include F1_CERT or EvidenceChain failures, and `open_permission_blocked_latch` is unchanged.
- Pass criteria: no F1/Evidence codes in reason list; latch not set without a reconcile trigger.
- Fail criteria: any F1/Evidence code appears or latch is set without a reconcile trigger.


#### **2.2.5 Cancel/Replace Permission Rules (Canonical)**

Cancel/Replace intents are allowed only if ALL are true:
1. Kill hard-stop does not forbid dispatch (§2.2.3).
2. NOT risk-increasing while `open_permission_blocked_latch == true` (§2.2.4).
3. NOT risk-increasing while `EvidenceChainState != GREEN` (§2.2.2).
4. NOT risk-increasing while `RiskState == Degraded` (§3.4).
5. Does NOT cancel protective reduce-only closing/hedging orders (§3.2).

**Definition (Risk-Increasing Cancel/Replace):**
- Any cancel/replace that increases absolute net exposure, increases exposure in the current risk direction, or removes `reduce_only` protection on a closing/hedging order.
- Examples: canceling reduce_only close/hedge orders; replacing with larger size in the risk-increasing direction.
Rejections for risk-increasing cancel/replace MUST use `Rejected(RiskIncreasingCancelReplaceForbidden)`.

**Acceptance Test (REQUIRED):**
AT-917
- Given: `EvidenceChainState != GREEN` and a risk-increasing cancel/replace.
- When: cancel/replace permission is evaluated.
- Then: the request is rejected with `Rejected(RiskIncreasingCancelReplaceForbidden)`.
- Pass criteria: rejection reason matches; no risk-increasing cancel/replace dispatch occurs.
- Fail criteria: dispatch occurs or reason missing/mismatched.


#### **2.2.6 RejectReasonCode Registry (Intent-Level Rejections)**

**Scope (non-negotiable):** Applies to any intent rejected **before dispatch**. This does **not** replace `ModeReasonCode` or `OpenPermissionReasonCode`.

**MUST:**
- Any intent rejected before dispatch MUST include `reject_reason_code: RejectReasonCode`, and the value MUST be in this registry.
- Any use of `Rejected(...)`, `Rejected(reason=...)`, or `Reject(intent=...)` in this contract implies `reject_reason_code = <TOKEN>` and `<TOKEN> ∈ RejectReasonCode`.

**Completeness rule (non-negotiable):**
- The registry MUST be complete w.r.t. this contract: if a new rejection token is added anywhere, the registry MUST be updated in the same patch.

**Allowed values (minimal complete set):**
- `TooSmallAfterQuantization`
- `InstrumentMetadataMissing`
- `ChurnBreakerActive`
- `LiquidityGateNoL2`
- `EmergencyCloseNoPrice`
- `ExpectedSlippageTooHigh`
- `NetEdgeTooLow`
- `NetEdgeInputMissing`
- `InventorySkew`
- `InventorySkewDeltaLimitMissing`
- `PendingExposureBudgetExceeded`
- `GlobalExposureBudgetExceeded`
- `ContractsAmountMismatch`
- `MarginHeadroomRejectOpens`
- `OrderTypeMarketForbidden`
- `OrderTypeStopForbidden`
- `LinkedOrderTypeForbidden`
- `PostOnlyWouldCross`
- `RiskIncreasingCancelReplaceForbidden`
- `RateLimitBrownout`
- `InstrumentExpiredOrDelisted`
- `FeedbackLoopGuardActive`
- `LabelTooLong`

**Acceptance Test (REQUIRED):**
AT-930
- Given: a test harness that triggers at least one rejection in each category (quantization, liquidity, exposure reservation, preflight, cancel/replace permission).
- When: each rejection occurs.
- Then: the response includes `reject_reason_code`, and its value is a member of `RejectReasonCode`.
- Pass criteria: all sampled rejections include a registry value.
- Fail criteria: any rejection has a missing or non-registry reason.


### 2.3 Reflexive Cortex (Hot-Loop Safety Override)

**Where:** `soldier/core/reflex/cortex.rs`

**Inputs:** `MarketData(dvol, spread_bps, depth_topN, last_1m_return)`  
**Output:** `SafetyOverride::{None, ForceReduceOnly{cooldown_s}, ForceKill}`

**Why this exists:** Policy staleness is one problem; volatility shock and microstructure collapse are a different one. The Cortex runs in Rust *inside the hot loop* and can override Python even when Python is “alive” but slow.

**Depth metric definition (non-negotiable):**
- `depth_topN` is USD notional depth computed over the top **N=5** price levels per side: sum `price_i * qty_i` for top-5 bids and top-5 asks.
- Use `min(total_bid_usd, total_ask_usd)` as `depth_topN` (conservative side).

**Cortex override aggregation (effective override):**
- Each §2.3 producer emits a candidate override each tick (currently: Reflexive Cortex and Exchange Health Monitor).
- `cortex_override` is the **effective** override: max severity across all active producers (`ForceKill > ForceReduceOnly > None`).
- PolicyGuard consumes the effective `cortex_override` (no last-write-wins semantics).
- If any producer inputs are missing/unparseable/stale, its candidate MUST be treated as `ForceReduceOnly` (fail-closed).

**Rules (deterministic):**
- If `spread_bps >= spread_kill_bps` for `cortex_kill_window_s` OR `depth_topN <= depth_kill_min` for `cortex_kill_window_s` -> `ForceKill`
- If **DVOL jumps ≥ +10% within ≤ 60s** → `ForceReduceOnly{cooldown_s=dvol_cooldown_s}`
- If `spread_bps > spread_max_bps` **OR** `depth_topN < depth_min` → `ForceReduceOnly{cooldown_s=spread_depth_cooldown_s}`
- ForceKill supersedes ForceReduceOnly if both are triggered in the same tick.

**Behavior when override is active:**
- If `cortex_override == ForceKill`: PolicyGuard computes `TradingMode = Kill` per §2.2.3 precedence.
- If `cortex_override == ForceReduceOnly`: PolicyGuard computes `TradingMode = ReduceOnly` per §2.2.3 precedence.
- Cancel **only** non-reduce-only opens; keep closes/hedges alive.

**Definition (Risk-Increasing Cancel/Replace):** see §2.2.5.

**Acceptance Test (REQUIRED):**
AT-231
- Given: `MarketData` where DVOL jumps by +10% within one minute.
- When: Cortex evaluates `MarketData` and PolicyGuard computes TradingMode.
- Then: opens are blocked and mode flips to `ReduceOnly` within one loop tick.
- Pass criteria: ReduceOnly entered within one tick; opens blocked.
- Fail criteria: TradingMode remains Active while DVOL jump condition is met.

AT-045
- Given: `spread_bps >= spread_kill_bps` for at least `cortex_kill_window_s` (or `depth_topN <= depth_kill_min` for the same window).
- When: Cortex evaluates `MarketData` and PolicyGuard computes TradingMode.
- Then: `cortex_override == ForceKill`, `TradingMode == Kill`, and `mode_reasons` includes `KILL_CORTEX_FORCE_KILL`.
- Pass criteria: Kill is entered within one tick after the window is satisfied.
- Fail criteria: ForceReduceOnly or Active while kill conditions persist.

AT-418
- Given: Reflexive Cortex would emit `ForceKill` in the same tick that Exchange Health Monitor emits `ForceReduceOnly`.
- When: `cortex_override` is computed and PolicyGuard computes TradingMode.
- Then: `cortex_override == ForceKill` and `TradingMode == Kill`.
- Pass criteria: Kill wins deterministically.
- Fail criteria: ReduceOnly wins or behavior depends on evaluation order.

AT-420
- Given: top-5 bid levels sum to `320_000` USD and top-5 ask levels sum to `280_000` USD (per-level price * qty).
- When: `depth_topN` is computed.
- Then: `depth_topN == 280_000` (min of bid/ask totals).
- Pass criteria: per-level notional used; N=5; conservative side chosen.
- Fail criteria: mid-price valuation, max-side, or different N.

AT-119
- Given: `open_permission_blocked_latch == true` with `open_permission_reason_codes` containing `WS_BOOK_GAP_RECONCILE_REQUIRED` or `WS_TRADES_GAP_RECONCILE_REQUIRED`, and a cancel/replace request that increases exposure (e.g., cancel a reduce-only close or replace with larger size in the risk-increasing direction).
- When: the cancel/replace is submitted.
- Then: the cancel/replace is rejected and exposure does not increase.
- Pass criteria: cancel/replace rejected while latch is true; OPEN remains blocked.
- Fail criteria: cancel/replace allowed or exposure increases during the gap.
### **2.3.1 Exchange Health Monitor (Maintenance Mode Override) — MUST implement**

**Why this exists:** You don’t trade into a known exchange outage window. Maintenance is a separate risk state from “Python is alive.”

**Rules:**
- Poll `/public/get_announcements` every **60s**
- If a maintenance window start is ≤ **60 minutes** away:
  - Set `RiskState::Maintenance`
  - This causes PolicyGuard to compute `TradingMode::ReduceOnly` (via `risk_state == Maintenance`; see §2.2.3)
  - Block all **new opens** even if NetEdge is positive
  - Allow closes/hedges (reduce-only)

**Missing/Unreachable Handling (Fail-Closed):**
- If `/public/get_announcements` is unreachable or returns invalid data for `exchange_health_stale_s` (default: 180s; Appendix A):
  - Set `cortex_override = ForceReduceOnly` (producer output; effective override is max-severity per §2.3).
  - Reason: unknown exchange state is not safe for new opens.

**Where:** `soldier/core/risk/exchange_health.rs`

**Acceptance Test (REQUIRED):**
AT-232
- Given: `/public/get_announcements` indicates maintenance starting in 30 minutes.
- When: Exchange Health Monitor evaluates announcements.
- Then: opens are blocked and closes allowed.
- Pass criteria: TradingMode ReduceOnly; OPEN blocked; CLOSE/HEDGE/CANCEL allowed.
- Fail criteria: OPEN dispatch occurs or mode remains Active.

AT-204
- Given: `/public/get_announcements` endpoint is unreachable for >= `exchange_health_stale_s`.
- When: Exchange Health Monitor evaluates status.
- Then: `cortex_override = ForceReduceOnly` and OPEN intents are blocked.
- Pass criteria: ReduceOnly entered; opens blocked.
- Fail criteria: Active mode while announcements are stale/unreachable.


#### **2.3.2 Network Jitter Monitor (Bunker Mode Override)**

**Purpose:** VPS tail latency is a first-class risk driver. If network jitter spikes, “cancel/replace/repair” becomes unreliable, increasing legging tail risk. Bunker Mode reduces exposure by blocking new risk until comms stabilize.

**Inputs (export as metrics):**
- `deribit_http_p95_ms` over last 30s
- `ws_event_lag_ms` (now - last_ws_msg_ts)
- `request_timeout_rate` over last 60s

**Window definition (explicit):** evaluate `deribit_http_p95_ms` once per second over the last 30s rolling window; “3 consecutive windows” means three consecutive evaluations above threshold.

**Rules (Non-Negotiable):**
- If `deribit_http_p95_ms > 750ms` for 3 consecutive windows OR `ws_event_lag_ms > bunker_jitter_threshold_ms` OR `request_timeout_rate > 2%`:
  - Set `bunker_mode_active = true` (PolicyGuard computes `TradingMode::ReduceOnly`; see §2.2.3)
  - Block OPEN intents
  - Allow CLOSE/HEDGE/CANCEL
- Exit Bunker Mode only after all metrics are below thresholds for a stable period `bunker_exit_stable_s` (default 120s; Appendix A).

**Missing Metrics Handling (Fail-Closed):**
- If any required metric (`deribit_http_p95_ms`, `ws_event_lag_ms`, `request_timeout_rate`) is missing or uncomputable:
  - Set `bunker_mode_active = true`
  - Reason: unknown network state is not safe for new opens.

**Acceptance Tests (REQUIRED):**
AT-267
- Given: `ws_event_lag_ms` breaches the threshold.
- When: Network Jitter Monitor evaluates bunker mode.
- Then: OPEN intents are blocked; CLOSE/HEDGE/CANCEL allowed.
- Pass criteria: ReduceOnly enforced; CLOSE/HEDGE/CANCEL allowed.
- Fail criteria: OPEN allowed or ReduceOnly not enforced.

AT-268
- Given: bunker entry conditions clear and metrics stay below thresholds.
- When: the stable period elapses.
- Then: the system remains ReduceOnly during cooldown and returns to normal after the full `bunker_exit_stable_s`.
- Pass criteria: exit only after full stable period.
- Fail criteria: exit early or no recovery.

AT-209
- Given: `ws_event_lag_ms > bunker_jitter_threshold_ms` (or any other bunker entry condition from §2.3.2 rules).
- When: Network Jitter Monitor evaluates bunker mode.
- Then: `bunker_mode_active = true`, PolicyGuard computes `TradingMode = ReduceOnly`, OPEN intents are blocked, CLOSE/HEDGE/CANCEL allowed only as permitted by §2.2.5.
- Pass criteria: Bunker Mode entered; opens blocked; closes/hedges allowed.
- Fail criteria: TradingMode is Active while bunker entry conditions are met.

AT-401
- Given: `bunker_mode_active == true` and a cancel/replace that increases exposure (e.g., cancel a reduce-only close).
- When: cancel/replace permission is evaluated.
- Then: the cancel/replace is rejected; non-risk-increasing cancels may proceed.
- Pass criteria: risk-increasing cancel rejected while bunker mode is active; OPEN remains blocked.
- Fail criteria: risk-increasing cancel allowed during bunker mode.

AT-345
- Given: `deribit_http_p95_ms > 750ms` for three consecutive evaluations of the 30s rolling window and no other bunker entry condition is true.
- When: Network Jitter Monitor evaluates bunker mode on each evaluation tick.
- Then: Bunker Mode enters on the third consecutive breach and blocks OPEN intents.
- Pass criteria: entry occurs only after three consecutive breaches; a non-breach resets the count.
- Fail criteria: entry occurs early or ignores the consecutive requirement.

AT-115
- Given: Bunker Mode entered due to `ws_event_lag_ms` above threshold.
- When: all bunker metrics remain below thresholds continuously for `bunker_exit_stable_s`.
- Then: TradingMode may exit ReduceOnly only after the full stable period elapses.
- Pass criteria: exit timing equals `bunker_exit_stable_s`.
- Fail criteria: exit occurs earlier or uses an unspecified duration.

AT-205
- Given: `ws_event_lag_ms` metric is missing/uncomputable (e.g., no WS messages received yet).
- When: Network Jitter Monitor evaluates bunker mode.
- Then: `bunker_mode_active = true` and OPEN intents are blocked.
- Pass criteria: Bunker Mode entered; opens blocked.
- Fail criteria: Active mode while required metrics are missing.

### **2.3.3 Mark/Index/Last Basis Monitor (Liquidation Reality Guard)**

**Purpose:** Liquidation/margin risk is driven by reference prices (e.g., mark), not necessarily last trade. Large basis
divergence is a microstructure failure mode; the bot MUST fail-closed for new risk when basis blows out.

**Where:** `soldier/core/risk/basis_monitor.rs`

**Inputs (per instrument, minimum):**
- `mark_price` (float, >0) + `mark_price_ts_ms`
- `index_price` (float, >0) + `index_price_ts_ms`
- `last_price` OR `mid_price` (float, >0) + `last_price_ts_ms`
- `now_ms`

**Derived metrics:**
- `basis_mark_last_bps = abs(mark_price - last_price) / mark_price * 10_000`
- `basis_mark_index_bps = abs(mark_price - index_price) / mark_price * 10_000`
- `basis_is_fresh = max(now_ms - mark_price_ts_ms, now_ms - index_price_ts_ms, now_ms - last_price_ts_ms) <= basis_price_max_age_ms`

**Fail-closed missing/stale handling:**
- If any required price is missing/unparseable OR `basis_is_fresh == false`:
  - emit `ForceReduceOnly{cooldown_s=basis_reduceonly_cooldown_s}` (producer output) until fresh data recovers.

**Trip rules (deterministic):**
- If `max(basis_mark_last_bps, basis_mark_index_bps) >= basis_kill_bps` for `basis_kill_window_s`:
  - emit `ForceKill`
- Else if `max(...) >= basis_reduceonly_bps` for `basis_reduceonly_window_s`:
  - emit `ForceReduceOnly{cooldown_s=basis_reduceonly_cooldown_s}`

**Acceptance Tests (REQUIRED):**
AT-951
- Given: `basis_reduceonly_bps=50`, `basis_reduceonly_window_s=5`, and basis exceeds 50 bps for >=5s.
  - All other gates are configured to pass (this test isolates Basis Monitor reduce-only trip).
- When: Basis Monitor evaluates and PolicyGuard computes TradingMode.
- Then: `cortex_override==ForceReduceOnly{cooldown_s=basis_reduceonly_cooldown_s}` and OPENs are blocked.
- Pass criteria: ReduceOnly enforced; cooldown uses basis-specific cooldown param.
- Fail criteria: no ReduceOnly OR cooldown uses unrelated parameters.

AT-952
- Given: `basis_kill_bps=150`, `basis_kill_window_s=5`, and basis exceeds 150 bps for >=5s.
  - All other gates are configured to pass (this test isolates Basis Monitor kill trip).
- When: Basis Monitor evaluates and PolicyGuard computes TradingMode.
- Then: `cortex_override==ForceKill` and TradingMode enters Kill.
- Pass criteria: Kill enforced within one tick after window.
- Fail criteria: Kill not enforced.

AT-954
- Given: required basis price inputs are missing or stale (age > `basis_price_max_age_ms`).
  - All other gates are configured to pass (this test isolates Basis Monitor stale-input fail-closed).
- When: Basis Monitor evaluates.
- Then: it emits ForceReduceOnly (fail-closed) and OPENs are blocked.
- Pass criteria: ReduceOnly enforced due solely to missing/stale basis inputs.
- Fail criteria: Active mode while basis inputs are missing/stale.

AT-963
- Given:
  - `basis_reduceonly_bps=50`, `basis_kill_bps=150`
  - mark/index/last are present and fresh (`basis_is_fresh == true`)
  - `max(basis_mark_last_bps, basis_mark_index_bps) < 50 bps` continuously for >= `basis_reduceonly_window_s`
  - All other gates are configured to pass (this test isolates the Basis Monitor)
- When: Basis Monitor evaluates and PolicyGuard computes TradingMode for an OPEN intent.
- Then: Basis Monitor MUST NOT emit `ForceReduceOnly` or `ForceKill`; no basis-driven override is present; the OPEN proceeds to dispatch.
- Pass criteria: dispatch count becomes 1 and there is no basis-driven override.
- Fail criteria: ReduceOnly/Kill (or OPEN blocked) attributable to Basis Monitor despite basis being within threshold and inputs fresh.


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

#### **2.4.1 WAL Writer Isolation (Hot Loop Protection)**

- The hot loop MUST NOT block on WAL disk I/O.
- WAL appends MUST go through a bounded in-memory queue; `RecordedBeforeDispatch` means the enqueue succeeds.
- If the WAL queue is full or enqueue fails, the system MUST fail-closed for OPEN intents (block OPENs / ReduceOnly) and MUST continue ticking.
- An enqueue failure MUST increment `wal_write_errors` (treated as a WAL write failure for EvidenceGuard).
- The system MUST expose WAL queue telemetry in `/status`:
  - `wal_queue_depth` (current items in the WAL queue)
  - `wal_queue_capacity` (max items in the WAL queue)
  - `wal_queue_enqueue_failures` (monotonic counter of failed enqueues)

**Hot-loop output queue backpressure (Non-Negotiable):**
- All hot-loop output queues (status writer, telemetry, order events) MUST be bounded.
- If any such queue is full, the hot loop MUST NOT block and MUST force ReduceOnly until backlog clears.

**Persisted Record (Minimum):**
- intent_hash, group_id, leg_idx, instrument, side, qty, limit_price
- tls_state, created_ts, sent_ts, ack_ts, last_fill_ts
- exchange_order_id (if known), last_trade_id (if known)

**Acceptance Tests (REQUIRED):**
AT-233
- Given: a crash occurs after send, before ACK.
- When: the system restarts.
- Then: it must NOT resend; it must reconcile and proceed.
- Pass criteria: no duplicate send; reconcile succeeds.
- Fail criteria: resend occurs or reconcile missing.

AT-234
- Given: a crash occurs after fill, before local update.
- When: the system restarts.
- Then: it detects fill from exchange trades and updates TLSM + triggers sequencer.
- Pass criteria: fill detected; TLSM updated; sequencer triggered.
- Fail criteria: fill missed or TLSM not updated.

AT-935
- Given: a crash occurs after RecordedBeforeDispatch succeeds (WAL intent record durable), but before any network send attempt, so `sent_ts` is absent and the exchange has no open order for the intent's `s4:` label.
- When: the system restarts (twice), and on each restart it replays WAL and completes reconciliation (label/open-order + trade reconciliation) before attempting dispatch.
- Then: on the first restart, it must dispatch the intent **exactly once**, record `sent_ts`, and proceed; on the second restart, it must NOT dispatch again (since WAL no longer indicates "unsent").
- Pass criteria: across two restarts, total dispatch count == 1; `sent_ts` becomes non-null after restart #1; restart #2 performs reconcile and produces 0 dispatches for that intent.
- Fail criteria: dispatch occurs before reconciliation completes, dispatch count == 0 despite "unsent + reconciled + dispatch permitted," or dispatch count > 1 across restarts.

AT-940
- Given: a crash occurs after the exchange ACK is received for an intent, but before local TLSM/WAL updates record `ack_ts` or advance state.
- When: the system restarts and replays WAL, then reconciles open orders and trades before any dispatch.
- Then: it must recover the ACKed state from reconciliation, record `ack_ts`, and must NOT resend the intent.
- Pass criteria: TLSM advances to Acked (or Filled if trades indicate) and `ack_ts` is recorded; no duplicate send.
- Fail criteria: resend occurs, `ack_ts` remains missing despite evidence, or TLSM remains inflight after reconciliation.

AT-906
- Given: WAL appends use a bounded queue of capacity N, and the WAL writer is stalled so the queue reaches N items.
- When: an OPEN intent is evaluated and the system attempts RecordedBeforeDispatch enqueue.
- Then: the OPEN intent is rejected before dispatch, `wal_write_errors` increments, EvidenceChainState is not GREEN, and the hot loop continues ticking.
- Pass criteria: no outbound dispatch for that OPEN; `wal_write_errors` increases; EvidenceChainState != GREEN within the EvidenceGuard window; opens remain blocked until enqueue succeeds.
- Fail criteria: hot loop blocks, an OPEN dispatch occurs without a successful enqueue, EvidenceChainState remains GREEN, or opens remain allowed while enqueue fails.

AT-925
- Given: a hot-loop output queue (status writer, telemetry, or order events) reaches capacity N.
- When: the hot loop attempts to enqueue another item.
- Then: the hot loop does not block and TradingMode is forced to ReduceOnly until the queue depth falls below N.
- Pass criteria: no stall; queue depth <= N; ReduceOnly enforced.
- Fail criteria: hot loop blocks or remains Active under backpressure.


**Trade-ID Idempotency Registry (Ghost-Race Hardening) — MUST implement:**
- Persist a set/table: `processed_trade_ids`
- Record mapping: `trade_id -> {group_id, leg_idx, ts, qty, price}`

**WS Fill Handler rule (idempotent):**
1) On trade/fill event: if `trade_id` already in WAL → **NOOP**
2) Else: append `trade_id` to WAL **first**, then apply TLSM/positions/attribution updates.

**Acceptance Tests (REQUIRED):**
AT-269
- Given: order fills during WS disconnect.
- When: on reconnect, Sweeper runs before WS replay.
- Then: Sweeper finds trade via REST → updates ledger; later WS trade arrives → ignored due to `processed_trade_ids`.
- Pass criteria: REST update occurs; WS replay is ignored as duplicate.
- Fail criteria: duplicate processing or missing ledger update.

AT-270
- Given: duplicate WS trade event.
- When: handler processes the duplicate.
- Then: the second event is ignored.
- Pass criteria: duplicate is a NOOP.
- Fail criteria: duplicate is processed.

---

## **3\. Safety & Recovery**

### **3.1 Deterministic Emergency Close**

**Requirement**: When an atomic group fails, we must exit the position *immediately* and *safely*.

**Where:** `soldier/core/execution/emergency_close.rs`

**Price Source (Deterministic, fail-closed):**
- Primary: `L2BookSnapshot` best bid/ask when present and fresh (age <= `l2_book_snapshot_max_age_ms`; Appendix A).
- Fallback: `L1TickerSnapshot` best bid/ask (REST/WS ticker) when present and fresh (age <= `l2_book_snapshot_max_age_ms`; Appendix A).
- The `best` price in step 1 uses the selected source (asks for buy, bids for sell).
- If no valid source (missing/unparseable/stale or inverted bid/ask), emergency close MUST NOT dispatch and MUST return `Rejected(EmergencyCloseNoPrice)` and log `EmergencyCloseNoPrice`.

**Algorithm (Deterministic, 3 tries):**
1. Attempt **IOC limit close** at best ± `close_buffer_ticks` (default 5 ticks; see Appendix A for `close_buffer_ticks`).
2. If partial fill: repeat for remaining qty (max 3 loops, exponential buffer: multiply by 2 each retry → 10 ticks, 20 ticks).
3. If still exposed after retries: submit **reduce-only perp hedge** to neutralize delta (bounded size).
4. Log `AtomicNakedEvent` with group_id + exposure + time-to-delta-neutral.

**AtomicNakedEvent schema (minimum):**
- `group_id` (UUIDv4)
- `strategy_id` (string)
- `incident_ts_ms` (epoch ms)
- `exposure_usd_before` (float)
- `exposure_usd_after` (float)
- `time_to_delta_neutral_ms` (integer)
- `close_attempts` (integer; 1-3)
- `hedge_used` (bool)
- `cause` (string; non-empty; recommended values: `atomic_legging_failure|emergency_close_exhausted|hedge_fallback`)
- `trading_mode_at_event` (`Active|ReduceOnly|Kill`)
- `evidence_chain_state_at_event` (EvidenceChainState; e.g., `GREEN|RED`)

AT-211
- Given: an atomic group enters mixed state (one leg filled, another rejected or none) and emergency close runs.
- When: emergency close completes (including optional hedge fallback).
- Then: exactly one AtomicNakedEvent is emitted with all schema fields present and `time_to_delta_neutral_ms` computed.
- Pass criteria: event exists with required fields and is joinable to `group_id`.
- Fail criteria: missing event or missing required fields.

AT-213
- Given: an atomic group enters mixed state (one leg filled, another rejected or none) and emergency close runs.
- When: AtomicNakedEvent is recorded.
- Then: the event includes `strategy_id`, `cause`, `trading_mode_at_event`, and `evidence_chain_state_at_event` with valid values.
- Pass criteria: each field is present; `cause` is non-empty; `trading_mode_at_event` is one of `Active|ReduceOnly|Kill`; `evidence_chain_state_at_event` matches EvidenceChainState enum values.
- Fail criteria: any required field missing or invalid.

**Acceptance Tests (REQUIRED):**
AT-235
- Given: one leg filled and the book thins.
- When: emergency close runs.
- Then: close attempts run and fallback hedge executes if still exposed; exposure goes to ~0.
- Pass criteria: bounded close attempts then hedge fallback if needed; exposure neutralized.
- Fail criteria: no close attempts or exposure remains.

AT-236
- Given: Liquidity Gate reject conditions are present.
- When: emergency close runs.
- Then: emergency close still submits IOC close attempts (Liquidity Gate does NOT block it).
- Pass criteria: IOC close attempts are submitted.
- Fail criteria: emergency close blocked by Liquidity Gate.

AT-937
- Given: `L2BookSnapshot` is missing/unparseable/stale and a fresh `L1TickerSnapshot` is available.
- When: emergency close runs.
- Then: IOC close attempts are submitted using the L1 best bid/ask as the `best` price.
- Pass criteria: dispatch occurs and uses the L1 ticker as the price source.
- Fail criteria: dispatch is blocked despite a valid L1 ticker or uses a stale/invalid source.

AT-938
- Given: `L2BookSnapshot` is missing/unparseable/stale and no fresh `L1TickerSnapshot` is available.
- When: emergency close runs.
- Then: no dispatch occurs and the attempt is rejected with `Rejected(EmergencyCloseNoPrice)`.
- Pass criteria: dispatch count remains 0 and the rejection reason is recorded.
- Fail criteria: any dispatch occurs or rejection reason is missing/mismatched.


### **3.2 Smart Watchdog**

**Goal:** Watchdog must not cancel hedges/closing orders.

**Protocol:**
- Watchdog triggers on silence > 5s → calls `POST /api/v1/emergency/reduce_only`.

**Soldier behavior on reduce_only:**
1. Ensure `emergency_reduceonly_active == true` so PolicyGuard computes `TradingMode::ReduceOnly` immediately.
2. Cancel orders where `reduce_only == false`.
3. KEEP all reduce-only closing/hedging orders alive.
4. If exposure breaches limit: submit emergency reduce-only hedge.

**Acceptance Test (REQUIRED):**
AT-237
- Given: a network hiccup mid-hedge.
- When: Watchdog triggers reduce-only.
- Then: the hedge stays alive.
- Pass criteria: reduce-only hedge remains live.
- Fail criteria: hedge is canceled.

AT-203
- Given: `emergency_reduceonly_active == true` and there exists (a) an open order with `reduce_only == false` and (b) a closing/hedging order with `reduce_only == true`.
- When: Watchdog reduce-only behavior runs.
- Then: (a) is canceled and (b) is NOT canceled.
- Pass criteria: only `reduce_only == false` orders are canceled; reduce-only close/hedge orders remain live.
- Fail criteria: any reduce-only close/hedge order is canceled, or any non-reduce-only order remains live.




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
- Keep conservative defaults if the endpoint is unavailable.
- **Repeated fetch failure rule:** If limits fetch fails `limits_fetch_failures_trip_count` times within `limits_fetch_failure_window_s` seconds, set `RiskState::Degraded`.
- **Config (Appendix A):** `limits_fetch_failures_trip_count = 3` (default), `limits_fetch_failure_window_s = 300` (default).

AT-106
- Given: `limits_fetch_failures_trip_count=3` and `limits_fetch_failure_window_s=300`.
- When: three consecutive `/private/get_account_summary` limit reads fail within 300s.
- Then: `RiskState==Degraded` and opens are blocked via ReduceOnly.
- Pass criteria: the third failure within window deterministically trips Degraded.
- Fail criteria: Degraded does not trip, or trips without meeting the threshold.

AT-133
- Given: `limits_fetch_failures_trip_count=3` and `limits_fetch_failure_window_s=300`.
- When: three `/private/get_account_summary` limit reads fail, but no three failures occur within any rolling 300s window (e.g., failures at `T0`, `T0+200s`, `T0+400s`).
- Then: `RiskState` MUST NOT become `Degraded` due solely to these failures.
- Pass criteria: Degraded does not trip unless 3 failures fall within the configured window.
- Fail criteria: Degraded trips when the threshold is not met within the window.

**Limiter Model (Local):**
- Token bucket (parameterized by the account’s current credits/rate), not hardcoded.
- **Priority Queue (Preemption):** emergency_close, reduce-only hedges, and cancels preempt data refresh tasks.

**Brownout Controller (Pressure Shedding — MUST implement):**
- Classify every request into one of: `EMERGENCY_CLOSE`, `CANCEL`, `HEDGE`, `OPEN`, `DATA`.
- Under limiter pressure OR a 429 burst:
  - shed `DATA` first (skip noncritical refreshes)
  - block `OPEN` next (treat as ReduceOnly)
  - preserve `CANCEL`/`HEDGE`/`EMERGENCY_CLOSE`
  - OPEN rejections under brownout MUST use `Rejected(RateLimitBrownout)`.
- On `too_many_requests` / `code 10028` (session termination):
  1. Set `rate_limit_session_kill_active = true`
  2. PolicyGuard MUST compute `TradingMode::Kill` within one tick
  3. Set Open Permission Latch reason: `SESSION_TERMINATION_RECONCILE_REQUIRED`
  4. Reconnect/backoff and run full reconcile before any trading resumes

**Hard Rules:**
1. If bucket empty: wait required time (async sleep). Never panic.
2. On observed 429: enter `RiskState::Degraded`, slow loops automatically, and reduce non-critical traffic.
3. On `too_many_requests` / `code 10028` OR "session terminated":
   - Set `rate_limit_session_kill_active = true`
   - PolicyGuard computes `TradingMode::Kill` immediately (no opens, no replaces)
   - Set Open Permission Latch reason: `SESSION_TERMINATION_RECONCILE_REQUIRED`
   - Exponential backoff, then **reconnect**
   - Run **3-way reconciliation** (orders + trades + positions + ledger)
   - Resume only when stable (`RiskState::Healthy`) and latch cleared

**Acceptance Tests (REQUIRED):**
AT-238
- Given: token bucket configured at `T tokens/sec` and `burst=B`.
- When: 100 mixed requests (data refresh + hedges + cancels) are fired.
- Then: aggregate throughput never exceeds `T`/`B`, and hedges/cancels preempt data refresh under contention.
- Pass criteria: rate limits enforced; priority preemption holds.
- Fail criteria: throughput exceeds limits or data refresh preempts hedges/cancels.

AT-239
- Given: token bucket exhausted by `DATA` requests.
- When: `OPEN`, `CANCEL`, `HEDGE`, `EMERGENCY_CLOSE` are submitted.
- Then: `DATA` is shed first; `OPEN` is blocked; `CANCEL`/`HEDGE`/`EMERGENCY_CLOSE` continue to be serviced.
- Pass criteria: data shed; open blocked; critical intents processed.
- Fail criteria: opens serviced or critical intents blocked while data continues.

AT-919
- Given: limiter pressure (or a 429 burst) and an OPEN intent.
- When: brownout shedding applies.
- Then: the OPEN is rejected with `Rejected(RateLimitBrownout)`.
- Pass criteria: rejection reason matches; no OPEN dispatch.
- Fail criteria: dispatch occurs or reason missing/mismatched.

AT-240
- Given: API returns `too_many_requests` (`code 10028`) mid-run.
- When: rate limit handling evaluates.
- Then: `OPEN` blocked immediately; `TradingMode = Kill` + Degraded immediately; reconnect with backoff → full reconcile → resume only after stable.
- Pass criteria: Kill entered and reconcile path executed before resuming.
- Fail criteria: opens proceed or reconnect/reconcile not enforced.

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
       - MUST set `open_permission_blocked_latch = true` with reason `WS_BOOK_GAP_RECONCILE_REQUIRED`.
    2) **Resubscribe** to the book channel for that instrument.
    3) Fetch a **full REST snapshot** for the instrument and rebuild the book.
    4) Run reconciliation, then only resume trading when `RiskState::Healthy`.

**B) Trades feeds (`trades.*`) — trade_seq continuity (per instrument):**
- Track `last_trade_seq[instrument]`.
- On each trade:
  - If `trade_seq == last_trade_seq + 1` (or strictly increasing where the feed batches): accept; update.
  - Else (gap or non-monotonic):
    1) Set `RiskState::Degraded` and **pause opens**.
       - MUST set `open_permission_blocked_latch = true` with reason `WS_TRADES_GAP_RECONCILE_REQUIRED`.
    2) Pull recent trades via REST for that instrument and reconcile to the ledger.
    3) Resume only when reconciliation confirms no missing fills.

**C) Private orders/positions/portfolio streams — no “global monotonic seq”:**
- Do **not** invent a `last_seq` for private state.
- Use:
  - **heartbeat / ping** to detect liveness
  - WS disconnect / session termination detection
- On disconnect OR session-level errors:
  1) Set `RiskState::Degraded` and **pause opens**.
     - MUST set `open_permission_blocked_latch = true` with reason `SESSION_TERMINATION_RECONCILE_REQUIRED`.
  2) Force REST snapshot reconciliation (open orders + positions + recent trades).
  3) Resume only after reconciliation passes.

#### **3.4.D** Application-Level WS Data Liveness (Zombie Socket Detection) — MUST implement:
- **Key rule:** TCP/WS ping/pong or heartbeats are not sufficient evidence of market-data liveness.
- Track `last_marketdata_event_ts_ms`: updated ONLY on application market-data payloads (book/trades/ticker), excluding heartbeat/ping/test frames.
- Compute `ws_marketdata_event_lag_ms = now_ms - last_marketdata_event_ts_ms`.

**Trip condition (stalled feed; gated to avoid illiquid false-trips):**
Trip `WS_DATA_STALE_RECONCILE_REQUIRED` only if BOTH are true:
1) `ws_marketdata_event_lag_ms > ws_zombie_silence_ms`, AND
2) (EITHER)
   - `has_open_exposure == true` (any open position OR any in-flight/open orders), OR
   - `had_recent_marketdata_activity == true` where `had_recent_marketdata_activity := (now_ms - last_marketdata_event_ts_ms) <= ws_zombie_activity_window_ms` evaluated at the last time the feed was known-good.

**On trip (deterministic corrective actions):**
1) Set `RiskState::Degraded` and pause opens.
2) Set Open Permission Latch reason: `WS_DATA_STALE_RECONCILE_REQUIRED`.
3) Force WS reconnect/resubscribe.
4) Fetch REST snapshots (orders + positions + recent trades) and run reconciliation.
5) Resume only when reconciliation succeeds and latch clears.

**Explicit exclusion (avoid false-trip loops):**
- This Zombie Socket rule is based on *market-data event silence* (`ws_marketdata_event_lag_ms`) and MUST NOT trip solely
  because an individual instrument’s book `change_id` fails to advance.
- If ticker/trades (or any other marketdata payload) are still arriving such that `ws_marketdata_event_lag_ms` is within
  threshold, the system MUST NOT set `WS_DATA_STALE_RECONCILE_REQUIRED` (no global reconnect loop).
- Per-instrument book quietness is handled by existing L2 staleness + Liquidity Gate and/or per-channel resubscribe logic;
  it is not a “zombie socket” unless market-data as a whole has stalled.

**Acceptance Tests (REQUIRED):**
AT-946
- Given: an illiquid instrument’s book `change_id` does not advance for > `ws_zombie_silence_ms`, but ticker (or trades)
  payloads for any subscribed market-data channel continue to arrive such that `ws_marketdata_event_lag_ms <= ws_zombie_silence_ms`.
  `has_open_exposure == true`.
  - All other gates are configured to pass; no unrelated Open Permission Latch reasons are set (test isolates Zombie Socket rule).
- When: WS liveness monitor evaluates.
- Then: it MUST NOT set `WS_DATA_STALE_RECONCILE_REQUIRED` (no global reconnect loop); the monitor remains non-tripped.
- Pass criteria: latch not set by this rule.
- Fail criteria: latch set or Degraded loops triggered solely by per-instrument book stagnation while other marketdata is live.

AT-947
- Given: `ws_marketdata_event_lag_ms > ws_zombie_silence_ms` and `has_open_exposure == true`, while WS ping/pong continues.
  - All other gates are configured to pass; no unrelated Open Permission Latch reasons are set (test isolates Zombie Socket rule).
- When: WS liveness monitor evaluates.
- Then: `RiskState::Degraded` and Open Permission Latch sets `WS_DATA_STALE_RECONCILE_REQUIRED`; opens are blocked until reconcile clears.
- Pass criteria: latch set; OPEN blocked; reconnect + reconcile path invoked.
- Fail criteria: OPEN allowed or latch not set.

AT-948
- Given: an illiquid instrument with no marketdata events for > `ws_zombie_silence_ms`, but `has_open_exposure == false` and `had_recent_marketdata_activity == false`.
  - All other gates are configured to pass; no unrelated Open Permission Latch reasons are set (test isolates Zombie Socket rule).
- When: WS liveness monitor evaluates.
- Then: it MUST NOT set `WS_DATA_STALE_RECONCILE_REQUIRED` (no reconnect loop from legitimate quiet markets).
- Pass criteria: latch not set by this rule.
- Fail criteria: latch set or Degraded loops triggered solely by quiet book.

**Safety rule during Degraded:** allow reduce-only closes/hedges to proceed; block any risk-increasing cancels/replaces/opens (see definition in §2.2.5).

**Acceptance Tests (REQUIRED):**
AT-271
- Given: an incremental book update where `prevChangeId != last_changeId`.
- When: WS continuity handling runs.
- Then: immediate Degraded → resubscribe + full snapshot rebuild → opens remain paused until rebuild completes.
- Pass criteria: Degraded entered; resubscribe + rebuild executed; opens paused.
- Fail criteria: no Degraded or opens resume before rebuild completes.

AT-408
- Given: an incremental book update where `prevChangeId != last_changeId`.
- When: WS continuity handling runs.
- Then: `open_permission_blocked_latch == true` and `open_permission_reason_codes` includes `WS_BOOK_GAP_RECONCILE_REQUIRED`.
- Pass criteria: latch true; reason code present; OPEN blocked.
- Fail criteria: latch false, reason code missing, or OPEN dispatch occurs.

AT-272
- Given: trades feed where `trade_seq` jumps (gap) for an instrument.
- When: WS continuity handling runs.
- Then: Degraded → REST trade pull + reconcile → no duplicate processing; only then resume.
- Pass criteria: Degraded entered; REST reconcile runs; no duplicate processing.
- Fail criteria: no reconcile or duplicates processed.

AT-120
- Given: RiskState is Degraded due to a WS continuity break.
- When: a cancel/replace that increases exposure is attempted.
- Then: the request is rejected; reduce-only closes/hedges remain allowed.
- Pass criteria: cancel/replace rejected while Degraded; reduce-only close/hedge allowed.
- Fail criteria: risk-increasing cancel/replace is allowed during Degraded.

AT-202
- Given: a WS trades stream gap is detected (trade_seq non-monotonic).
- When: the system evaluates permissions for an OPEN intent.
- Then: OPEN is blocked and `/status.open_permission_reason_codes` includes `WS_TRADES_GAP_RECONCILE_REQUIRED`.
- Pass criteria: OPEN blocked; reason code present; latch sticky until reconciliation clears.
- Fail criteria: OPEN allowed or reason code absent.

AT-409
- Given: a private WS session termination or disconnect is detected (e.g., 10028/session termination).
- When: session termination handling runs.
- Then: `open_permission_blocked_latch == true` and `open_permission_reason_codes` includes `SESSION_TERMINATION_RECONCILE_REQUIRED`.
- Pass criteria: latch true; reason code present; OPEN blocked until reconciliation clears.
- Fail criteria: latch false, reason code missing, or OPEN allowed before reconciliation.

AT-941
- Given: a crash occurs during reconciliation (WS reconnect and REST snapshot in progress) while RiskState is Degraded and the open-permission latch is set.
- When: the system restarts and replays WAL.
- Then: it must re-run reconciliation idempotently, keep opens blocked until reconciliation passes, and avoid duplicate dispatch.
- Pass criteria: Degraded/latch persists until reconcile succeeds; no dispatch before reconciliation completes; no duplicate processing.
- Fail criteria: opens proceed before reconciliation completes or duplicate dispatch/processing occurs.


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

AT-210
- Given: local TLSM state is Sent (or equivalent inflight), but exchange trades show Filled and ACK is missing.
- When: the system processes the orphan fill via REST/WS reconciliation.
- Then: TLSM transitions to Filled (panic-free), no duplicate order is created, and the sequencer executes close/hedge as required.
- Pass criteria: correct terminal TLSM state and no duplicate dispatch.
- Fail criteria: panic, duplicate dispatch, or incorrect final state.


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

**Acceptance Tests (REQUIRED):**
AT-121
- Given: an order fills during WS disconnect and the Sweeper runs before WS replay.
- When: the Sweeper queries REST trades for the label/instrument.
- Then: ledger updates to Filled/PartiallyFilled and later WS trade is ignored via `processed_trade_ids`.
- Pass criteria: no duplicate trade processing; TLSM state updated from REST trade.
- Fail criteria: duplicate fills or missing TLSM update.

AT-122
- Given: an exchange open order has label `s4:` and no matching ledger intent.
- When: the Sweeper runs.
- Then: `CancelStaleOrder` is issued and `GhostOrderCanceled` is logged.
- Pass criteria: cancel dispatch occurs and the log entry is written.
- Fail criteria: ghost order remains open or no log entry is produced.

AT-123
- Given: a Sent/Acked order has no open order and no trade in the REST lookback.
- When: the Sweeper runs.
- Then: TLSM state is marked `Failed` and the sequencer is unblocked.
- Pass criteria: `Failed` state recorded and sequencer resumes.
- Fail criteria: state remains inflight or sequencer remains blocked.

AT-124
- Given: open order age `> stale_order_sec`, `reduce_only == false`, and `RiskState == Degraded`.
- When: the Sweeper runs.
- Then: the order is canceled and not replaced.
- Pass criteria: cancel issued; no `ReplaceIOC` emitted while Degraded.
- Fail criteria: any `ReplaceIOC` occurs while Degraded.


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
**Action:** set `RiskState::Degraded` if drift exceeds threshold `svi_guard_trip_count` times within `svi_guard_trip_window_s` (defaults from Appendix A).

**SVI Math Guard (Hard NaN / Blow-Up Shield):**
- If any fitted parameter is non-finite (`NaN` / `Inf`) → return `None` and hold last valid fit.
- If any derived implied vol is non-finite OR exceeds **500%** (`iv > 5.0`) → return `None`.
- On any guard trip: increment `svi_guard_trips`; if count exceeds `svi_guard_trip_count` within `svi_guard_trip_window_s` (defaults from Appendix A) → set `RiskState::Degraded`.

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
- If count exceeds `svi_guard_trip_count` within `svi_guard_trip_window_s` (defaults from Appendix A) → `RiskState::Degraded` and **pause opens**.

**Acceptance Test (REQUIRED):**
AT-241
- Given: a deliberately wavy fit that passes RMSE but violates convexity.
- When: arb-guards validate the fit.
- Then: the fit is rejected and the previous fit is held.
- Pass criteria: fit rejected; last valid retained.
- Fail criteria: invalid fit accepted.

#### **4.1.2 Liquidity-Aware Acceptance (Avoid Stale-Fit Paralysis)**

**Rule:**
- In low depth (`depth_topN < depth_min`), accept fits with `drift <= 30%` and `rmse <= 0.07` **as long as Arb-Guards pass**.

**Acceptance Test (REQUIRED):**
AT-242
- Given: low depth snapshot with `drift=30%` and `rmse=0.07`.
- When: SVI fit is evaluated.
- Then: the fit is accepted if arb-guards pass, and rejected if arb-guards fail.
- Pass criteria: accept with arb-pass; reject with arb-fail.
- Fail criteria: reject despite arb-pass or accept despite arb-fail.

### **4.2 Fee-Aware Execution**

**Dynamic Fee Model:**
- Fee depends on instrument type (option/perp), maker/taker, and delivery proximity.
- `fee_usd = Σ(leg.notional_usd * (fee_rate + delivery_buffer))`

**Implementation:** `soldier/core/strategy/fees.rs`
- Provide `estimate_fees(legs, is_maker, is_near_expiry) -> fee_usd`

**Acceptance Test (REQUIRED):**
AT-243
- Given: gross edge smaller than fees.
- When: fee-aware execution evaluates a trade.
- Then: the trade is rejected.
- Pass criteria: rejection occurs.
- Fail criteria: trade proceeds.

**Fee Cache Staleness (Fail-Closed):**
- Poll fee model (via `/private/get_account_summary` for tier/rates) every 60s.
- Track `fee_model_cache_age_s` (derived from epoch ms timestamp).
- Timestamp requirement: `fee_model_cached_at_ts` MUST be epoch milliseconds (not monotonic ms) to ensure staleness is computed correctly across restarts and between components.
- If `fee_model_cached_at_ts` is missing or unparseable, treat the fee cache as hard-stale (`RiskState::Degraded`) and PolicyGuard MUST force `TradingMode::ReduceOnly` until refresh succeeds.
- Soft stale (age > `fee_cache_soft_s`, default 300s; see Appendix A): apply conservative fee buffer using `fee_stale_buffer` (default 0.20): `fee_rate_effective = fee_rate * (1 + fee_stale_buffer)`.
- Hard stale (age > `fee_cache_hard_s`, default 900s; see Appendix A): set `RiskState::Degraded` and PolicyGuard MUST force `TradingMode::ReduceOnly` until refresh succeeds.

**Acceptance Tests (REQUIRED):**
AT-244
- Given: fresh fee cache (age <= `fee_cache_soft_s`).
- When: fee estimates are computed.
- Then: estimates use actual rates.
- Pass criteria: no stale buffer applied.
- Fail criteria: stale buffer applied while cache is fresh.

AT-245
- Given: hard-stale fee cache (age > `fee_cache_hard_s`).
- When: PolicyGuard computes TradingMode and intents are evaluated.
- Then: `RiskState==Degraded` and opens are blocked; mode becomes ReduceOnly.
- Pass criteria: RiskState Degraded; ReduceOnly enforced; OPEN blocked.
- Fail criteria: RiskState not Degraded, OPEN allowed, or mode remains Active.

AT-031
- Given: `fee_model_cached_at_ts == T0` (epoch ms) and process restarts before any fee refresh; `now_ms == T0 + (fee_cache_hard_s*1000) + 1`.
- When: `fee_model_cache_age_s` is computed after restart and PolicyGuard computes TradingMode.
- Then: `fee_model_cache_age_s > fee_cache_hard_s` and PolicyGuard forces `TradingMode::ReduceOnly` (OPEN blocked) until refresh succeeds.
- Pass criteria: age is computed from epoch timestamps across restart (no monotonic reset underflow).
- Fail criteria: age resets/underflows and PolicyGuard remains Active while cache is hard-stale.

AT-042
- Given: `fee_model_cached_at_ts` is missing or unparseable.
- When: PolicyGuard computes TradingMode.
- Then: `RiskState==Degraded`, `TradingMode==ReduceOnly`, and OPEN intents are rejected before dispatch.
- Pass criteria: RiskState Degraded; no OPEN dispatch; CLOSE/HEDGE/CANCEL allowed unless Kill.
- Fail criteria: RiskState not Degraded, `TradingMode==Active`, or any OPEN dispatch occurs.

AT-032
- Given:
  - `fee_cache_soft_s` is configured.
  - `fee_cache_hard_s` is configured and `fee_cache_hard_s > fee_cache_soft_s`.
  - `fee_stale_buffer` is configured (default 0.20).
  - `fee_model_cache_age_s = fee_cache_soft_s + 1` and `fee_model_cache_age_s <= fee_cache_hard_s`.
  - A candidate OPEN intent that would otherwise pass NetEdge with the fresh fee rate.
- When:
  - The system evaluates the OPEN intent through the fee-aware execution gates.
- Then:
  - The fee estimate uses an effective fee rate buffered by `fee_stale_buffer`.
- Pass criteria:
  - The computed fee estimate reflects the configured buffer in the soft-stale window.
- Fail criteria:
  - The fee estimate is unbuffered in the soft-stale window OR applies the buffer outside the soft-stale window.

AT-033
- Given:
  - `fee_cache_hard_s` is configured.
  - `fee_model_cache_age_s = fee_cache_hard_s + 1`.
- When:
  - PolicyGuard computes TradingMode and the system attempts to dispatch an OPEN intent.
- Then:
  - `TradingMode = ReduceOnly` and the OPEN intent is rejected.
- Pass criteria:
  - No OPEN intent is dispatched while hard-stale fee data persists.
- Fail criteria:
  - Any OPEN intent is dispatched while hard-stale fee data persists.


- Update fee tier / maker-taker rates used by:
  - §1.4.1 Net Edge Gate (fees component)
  - §1.4 Pricer (fee-aware edge checks)

**Acceptance Test (REQUIRED):**
AT-246
- Given: fee tier changes.
- When: the next polling cycle completes.
- Then: NetEdge computation reflects the new tier.
- Pass criteria: updated fee tier applied within one cycle.
- Fail criteria: NetEdge remains based on old tier.


### **4.3 Trade Attribution Schema (Realized Friction Truth)**

**Council Weakness Covered:** Self-improving open loop \+ time handling / drift. **Where:** `soldier/core/analytics/attribution.rs` **Requirement:** Every trade must log projected edge vs realized execution friction with timestamps to measure drift. **Key Fields:** `exchange_ts`, `local_send_ts`, `local_recv_ts`, `drift_ms = local_recv_ts - exchange_ts`. **Rules:**

* If `drift_ms` exceeds `time_drift_threshold_ms` (default: **50ms**, configurable), the system MUST set `RiskState::Degraded` and PolicyGuard MUST compute `TradingMode::ReduceOnly` via the canonical `risk_state == Degraded` trigger (see §2.2.3).
* Require **chrony/NTP** running as an operational prerequisite.
* Time drift monitoring is a RiskState input; PolicyGuard enforces the mode consequence via its canonical precedence ladder.
* **Alignment**: Default aligns with §8.1 Time Drift gate (p99_clock_drift ≤ 50ms).

**Acceptance Test (REQUIRED):**
AT-273
- Given: `drift_ms > time_drift_threshold_ms`.
- When: time drift gate evaluates.
- Then: opens are blocked (ReduceOnly) until drift is restored.
- Pass criteria: ReduceOnly enforced while drift persists.
- Fail criteria: opens allowed during drift violation.

AT-108
- Given: `drift_ms > time_drift_threshold_ms`.
- When: PolicyGuard computes TradingMode with RiskState reflecting the drift violation.
- Then: `trading_mode==ReduceOnly` and `mode_reasons` includes `REDUCEONLY_RISKSTATE_DEGRADED`.
- Pass criteria: OPEN blocked until drift restored.
- Fail criteria: `trading_mode` Active while drift violation persists.


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

**Acceptance Tests (REQUIRED):**
AT-247
- Given: `S_fill == S_signal` and `IV_fill == IV_signal`.
- When: PnL decomposition runs.
- Then: `delta_pnl≈0` and `vega_pnl≈0`; residual must not explode.
- Pass criteria: delta/vega near zero; residual bounded.
- Fail criteria: large delta/vega or residual blow-up.

AT-248
- Given: `theta_per_day = -0.04` and `dt_seconds = 43200` (12h).
- When: theta PnL is computed.
- Then: `theta_pnl ≈ -0.02` (all else equal).
- Pass criteria: theta PnL matches expectation within tolerance.
- Fail criteria: theta PnL deviates materially.


### **4.3.2 Truth Capsule (Decision Context Logger) — MUST implement**

**Goal:** Make every *realized* outcome explainable by the *inputs + gates + model state* that produced the order.
Without this, optimization is open-loop and you will “improve” the wrong knobs.

**Write timing (hard rule):**
- TruthCapsule MUST be recorded **before first dispatch** of any leg in an AtomicGroup (RecordedBeforeDispatch).
- TruthCapsule durability may be asynchronous by default; require a durability barrier only when explicitly configured.
- If TruthCapsule recording fails → block opens and enter `RiskState::Degraded` (ReduceOnly).

AT-046
- Given: an AtomicGroup has at least one leg eligible for dispatch, and no TruthCapsule exists for the `(group_id, leg_idx, intent_hash)` about to dispatch.
- When: the system attempts the first dispatch of any leg in that AtomicGroup.
- Then: dispatch MUST be blocked (no outbound order sent) and the system MUST enter a fail-closed state (`RiskState::Degraded` and `TradingMode::ReduceOnly` via canonical triggers).
- Pass criteria: no first-dispatch occurs without an existing TruthCapsule; opens remain blocked until logging is healthy.
- Fail criteria: any order is dispatched before a TruthCapsule exists for that leg/group.

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
- Persist Decision Snapshots in an append-only store (partitioned by date or hour; storage format implementation-defined).
- On every trade decision that results in dispatch, the system MUST persist the Decision Snapshot and write `decision_snapshot_id` into the Truth Capsule / decision record.
- If Decision Snapshot persistence fails → treat as a TruthCapsule logging failure: block opens and enter `RiskState::Degraded` (ReduceOnly).
- If heavy tick/L2 stream archives are paused due to disk watermarks, Decision Snapshots MUST still be recorded (they are small and required).

- `truth_capsule_id`, `group_id`, `leg_idx`, `intent_hash`, `strategy_id`, `policy_hash`
- **Snapshot references:**
  - `decision_snapshot_id` (decision-time L2 top‑N; REQUIRED). This is the canonical field; `l2_snapshot_id` is legacy and MUST NOT be emitted in v5.1 outputs.
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

**Acceptance Tests (REQUIRED):**
AT-249
- Given: an order is dispatched.
- When: TruthCapsule linkage is checked.
- Then: a `truth_capsule_id` exists linked by `(group_id, leg_idx, intent_hash)`.
- Pass criteria: linkage exists for every dispatch.
- Fail criteria: any dispatch without linkage.

AT-250
- Given: TruthCapsule write fails.
- When: the system evaluates opens.
- Then: opens are blocked and system enters ReduceOnly.
- Pass criteria: ReduceOnly enforced; OPEN blocked.
- Fail criteria: OPEN proceeds after write failure.

AT-251
- Given: forced slow disk / slow writer with a bounded queue capacity `N`.
- When: TruthCapsule writes are enqueued to saturation.
- Then: queue size never exceeds `N`; the hot loop does not block; if backpressure occurs, the system enters ReduceOnly rather than stalling.
- Pass criteria: queue <= `N`; hot loop remains non-blocking; ReduceOnly on backpressure.
- Fail criteria: queue exceeds `N`, hot loop stalls, or remains Active under backpressure.

AT-252
- Given: writer thread/process errors OR queue overflows.
- When: TruthCapsule writer reports failures.
- Then: `truth_capsule_write_errors` increments and trading is forced to ReduceOnly until healthy.
- Pass criteria: error counter increments; ReduceOnly enforced.
- Fail criteria: counter not incremented or mode remains Active.

AT-253
- Given: an attribution row is written for a filled leg.
- When: the row joins to TruthCapsule.
- Then: it reproduces `limit_price_sent`, `gross_edge_usd_est`, `predicted_slippage_bps_sim`.
- Pass criteria: join succeeds and fields match.
- Fail criteria: join fails or fields mismatch.

AT-044
- Given: a Decision Snapshot is emitted.
- When: the Truth Capsule is recorded.
- Then: `decision_snapshot_id` exists and `l2_snapshot_id` does not exist.
- Pass criteria: exactly one canonical field present.
- Fail criteria: alias field appears or canonical field missing.

### **4.4 Fill Simulator (Shadow Mode Book-Walk)**

**Council Weakness Covered:** Constraint relief — execution reality feedback loop. **Where:** `soldier/core/sim/exchange.rs` **Requirement:** Before live fire, run Shadow Mode that simulates fills by walking L2 depth and applying maker/taker fees. **Algorithm:**

* Walk the book to compute WAP for size.  
* Apply fee model.  
* Persist alongside real attribution logs for comparison.

**Schema Parity Rule:**
Shadow mode must write the SAME Parquet schema as live (§4.3) with `mode = shadow|live`.

**Acceptance Test (REQUIRED):**
AT-254
- Given: a fixed L2 snapshot and order size.
- When: the fill simulator runs.
- Then: it outputs deterministic WAP + `slippage_bps`, and `slippage_bps(size=2x) > slippage_bps(size=1x)` on a thin book.
- Pass criteria: deterministic outputs and monotonic slippage with size.
- Fail criteria: non-deterministic output or slippage not increasing with size.


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

**Acceptance Test (REQUIRED):**
AT-255
- Given: 50 synthetic fills where `realized = sim * 1.2`.
- When: slippage calibration runs.
- Then: `realism_penalty_factor → ~1.2` and stable (±0.05); if missing/uninitialized, default factor = 1.3 and tighten opens.
- Pass criteria: factor converges to ~1.2; default applied when missing.
- Fail criteria: factor diverges or missing factor does not default.

## **5\. Self-Improvement: The Closed-Loop Control**

### **5.1 The Optimization Cycle (Python)**

A daily cron job ingests Parquet data to calculate realized friction and generate policy patches.

**Closed-Loop Rules (Example):**
1. If `avg_slippage_bps > target_bps` → increase `min_edge_usd` by 10%.
2. If `fill_rate < 5%` → decrease `limit_distance_bps` slightly.
3. If `atomic_naked_events > 0` → tighten max size + force ReduceOnly for cooldown window.

**Governor (Safety):**
- Clamp changes within bounds (implementation-defined safe ranges for each parameter).
- Require "dry-run" mode first: logs patch, does not apply.

**Implementation:** `python/optimizer/closed_loop.py`


---


### **5.2 Replay Gatekeeper (48h Policy Regression Test)**

**Requirement:** No policy patch may be applied unless it passes replay simulation over the last 48h.

**Prereq (must implement):**
- **Decision Snapshots (required):** Every dispatched intent MUST reference a decision-time snapshot via `decision_snapshot_id` (see §4.3.2).
- Track `snapshot_coverage_pct` over the replay window (48h): `% of dispatched intents with a valid `decision_snapshot_id` AND snapshot payload available`.
- **Replay Required Inputs (Non-Negotiable):**
  - **Decision Snapshots are REQUIRED** for replay validity (see §4.3.2).
  - Replay Gatekeeper MUST HARD FAIL if `snapshot_coverage_pct < 95%` (fail-closed; no patch may apply).

**Parameter definition (REQUIRED to make the gate enforceable):**
- `dd_limit` is the maximum allowable `replay_max_drawdown_usd` for the 48h replay window, in USD.
- `dd_limit` MUST be explicitly configured (no implicit default). If missing/unparseable, Replay Gatekeeper MUST HARD FAIL (fail-closed).
- **Full tick/L2 archives are OPTIONAL (diagnostics/research), not required for the gate:**
  - If full tick/L2 archives are paused due to disk watermarks (§7.2), Replay Gatekeeper continues using Decision Snapshots.
  - Archive pause MUST NOT, by itself, force `RiskState::Degraded`.
  - If Decision Snapshots cannot be written/read OR coverage drops below threshold, THEN fail-closed and enter Degraded (ReduceOnly).
- Maintain `realism_penalty_factor` from §4.5 (fail-safe default if missing).

**Where:** `python/governor/replay_gatekeeper.py`

**Validation rules (hard gates):**
- `replay_atomic_naked_events == 0`
- `replay_max_drawdown_usd <= dd_limit`

**Required parameter (fail-closed):**
- `dd_limit` is the maximum allowable `replay_max_drawdown_usd` over the 48h replay window, in USD.
- `dd_limit` MUST be provided by configuration; if missing or unparseable, Replay Gatekeeper MUST HARD FAIL (fail-closed).

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

**Acceptance Tests (REQUIRED):**
AT-256
- Given: an order/intent is dispatched.
- When: Decision Snapshot linkage is checked.
- Then: it MUST join via `decision_snapshot_id`.
- Pass criteria: linkage exists for every dispatch.
- Fail criteria: any dispatch without a valid `decision_snapshot_id`.

AT-257
- Given: `snapshot_coverage_pct < 95%`.
- When: Replay Gatekeeper runs.
- Then: it MUST FAIL.
- Pass criteria: gate fails below 95%.
- Fail criteria: gate passes below 95%.

AT-002
- Given: `snapshot_coverage_pct == 95%`.
- When: Replay Gatekeeper runs.
- Then: gate MUST PASS.
- Pass criteria: PASS at exactly 95%.
- Fail criteria: FAIL at 95% OR PASS when < 95%.

AT-258
- Given: disk watermark pauses full tick/L2 archives.
- When: Replay Gatekeeper evaluates inputs.
- Then: it continues using Decision Snapshots and MUST NOT force `RiskState::Degraded` solely due to archive pause.
- Pass criteria: no Degraded solely from archive pause.
- Fail criteria: Degraded triggered by archive pause alone.

AT-259
- Given: a policy passes replay pre-penalty checks.
- When: Replay Gatekeeper completes.
- Then: it approves the patch for rollout (still subject to canary staging §5.3).
- Pass criteria: PASS leads to approval.
- Fail criteria: PASS does not approve or FAIL approves.

AT-431
- Given: `replay_atomic_naked_events > 0`.
- When: Replay Gatekeeper runs.
- Then: it MUST FAIL and the patch remains blocked.
- Pass criteria: gate fails; patch not eligible for canary rollout.
- Fail criteria: gate passes or patch proceeds with atomic naked events.

AT-432
- Given: `replay_net_pnl_penalized <= 0` after realism penalty is applied.
- When: Replay Gatekeeper runs.
- Then: it MUST FAIL and the patch remains blocked.
- Pass criteria: gate fails; patch not eligible for canary rollout.
- Fail criteria: gate passes or patch proceeds with non-positive penalized PnL.

**Acceptance Tests:**

AT-034
- Given: Replay Gatekeeper is invoked and `dd_limit` is missing or unparseable.
- When: the gate evaluates `replay_max_drawdown_usd`.
- Then: the gate HARD FAILS and the patch remains blocked (last stable policy stays active).
- Pass criteria: patch is not eligible for canary rollout.
- Fail criteria: patch becomes eligible without a valid `dd_limit`.

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
- `fill_rate < fill_rate_floor` AND strategy attempts > canary_min_attempts
- `net_pnl_usd < pnl_floor`
- EvidenceChainState != GREEN for > 60s
- Any abort condition triggers immediate rollback to last stable policy + sets ReduceOnly cooldown per §7.1.4.

**Abort threshold parameters (fail-closed):**
- `slippage_limit` is a p95 slippage threshold in bps for the canary window.
- `fill_rate_floor` is a minimum fill-rate threshold in [0,1] for the canary window.
- `canary_min_attempts` is the minimum number of strategy attempts before the fill-rate abort condition can trigger.
- `pnl_floor` is a minimum allowable net PnL threshold in USD for the canary window.
- All four MUST be provided by configuration; if any is missing/unparseable, the rollout MUST abort + rollback (fail-closed).

AT-035
- Given: canary rollout runs and at least one of `slippage_limit`, `fill_rate_floor`, `canary_min_attempts`, `pnl_floor` is missing/unparseable.
- When: the abort evaluator runs.
- Then: immediate rollback occurs and ReduceOnly cooldown is enforced.
- Pass criteria: rollback + cooldown occur; policy does not progress stages.
- Fail criteria: rollout proceeds without valid abort thresholds.

AT-036
- Given: canary rollout runs with `slippage_limit` configured and observed `p95_slippage_bps > slippage_limit`.
- When: the abort evaluator runs.
- Then: immediate rollback occurs and ReduceOnly cooldown is enforced.
- Pass criteria: policy is rolled back and cooldown prevents opens.
- Fail criteria: policy remains active despite slippage abort condition.

AT-433
- Given: canary rollout runs with `fill_rate_floor` configured and observed `fill_rate < fill_rate_floor` with attempts > `canary_min_attempts`.
- When: the abort evaluator runs.
- Then: immediate rollback occurs and ReduceOnly cooldown is enforced.
- Pass criteria: policy is rolled back and cooldown prevents opens.
- Fail criteria: policy remains active despite fill-rate abort condition.

AT-434
- Given: canary rollout runs with `pnl_floor` configured and observed `net_pnl_usd < pnl_floor`.
- When: the abort evaluator runs.
- Then: immediate rollback occurs and ReduceOnly cooldown is enforced.
- Pass criteria: policy is rolled back and cooldown prevents opens.
- Fail criteria: policy remains active despite pnl abort condition.

AT-435
- Given: EvidenceChainState != GREEN for > 60s during canary.
- When: the abort evaluator runs.
- Then: immediate rollback occurs and ReduceOnly cooldown is enforced.
- Pass criteria: policy is rolled back and cooldown prevents opens.
- Fail criteria: policy remains active despite EvidenceChainState abort condition.

AT-436
- Given: `atomic_naked_events > 0` during canary.
- When: the abort evaluator runs.
- Then: immediate rollback occurs and ReduceOnly cooldown is enforced.
- Pass criteria: policy is rolled back and cooldown prevents opens.
- Fail criteria: policy remains active despite atomic naked event.

## **6\. Implementation Roadmap v4.0**

### **Phase 1: The Foundation (Panic-Free)**

* TLSM & `s4:` labeling schema.  
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

* **Prometheus \+ Grafana:** Dashboards \+ alerts (gamma, delta, atomic\_naked\_events, 429\_count_5m, 10028\_count_5m, ws\_gap\_count).  
* **DuckDB:** Query Parquet attribution quickly (hourly slippage, fill-rate, fee drag).  
* **chrony/NTP:** Enforce time correctness for attribution.

**Minimum Alert Set:**

* `atomic_naked_events > 0`  
* `429_count_5m > 0`  
* `10028_count_5m > 0`
* `policy_age_sec > 300` (force ReduceOnly)
* `decision_snapshot_write_errors > 0`
* `truth_capsule_write_errors > 0`
* `parquet_queue_overflow_count > 0` (or increasing)
* `evidence_guard_blocked_opens_count > 0` (new metric)


### **7.0 Owner Control Plane Endpoints (Read-Only, Owner-Grade)**

**Requirement:** The system MUST provide a read-only status endpoint for human oversight and for external watchdog tooling.

**Endpoints:**
- `GET /api/v1/status` (read-only)
- `GET /api/v1/health` (read-only; minimal external watchdog primitive)

**/health response MUST include (minimum):**
- `ok` (bool; MUST be true when process is up)
- `build_id` (string)
- `contract_version` (string)

**Acceptance Test (REQUIRED):**

AT-022
- Given: service is running.
- When: `GET /api/v1/health`.
- Then: HTTP 200 and keys `ok`, `build_id`, `contract_version` exist with `ok == true`.
- Pass criteria: response matches required keys/values.
- Fail criteria: non-200 OR missing keys OR `ok != true`.

**/status response MUST include (minimum):**
- `status_schema_version` (integer; current version = 1)
- `trading_mode`, `risk_state`, `evidence_chain_state`, `bunker_mode_active`
- `connectivity_degraded` (bool; true iff `bunker_mode_active == true` OR `open_permission_reason_codes` contains `RESTART_RECONCILE_REQUIRED`, `WS_BOOK_GAP_RECONCILE_REQUIRED`, `WS_TRADES_GAP_RECONCILE_REQUIRED`, `WS_DATA_STALE_RECONCILE_REQUIRED`, `INVENTORY_MISMATCH_RECONCILE_REQUIRED`, or `SESSION_TERMINATION_RECONCILE_REQUIRED`)
- `policy_age_sec`, `last_policy_update_ts` (epoch ms; MUST equal `python_policy_generated_ts_ms` from PolicyGuard inputs)
- `f1_cert_state` + `f1_cert_expires_at`
- `disk_used_pct` (ratio in [0,1]), `disk_used_last_update_ts_ms` (epoch ms; see §2.2.1.1)
- `mm_util`, `mm_util_last_update_ts_ms` (epoch ms; see §2.2.1.1)
- `snapshot_coverage_pct` (MUST be computed over `replay_window_hours`; current computed metric / last window)
- `atomic_naked_events_24h`, `429_count_5m`, `10028_count_5m`
- `wal_queue_depth`, `wal_queue_capacity`, `wal_queue_enqueue_failures` (see §2.4.1)
- `deribit_http_p95_ms`, `ws_event_lag_ms`
- `mode_reasons` (ModeReasonCode[]; authoritative explanation of `trading_mode` for this tick; MUST be `[]` iff `trading_mode == Active`)
- `open_permission_blocked_latch` (bool; true means OPEN blocked; CLOSE/HEDGE/CANCEL allowed only as permitted by §2.2.5)
- `open_permission_reason_codes` (OpenPermissionReasonCode[]; MUST be [] iff `open_permission_blocked_latch == false`)
- `open_permission_requires_reconcile` (bool; MUST equal `open_permission_blocked_latch` for v5.1 - all reason codes are reconcile-class)

**WAL queue invariants:**
- `wal_queue_depth` MUST be integer >= 0.
- `wal_queue_capacity` MUST be integer > 0.
- `wal_queue_depth` MUST be <= `wal_queue_capacity`.

**Metric Binding (Canonical Windows):**
- `429_count_5m` and `10028_count_5m` are the canonical rate-limit counters used for alerts, incident triggers, and release gates.
- `429_count` and `10028_count` MUST NOT be used.
- `atomic_naked_events_24h` MUST be an integer counter (rolling 24h count) with valid range >= 0.



**/status F1_CERT fields (contract-bound semantics):**
- `f1_cert_state` (string enum; derived by PolicyGuard):
  - `PASS`: F1_CERT present, within freshness window, and binding matches runtime (§2.2.1).
  - `FAIL`: F1_CERT present but `f1_cert.status == "FAIL"`.
  - `STALE`: F1_CERT present but `now_ms - f1_cert.generated_ts_ms > (f1_cert_freshness_window_s * 1000)`.
  - `MISSING`: F1_CERT missing/unreadable/unparseable.
  - `INVALID`: F1_CERT present but binding check fails (build_id/runtime_config_hash/contract_version mismatch).
- `f1_cert_expires_at` (epoch ms):
  - If F1_CERT is present and parseable: `f1_cert.generated_ts_ms + (f1_cert_freshness_window_s * 1000)`.
  - If F1_CERT is missing/unparseable: MUST be `null`.

**Acceptance Test (REQUIRED):**
AT-003
- Given: F1_CERT is present with `status="PASS"`, `generated_ts_ms=T0`, and `f1_cert_freshness_window_s=86400`.
- When: `GET /api/v1/status` is queried at `now_ms=T0+1000`.
- Then: `f1_cert_state=="PASS"` and `f1_cert_expires_at==T0+(86400*1000)`.
- Pass criteria: response contains both keys and the computed values exactly.
- Fail criteria: keys missing, `f1_cert_state != "PASS"`, or `f1_cert_expires_at` not equal to the computed expiry.

AT-412
- Given: F1_CERT is missing or unparseable.
- When: `GET /api/v1/status`.
- Then: `f1_cert_state=="MISSING"` and `f1_cert_expires_at==null`.
- Pass criteria: both fields present with `f1_cert_expires_at` null.
- Fail criteria: `f1_cert_expires_at` non-null, missing, or state inconsistent.

**Security:** This endpoint MUST NOT allow changing risk. No “set Active” endpoints in this patch.

**Testing Requirement (Non-Negotiable):**
Any new endpoint introduced by this contract MUST include at least one endpoint-level test.

**Acceptance Test (REQUIRED):**

AT-023
- Given: service is running.
- When: `GET /api/v1/status`.
- Then: response MUST include every key listed under "/status response MUST include (minimum)".
- Pass criteria: all required keys exist.
- Fail criteria: any required key missing.

AT-407
- Given: service is running with `TradingMode` and `RiskState` at baseline values.
- When: a non-GET request (e.g., `POST /api/v1/status`) is attempted.
- Then: the request is rejected (4xx/405) and `TradingMode`/`RiskState` are unchanged.
- Pass criteria: non-GET is rejected and no risk mutation occurs.
- Fail criteria: non-GET accepted or any risk mutation occurs.

AT-405
- Given: `/status` is fetched.
- When: `status_schema_version` is read.
- Then: `status_schema_version == 1`.
- Pass criteria: value equals 1.
- Fail criteria: missing or not 1.

AT-419
- Given: `/status` is fetched.
- When: rate-limit counters are read.
- Then: `429_count_5m` and `10028_count_5m` exist.
- Pass criteria: both keys present.
- Fail criteria: any key missing.

AT-927
- Given: `/status` is fetched.
- When: `atomic_naked_events_24h` is read.
- Then: it is an integer >= 0.
- Pass criteria: key present; integer type; non-negative.
- Fail criteria: missing key, non-integer value, or negative value.

AT-907
- Given: `/status` is fetched.
- When: WAL queue metrics are read.
- Then: `wal_queue_depth` and `wal_queue_capacity` exist, are integers, and satisfy `0 <= wal_queue_depth <= wal_queue_capacity` with `wal_queue_capacity > 0`.
- Pass criteria: keys present; numeric types; constraints hold.
- Fail criteria: missing keys, non-integer values, `wal_queue_capacity <= 0`, or `wal_queue_depth > wal_queue_capacity`.

AT-212
- Given: `open_permission_reason_codes` contains `WS_TRADES_GAP_RECONCILE_REQUIRED`.
- When: `/status` is fetched.
- Then: `connectivity_degraded == true`.
- Pass criteria: `connectivity_degraded` is true.
- Fail criteria: `connectivity_degraded` is false or missing.

AT-403
- Given: `open_permission_reason_codes` contains `RESTART_RECONCILE_REQUIRED` or `INVENTORY_MISMATCH_RECONCILE_REQUIRED`.
- When: `/status` is fetched.
- Then: `connectivity_degraded == true`.
- Pass criteria: `connectivity_degraded` is true.
- Fail criteria: `connectivity_degraded` is false or missing.

AT-352
- Given: `bunker_mode_active == true` and `open_permission_reason_codes == []`.
- When: `/status` is fetched.
- Then: `connectivity_degraded == true`.
- Pass criteria: `connectivity_degraded` is true.
- Fail criteria: `connectivity_degraded` is false or missing.

AT-353
- Given: `bunker_mode_active == false` and `open_permission_reason_codes == []`.
- When: `/status` is fetched.
- Then: `connectivity_degraded == false`.
- Pass criteria: `connectivity_degraded` is false.
- Fail criteria: `connectivity_degraded` is true or missing.

**Acceptance Tests (REQUIRED - semantic invariants):**

AT-024
- Given: `/status` is fetched.
- When: `trading_mode == Active`.
- Then: `mode_reasons` MUST be `[]`.
- Pass criteria: Active ⇒ `mode_reasons == []`.
- Fail criteria: Active with non-empty `mode_reasons`, or non-Active with empty `mode_reasons` when reasons are required.

AT-025
- Given: `/status.mode_reasons` contains ≥1 reason.
- When: reasons are evaluated against precedence tiers.
- Then: `mode_reasons` MUST be "tier-pure" (all reasons from the highest triggered tier only).
- Pass criteria: no mixed-tier reasons appear in one response.
- Fail criteria: any response contains mixed-tier reasons.

AT-351
- Given: `policy_age_sec > max_policy_age_sec`, `evidence_chain_state != GREEN`, and no Kill reasons are active.
- When: PolicyGuard computes TradingMode and `/status` is fetched.
- Then: `mode_reasons` includes both `REDUCEONLY_POLICY_STALE` and `REDUCEONLY_EVIDENCE_CHAIN_NOT_GREEN` in the allowed order.
- Pass criteria: all active ReduceOnly reasons are present and ordered correctly.
- Fail criteria: any active reason missing, extra reason added, or order incorrect.

AT-026
- Given: `/status.mode_reasons` contains reasons.
- When: reasons are returned.
- Then: their ordering MUST match the "Allowed values list order" in §2.2.3.
- Pass criteria: output order matches contract order.
- Fail criteria: any out-of-order reason list.

AT-027
- Given: `/status` is fetched.
- When: `open_permission_blocked_latch == false`.
- Then: `open_permission_reason_codes` MUST be `[]` and `open_permission_requires_reconcile == false`.
- Pass criteria: all latch fields agree with the invariants.
- Fail criteria: any latch-field inconsistency.

AT-342
- Given: `/status` is fetched.
- When: `open_permission_blocked_latch == true` and `open_permission_reason_codes` contains at least one reconcile-class code.
- Then: `open_permission_requires_reconcile == true` and `open_permission_reason_codes` is non-empty.
- Pass criteria: latch=true ⇒ requires_reconcile=true and reason_codes length >= 1.
- Fail criteria: latch=true with requires_reconcile=false OR reason_codes empty.

AT-028
- Given: `/status` is fetched.
- When: `last_policy_update_ts` is reported.
- Then: `last_policy_update_ts` MUST equal PolicyGuard input `python_policy_generated_ts_ms`.
- Pass criteria: equality holds.
- Fail criteria: mismatch between reported and PolicyGuard input timestamps.

AT-406
- Given: `python_policy_generated_ts_ms = T0` and `now_ms = T0 + 123_000`.
- When: `/status` is fetched.
- Then: `policy_age_sec == 123`.
- Pass criteria: `policy_age_sec` matches the computed value.
- Fail criteria: missing or mismatch.

AT-029
- Given: replay window is `replay_window_hours` (default 48h).
- When: `/status.snapshot_coverage_pct` is computed.
- Then: it MUST be computed over the configured replay window hours.
- Pass criteria: window used matches `replay_window_hours`.
- Fail criteria: snapshot coverage computed over a different window.

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
- `429_count_5m > 0` OR `10028_count_5m > 0`
- canary abort (slippage blowout / pnl floor breach)

**Required actions:**
- Immediate `TradingMode::ReduceOnly` cooldown (duration configured; default 6–24h).
- Produce `artifacts/incidents/<ts>_incident.md` with:
  - Timeline (first bad event → containment → flat)
  - Root cause tag (liquidity / rate limit / WS gap / policy drift / sizing)
  - “What would have prevented this” (which gate failed or was missing)
  - Next patch recommendation (SAFE only unless human approves)

#### **7.1.5 Acceptance Tests**
AT-274
- Given: daily review runs.
- When: review output is written.
- Then: `artifacts/reviews/<date>/daily_review.json` includes `atomic_naked_events`, `p95_slippage_bps`, `fee_drag_usd`, `replay_net_pnl_penalized`, and current `policy_hash`.
- Pass criteria: file exists with required fields.
- Fail criteria: missing file or missing fields.

AT-275
- Given: patch is AGGRESSIVE and `artifacts/HUMAN_APPROVAL.json` is missing.
- When: auto-apply decision runs.
- Then: the patch MUST NOT apply (even if replay/canary pass).
- Pass criteria: patch blocked.
- Fail criteria: patch applied without approval.

AT-276
- Given: `atomic_naked_events > 0`.
- When: incident handling runs.
- Then: an incident report is generated and ReduceOnly cooldown is enforced.
- Pass criteria: report created + ReduceOnly cooldown active.
- Fail criteria: missing report or no cooldown.

AT-902
- Given: an OPEN intent is blocked by any gate.
- When: the decision is recorded in `artifacts/decision_log.jsonl`.
- Then: an audit-trail entry exists containing `intent_id`, `gate_name`, `trading_mode`, and `reason_codes`.
- Pass criteria: log entry exists with required fields.
- Fail criteria: missing log entry or missing required fields.

AT-903
- Given: a policy change is applied.
- When: `artifacts/policy_patches/<ts>_patch.json` is written.
- Then: `patch_meta.impact` exists and is one of `SAFE|NEUTRAL|AGGRESSIVE`.
- Pass criteria: valid `patch_meta.impact` present.
- Fail criteria: missing impact or invalid value.

AT-904
- Given: an incident trigger occurs (`atomic_naked_events > 0` or `429_count_5m > 0` or `10028_count_5m > 0`).
- When: incident handling runs.
- Then: `artifacts/incidents/<ts>_incident.md` is generated with timeline, root cause tag, prevention note, and next patch recommendation.
- Pass criteria: report exists with required sections.
- Fail criteria: missing report or missing required sections.


### **7.2 Data Retention & Disk Watermarks — MUST implement**

**Goal:** Prevent “disk full → corrupted logs → blind trading decisions.”

**Retention defaults (configurable):**
- Tick/L2 archives: keep **72h** (rolling) (compressed).
- Parquet analytics (attribution + truth capsules): keep **30d** (compressed).
- **Decision Snapshots (REQUIRED replay input; see §4.3.2):** rolling retention window for Decision Snapshot partitions.
  - Default: `decision_snapshot_retention_days = 30` (configurable).
  - Hard lower bound: `decision_snapshot_retention_days` MUST be ≥ `ceil(replay_window_hours / 24)` (Replay Gatekeeper window; default 48h → 2 days; see §5.2).
  - Safety invariant: retention MUST NOT delete any Decision Snapshots that fall within the window used to compute `snapshot_coverage_pct`.
  - Storage model requirement: Decision Snapshots MUST be partitioned by day (or hour) so retention deletes only cold partitions (never hot writer partitions).
- WAL / intent ledger: keep **indefinitely** (small, critical).

**Disk watermarks (hard rules):**
- `disk_used_pct` is a ratio in [0.0, 1.0] (e.g., 0.80 == 80%).
- `disk_used_pct >= disk_pause_archives_pct` → stop full tick + L2 archives; keep Kline + trades.
- `disk_used_pct >= disk_degraded_pct` → enter RiskState::Degraded and force ReduceOnly.
- `disk_used_pct >= disk_kill_pct` → enter Kill (block all dispatch; containment forbidden per §2.2.3); run retention reclaim immediately.

**Automatic retention reclaim (non-blocking):**
- The system MUST implement `retention_reclaim()` to prevent the `disk_degraded_pct`→`disk_kill_pct` death spiral.
- Triggering:
  - `disk_used_pct >= disk_pause_archives_pct`: best-effort reclaim (background task; rate-limited, e.g., ≤ 1 run/hour).
  - `disk_used_pct >= disk_degraded_pct`: mandatory reclaim (repeat until `disk_used_pct < disk_pause_archives_pct` OR no reclaimable data remains).
- Eligible deletions (ONLY beyond configured retention windows; delete cold partitions only):
  - Tick/L2 archives older than retention (default 72h).
  - Parquet analytics (attribution + truth capsules) older than retention (default 30d).
  - Decision Snapshots older than `decision_snapshot_retention_days`, subject to replay-window safety below.
- Safety invariants:
  - MUST NOT delete WAL / intent ledger (indefinite).
  - MUST NOT delete any Decision Snapshot partition that intersects the current replay window used to compute `snapshot_coverage_pct`.
  - MUST NOT delete hot writer partitions (current open partition(s)); reclaim operates only on closed partitions.
- Evidence:
  - Each reclaim run MUST write `artifacts/disk_reclaim/<ts>_reclaim.json` containing: reclaimed_bytes, cutoff_ts per dataset, disk_used_pct_before/after.
  - Reclaim MUST NOT stall the hot loop; it runs as a low-priority async/background task.

**Acceptance Tests (REQUIRED):**
AT-260
- Given: simulated `disk_used_pct >= disk_pause_archives_pct`.
- When: disk watermark logic runs.
- Then: full tick/L2 archive writing stops; Decision Snapshots continue.
- Pass criteria: archives paused; Decision Snapshots still recorded.
- Fail criteria: archives continue or Decision Snapshots stop.

AT-261
- Given: simulated `disk_used_pct >= disk_degraded_pct`.
- When: disk watermark logic runs.
- Then: system enters `RiskState::Degraded` and enforces ReduceOnly until back under `disk_pause_archives_pct`.
- Pass criteria: ReduceOnly enforced; exits only after recovery.
- Fail criteria: remains Active or exits early.

AT-262
- Given: simulated `disk_used_pct >= disk_kill_pct`.
- When: disk watermark logic runs.
- Then: trading loop enters Kill.
- Pass criteria: Kill entered; no dispatch.
- Fail criteria: dispatch occurs or mode not Kill.

AT-263
- Given: simulated `disk_used_pct >= disk_degraded_pct`.
- When: `retention_reclaim()` runs.
- Then: it deletes only cold partitions older than retention; MUST NOT touch WAL; MUST NOT delete Decision Snapshot data within the replay window.
- Pass criteria: only eligible cold partitions reclaimed; WAL and replay-window data untouched.
- Fail criteria: WAL touched or replay-window data deleted.

AT-942
- Given: a crash occurs during `retention_reclaim()` after some cold partitions are deleted but before the reclaim run is finalized.
- When: the system restarts and runs `retention_reclaim()` again.
- Then: it must NOT delete WAL, must NOT delete hot writer partitions, and must NOT delete Decision Snapshot data within the replay window; reclaim must remain consistent.
- Pass criteria: WAL intact; hot partitions intact; replay-window data intact; next reclaim completes and writes the reclaim artifact.
- Fail criteria: WAL touched, hot partitions deleted, replay-window data deleted, or reclaim leaves inconsistent state.

**Minimum alerts add:**
- `disk_used_pct >= disk_pause_archives_pct`
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
| Rate Limits | N/A | 429_count_5m==0 AND 10028_count_5m==0 | 0 | REQUIRED |
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

**Acceptance Tests (REQUIRED):**
AT-264
- Given: Time-to-DeltaNeutral >= 2s in any incident.
- When: scaling/promotion is evaluated.
- Then: scaling is blocked (Sniper-only).
- Pass criteria: scaling blocked.
- Fail criteria: scaling proceeds.

AT-265
- Given: Fee Drag Ratio exceeds threshold.
- When: release gate evaluates.
- Then: auto-raise `min_edge_usd` or block opens (policy patch).
- Pass criteria: policy response triggers.
- Fail criteria: no response to fee drag breach.

### **8.2 Minimum Test Suite (The Torture Chamber)**
All must pass in CI before any deployment:

**A) Deterministic Unit Tests (AT Bindings)**
- Quantization rounding + size/units consistency: AT-219, AT-277, AT-280.
- TLSM out-of-order + orphan fill handling: AT-230, AT-210.
- Gates: GrossEdge > 0 but NetEdge < 0 → REJECT: AT-015.
- Arb-Guards: RMSE-pass but convexity fail → REJECT: AT-241.

**Deterministic Unit Test Name Bindings (implementation -> AT):**
- `test_truth_capsule_written_before_dispatch_and_fk_linked()` → AT-046, AT-249.
- `test_atomic_containment_calls_emergency_close_algorithm_with_hedge_fallback()` → AT-118, AT-235.
- `test_disk_watermark_stops_tick_archives_and_forces_reduceonly()` → AT-311, AT-312.
- `test_release_gate_fee_drag_ratio_blocks_scaling()` → AT-265.
- `test_atomic_qty_epsilon_tolerates_float_noise_but_rejects_mismatch()` → AT-278.
- `test_cortex_spread_max_bps_forces_reduceonly()` → AT-284.
- `test_cortex_depth_min_forces_reduceonly()` → AT-286.
- `test_svi_depth_min_applies_loosened_thresholds()` → AT-287.
- `test_stale_order_sec_cancels_non_reduce_only_orders()` → AT-303.

**Appendix A Default Test Name Bindings (implementation -> AT):**
- `test_contracts_amount_match_tolerance_rejects_mismatches_above_0_001()` → AT-280.
- `test_instrument_cache_ttl_s_expires_after_3600s()` → AT-279.
- `test_inventory_skew_k_and_tick_penalty_max_adjust_prices()` → AT-281, AT-282.
- `test_rescue_cross_spread_ticks_uses_2_ticks_default()` → AT-283.
- `test_f1_cert_freshness_window_s_forces_reduceonly_after_86400s()` → AT-294.
- `test_mm_util_max_age_ms_forces_reduceonly_after_30000ms()` → AT-295.
- `test_disk_used_max_age_ms_forces_reduceonly_after_30000ms()` → AT-296.
- `test_watchdog_kill_s_triggers_kill_after_10s_no_health_report()` → AT-297.
- `test_mm_util_reject_opens_blocks_opens_at_70_pct()` → AT-300.
- `test_mm_util_reduceonly_forces_reduceonly_at_85_pct()` → AT-301.
- `test_mm_util_kill_forces_kill_at_95_pct()` → AT-302.
- `test_evidenceguard_global_cooldown_blocks_opens_for_120s()` → AT-304.
- `test_position_reconcile_epsilon_tolerates_1e_6_qty_diff()` → AT-305.
- `test_reconcile_trade_lookback_sec_queries_300s_history()` → AT-306.
- `test_parquet_queue_trip_pct_triggers_evidenceguard_at_90_pct()` → AT-307.
- `test_parquet_queue_clear_pct_resumes_opens_below_70_pct()` → AT-309.
- `test_parquet_queue_trip_window_s_measures_over_5s()` → AT-308.
- `test_queue_clear_window_s_requires_120s_stability()` → AT-310.
- `test_disk_pause_archives_pct_stops_tick_writes_at_80_pct()` → AT-311.
- `test_disk_degraded_pct_forces_reduceonly_at_85_pct()` → AT-312.
- `test_disk_kill_pct_hard_stops_at_92_pct()` → AT-313.
- `test_time_drift_threshold_ms_forces_reduceonly_above_50ms()` → AT-314.
- `test_max_policy_age_sec_forces_reduceonly_after_300s()` → AT-315.
- `test_close_buffer_ticks_uses_5_ticks_on_first_attempt()` → AT-316.
- `test_max_slippage_bps_rejects_trades_above_10bps()` → AT-317.
- `test_fee_cache_soft_s_applies_buffer_after_300s()` → AT-318.
- `test_fee_cache_hard_s_forces_degraded_after_900s()` → AT-319.
- `test_fee_stale_buffer_multiplies_fees_by_1_20()` → AT-320.
- `test_svi_guard_trip_count_triggers_degraded_after_3_trips()` → AT-321.
- `test_svi_guard_trip_window_s_counts_over_300s()` → AT-322.
- `test_dvol_jump_pct_triggers_reduceonly_at_10_pct_spike()` → AT-290.
- `test_dvol_jump_window_s_measures_over_60s()` → AT-291.
- `test_dvol_cooldown_s_blocks_opens_for_300s()` → AT-292.
- `test_spread_depth_cooldown_s_blocks_opens_for_120s()` → AT-293.
- `test_decision_snapshot_retention_days_deletes_after_30_days()` → AT-323.
- `test_replay_window_hours_checks_coverage_over_48h()` → AT-324.
- `test_tick_l2_retention_hours_deletes_after_72h()` → AT-325.
- `test_parquet_analytics_retention_days_deletes_after_30_days()` → AT-326.

**B) Chaos/Integration Scenarios**
AT-328
- Given: Leg A Filled, Leg B Rejected.
- When: containment runs.
- Then: EmergencyFlatten executes within 200ms–1s and exposure is neutralized.
- Pass criteria: flatten within window; exposure neutralized.
- Fail criteria: flatten late or missing.

AT-329
- Given: WS drop after send.
- When: Sweeper runs.
- Then: orphan is canceled within 10s and ledger matches exchange.
- Pass criteria: cancel within 10s; ledger reconciled.
- Fail criteria: orphan persists or ledger mismatch.

AT-330
- Given: 10028/too_many_requests session termination.
- When: session kill handling runs.
- Then: `TradingMode::Kill`, reconnect with backoff, reconcile, resume only stable.
- Pass criteria: Kill entered; reconcile completed before resume.
- Fail criteria: resume without reconcile or Kill not entered.

**C) Replay Simulation**
AT-331
- Given: replay window includes a vol shock day.
- When: replay simulation runs.
- Then: Reflexive Cortex forces ReduceOnly.
- Pass criteria: ReduceOnly enforced during shock.
- Fail criteria: remains Active through shock.

AT-332
- Given: a policy whose replay profit flips ≤ 0 after realism penalty.
- When: Replay Gatekeeper evaluates the policy.
- Then: the policy fails.
- Pass criteria: FAIL when penalized profit ≤ 0.
- Fail criteria: PASS despite penalized loss.

### **8.3 Canary Rollout Protocol (Hard Gate)**
Policy staging in §5.3 is mandatory. Promotion requires:

- Stage 0 (Shadow) PASS for 6–24h
- Stage 1 (Testnet micro-canary) PASS for 2–6h
- Any abort trigger → rollback + ReduceOnly cooldown

### **8.4 Certification Artifact (Hard Gate Implementation)**
**Where:**
- `python/tools/f1_certify.py`
- outputs `artifacts/F1_CERT.json` and `artifacts/F1_CERT.md`
- `artifacts/F1_CERT.json` MUST include (minimum): `{ status, generated_ts_ms, build_id, runtime_config_hash, contract_version }` (see §2.2.1).

**Example CI command:**
- Run: `python python/tools/f1_certify.py --window=24h --out=artifacts/F1_CERT.json`
- Block release unless `status == PASS`.

**Acceptance Test (REQUIRED):**
AT-266
- Given: `atomic_naked_events = 1` in a test run.
- When: certification runs.
- Then: cert status is FAIL and deployment is blocked.
- Pass criteria: FAIL + block.
- Fail criteria: PASS or deployment proceeds.


---

## **Appendix A: Configuration Defaults (Safety-Critical Thresholds)**

This appendix defines default values for safety-critical configuration parameters referenced throughout the contract. These defaults provide fail-safe behavior and deterministic acceptance testing.

**Enforcement (Non-Negotiable):** If a safety-critical config value is missing at runtime, the Soldier MUST apply the default from this appendix **if it is defined here**; otherwise it MUST fail-closed by blocking the associated capability (no silent defaults).

**Acceptance Tests (REQUIRED):**
AT-341
- Given: config missing `instrument_cache_ttl_s`, `evidenceguard_global_cooldown`, and `mm_util_kill` at runtime.
- When: safety-critical defaults are applied from Appendix A for `instrument_cache_ttl_s`, `evidenceguard_global_cooldown`, and `mm_util_kill`.
- Then: defaults are used (`instrument_cache_ttl_s = 3600`, `evidenceguard_global_cooldown = 120`, `mm_util_kill = 0.95`) and enforcement uses those defaults (no implicit zero/none).
- Pass criteria: defaults apply and gating behavior matches the documented defaults.
- Fail criteria: parameters fall back to zero/none or remain unset while still allowing behavior.

AT-040
- Given: a safety-critical gate references a required parameter that has no Appendix A default (e.g., `dd_limit` in §5.2).
- When: that parameter is missing or unparseable at runtime.
- Then: the gate MUST fail-closed (block policy application / rollout) and surface a deterministic reason.
- Pass criteria: the system blocks the associated capability until the parameter is provided.
- Fail criteria: the system proceeds using an implicit/zero/none default.

AT-424
- Given: each safety-critical config value listed in Appendix A is omitted at runtime (one-at-a-time), with other gates satisfied.
- When: the associated gate computes its decision.
- Then: the Appendix A default is used for that parameter.
- Pass criteria: gate behavior matches the documented default for each parameter under test.
- Fail criteria: any parameter uses implicit/zero/none or gate behavior does not match Appendix A default.

### **A.1 Atomic Group Execution**

**`atomic_qty_epsilon`** (§1.2 Atomic Group Executor)
- **Default**: `1e-9` (in the same units as `filled_qty`)
- **Purpose**: Tolerance for declaring "no fill mismatch" between legs
- **Rationale**: Tiny epsilon tolerates only floating-point rounding noise, not meaningful exposure mismatch
AT-278
- Given: two legs filled at nominally equal quantities differing only by ≤ `atomic_qty_epsilon` (no partials).
- When: group completion is evaluated.
- Then: the group is eligible for `Complete`.
- Pass criteria: `Complete` eligibility holds.
- Fail criteria: completion rejected due only to epsilon-level difference.

**`instrument_cache_ttl_s`** (§1.0.X Instrument Metadata Freshness)
- **Default**: `3600` seconds
- **Purpose**: Default TTL for instrument metadata freshness; stale metadata triggers Degraded + ReduceOnly.
AT-279
- Given: `instrument_cache_age_s > instrument_cache_ttl_s`.
- When: instrument freshness is evaluated.
- Then: `RiskState::Degraded` + ReduceOnly within one tick; CLOSE/HEDGE/CANCEL allowed.
- Pass criteria: ReduceOnly enforced with Degraded.
- Fail criteria: remains Active or blocks closes.

**`contracts_amount_match_tolerance`** (§1.0 Instrument Units & Notional Invariants)
- **Default**: `0.001` (0.1% relative tolerance)
- **Purpose**: Tolerance for contracts vs amount consistency check when both are provided; prevents wiring bugs.
- **Rationale**: 0.1% tolerates floating-point rounding without masking meaningful mismatches.
AT-280
- Given: `contracts=100` and `amount` deviates by >0.1% from `contracts * contract_multiplier`.
- When: units consistency is evaluated.
- Then: reject + Degraded.
- Pass criteria: rejection + Degraded.
- Fail criteria: intent proceeds or no Degraded.

---

### **A.1.1 Inventory Skew Gate**

**`inventory_skew_k`** (§1.4.2 Inventory Skew Gate)
- **Default**: `0.5`
- **Purpose**: Scaling factor for edge requirement increase when approaching inventory limits.
- **Rationale**: At max inventory (`inventory_bias=1.0`), require 50% higher edge (conservative but tradable).
AT-281
- Given: `inventory_bias=0.9` for a risk-increasing trade.
- When: Inventory Skew adjusts `min_edge_usd`.
- Then: `min_edge_usd` is increased by ~45%.
- Pass criteria: ~45% increase (within tolerance).
- Fail criteria: adjustment materially deviates.

**`inventory_skew_tick_penalty_max`** (§1.4.2 Inventory Skew Gate)
- **Default**: `3` ticks
- **Purpose**: Maximum limit price shift away from touch when near inventory limits.
- **Rationale**: 3 ticks reduces fill rate without making execution impossible; balances inventory control with opportunity cost.
AT-282
- Given: `inventory_bias=1.0` for a BUY.
- When: Inventory Skew adjusts `limit_price`.
- Then: limit price shifts 3 ticks below best ask.
- Pass criteria: 3-tick shift.
- Fail criteria: shift differs.

**`rescue_cross_spread_ticks`** (§1.2 Atomic Group Executor)
- **Default**: `2` ticks
- **Purpose**: How far to cross the spread when placing rescue IOC orders for atomic group containment.
- **Rationale**: 2 ticks provides aggressive fill probability while limiting slippage cost during containment.
- **Semantics**: For BUY rescue: `limit_price = best_ask + (rescue_cross_spread_ticks * tick_size)`; for SELL rescue: `limit_price = best_bid - (rescue_cross_spread_ticks * tick_size)`.
AT-283
- Given: a mixed-state rescue attempt.
- When: rescue IOC limit price is computed.
- Then: limit price is 2 ticks past best bid/ask (BUY crosses ask upward; SELL crosses bid downward).
- Pass criteria: 2-tick cross applied correctly.
- Fail criteria: incorrect cross or tick distance.

---

### **A.2 Reflexive Cortex (Microstructure Collapse)**

**`spread_max_bps`** (§2.3 Reflexive Cortex)
- **Default**: `25` bps
- **Purpose**: Maximum tolerable spread before forcing ReduceOnly
- **Rationale**: Live F1 PASS target tolerates p95 slippage ≤ 10 bps (§8.1). Spreads >2.5× indicate microstructure collapse.
AT-284
- Given: `spread_bps = 26`.
- When: Cortex evaluates `MarketData`.
- Then: Cortex outputs `ForceReduceOnly{cooldown_s=spread_depth_cooldown_s}` and opens are blocked.
- Pass criteria: ForceReduceOnly issued; opens blocked.
- Fail criteria: no ForceReduceOnly or opens allowed.

**`spread_kill_bps`** (§2.3 Reflexive Cortex)
- **Default**: `75` bps
- **Purpose**: Hard kill threshold for extreme spread blowout
- **Rationale**: 3x `spread_max_bps` indicates market dislocation and unreliable execution.
AT-285
- Given: `spread_bps >= spread_kill_bps` for `cortex_kill_window_s`.
- When: Cortex evaluates `MarketData`.
- Then: Cortex outputs `ForceKill`.
- Pass criteria: ForceKill issued.
- Fail criteria: ForceKill not issued.

**`depth_min`** (§2.3 Cortex, §4.1 SVI)
- **Default**: `300_000` USD
- **Unit**: USD notional depth in top-N price levels (N=5 per side; see §2.3 depth_topN definition).
- **Purpose**: Minimum depth threshold; below triggers ReduceOnly (Cortex) and loosened SVI gates
- **Rationale**: Contract uses `notional_usd=30_000` as worked example (§1.0). 10× ensures "low depth" means thin markets.
- **Behavior**: Cortex \u2192 ReduceOnly; SVI \u2192 drift 20%→40%, RMSE 0.05→0.08
AT-286
- Given: `depth_topN = 299_999`.
- When: Cortex evaluates `MarketData`.
- Then: Cortex outputs `ForceReduceOnly`.
- Pass criteria: ForceReduceOnly issued.
- Fail criteria: ForceReduceOnly not issued.

AT-287
- Given: `depth_topN = 299_999`.
- When: SVI gate evaluates a low-depth fit.
- Then: SVI applies 40% drift max and 0.08 RMSE max.
- Pass criteria: loosened thresholds applied.
- Fail criteria: thresholds not loosened.

**`depth_kill_min`** (§2.3 Reflexive Cortex)
- **Default**: `100_000` USD
- **Unit**: USD notional depth in top-N price levels (N=5 per side; see §2.3 depth_topN definition).
- **Purpose**: Hard kill threshold for extreme depth depletion.
- **Rationale**: One-third of `depth_min` indicates a broken book.
AT-288
- Given: `depth_topN <= depth_kill_min` for `cortex_kill_window_s`.
- When: Cortex evaluates `MarketData`.
- Then: Cortex outputs `ForceKill`.
- Pass criteria: ForceKill issued.
- Fail criteria: ForceKill not issued.

**`cortex_kill_window_s`** (§2.3 Reflexive Cortex)
- **Default**: `10` seconds
- **Purpose**: Continuous breach window to trigger ForceKill.
- **Rationale**: Prevents flapping on transient spread/depth spikes.
AT-289
- Given: breach persists 9s and then 10s.
- When: Cortex evaluates the kill window.
- Then: no trip at 9s; `ForceKill` at 10s.
- Pass criteria: trip only at >= `cortex_kill_window_s`.
- Fail criteria: trip early or not at threshold.

**`dvol_jump_pct`** (§2.3 Reflexive Cortex)
- **Default**: `0.10` (10%)
- **Purpose**: DVOL jump threshold triggering ReduceOnly (volatility shock detection).
- **Rationale**: 10% intra-minute DVOL spike signals market stress or regime shift; halts opens until cooldown expires.
AT-290
- Given: DVOL increases by ≥10% within 60s.
- When: Cortex evaluates `MarketData`.
- Then: Cortex outputs `ForceReduceOnly{cooldown_s=dvol_cooldown_s}`.
- Pass criteria: ForceReduceOnly issued with cooldown `dvol_cooldown_s`.
- Fail criteria: no ForceReduceOnly.

**`dvol_jump_window_s`** (§2.3 Reflexive Cortex)
- **Default**: `60` seconds
- **Purpose**: Rolling window for DVOL jump detection.
- **Rationale**: 60s captures intra-minute volatility shocks while filtering tick-level noise.
AT-291
- Given: DVOL jump from 0.50 to 0.55 over 61s, then over 59s.
- When: Cortex evaluates the window.
- Then: no trip outside window; trip inside window.
- Pass criteria: no trip at 61s; trip at 59s.
- Fail criteria: window logic inverted.

**`dvol_cooldown_s`** (§2.3 Reflexive Cortex)
- **Default**: `300` seconds (5 minutes)
- **Purpose**: Cooldown duration after DVOL jump before resuming opens.
- **Rationale**: 5min allows regime to stabilize post-shock; longer than spread/depth cooldown (120s) due to higher severity.
AT-292
- Given: DVOL trip at T=0.
- When: cooldown runs.
- Then: opens blocked until T=`dvol_cooldown_s`; closes/hedges/cancels allowed throughout.
- Pass criteria: opens blocked for full cooldown.
- Fail criteria: opens allowed early.

**`spread_depth_cooldown_s`** (§2.3 Reflexive Cortex)
- **Default**: `120` seconds (2 minutes)
- **Purpose**: Cooldown duration after spread/depth trip before resuming opens.
- **Rationale**: 2min balances recovery time vs opportunity cost; shorter than DVOL cooldown (less severe).
AT-293
- Given: spread/depth trip at T=0.
- When: cooldown runs.
- Then: opens blocked until T=`spread_depth_cooldown_s`; closes/hedges/cancels allowed throughout.
- Pass criteria: opens blocked for full cooldown.
- Fail criteria: opens allowed early.

**`basis_price_max_age_ms`** (§2.3.3 Basis Monitor)
- **Default**: `5000` ms
- **Purpose**: Max allowed staleness across mark/index/last timestamps before failing closed (ReduceOnly).
AT-958
- Given: any basis input timestamp is older than 5000ms.
- When: Basis Monitor evaluates.
- Then: it emits ForceReduceOnly.
- Pass criteria: ReduceOnly enforced due to stale basis inputs.
- Fail criteria: Active mode with stale basis inputs.

**`basis_reduceonly_bps`** (§2.3.3 Basis Monitor)
- **Default**: `50` bps
- **Purpose**: Basis divergence threshold that forces ReduceOnly.
**`basis_reduceonly_window_s`**
- **Default**: `5` seconds
**`basis_reduceonly_cooldown_s`**
- **Default**: `300` seconds
- **Purpose**: Dedicated cooldown for basis ReduceOnly; MUST NOT reuse `spread_depth_cooldown_s`.
AT-959
- Given: basis exceeds 50 bps for 5s.
- When: cooldown is applied.
- Then: opens remain blocked for 300s (basis cooldown).
- Pass criteria: 300s basis cooldown enforced.
- Fail criteria: cooldown differs or reuses unrelated params.

**`basis_kill_bps`** (§2.3.3 Basis Monitor)
- **Default**: `150` bps
- **Purpose**: Extreme divergence threshold that forces Kill.
**`basis_kill_window_s`**
- **Default**: `5` seconds


---

### **A.2.1 F1 Certification & Critical Inputs**

**`f1_cert_freshness_window_s`** (§2.2.1 Runtime F1 Certification Gate)
- **Default**: `86400` seconds (24 hours)
- **Purpose**: TTL for F1_CERT validity; stale cert triggers ReduceOnly.
- **Rationale**: 24h aligns with daily certification cadence and allows weekend/holiday tolerance.
AT-294
- Given: `now - F1_CERT.generated_ts_ms > 86400000ms`.
- When: F1_CERT freshness is evaluated.
- Then: ReduceOnly is forced.
- Pass criteria: ReduceOnly enforced.
- Fail criteria: remains Active.

**`mm_util_max_age_ms`** (§2.2.1.1 PolicyGuard Critical Input Freshness)
- **Default**: `30000` milliseconds (30 seconds)
- **Purpose**: Max staleness for margin utilization metric before forcing ReduceOnly.
- **Rationale**: 30s provides reasonable tolerance for API latency while ensuring timely margin risk detection.
AT-295
- Given: `mm_util_last_update_ts_ms` stale > 30s.
- When: PolicyGuard evaluates inputs.
- Then: OPEN blocked; CLOSE allowed.
- Pass criteria: OPEN blocked; CLOSE allowed.
- Fail criteria: OPEN allowed or CLOSE blocked.

**`disk_used_max_age_ms`** (§2.2.1.1 PolicyGuard Critical Input Freshness)
- **Default**: `30000` milliseconds (30 seconds)
- **Purpose**: Max staleness for disk usage metric before forcing ReduceOnly.
- **Rationale**: 30s balances system monitoring overhead with integrity protection.
AT-296
- Given: `disk_used_last_update_ts_ms` stale > 30s.
- When: PolicyGuard evaluates inputs.
- Then: OPEN blocked; CLOSE allowed.
- Pass criteria: OPEN blocked; CLOSE allowed.
- Fail criteria: OPEN allowed or CLOSE blocked.

---

### **A.3 Watchdog & Recovery**

**`watchdog_kill_s`** (§2.2.3 PolicyGuard)
- **Default**: `10` seconds
- **Purpose**: Watchdog staleness threshold triggering `TradingMode::Kill`
- **Rationale**: Smart Watchdog triggers ReduceOnly at 5s (§3.2). Kill at 10s provides 2× margin while remaining aggressive.
AT-297
- Given: 6s of silence, then 11s of silence.
- When: Watchdog evaluates staleness.
- Then: ReduceOnly at 6s; Kill at 11s.
- Pass criteria: mode transitions at the thresholds.
- Fail criteria: early/late transitions.

**`emergency_reduceonly_cooldown_s`** (§2.2 PolicyGuard / §3.2 Smart Watchdog)
- **Default**: `300` seconds (5 minutes)
- **Purpose**: Cooldown duration for `emergency_reduceonly_active` after `POST /api/v1/emergency/reduce_only`.
- **Rationale**: Provides time for operator intervention and system stabilization after watchdog/heartbeat issues.
See AT-132.

**`bunker_exit_stable_s`** (§2.3.2 Network Jitter Monitor)
- **Default**: `120` seconds
- **Purpose**: Stable period below thresholds before exiting Bunker Mode.
AT-298
- Given: bunker metrics remain below thresholds for `bunker_exit_stable_s`.
- When: exit conditions are evaluated.
- Then: Bunker Mode exits only after the full stable period.
- Pass criteria: exit timing equals `bunker_exit_stable_s`.
- Fail criteria: exit occurs earlier.

**`exchange_health_stale_s`** (§2.3.1 Exchange Health Monitor)
- **Default**: `180` seconds (3 minutes)
- **Purpose**: Max staleness for `/public/get_announcements` before forcing ReduceOnly.
- **Rationale**: 3min provides tolerance for transient API issues while ensuring timely detection of unknown exchange state.
AT-299
- Given: `/public/get_announcements` unreachable or invalid for >= 180s.
- When: Exchange Health Monitor evaluates status.
- Then: `cortex_override = ForceReduceOnly`; opens blocked.
- Pass criteria: ForceReduceOnly set; OPEN blocked.
- Fail criteria: remains Active.
**`ws_zombie_silence_ms`** (§3.4 WS Data Liveness)
- **Default**: `15000` ms
- **Purpose**: Threshold for application-level marketdata silence before suspecting a zombie socket (gated by exposure/activity; see §3.4.D).

**`ws_zombie_activity_window_ms`** (§3.4 WS Data Liveness)
- **Default**: `60000` ms
- **Purpose**: Window used to determine `had_recent_marketdata_activity` (avoids false-trips on legitimately quiet books).

**`public_trade_feed_max_age_ms`** (§1.2.3 Self-Impact Guard)
- **Default**: `5000` ms
- **Purpose**: Max allowed staleness for the public trades aggregation used by self-impact detection; stale => treat as WS trades gap (fail-closed for opens).

**`feedback_loop_window_s`** (§1.2.3 Self-Impact Guard)
- **Default**: `10` seconds
- **Purpose**: Rolling window to compute `public_notional_usd` and `self_notional_usd`.

**`self_trade_fraction_trip`** (§1.2.3 Self-Impact Guard)
- **Default**: `0.50`
- **Purpose**: Self fraction threshold above which opens are blocked (echo chamber protection).

**`self_trade_min_self_notional_usd`** (§1.2.3 Self-Impact Guard)
- **Default**: `5000` USD
- **Purpose**: Minimum self notional required for the fraction trip to be meaningful.

**`self_trade_notional_trip_usd`** (§1.2.3 Self-Impact Guard)
- **Default**: `20000` USD
- **Purpose**: Absolute self-notional trip for extreme impact even if fraction is unreliable.

**`feedback_loop_cooldown_s`** (§1.2.3 Self-Impact Guard)
- **Default**: `300` seconds
- **Purpose**: Cooldown applied after a feedback loop trip.



**`mm_util_reject_opens`** (§1.4.3 Margin Headroom Gate)
- **Default**: `0.70` (70%)
- **Purpose**: Margin utilization threshold for rejecting new opens at gate level.
- **Rationale**: 70% provides early warning before ReduceOnly (85%) and Kill (95%) thresholds.
AT-300
- Given: `mm_util >= 0.70`.
- When: Margin Headroom Gate evaluates a new OPEN.
- Then: the OPEN is rejected; CLOSE/HEDGE allowed.
- Pass criteria: OPEN rejected; CLOSE/HEDGE allowed.
- Fail criteria: OPEN allowed.

**`mm_util_reduceonly`** (§1.4.3 Margin Headroom Gate)
- **Default**: `0.85` (85%)
- **Purpose**: Margin utilization threshold triggering `TradingMode::ReduceOnly`.
- **Rationale**: 85% is aggressive but provides 10% buffer before Kill (95%); prevents late liquidation risk.
AT-301
- Given: `mm_util >= 0.85`.
- When: PolicyGuard computes TradingMode.
- Then: ReduceOnly forced; opens blocked; closes allowed.
- Pass criteria: ReduceOnly enforced.
- Fail criteria: remains Active.

**`mm_util_kill`** (§1.4.3 Margin Headroom Gate)
- **Default**: `0.95` (95%)
- **Purpose**: Margin utilization threshold triggering `TradingMode::Kill` + emergency flatten.
- **Rationale**: 95% is near-liquidation; immediate containment (emergency close + hedge) is mandatory.
AT-302
- Given: `mm_util >= 0.95`.
- When: PolicyGuard computes TradingMode.
- Then: Kill forced; deterministic emergency flatten executes.
- Pass criteria: Kill entered; flatten executes.
- Fail criteria: Kill not entered.

**`stale_order_sec`** (§3.5 Zombie Sweeper)
- **Default**: `30` seconds
- **Purpose**: Age threshold for canceling non-reduce-only open orders
- **Rationale**: Sweeper runs every 10s (§3.5). 30s ensures 2-3 cycles before force-cancel.
AT-303
- Given: non-reduce-only order age >30s.
- When: Zombie Sweeper runs.
- Then: non-reduce-only orders are canceled; reduce-only orders are NOT canceled.
- Pass criteria: only non-reduce-only orders canceled.
- Fail criteria: reduce-only orders canceled or non-reduce-only remain.

**`evidenceguard_window_s`** (§2.2.2 EvidenceGuard)
- **Default**: `60` seconds
- **Purpose**: Rolling window used to evaluate EvidenceChainState GREEN criteria.
- **Rationale**: Detects sustained writer failures quickly while filtering transient spikes.
See AT-105.

**`evidenceguard_global_cooldown`** (§2.2.2 EvidenceGuard)
- **Default**: `120` seconds
- **Purpose**: Global cooldown window before EvidenceChainState may return to GREEN after recovery (hysteresis).
AT-304
- Given: write errors stop.
- When: EvidenceGuard evaluates cooldown.
- Then: EvidenceGuard remains ReduceOnly for ≥ `evidenceguard_global_cooldown` before allowing GREEN.
- Pass criteria: cooldown enforced.
- Fail criteria: GREEN returns early.

**`position_reconcile_epsilon`** (§2.2.4 Open Permission Latch)
- **Default**: `1e-6` (or instrument `min_amount` if larger)
- **Purpose**: Tolerance for position matching during reconciliation; allows for floating-point precision limits.
AT-305
- Given: ledger vs exchange position differ by ≤ epsilon, then by > epsilon.
- When: reconciliation runs.
- Then: pass at ≤ epsilon; `INVENTORY_MISMATCH_RECONCILE_REQUIRED` when > epsilon.
- Pass criteria: correct pass/fail by threshold.
- Fail criteria: inverted threshold behavior.

**`reconcile_trade_lookback_sec`** (§2.2.4 Open Permission Latch)
- **Default**: `300` seconds (5 minutes)
- **Purpose**: Lookback window for detecting missing trades during reconciliation.
- **Rationale**: 5min covers typical WS gap/restart scenarios without excessive REST API load.
AT-306
- Given: reconciliation runs.
- When: trade lookback is applied.
- Then: it queries `/get_user_trades` for last 300s and matches against ledger trade registry.
- Pass criteria: correct lookback query and matching.
- Fail criteria: missing query or mismatch handling.

**`parquet_queue_trip_pct`** (§2.2.2 EvidenceGuard)
- **Default**: `0.90` (90%)
- **Purpose**: Queue depth threshold that trips EvidenceChainState to not GREEN.
- **Rationale**: 90% provides headroom before overflow while allowing bursts.
AT-307
- Given: `parquet_queue_depth_pct > 0.90` for ≥ `parquet_queue_trip_window_s`.
- When: EvidenceGuard evaluates queue depth.
- Then: EvidenceChain not GREEN; OPEN blocked.
- Pass criteria: not-GREEN + OPEN blocked.
- Fail criteria: remains GREEN or OPEN allowed.

**`parquet_queue_trip_window_s`** (§2.2.2 EvidenceGuard)
- **Default**: `5` seconds
- **Purpose**: Breach window duration before parquet_queue_trip_pct triggers not-GREEN state.
- **Rationale**: 5s filters transient spikes while catching sustained queue pressure.
AT-308
- Given: queue depth exceeds 90% for 4s, then 5s.
- When: trip window is evaluated.
- Then: no trip at 4s; trip at ≥5s.
- Pass criteria: trip only at or beyond window.
- Fail criteria: trip early or not at threshold.

**`parquet_queue_clear_pct`** (§2.2.2 EvidenceGuard)
- **Default**: `0.70` (70%)
- **Purpose**: Queue depth hysteresis threshold for returning to GREEN.
- **Rationale**: 20% hysteresis band (90% trip, 70% clear) prevents oscillation.
AT-309
- Given: queue depth drops below 70%.
- When: clear window is evaluated.
- Then: queue must remain below 70% for ≥ `queue_clear_window_s` before GREEN restored.
- Pass criteria: GREEN restored only after window.
- Fail criteria: GREEN restored early.

**`queue_clear_window_s`** (§2.2.2 EvidenceGuard)
- **Default**: `120` seconds
- **Purpose**: Hysteresis cooldown window before EvidenceChainState may return to GREEN after queue depth clears.
- **Rationale**: Equals `evidenceguard_global_cooldown` by default; explicit parameter allows independent tuning if needed.
AT-310
- Given: queue drops below 70%.
- When: cooldown evaluation runs.
- Then: system waits ≥120s before GREEN (max of this and `evidenceguard_global_cooldown`).
- Pass criteria: wait meets max cooldown.
- Fail criteria: GREEN returns early.

**`disk_pause_archives_pct`** (§7.2 Disk Watermarks)
- **Default**: `0.80` (80%)
- **Purpose**: Disk usage threshold for pausing tick/L2 archive writes (Decision Snapshots + WAL continue).
- **Rationale**: 0.80 provides headroom before Degraded (0.85) and Kill (0.92); protects critical writes.
AT-311
- Given: `disk_used_pct >= 0.80`.
- When: disk watermark logic runs.
- Then: full tick/L2 archives stop; Decision Snapshots + WAL + analytics continue.
- Pass criteria: archives paused; critical writes continue.
- Fail criteria: archives continue or critical writes stop.

**`disk_degraded_pct`** (§7.2 Disk Watermarks)
- **Default**: `0.85` (85%)
- **Purpose**: Disk usage threshold triggering `RiskState::Degraded` + `TradingMode::ReduceOnly`.
- **Rationale**: 85% triggers retention reclaim and blocks opens; 7% buffer before Kill hard-stop.
AT-312
- Given: `disk_used_pct >= 0.85`.
- When: disk watermark logic runs.
- Then: `RiskState::Degraded`; ReduceOnly until back under 0.80; reclaim runs.
- Pass criteria: ReduceOnly enforced; reclaim triggered.
- Fail criteria: remains Active or no reclaim.

**`disk_kill_pct`** (§7.2 Disk Watermarks)
- **Default**: `0.92`
- **Purpose**: Disk usage threshold triggering `TradingMode::Kill` + trading loop hard-stop.
- **Rationale**: 0.92 is integrity-first hard-stop; no dispatch (including CLOSE/HEDGE/CANCEL) to prevent corruption.
AT-313
- Given: `disk_used_pct >= 0.92`.
- When: disk watermark logic runs.
- Then: trading loop hard-stops; no dispatch occurs (containment forbidden).
- Pass criteria: hard-stop with no dispatch.
- Fail criteria: any dispatch occurs.

**`time_drift_threshold_ms`** (§4.3 Trade Attribution Schema)
- **Default**: `50` milliseconds
- **Purpose**: Maximum tolerable clock drift before forcing ReduceOnly; prevents attribution corruption and execution timing errors.
- **Rationale**: Aligns with §8.1 Time Drift gate (p99_clock_drift ≤ 50ms). Tight threshold ensures reliable timestamps for slippage measurement and replay.
AT-314
- Given: `drift_ms > 50ms`.
- When: time drift gate evaluates.
- Then: PolicyGuard forces ReduceOnly until time sync restored.
- Pass criteria: ReduceOnly enforced during drift.
- Fail criteria: remains Active.

**`max_policy_age_sec`** (§2.2.3 PolicyGuard)
- **Default**: `300` seconds (5 minutes)
- **Purpose**: Maximum policy staleness before forcing ReduceOnly; prevents trading on stale/outdated policy.
- **Rationale**: Aligned with ops alert threshold (§7.1). 5min provides reasonable tolerance for transient Commander hiccups while preventing drift.
AT-315
- Given: `policy_age_sec > 300`.
- When: PolicyGuard evaluates staleness.
- Then: ReduceOnly enforced until fresh policy received.
- Pass criteria: ReduceOnly enforced.
- Fail criteria: remains Active.

**`limits_fetch_failures_trip_count`** (§3.3 Local Rate Limit Circuit Breaker)
- **Default**: `3`
- **Purpose**: Number of limits-fetch failures required to trip `RiskState::Degraded`.
- **Rationale**: Filters transient endpoint hiccups while catching persistent fetch failure quickly.
See AT-106 and AT-133.

**`limits_fetch_failure_window_s`** (§3.3 Local Rate Limit Circuit Breaker)
- **Default**: `300` seconds (5 minutes)
- **Purpose**: Rolling window duration for counting limits-fetch failures toward `limits_fetch_failures_trip_count`.
- **Rationale**: Aligns with other 5-minute staleness/ops thresholds; prevents "ancient failures" from accumulating forever.
See AT-106 and AT-133.

---

### **A.3.1 Emergency Close & Liquidity Gates**

**`close_buffer_ticks`** (§3.1 Deterministic Emergency Close)
- **Default**: `5` ticks
- **Purpose**: Initial spread buffer for emergency IOC close orders (in ticks from best price).
- **Rationale**: 5 ticks respects instrument microstructure (BTC-10k vs ETH-1k have different tick regimes); exponential retry provides fallback.
AT-316
- Given: emergency close attempts 1, 2, 3.
- When: close prices are computed.
- Then: attempt 1 uses `best ± 5 ticks`; retry 2 uses ~10 ticks; retry 3 uses ~20 ticks.
- Pass criteria: tick buffers scale as specified.
- Fail criteria: buffers do not scale correctly.

**`max_slippage_bps`** (§1.3 Pre-Trade Liquidity Gate)
- **Default**: `10` bps (0.10%)
- **Purpose**: Maximum acceptable estimated slippage before rejecting trade.
- **Rationale**: Exact alignment with F1 PASS target (p95 slippage ≤10bps §8.1); gate matches certification requirement.
AT-317
- Given: L2 walk estimates `slippage_bps > 10`.
- When: Liquidity Gate evaluates.
- Then: trade is rejected before dispatch.
- Pass criteria: rejection occurs pre-dispatch.
- Fail criteria: trade proceeds.

**`l2_book_snapshot_max_age_ms`** (§1.3 Pre-Trade Liquidity Gate)
- **Default**: `1000` ms
- **Purpose**: Maximum allowed age of `L2BookSnapshot` for LiquidityGate decisions.
- **Rationale**: Ensures slippage estimates use fresh depth and avoids fail-open on stale books.
See AT-344.

---

### **A.4 Fee Model Staleness**

**`fee_cache_soft_s`** (§4.2 Fee-Aware Execution)
- **Default**: `300` seconds (5 minutes)
- **Purpose**: Soft threshold for fee model staleness; triggers conservative buffer.
- **Rationale**: 5min polling interval is reasonable; soft buffer prevents false rejects while encouraging refresh.
AT-318
- Given: fee cache age > 300s.
- When: fee estimates are computed.
- Then: apply 20% buffer to fee rates.
- Pass criteria: buffer applied.
- Fail criteria: buffer missing.

**`fee_cache_hard_s`** (§4.2 Fee-Aware Execution)
- **Default**: `900` seconds (15 minutes)
- **Purpose**: Hard threshold for fee model staleness; triggers Degraded + ReduceOnly.
- **Rationale**: 3× soft limit provides ample warning; 15min stale fee data is unacceptable for edge calculations.
AT-319
- Given: fee cache age > 900s.
- When: PolicyGuard evaluates.
- Then: `RiskState::Degraded`; OPEN blocked.
- Pass criteria: ReduceOnly enforced; OPEN blocked.
- Fail criteria: remains Active.

**`fee_stale_buffer`** (§4.2 Fee-Aware Execution)
- **Default**: `0.20` (20% multiplicative buffer)
- **Purpose**: Conservative buffer applied to fee rates when cache is soft-stale.
- **Rationale**: 20% provides margin for tier changes without excessive rejections.
AT-320
- Given: soft-stale cache.
- When: `fee_rate_effective` is computed.
- Then: `fee_rate_effective = fee_rate * 1.20`.
- Pass criteria: rate multiplied by 1.20.
- Fail criteria: incorrect multiplier.

---

### **A.5 SVI Stability Guards**

**`svi_guard_trip_count`** (§4.1 SVI Stability Gates)
- **Default**: `3` trips
- **Purpose**: Number of guard failures within window before forcing Degraded.
- **Rationale**: 3 trips filters transient noise while catching persistent calibration issues.
AT-321
- Given: SVI drift/math/arb guard fails 3 times in 5min.
- When: guard trip count is evaluated.
- Then: `RiskState::Degraded`.
- Pass criteria: Degraded entered on third trip.
- Fail criteria: no Degraded or premature Degraded.

**`svi_guard_trip_window_s`** (§4.1 SVI Stability Gates)
- **Default**: `300` seconds (5 minutes)
- **Purpose**: Time window for counting guard trip frequency.
- **Rationale**: 5min window balances responsiveness with stability.
AT-322
- Given: guard failures separated by >5min.
- When: trip count is evaluated.
- Then: failures do not accumulate toward the trip threshold.
- Pass criteria: count resets outside window.
- Fail criteria: failures accumulate across windows.

---

### **A.6 Retention & Replay Windows**

**`decision_snapshot_retention_days`** (§7.2 Retention Policy)
- **Default**: `30` days
- **Purpose**: Rolling retention window for Decision Snapshot partitions (replay input).
- **Rationale**: 30 days provides sufficient history for Governor tuning and incident analysis while managing storage costs.
- **Safety Invariant**: `decision_snapshot_retention_days >= ceil(replay_window_hours / 24)` (must cover replay window; default 48h → 2 days).
AT-323
- Given: Decision Snapshots older than 30 days and snapshots within the replay window.
- When: retention reclaim runs.
- Then: older snapshots are eligible for deletion (cold partitions only); replay-window snapshots MUST NOT be deleted.
- Pass criteria: only cold partitions deleted; replay-window data retained.
- Fail criteria: replay-window data deleted or cold partitions retained without reason.

**`replay_window_hours`** (§5.2 Replay Gatekeeper)
- **Default**: `48` hours
- **Purpose**: Time window used to compute `snapshot_coverage_pct` for Replay Gatekeeper readiness.
- **Rationale**: 48h provides weekend coverage and captures recent regime while limiting computational cost.
AT-324
- Given: Replay Gatekeeper evaluates the last 48h window.
- When: `snapshot_coverage_pct < 95%`.
- Then: the gate is BLOCKED.
- Pass criteria: gate blocks below 95%.
- Fail criteria: gate passes below 95%.

**`tick_l2_retention_hours`** (§7.2 Retention Policy)
- **Default**: `72` hours
- **Purpose**: Retention window for tick/L2 archives (compressed).
- **Rationale**: 72h provides sufficient history for slippage calibration and debugging while managing disk usage.
AT-325
- Given: tick/L2 archives older than 72h.
- When: retention reclaim runs.
- Then: they are eligible for deletion.
- Pass criteria: eligible archives deleted.
- Fail criteria: eligible archives retained without reason.

**`parquet_analytics_retention_days`** (§7.2 Retention Policy)
- **Default**: `30` days
- **Purpose**: Retention window for Parquet analytics (attribution + truth capsules).
- **Rationale**: 30 days provides month-over-month analysis capability for Governor tuning and F1 certification metrics.
AT-326
- Given: Parquet analytics older than 30 days.
- When: retention reclaim runs.
- Then: they are eligible for deletion.
- Pass criteria: eligible analytics deleted.
- Fail criteria: eligible analytics retained without reason.

---

### **A.7 Summary Table**

| Parameter | Default | Unit | Referenced In |
|-----------|---------|------|---------------|
| `atomic_qty_epsilon` | `1e-9` | qty units | §1.2 |
| `contracts_amount_match_tolerance` | `0.001` | relative | §1.0 |
| `instrument_cache_ttl_s` | `3600` | sec | §1.0.X |
| `inventory_skew_k` | `0.5` | dimensionless | §1.4.2 |
| `inventory_skew_tick_penalty_max` | `3` | ticks | §1.4.2 |
| `rescue_cross_spread_ticks` | `2` | ticks | §1.2 |
| `spread_max_bps` | `25` | bps | §2.3 |
| `depth_min` | `300_000` | USD | §2.3, §4.1 |
| `f1_cert_freshness_window_s` | `86400` | sec | §2.2.1 |
| `mm_util_max_age_ms` | `30000` | ms | §2.2.1.1 |
| `disk_used_max_age_ms` | `30000` | ms | §2.2.1.1 |
| `evidenceguard_counters_max_age_ms` | `60000` | ms | §2.2.2 |
| `watchdog_kill_s` | `10` | sec | §2.2.3 |
| `emergency_reduceonly_cooldown_s` | `300` | sec | §2.2, §3.2 |
| `mm_util_reject_opens` | `0.70` | pct | §1.4.3 |
| `mm_util_reduceonly` | `0.85` | pct | §1.4.3 |
| `mm_util_kill` | `0.95` | pct | §1.4.3 |
| `stale_order_sec` | `30` | sec | §3.5 |
| `evidenceguard_window_s` | `60` | sec | §2.2.2 |
| `evidenceguard_global_cooldown` | `120` | sec | §2.2.2 |
| `position_reconcile_epsilon` | `1e-6` | qty units | §2.2.4 |
| `reconcile_trade_lookback_sec` | `300` | sec | §2.2.4 |
| `parquet_queue_trip_pct` | `0.90` | pct | §2.2.2 |
| `parquet_queue_trip_window_s` | `5` | sec | §2.2.2 |
| `parquet_queue_clear_pct` | `0.70` | pct | §2.2.2 |
| `queue_clear_window_s` | `120` | sec | §2.2.2 |
| `group_lock_max_wait_ms` | `10` | ms | §1.2.1 |
| `disk_pause_archives_pct` | `0.80` | pct | §7.2 |
| `disk_degraded_pct` | `0.85` | pct | §7.2 |
| `disk_kill_pct` | `0.92` | pct | §7.2 |
| `bunker_jitter_threshold_ms` | `2000` | ms | §2.3.2 |
| `bunker_exit_stable_s` | `120` | sec | §2.3.2 |
| `time_drift_threshold_ms` | `50` | ms | §4.3 |
| `max_policy_age_sec` | `300` | sec | §2.2.3 |
| `close_buffer_ticks` | `5` | ticks | §3.1 |
| `max_slippage_bps` | `10` | bps | §1.3 |
| `l2_book_snapshot_max_age_ms` | `1000` | ms | §1.3 |
| `limits_fetch_failures_trip_count` | `3` | count | §3.3 |
| `limits_fetch_failure_window_s` | `300` | sec | §3.3 |
| `fee_cache_soft_s` | `300` | sec | §4.2 |
| `fee_cache_hard_s` | `900` | sec | §4.2 |
| `fee_stale_buffer` | `0.20` | relative | §4.2 |
| `svi_guard_trip_count` | `3` | count | §4.1 |
| `svi_guard_trip_window_s` | `300` | sec | §4.1 |
| `dvol_jump_pct` | `0.10` | relative | §2.3 |
| `dvol_jump_window_s` | `60` | sec | §2.3 |
| `dvol_cooldown_s` | `300` | sec | §2.3 |
| `spread_depth_cooldown_s` | `120` | sec | §2.3 |
| `basis_price_max_age_ms` | `5000` | ms | §2.3.3 |
| `basis_reduceonly_bps` | `50` | bps | §2.3.3 |
| `basis_reduceonly_window_s` | `5` | sec | §2.3.3 |
| `basis_reduceonly_cooldown_s` | `300` | sec | §2.3.3 |
| `basis_kill_bps` | `150` | bps | §2.3.3 |
| `basis_kill_window_s` | `5` | sec | §2.3.3 |
| `ws_zombie_silence_ms` | `15000` | ms | §3.4 |
| `ws_zombie_activity_window_ms` | `60000` | ms | §3.4 |
| `public_trade_feed_max_age_ms` | `5000` | ms | §1.2.3 |
| `feedback_loop_window_s` | `10` | sec | §1.2.3 |
| `self_trade_fraction_trip` | `0.50` | ratio | §1.2.3 |
| `self_trade_min_self_notional_usd` | `5000` | USD | §1.2.3 |
| `self_trade_notional_trip_usd` | `20000` | USD | §1.2.3 |
| `feedback_loop_cooldown_s` | `300` | sec | §1.2.3 |
| `decision_snapshot_retention_days` | `30` | days | §7.2 |
| `replay_window_hours` | `48` | hours | §5.2 |
| `tick_l2_retention_hours` | `72` | hours | §7.2 |
| `parquet_analytics_retention_days` | `30` | days | §7.2 |
