# Flow Bundle: PHASE-1 — Phase 1 Contract Surface

Use this file as the single paste-source for your flow audit prompt.

## FLOW_SPEC (YAML)
```yaml
id: PHASE-1
name: Phase 1 Contract Surface
refs:
  sections:
  - Definitions
  - 1.1.1
  - 1.1.2
  - '1.3'
  - 1.4.1
  - 1.4.4
  - '2.4'
  - 2.4.1
  - '4.2'
```

## CONTRACT_EXCERPTS
<!-- EXCERPT: Definitions | starts L33 | ends L61 -->
L33  ## Definitions
L34  
L35  - **instrument_kind**: one of `option | linear_future | inverse_future | perpetual` (derived from venue metadata).
L36    - **Linear Perpetuals (USDC‑margined)**: treat as `linear_future` for sizing (canonical `qty_coin`), even if their venue symbol says "PERPETUAL".
L37  - **order_type** (Deribit `type`): `limit | market | stop_limit | stop_market | ...` (venue-specific).
L38  - **linked_order_type**: Deribit linked/OCO semantics (venue-specific; gated off for this bot).
L39  - **Aggressive IOC Limit**: a `limit` order with `time_in_force=immediate_or_cancel` and a *bounded* limit price computed from `fair_price` with fee-aware edge-based clamps (see §1.4).
L40  
L41  - **L1TickerSnapshot**: {`instrument_id`, `best_bid`, `best_ask`, `ts_ms`, `source` (REST|WS)} from the ticker feed. Valid only if `best_bid > 0`, `best_ask > 0`, `best_bid <= best_ask`, and `(now_ms - ts_ms) <= l2_book_snapshot_max_age_ms`.
L42  
L43  - **contract_version**: canonical version string `5.1` (numeric only; no codename/tagline).
L44  
L45  - **RiskState** (health/cause layer): `Healthy | Degraded | Maintenance | Kill`
L46  - **TradingMode** (enforcement layer): `Active | ReduceOnly | Kill`  
L47    Resolved by PolicyGuard each tick from RiskState, policy staleness, watchdog, exchange health, fee cache staleness, and Cortex overrides.
L48    **Runtime F1 Gate in PolicyGuard (HARD, runtime enforcement):** See §2.2.1 for canonical specification. Summary: F1_CERT missing/stale/invalid → ReduceOnly (blocks opens; allows closes/hedges/cancels).
L49  - **reduce_only** (venue order flag): boolean on outbound order placement requests.
L50    - `reduce_only == true` -> classified as CLOSE/HEDGE (risk-reducing) for all "OPEN vs CLOSE/HEDGE/CANCEL" gates in this contract.
L51    - `reduce_only != true` (false or missing) -> classified as OPEN.
L52  - **CANCEL intent**: cancel-only requests (no new order placement). Replace is treated as cancel + new order placement (classified above).
L53  - **Fail-closed intent classification:** if an intent cannot be classified, it MUST be treated as OPEN.
L54  
L55  AT-201
L56  - Given: an OrderIntent with an unknown `action` value (not Place/Cancel/Close/Hedge) OR missing required classification fields.
L57  - When: intent classification is computed.
L58  - Then: classification MUST be OPEN, and OPEN gates (PolicyGuard mode + CP-001 latch + EvidenceGuard) MUST apply.
L59  - Pass criteria: intent is treated as OPEN and blocked when any OPEN gate blocks.
L60  - Fail criteria: intent is treated as CLOSE/HEDGE/CANCEL or bypasses OPEN gates.
L61  

--------------------------------------------------------------------------------

<!-- EXCERPT: 1.1.1 | starts L342 | ends L406 -->
L342  ### **1.1.1 Canonical Quantization (Pre-Hash & Pre-Dispatch)**
L343  
L344  **Requirement:** All idempotency keys and order payloads MUST use canonical, exchange-valid rounded values.
L345  
L346  **Where:** `soldier/core/execution/quantize.rs`
L347  
L348  **Inputs:** `instrument_id`, `raw_qty`, `raw_limit_price`  
L349  **Outputs:** `qty_q`, `limit_price_q` (quantized)
L350  
L351  **Rules (Deterministic):**
L352  - Fetch instrument constraints: `tick_size`, `amount_step`, `min_amount`.
L353  - If any of `tick_size`, `amount_step`, or `min_amount` is missing or unparseable -> Reject(intent=InstrumentMetadataMissing) and do not dispatch (fail-closed).
L354  - `qty_q = round_down(raw_qty, amount_step)` (never round up size).
L355  - `limit_price_q = round_to_nearest_tick(raw_limit_price, tick_size)` (or round in the safer direction; see below).
L356  - If `qty_q < min_amount` → Reject(intent=TooSmallAfterQuantization).
L357  - Idempotency hash must be computed ONLY from quantized fields:
L358    `intent_hash = xxhash64(instrument + side + qty_q + limit_price_q + group_id + leg_idx)`
L359  
L360  **Safer rounding direction:**
L361  - For BUY: round `limit_price_q` DOWN (never pay extra).
L362  - For SELL: round `limit_price_q` UP (never sell cheaper).
L363  
L364  **Acceptance Tests (REQUIRED):**
L365  AT-218
L366  - Given: two codepaths compute the same intent fields.
L367  - When: `intent_hash` is generated.
L368  - Then: both hashes are identical.
L369  - Pass criteria: `intent_hash` equality across codepaths.
L370  - Fail criteria: hash mismatch for identical inputs.
L371  
L372  AT-219
L373  - Given: raw BUY and SELL prices that are not on tick.
L374  - When: quantization runs.
L375  - Then: BUY rounds down and SELL rounds up (never worse price).
L376  - Pass criteria: BUY price never increases; SELL price never decreases.
L377  - Fail criteria: BUY rounds up or SELL rounds down.
L378  
L379  AT-908
L380  - Given: `qty_q < min_amount` after quantization for an OPEN intent.
L381  - When: quantization runs.
L382  - Then: intent is rejected with `Rejected(TooSmallAfterQuantization)` and no dispatch occurs.
L383  - Pass criteria: rejection reason matches; dispatch count remains 0.
L384  - Fail criteria: dispatch occurs or reason missing/mismatched.
L385  
L386  AT-926
L387  - Given: instrument metadata is missing/unparseable (`tick_size` or `amount_step` or `min_amount`).
L388  - When: quantization runs for an OPEN intent.
L389  - Then: the intent is rejected with `Rejected(InstrumentMetadataMissing)` and no dispatch occurs.
L390  - Pass criteria: rejection reason matches; dispatch count remains 0.
L391  - Fail criteria: dispatch occurs or an implicit default is used.
L392  
L393  AT-928
L394  - Given: the WAL already contains `intent_hash` for a pending intent.
L395  - When: the system evaluates a new intent with the same `intent_hash`.
L396  - Then: it is a NOOP (no dispatch; no new WAL entry).
L397  - Pass criteria: dispatch count remains 0; WAL unchanged.
L398  - Fail criteria: a duplicate dispatch occurs or WAL duplicates the intent.
L399  
L400  **Idempotency Rules (Non-Negotiable):**
L401  1. **Dedupe-on-Send (Local):** Before dispatch, check `intent_hash` in the WAL. If exists → NOOP.
L402  2. **Dedupe-on-Send (Remote):** Use Deribit `label` as the idempotency key. If WS reconnect occurs, re-fetch open orders and match by `group_id`.
L403  3. **Replay Safe:** On restart, rebuild “in-flight intents” from WAL, then reconcile with exchange orders/trades. Never resend an intent unless WAL state says it is unsent.
L404  4. **Attribution-Keyed:** Every fill must map to `group_id` + `leg_idx`, so we can compute “atomic slippage” per group.
L405  
L406  

--------------------------------------------------------------------------------

<!-- EXCERPT: 1.1.2 | starts L272 | ends L341 -->
L272  #### **1.1.2 Label Parse + Disambiguation (Collision-Safe)**
L273  
L274  **Requirement:** Label collisions can still occur (hash collisions or non-conforming labels). The Soldier must deterministically map exchange orders to local intents.
L275  
L276  **Where:** `soldier/core/recovery/label_match.rs`
L277  
L278  **Algorithm:**
L279  1) Parse label → extract `{sid8, gid12, leg_idx, ih16}`.
L280  2) Candidate set = all local intents where:
L281     - `gid12` matches AND `leg_idx` matches.
L282  3) If candidate set size == 1 → match.
L283  4) Else disambiguate using the following tie-breakers in order:
L284     A) `ih16` match (first 16 chars of intent_hash)
L285     B) instrument match
L286     C) side match
L287     D) qty_q match
L288  5) If still ambiguous → mark `RiskState::Degraded`, block opens, and require REST trade/order snapshot reconcile.
L289  
L290  **Acceptance Tests (REQUIRED):**
L291  AT-216
L292  - Given: an outbound order intent is built with a valid `s4:` label.
L293  - When: the label parser runs.
L294  - Then: the label starts with `s4:`, length ≤ 64 chars, and parser extracts `{sid8, gid12, li, ih16}` correctly.
L295  - Pass criteria: parser outputs match expected components and label length is within bounds.
L296  - Fail criteria: label format invalid, length > 64, or parsed components mismatch.
L297  
L298  AT-217
L299  - Given: two intents share the same `gid12` and `leg_idx`.
L300  - When: the label matcher disambiguates using tie-breakers.
L301  - Then: it resolves using `ih16` + instrument + side; if still ambiguous, `RiskState::Degraded` and opens blocked.
L302  - Pass criteria: deterministic match when tie-breakers suffice; Degraded + opens blocked on unresolved ambiguity.
L303  - Fail criteria: ambiguous mapping accepted or opens proceed without Degraded on unresolved ambiguity.
L304  
L305  AT-041
L306  - Given: a generated `s4` label would exceed 64 chars.
L307  - When: the system attempts to create an OrderIntent.
L308  - Then: the intent is rejected before dispatch and `RiskState==Degraded`.
L309  - Pass criteria: no order is sent; `/status` shows `RiskState::Degraded`; `mode_reasons` includes a label-length reason code if defined.
L310  - Fail criteria: any order dispatch occurs or `RiskState` remains Active.
L311  
L312  AT-921
L313  - Given: a generated `s4` label would exceed 64 chars.
L314  - When: the system attempts to create an OrderIntent.
L315  - Then: the intent is rejected with `Rejected(LabelTooLong)` and no dispatch occurs.
L316  - Pass criteria: rejection reason matches; dispatch count remains 0; `RiskState==Degraded`.
L317  - Fail criteria: dispatch occurs or reason missing/mismatched.
L318  
L319  
L320  
L321  * `strat_id`: Static ID of the running strategy (e.g., `strangle_btc_low_vol`).  
L322  * `group_id`: UUIDv4 (Shared by all legs in a single atomic attempt).  
L323  * `leg_idx`: `0` or `1` (Identity within the group).  
L324  * `intent_hash`: `xxhash64(instrument + side + qty_q + limit_price_q + group_id + leg_idx)` (see §1.1.1 for quantization)  
L325    **Hard rule:** Do NOT include wall-clock timestamps in the idempotency hash.
L326  
L327  AT-343
L328  - Given: two intents with identical canonical fields (instrument, side, qty_q, limit_price_q, group_id, leg_idx) evaluated at different wall-clock times.
L329  - When: `intent_hash` is computed for both.
L330  - Then: the two `intent_hash` values are identical.
L331  - Pass criteria: `intent_hash(t0) == intent_hash(t1)` for identical canonical fields.
L332  - Fail criteria: hash differs solely due to wall-clock time.
L333  
L334  AT-933
L335  - Given: a WS reconnect occurs and the exchange still has open orders for an existing `group_id`.
L336  - When: the system re-fetches open orders and matches by `group_id`.
L337  - Then: no duplicate dispatch occurs and the existing orders are treated as in-flight.
L338  - Pass criteria: dispatch count remains 0 for duplicates; reconciliation succeeds.
L339  - Fail criteria: duplicate dispatch occurs or orders are treated as missing.
L340  
L341  

--------------------------------------------------------------------------------

<!-- EXCERPT: 1.3 | starts L590 | ends L643 -->
L590  ### **1.3 Pre-Trade Liquidity Gate (Do Not Sweep the Book)**
L591  
L592  **Council Weakness Covered:** No Liquidity Gate (Low) \+ Taker Bleed (Critical). **Requirement:** Before any order is sent (including IOC), the Soldier must estimate book impact for the requested size and reject trades that exceed max slippage. **Where:** `soldier/core/execution/gate.rs` **Input:** `OrderQty`, `L2BookSnapshot`, `max_slippage_bps = 10` (default: see Appendix A)
L593  
L594  If `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms` (Appendix A), LiquidityGate MUST reject OPEN intents. CLOSE/HEDGE/replace order placement is rejected; CANCEL-only intents remain allowed. Deterministic Emergency Close is exempt from profitability gates, but still requires a valid price source; if L2 is missing/stale it MUST use the §3.1 fallback price source and MUST block only if no fallback source is valid.
L595  Rejections due to missing/unparseable/stale L2 MUST use `Rejected(LiquidityGateNoL2)`.
L596  
L597  **Output:** `Allowed | Rejected(reason=ExpectedSlippageTooHigh)`
L598  
L599  **Algorithm (Deterministic):**
L600  
L601  1. Walk the L2 book on the correct side (asks for buy, bids for sell).  
L602  2. Compute the Weighted Avg Price (WAP) for `OrderQty`.  
L603  3. Compute expected slippage: `slippage_bps = (WAP - BestPrice) / BestPrice * 10_000` (sign adjusted)  
L604  4. Reject if `slippage_bps` > `max_slippage_bps` (default 10bps; `max_slippage_bps` from Appendix A).  
L605  5. If rejected, log `LiquidityGateReject` with computed WAP \+ slippage.
L606  
L607  **Scope (explicit):**
L608  - Applies to normal dispatch and containment rescue IOC orders (see §1.1 containment Step A).
L609  - Does NOT apply to Deterministic Emergency Close (§3.1) or containment Step B; emergency close MUST NOT be blocked by profitability gates.
L610  - Emergency close still requires a valid price source; missing/stale L2 MUST use the §3.1 fallback price source and MUST block only if no fallback source is valid.
L611  
L612  **Acceptance Test (REQUIRED):**
L613  AT-222
L614  - Given: an L2 book where `OrderQty` requires consuming multiple levels causing `slippage_bps > max_slippage_bps`.
L615  - When: Liquidity Gate evaluates the order.
L616  - Then: intent is rejected with `Rejected(ExpectedSlippageTooHigh)` and a `LiquidityGateReject` log; no `OrderIntent` is emitted.
L617  - Pass criteria: rejection + log; pricer/NetEdge gate does not run.
L618  - Fail criteria: order proceeds or log missing.
L619  - And: emergency close proceeds even if Liquidity Gate would reject under the same slippage conditions.
L620  
L621  AT-344
L622  - Given: `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms`.
L623  - When: Liquidity Gate evaluates an OPEN intent.
L624  - Then: the intent is rejected (no dispatch) and a LiquidityGate rejection is logged.
L625  - Pass criteria: no OPEN dispatch occurs; rejection reason recorded.
L626  - Fail criteria: OPEN dispatch proceeds without a valid L2 snapshot.
L627  
L628  AT-909
L629  - Given: `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms` for an OPEN.
L630  - When: Liquidity Gate evaluates the order.
L631  - Then: the intent is rejected with `Rejected(LiquidityGateNoL2)` and no dispatch occurs.
L632  - Pass criteria: rejection reason matches; dispatch count remains 0.
L633  - Fail criteria: dispatch occurs or reason missing/mismatched.
L634  
L635  AT-421
L636  - Given: `L2BookSnapshot` is missing, unparseable, or older than `l2_book_snapshot_max_age_ms`.
L637  - When: a CANCEL-only intent and a CLOSE/HEDGE order placement intent are evaluated.
L638  - Then: CANCEL is allowed; CLOSE/HEDGE order placement is rejected (no dispatch).
L639  - Pass criteria: cancel proceeds; close/hedge is rejected.
L640  - Fail criteria: close/hedge proceeds or cancel is blocked.
L641  
L642  
L643  

--------------------------------------------------------------------------------

<!-- EXCERPT: 1.4.1 | starts L677 | ends L719 -->
L677  ### **1.4.1 Net Edge Gate (Fees + Expected Slippage)**
L678  **Why this exists:** Prevent “gross edge” hallucinations from bypassing execution safety.
L679  
L680  **Where:** `soldier/core/execution/gates.rs`  
L681  **Input:** `gross_edge_usd`, `fee_usd`, `expected_slippage_usd`, `min_edge_usd`  
L682  **Output:** `Allowed | Rejected(reason=NetEdgeTooLow)`
L683  
L684  **Rule (Non-Negotiable):**
L685  - `net_edge_usd = gross_edge_usd - fee_usd - expected_slippage_usd`
L686  - If any of `gross_edge_usd`, `fee_usd`, `expected_slippage_usd`, or `min_edge_usd` is missing/unparseable -> Reject(intent=NetEdgeInputMissing) and do not dispatch (fail-closed).
L687  - Reject if `net_edge_usd < min_edge_usd`.
L688  
L689  **Hard Rule:**
L690  - This gate MUST run **before** any `OrderIntent` is eligible for dispatch (before AtomicGroup creation).
L691  
L692  **Scope (explicit):**
L693  - Applies to normal dispatch and containment rescue IOC orders (see §1.1 containment Step A).
L694  - Does NOT apply to Deterministic Emergency Close (§3.1) or reduce-only close/hedge intents.
L695  
L696  **Acceptance Tests (REQUIRED):**
L697  
L698  AT-015
L699  - Given: `net_edge_usd < min_edge_usd`.
L700  - When: an OPEN intent is evaluated by the Net Edge Gate.
L701  - Then: the OPEN intent is rejected and MUST NOT dispatch.
L702  - Pass criteria: zero dispatch for that OPEN.
L703  - Fail criteria: OPEN dispatch occurs.
L704  
L705  AT-327
L706  - Given: Net Edge Gate would reject under net edge conditions.
L707  - When: Deterministic Emergency Close runs.
L708  - Then: emergency close proceeds despite Net Edge Gate rejection.
L709  - Pass criteria: emergency close dispatch occurs.
L710  - Fail criteria: emergency close blocked by Net Edge Gate.
L711  
L712  AT-932
L713  - Given: `fee_usd` or `expected_slippage_usd` is missing/unparseable for an OPEN intent.
L714  - When: the Net Edge Gate evaluates the intent.
L715  - Then: the intent is rejected with `Rejected(NetEdgeInputMissing)` and no dispatch occurs.
L716  - Pass criteria: rejection reason matches; dispatch count remains 0.
L717  - Fail criteria: dispatch occurs or an implicit default is used.
L718  
L719  

--------------------------------------------------------------------------------

<!-- EXCERPT: 1.4.4 | starts L915 | ends L1022 -->
L 915  ### **1.4.4 Deribit Order-Type Preflight Guard (Artifact-Backed)**
L 916  
L 917  **Purpose:** Freeze the engine against *verified* Deribit behavior and prevent “market order roulette.”
L 918  
L 919  **Preflight Rules (MUST implement):**
L 920  
L 921  **A) Options (`instrument_kind == option`)**
L 922  - Allowed `type`: **`limit` only**
L 923  - **Market orders:** forbidden by policy (F-01b)  
L 924    - If `type == market` → **REJECT** with `Rejected(OrderTypeMarketForbidden)` (no rewrite/normalization).
L 925  - **Stop orders:** forbidden (F-01a)  
L 926    - Reject any `type in {stop_market, stop_limit}` or any presence of `trigger` / `trigger_price` with `Rejected(OrderTypeStopForbidden)`.
L 927  - **Linked/OCO orders:** forbidden (F-08)  
L 928    - Reject any non-null `linked_order_type` with `Rejected(LinkedOrderTypeForbidden)`.
L 929  - Execution policy: use **Aggressive IOC Limit** with bounded `limit_price_q` (see §1.4.1).
L 930  
L 931  **B) Futures/Perps (`instrument_kind in {linear_future, inverse_future, perpetual}`)**
L 932  - **Allowed `type`:** `limit` (for this bot's execution policy)
L 933  - **Market orders:** forbidden by policy  
L 934    - If `type == market` → **REJECT** with `Rejected(OrderTypeMarketForbidden)` (no rewrite/normalization).
L 935  - **Stop orders:** **NOT SUPPORTED** for this bot (execution policy is IOC limits only)  
L 936    - Reject any `type in {stop_market, stop_limit}` even if `trigger` is present, with `Rejected(OrderTypeStopForbidden)`.
L 937    - Deribit venue fact (F-09): If stop orders were enabled, venue requires `trigger` to be set.
L 938  - **Linked/OCO orders:** forbidden unless explicitly certified (F-08 currently indicates NOT SUPPORTED)  
L 939    - Reject any non-null `linked_order_type` unless `linked_orders_supported == true` **and** feature flag `ENABLE_LINKED_ORDERS_FOR_BOT == true`, with `Rejected(LinkedOrderTypeForbidden)`.
L 940  
L 941  **Linked orders gating variables (contract-bound definitions):**
L 942  - `linked_orders_supported` (bool): MUST be `false` for v5.1 (see Deribit Venue Facts Addendum F-08: VERIFIED (NOT SUPPORTED)).
L 943  - `ENABLE_LINKED_ORDERS_FOR_BOT` (bool): runtime config feature flag; default `false` (fail-closed if missing/unset).
L 944  
L 945  **Acceptance Test (REQUIRED):**
L 946  AT-004
L 947  - Given: an intent with `linked_order_type` set (non-null).
L 948  - When: preflight validation runs with `linked_orders_supported==false` and `ENABLE_LINKED_ORDERS_FOR_BOT==false` (defaults).
L 949  - Then: the intent is rejected before any API call.
L 950  - Pass criteria: no outbound order is emitted and a deterministic reject reason is logged.
L 951  - Fail criteria: any order with non-null `linked_order_type` is dispatched.
L 952  
L 953  
L 954  **C) Post-only behavior**
L 955  - If `post_only == true` and order would cross the book, Deribit rejects (F-06).  
L 956    - Preflight must ensure post-only prices are non-crossing (or disable post_only). If it would cross, reject with `Rejected(PostOnlyWouldCross)`.
L 957  
L 958  **Enforcement points (code):**
L 959  - Centralize in a single function called by the trade dispatch path (`private/buy` + `private/sell`) before any API call.
L 960  - Violations must be **hard rejects** (do not “try anyway”).
L 961  
L 962  **Regression tests (MUST):**
L 963  
L 964  AT-016
L 965  - Given: an options order intent has `order_type == market`.
L 966  - When: Deribit Order-Type Preflight Guard runs.
L 967  - Then: intent MUST be rejected before dispatch.
L 968  - Pass criteria: no dispatch occurs.
L 969  - Fail criteria: market order dispatch occurs.
L 970  
L 971  AT-017
L 972  - Given: a perpetual order intent has `order_type == market`.
L 973  - When: preflight runs.
L 974  - Then: intent MUST be rejected before dispatch.
L 975  - Pass criteria: no dispatch occurs.
L 976  - Fail criteria: market order dispatch occurs.
L 977  
L 978  AT-018
L 979  - Given: an options order intent is `stop_market` or stop with market execution.
L 980  - When: preflight runs.
L 981  - Then: intent MUST be rejected before dispatch.
L 982  - Pass criteria: no dispatch occurs.
L 983  - Fail criteria: stop-market dispatch occurs.
L 984  
L 985  AT-019
L 986  - Given: a perpetual order intent is `stop_market` or stop with market execution.
L 987  - When: preflight runs.
L 988  - Then: intent MUST be rejected before dispatch.
L 989  - Pass criteria: no dispatch occurs.
L 990  - Fail criteria: stop-market dispatch occurs.
L 991  
L 992  AT-913
L 993  - Given: an intent with `order_type == market`.
L 994  - When: preflight validation runs.
L 995  - Then: the intent is rejected with `Rejected(OrderTypeMarketForbidden)`.
L 996  - Pass criteria: rejection reason matches; no dispatch occurs.
L 997  - Fail criteria: dispatch occurs or reason missing/mismatched.
L 998  
L 999  AT-914
L1000  - Given: an intent with `order_type in {stop_market, stop_limit}`.
L1001  - When: preflight validation runs.
L1002  - Then: the intent is rejected with `Rejected(OrderTypeStopForbidden)`.
L1003  - Pass criteria: rejection reason matches; no dispatch occurs.
L1004  - Fail criteria: dispatch occurs or reason missing/mismatched.
L1005  
L1006  AT-915
L1007  - Given: `linked_order_type` is non-null while linked orders are unsupported.
L1008  - When: preflight validation runs.
L1009  - Then: the intent is rejected with `Rejected(LinkedOrderTypeForbidden)`.
L1010  - Pass criteria: rejection reason matches; no dispatch occurs.
L1011  - Fail criteria: dispatch occurs or reason missing/mismatched.
L1012  
L1013  AT-916
L1014  - Given: `post_only == true` and the limit price would cross the book.
L1015  - When: preflight validation runs.
L1016  - Then: the intent is rejected with `Rejected(PostOnlyWouldCross)`.
L1017  - Pass criteria: rejection reason matches; no dispatch occurs.
L1018  - Fail criteria: dispatch occurs or reason missing/mismatched.
L1019  
L1020  - See AT-004 for linked orders testing (`linked_orders_oco_is_gated_off`).
L1021  
L1022  

--------------------------------------------------------------------------------

<!-- EXCERPT: 2.4 | starts L1917 | ends L2006 -->
L1917  ### **2.4 Durable Intent Ledger (WAL Truth Source)**
L1918  
L1919  **Council Weakness Covered:** TLSM duplication \+ messy middle \+ restart correctness. **Requirement:** Redis is not a source of truth. All intents \+ state transitions must be persisted to a crash-safe local WAL (Sled or SQLite). **Where:** `soldier/infra/store/ledger.rs` **Rules:**
L1920  
L1921  * Write intent record BEFORE network dispatch.  
L1922  * Write every TLSM transition immediately (append-only).  
L1923  * On startup, replay ledger into in-memory state and reconcile with exchange.
L1924  
L1925  **Persistence levels (latency-aware):**
L1926  - **RecordedBeforeDispatch:** intent is recorded (e.g., in-memory WAL buffer) before dispatch.
L1927  - **DurableBeforeDispatch:** durability barrier reached (fsync marker or equivalent) before dispatch.
L1928  
L1929  **Dispatch rule:** RecordedBeforeDispatch is **mandatory**. DurableBeforeDispatch is required when the
L1930  durability barrier is configured/required by the subsystem.
L1931  
L1932  #### **2.4.1 WAL Writer Isolation (Hot Loop Protection)**
L1933  
L1934  - The hot loop MUST NOT block on WAL disk I/O.
L1935  - WAL appends MUST go through a bounded in-memory queue; `RecordedBeforeDispatch` means the enqueue succeeds.
L1936  - If the WAL queue is full or enqueue fails, the system MUST fail-closed for OPEN intents (block OPENs / ReduceOnly) and MUST continue ticking.
L1937  - An enqueue failure MUST increment `wal_write_errors` (treated as a WAL write failure for EvidenceGuard).
L1938  - The system MUST expose WAL queue telemetry in `/status`:
L1939    - `wal_queue_depth` (current items in the WAL queue)
L1940    - `wal_queue_capacity` (max items in the WAL queue)
L1941    - `wal_queue_enqueue_failures` (monotonic counter of failed enqueues)
L1942  
L1943  **Hot-loop output queue backpressure (Non-Negotiable):**
L1944  - All hot-loop output queues (status writer, telemetry, order events) MUST be bounded.
L1945  - If any such queue is full, the hot loop MUST NOT block and MUST force ReduceOnly until backlog clears.
L1946  
L1947  **Persisted Record (Minimum):**
L1948  - intent_hash, group_id, leg_idx, instrument, side, qty, limit_price
L1949  - tls_state, created_ts, sent_ts, ack_ts, last_fill_ts
L1950  - exchange_order_id (if known), last_trade_id (if known)
L1951  
L1952  **Acceptance Tests (REQUIRED):**
L1953  AT-233
L1954  - Given: a crash occurs after send, before ACK.
L1955  - When: the system restarts.
L1956  - Then: it must NOT resend; it must reconcile and proceed.
L1957  - Pass criteria: no duplicate send; reconcile succeeds.
L1958  - Fail criteria: resend occurs or reconcile missing.
L1959  
L1960  AT-234
L1961  - Given: a crash occurs after fill, before local update.
L1962  - When: the system restarts.
L1963  - Then: it detects fill from exchange trades and updates TLSM + triggers sequencer.
L1964  - Pass criteria: fill detected; TLSM updated; sequencer triggered.
L1965  - Fail criteria: fill missed or TLSM not updated.
L1966  
L1967  AT-906
L1968  - Given: WAL appends use a bounded queue of capacity N, and the WAL writer is stalled so the queue reaches N items.
L1969  - When: an OPEN intent is evaluated and the system attempts RecordedBeforeDispatch enqueue.
L1970  - Then: the OPEN intent is rejected before dispatch, `wal_write_errors` increments, EvidenceChainState is not GREEN, and the hot loop continues ticking.
L1971  - Pass criteria: no outbound dispatch for that OPEN; `wal_write_errors` increases; EvidenceChainState != GREEN within the EvidenceGuard window; opens remain blocked until enqueue succeeds.
L1972  - Fail criteria: hot loop blocks, an OPEN dispatch occurs without a successful enqueue, EvidenceChainState remains GREEN, or opens remain allowed while enqueue fails.
L1973  
L1974  AT-925
L1975  - Given: a hot-loop output queue (status writer, telemetry, or order events) reaches capacity N.
L1976  - When: the hot loop attempts to enqueue another item.
L1977  - Then: the hot loop does not block and TradingMode is forced to ReduceOnly until the queue depth falls below N.
L1978  - Pass criteria: no stall; queue depth <= N; ReduceOnly enforced.
L1979  - Fail criteria: hot loop blocks or remains Active under backpressure.
L1980  
L1981  
L1982  **Trade-ID Idempotency Registry (Ghost-Race Hardening) — MUST implement:**
L1983  - Persist a set/table: `processed_trade_ids`
L1984  - Record mapping: `trade_id -> {group_id, leg_idx, ts, qty, price}`
L1985  
L1986  **WS Fill Handler rule (idempotent):**
L1987  1) On trade/fill event: if `trade_id` already in WAL → **NOOP**
L1988  2) Else: append `trade_id` to WAL **first**, then apply TLSM/positions/attribution updates.
L1989  
L1990  **Acceptance Tests (REQUIRED):**
L1991  AT-269
L1992  - Given: order fills during WS disconnect.
L1993  - When: on reconnect, Sweeper runs before WS replay.
L1994  - Then: Sweeper finds trade via REST → updates ledger; later WS trade arrives → ignored due to `processed_trade_ids`.
L1995  - Pass criteria: REST update occurs; WS replay is ignored as duplicate.
L1996  - Fail criteria: duplicate processing or missing ledger update.
L1997  
L1998  AT-270
L1999  - Given: duplicate WS trade event.
L2000  - When: handler processes the duplicate.
L2001  - Then: the second event is ignored.
L2002  - Pass criteria: duplicate is a NOOP.
L2003  - Fail criteria: duplicate is processed.
L2004  
L2005  ---
L2006  

--------------------------------------------------------------------------------

<!-- EXCERPT: 2.4.1 | starts L1932 | ends L2006 -->
L1932  #### **2.4.1 WAL Writer Isolation (Hot Loop Protection)**
L1933  
L1934  - The hot loop MUST NOT block on WAL disk I/O.
L1935  - WAL appends MUST go through a bounded in-memory queue; `RecordedBeforeDispatch` means the enqueue succeeds.
L1936  - If the WAL queue is full or enqueue fails, the system MUST fail-closed for OPEN intents (block OPENs / ReduceOnly) and MUST continue ticking.
L1937  - An enqueue failure MUST increment `wal_write_errors` (treated as a WAL write failure for EvidenceGuard).
L1938  - The system MUST expose WAL queue telemetry in `/status`:
L1939    - `wal_queue_depth` (current items in the WAL queue)
L1940    - `wal_queue_capacity` (max items in the WAL queue)
L1941    - `wal_queue_enqueue_failures` (monotonic counter of failed enqueues)
L1942  
L1943  **Hot-loop output queue backpressure (Non-Negotiable):**
L1944  - All hot-loop output queues (status writer, telemetry, order events) MUST be bounded.
L1945  - If any such queue is full, the hot loop MUST NOT block and MUST force ReduceOnly until backlog clears.
L1946  
L1947  **Persisted Record (Minimum):**
L1948  - intent_hash, group_id, leg_idx, instrument, side, qty, limit_price
L1949  - tls_state, created_ts, sent_ts, ack_ts, last_fill_ts
L1950  - exchange_order_id (if known), last_trade_id (if known)
L1951  
L1952  **Acceptance Tests (REQUIRED):**
L1953  AT-233
L1954  - Given: a crash occurs after send, before ACK.
L1955  - When: the system restarts.
L1956  - Then: it must NOT resend; it must reconcile and proceed.
L1957  - Pass criteria: no duplicate send; reconcile succeeds.
L1958  - Fail criteria: resend occurs or reconcile missing.
L1959  
L1960  AT-234
L1961  - Given: a crash occurs after fill, before local update.
L1962  - When: the system restarts.
L1963  - Then: it detects fill from exchange trades and updates TLSM + triggers sequencer.
L1964  - Pass criteria: fill detected; TLSM updated; sequencer triggered.
L1965  - Fail criteria: fill missed or TLSM not updated.
L1966  
L1967  AT-906
L1968  - Given: WAL appends use a bounded queue of capacity N, and the WAL writer is stalled so the queue reaches N items.
L1969  - When: an OPEN intent is evaluated and the system attempts RecordedBeforeDispatch enqueue.
L1970  - Then: the OPEN intent is rejected before dispatch, `wal_write_errors` increments, EvidenceChainState is not GREEN, and the hot loop continues ticking.
L1971  - Pass criteria: no outbound dispatch for that OPEN; `wal_write_errors` increases; EvidenceChainState != GREEN within the EvidenceGuard window; opens remain blocked until enqueue succeeds.
L1972  - Fail criteria: hot loop blocks, an OPEN dispatch occurs without a successful enqueue, EvidenceChainState remains GREEN, or opens remain allowed while enqueue fails.
L1973  
L1974  AT-925
L1975  - Given: a hot-loop output queue (status writer, telemetry, or order events) reaches capacity N.
L1976  - When: the hot loop attempts to enqueue another item.
L1977  - Then: the hot loop does not block and TradingMode is forced to ReduceOnly until the queue depth falls below N.
L1978  - Pass criteria: no stall; queue depth <= N; ReduceOnly enforced.
L1979  - Fail criteria: hot loop blocks or remains Active under backpressure.
L1980  
L1981  
L1982  **Trade-ID Idempotency Registry (Ghost-Race Hardening) — MUST implement:**
L1983  - Persist a set/table: `processed_trade_ids`
L1984  - Record mapping: `trade_id -> {group_id, leg_idx, ts, qty, price}`
L1985  
L1986  **WS Fill Handler rule (idempotent):**
L1987  1) On trade/fill event: if `trade_id` already in WAL → **NOOP**
L1988  2) Else: append `trade_id` to WAL **first**, then apply TLSM/positions/attribution updates.
L1989  
L1990  **Acceptance Tests (REQUIRED):**
L1991  AT-269
L1992  - Given: order fills during WS disconnect.
L1993  - When: on reconnect, Sweeper runs before WS replay.
L1994  - Then: Sweeper finds trade via REST → updates ledger; later WS trade arrives → ignored due to `processed_trade_ids`.
L1995  - Pass criteria: REST update occurs; WS replay is ignored as duplicate.
L1996  - Fail criteria: duplicate processing or missing ledger update.
L1997  
L1998  AT-270
L1999  - Given: duplicate WS trade event.
L2000  - When: handler processes the duplicate.
L2001  - Then: the second event is ignored.
L2002  - Pass criteria: duplicate is a NOOP.
L2003  - Fail criteria: duplicate is processed.
L2004  
L2005  ---
L2006  

--------------------------------------------------------------------------------

<!-- EXCERPT: 4.2 | starts L2429 | ends L2525 -->
L2429  ### **4.2 Fee-Aware Execution**
L2430  
L2431  **Dynamic Fee Model:**
L2432  - Fee depends on instrument type (option/perp), maker/taker, and delivery proximity.
L2433  - `fee_usd = Σ(leg.notional_usd * (fee_rate + delivery_buffer))`
L2434  
L2435  **Implementation:** `soldier/core/strategy/fees.rs`
L2436  - Provide `estimate_fees(legs, is_maker, is_near_expiry) -> fee_usd`
L2437  
L2438  **Acceptance Test (REQUIRED):**
L2439  AT-243
L2440  - Given: gross edge smaller than fees.
L2441  - When: fee-aware execution evaluates a trade.
L2442  - Then: the trade is rejected.
L2443  - Pass criteria: rejection occurs.
L2444  - Fail criteria: trade proceeds.
L2445  
L2446  **Fee Cache Staleness (Fail-Closed):**
L2447  - Poll fee model (via `/private/get_account_summary` for tier/rates) every 60s.
L2448  - Track `fee_model_cache_age_s` (derived from epoch ms timestamp).
L2449  - Timestamp requirement: `fee_model_cached_at_ts` MUST be epoch milliseconds (not monotonic ms) to ensure staleness is computed correctly across restarts and between components.
L2450  - If `fee_model_cached_at_ts` is missing or unparseable, treat the fee cache as hard-stale (`RiskState::Degraded`) and PolicyGuard MUST force `TradingMode::ReduceOnly` until refresh succeeds.
L2451  - Soft stale (age > `fee_cache_soft_s`, default 300s; see Appendix A): apply conservative fee buffer using `fee_stale_buffer` (default 0.20): `fee_rate_effective = fee_rate * (1 + fee_stale_buffer)`.
L2452  - Hard stale (age > `fee_cache_hard_s`, default 900s; see Appendix A): set `RiskState::Degraded` and PolicyGuard MUST force `TradingMode::ReduceOnly` until refresh succeeds.
L2453  
L2454  **Acceptance Tests (REQUIRED):**
L2455  AT-244
L2456  - Given: fresh fee cache (age <= `fee_cache_soft_s`).
L2457  - When: fee estimates are computed.
L2458  - Then: estimates use actual rates.
L2459  - Pass criteria: no stale buffer applied.
L2460  - Fail criteria: stale buffer applied while cache is fresh.
L2461  
L2462  AT-245
L2463  - Given: hard-stale fee cache (age > `fee_cache_hard_s`).
L2464  - When: PolicyGuard computes TradingMode and intents are evaluated.
L2465  - Then: `RiskState==Degraded` and opens are blocked; mode becomes ReduceOnly.
L2466  - Pass criteria: RiskState Degraded; ReduceOnly enforced; OPEN blocked.
L2467  - Fail criteria: RiskState not Degraded, OPEN allowed, or mode remains Active.
L2468  
L2469  AT-031
L2470  - Given: `fee_model_cached_at_ts == T0` (epoch ms) and process restarts before any fee refresh; `now_ms == T0 + (fee_cache_hard_s*1000) + 1`.
L2471  - When: `fee_model_cache_age_s` is computed after restart and PolicyGuard computes TradingMode.
L2472  - Then: `fee_model_cache_age_s > fee_cache_hard_s` and PolicyGuard forces `TradingMode::ReduceOnly` (OPEN blocked) until refresh succeeds.
L2473  - Pass criteria: age is computed from epoch timestamps across restart (no monotonic reset underflow).
L2474  - Fail criteria: age resets/underflows and PolicyGuard remains Active while cache is hard-stale.
L2475  
L2476  AT-042
L2477  - Given: `fee_model_cached_at_ts` is missing or unparseable.
L2478  - When: PolicyGuard computes TradingMode.
L2479  - Then: `RiskState==Degraded`, `TradingMode==ReduceOnly`, and OPEN intents are rejected before dispatch.
L2480  - Pass criteria: RiskState Degraded; no OPEN dispatch; CLOSE/HEDGE/CANCEL allowed unless Kill.
L2481  - Fail criteria: RiskState not Degraded, `TradingMode==Active`, or any OPEN dispatch occurs.
L2482  
L2483  AT-032
L2484  - Given:
L2485    - `fee_cache_soft_s` is configured.
L2486    - `fee_cache_hard_s` is configured and `fee_cache_hard_s > fee_cache_soft_s`.
L2487    - `fee_stale_buffer` is configured (default 0.20).
L2488    - `fee_model_cache_age_s = fee_cache_soft_s + 1` and `fee_model_cache_age_s <= fee_cache_hard_s`.
L2489    - A candidate OPEN intent that would otherwise pass NetEdge with the fresh fee rate.
L2490  - When:
L2491    - The system evaluates the OPEN intent through the fee-aware execution gates.
L2492  - Then:
L2493    - The fee estimate uses an effective fee rate buffered by `fee_stale_buffer`.
L2494  - Pass criteria:
L2495    - The computed fee estimate reflects the configured buffer in the soft-stale window.
L2496  - Fail criteria:
L2497    - The fee estimate is unbuffered in the soft-stale window OR applies the buffer outside the soft-stale window.
L2498  
L2499  AT-033
L2500  - Given:
L2501    - `fee_cache_hard_s` is configured.
L2502    - `fee_model_cache_age_s = fee_cache_hard_s + 1`.
L2503  - When:
L2504    - PolicyGuard computes TradingMode and the system attempts to dispatch an OPEN intent.
L2505  - Then:
L2506    - `TradingMode = ReduceOnly` and the OPEN intent is rejected.
L2507  - Pass criteria:
L2508    - No OPEN intent is dispatched while hard-stale fee data persists.
L2509  - Fail criteria:
L2510    - Any OPEN intent is dispatched while hard-stale fee data persists.
L2511  
L2512  
L2513  - Update fee tier / maker-taker rates used by:
L2514    - §1.4.1 Net Edge Gate (fees component)
L2515    - §1.4 Pricer (fee-aware edge checks)
L2516  
L2517  **Acceptance Test (REQUIRED):**
L2518  AT-246
L2519  - Given: fee tier changes.
L2520  - When: the next polling cycle completes.
L2521  - Then: NetEdge computation reflects the new tier.
L2522  - Pass criteria: updated fee tier applied within one cycle.
L2523  - Fail criteria: NetEdge remains based on old tier.
L2524  
L2525  

--------------------------------------------------------------------------------
