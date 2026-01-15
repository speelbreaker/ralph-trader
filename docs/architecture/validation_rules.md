# Validation Rules (Deterministic Gate Specs)

> **Source of Truth:** [CONTRACT.md](file:///Users/admin/Desktop/ralph/CONTRACT.md)  
> **Last audited:** 2026-01-15

All rules are deterministic, enforceable, and contract-backed. Each gate specifies exact conditions, enforcement points, and failure modes.

---

## VR-001: F1 Certification Gate

**Gate ID:** VR-001  
**Trigger:** `artifacts/F1_CERT.json` missing OR `status != PASS` OR `now - generated_ts_ms > f1_cert_max_age_s` (default 24h)  
**Enforcement point:** `PolicyGuard.get_effective_mode()` (soldier/core/policy/guard.rs)  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** ReduceOnly until F1_CERT is valid  
**Contract citation:** §2.2.1 (line 648) — "missing OR stale OR FAIL => TradingMode MUST be ReduceOnly"

---

## VR-002: EvidenceGuard Gate

**Gate ID:** VR-002  
**Trigger:** EvidenceChainState != GREEN (any of: `truth_capsule_write_errors > 0`, `decision_snapshot_write_errors > 0`, `parquet_queue_overflow_count` increasing, `wal_write_errors > 0` in rolling 60s window)  
**Enforcement point:** `PolicyGuard.get_effective_mode()` + hot-path execution gate before dispatching OPEN orders  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open (any new risk)  
**Failure mode:** ReduceOnly; remain until GREEN for cooldown window (e.g., 120s)  
**Contract citation:** §2.2.2 (line 667) — "block ALL new OPEN intents… CLOSE / HEDGE / CANCEL still allowed"

---

## VR-003: Policy Staleness Gate

**Gate ID:** VR-003  
**Trigger:** `now - python_policy_generated_ts_ms > max_policy_age_s`  
**Enforcement point:** `PolicyGuard.get_effective_mode()`  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** ReduceOnly (even if late update arrives)  
**Contract citation:** §2.2 (line 708) — "If policy_age_s > max_policy_age_s → force ReduceOnly"

---

## VR-004a: Watchdog Heartbeat Kill Gate

**Gate ID:** VR-004a  
**Trigger:** `now - watchdog_last_heartbeat_ts_ms > watchdog_kill_s`  
**Enforcement point:** `PolicyGuard.get_effective_mode()`  
**Allowed actions:** None (Kill mode)  
**Forbidden actions:** All trading  
**Failure mode:** Kill immediately  
**Contract citation:** §2.2 (lines 689–691) — "Kill if watchdog heartbeat stale"

---

## VR-004b: Watchdog Silence ReduceOnly Trigger

**Gate ID:** VR-004b  
**Trigger:** Watchdog detects silence > 5s  
**Enforcement point:** Watchdog → `POST /api/v1/emergency/reduce_only`  
**Allowed actions:** Close, Hedge, Cancel (reduce-only orders stay alive)  
**Forbidden actions:** Orders where `reduce_only == false`  
**Failure mode:** Force `TradingMode = ReduceOnly`; persists until cooldown + reconciliation  
**Contract citation:** §3.2 (line 847) — "Watchdog triggers on silence > 5s → calls POST /api/v1/emergency/reduce_only"

---

## VR-005: Bunker Mode (Network Jitter) Gate

**Gate ID:** VR-005  
**Trigger:** `deribit_http_p95_ms > 750ms` for 3 consecutive 30s windows OR `ws_event_lag_ms > 2000ms` OR `request_timeout_rate > 2%`  
**Enforcement point:** `PolicyGuard.get_effective_mode()` via `bunker_mode_active`  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** ReduceOnly; exit only after all metrics below threshold for 120s  
**Contract citation:** §2.3.2 (lines 773–777) — "Force TradingMode::ReduceOnly (Bunker Mode)"

---

## VR-006: Disk Watermark Gates

**Gate ID:** VR-006a  
**Trigger:** `disk_used_pct >= 80%`  
**Enforcement point:** Ops monitor → Archive writers  
**Allowed actions:** Continue Decision Snapshots, WAL, TruthCapsule, Attribution  
**Forbidden actions:** Writing heavy tick/L2 archives  
**Failure mode:** Pause heavy archives only  
**Contract citation:** §7.2 (lines 1496–1499) — "stop writing full tick/L2 stream archives, BUT continue… Decision Snapshots"

**Gate ID:** VR-006b  
**Trigger:** `disk_used_pct >= 85%`  
**Enforcement point:** Ops monitor → PolicyGuard via RiskState  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** `RiskState::Degraded` → ReduceOnly until back under 80%  
**Contract citation:** §7.2 (line 1501) — "force RiskState::Degraded (ReduceOnly) until back under 80%"

**Gate ID:** VR-006c  
**Trigger:** `disk_used_pct >= 92%`  
**Enforcement point:** Ops monitor → PolicyGuard  
**Allowed actions:** None  
**Forbidden actions:** All trading  
**Failure mode:** Kill switch  
**Contract citation:** §7.2 (line 1502) — "hard-stop trading loop (Kill switch)"

---

## VR-007: Fee Model Staleness Gate

**Gate ID:** VR-007a (soft)  
**Trigger:** `fee_model_cache_age_s > fee_cache_soft_s` (default 300s)  
**Enforcement point:** `soldier/core/strategy/fees.rs` → NetEdge gate  
**Allowed actions:** All (with buffered fees)  
**Forbidden actions:** None (but higher rejection rate)  
**Failure mode:** Apply conservative buffer: `fee_rate_effective = fee_rate * 1.20`  
**Contract citation:** §4.2 (lines 1079–1080) — "apply conservative buffer fee_stale_buffer = 0.20"

**Gate ID:** VR-007b (hard)  
**Trigger:** `fee_model_cache_age_s > fee_cache_hard_s` (default 900s)  
**Enforcement point:** PolicyGuard via `fee_model_cache_age_s`  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** `RiskState::Degraded` → ReduceOnly until refreshed  
**Contract citation:** §4.2 (line 1081) — "set RiskState::Degraded and force ReduceOnly until refreshed"

---

## VR-008: Cortex Override Gate

**Gate ID:** VR-008a (DVOL shock)  
**Trigger:** DVOL jumps ≥ +10% within ≤ 60s  
**Enforcement point:** `soldier/core/reflex/cortex.rs`  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** `ForceReduceOnly{cooldown_s=300}`  
**Contract citation:** §2.3 (line 732) — "DVOL jumps ≥ +10% within ≤ 60s → ForceReduceOnly"

**Gate ID:** VR-008b (spread/depth collapse)  
**Trigger:** `spread_bps > spread_max_bps` OR `depth_topN < depth_min`  
**Enforcement point:** `soldier/core/reflex/cortex.rs`  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** `ForceReduceOnly{cooldown_s=120}`  
**Contract citation:** §2.3 (line 733) — "spread_bps > spread_max_bps OR depth_topN < depth_min → ForceReduceOnly"

---

## VR-009: Margin Headroom Gate

**Gate ID:** VR-009a  
**Trigger:** `mm_util >= 0.70` (where `mm_util = maintenance_margin / max(equity, epsilon)`)  
**Enforcement point:** `soldier/core/risk/margin_gate.rs`  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open (new opens rejected)  
**Failure mode:** Reject open intents  
**Contract citation:** §1.4.3 (lines 536–537) — "If mm_util >= 0.70 → Reject any NEW opens"

**Gate ID:** VR-009b  
**Trigger:** `mm_util >= 0.85`  
**Enforcement point:** `soldier/core/risk/margin_gate.rs` → PolicyGuard  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** Force `TradingMode = ReduceOnly`  
**Contract citation:** §1.4.3 (line 537) — "If mm_util >= 0.85 → Force TradingMode = ReduceOnly"

**Gate ID:** VR-009c  
**Trigger:** `mm_util >= 0.95`  
**Enforcement point:** `soldier/core/risk/margin_gate.rs`  
**Allowed actions:** Emergency flatten only  
**Forbidden actions:** All other trading  
**Failure mode:** Force `TradingMode = Kill` + trigger deterministic emergency flatten  
**Contract citation:** §1.4.3 (line 538) — "If mm_util >= 0.95 → Force TradingMode = Kill + trigger deterministic emergency flatten"

---

## VR-010: Replay Gatekeeper Coverage Gate

**Gate ID:** VR-010  
**Trigger:** `snapshot_coverage_pct < 95%` over replay window (48h)  
**Enforcement point:** `python/governor/replay_gatekeeper.py`  
**Allowed actions:** None (gate blocks policy application)  
**Forbidden actions:** Applying any policy patch  
**Failure mode:** HARD FAIL — reject patch, keep current policy  
**Contract citation:** §5.2 (line 1290) — "MUST HARD FAIL if snapshot_coverage_pct < 95%"

---

## VR-011: Liquidity Gate

**Gate ID:** VR-011  
**Trigger:** Expected `slippage_bps > MaxSlippageBps` when walking L2 book for OrderQty  
**Enforcement point:** `soldier/core/execution/gate.rs`  
**Allowed actions:** None for this intent  
**Forbidden actions:** Dispatching the order  
**Failure mode:** `Rejected(ExpectedSlippageTooHigh)` — log `LiquidityGateReject` with WAP + slippage  
**Contract citation:** §1.3 (lines 404–406) — "Reject if slippage_bps > MaxSlippageBps"

---

## VR-012: Net Edge Gate

**Gate ID:** VR-012  
**Trigger:** `net_edge_usd = gross_edge_usd - fee_usd - expected_slippage_usd < min_edge_usd`  
**Enforcement point:** `soldier/core/execution/gates.rs`  
**Allowed actions:** None for this intent  
**Forbidden actions:** Creating OrderIntent  
**Failure mode:** `Rejected(NetEdgeTooLow)` — gate runs BEFORE AtomicGroup creation  
**Contract citation:** §1.4.1 (lines 451–455) — "Reject if net_edge_usd < min_edge_usd"

---

## VR-013: Instrument Cache Staleness Gate

**Gate ID:** VR-013  
**Trigger:** Instrument metadata age > `instrument_cache_ttl_s`  
**Enforcement point:** Instrument cache (sizing/quantization path)  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open  
**Failure mode:** `RiskState::Degraded` → ReduceOnly within one tick  
**Contract citation:** §1.0.X (lines 136–138) — "set RiskState::Degraded; block opens by forcing TradingMode::ReduceOnly"

---

## VR-014: WAL Record-Before-Dispatch Gate

**Gate ID:** VR-014  
**Trigger:** Intent not recorded in WAL before network dispatch  
**Enforcement point:** `soldier/infra/store/ledger.rs` + dispatch path  
**Allowed actions:** None (invariant violation)  
**Forbidden actions:** Dispatching unrecorded intent  
**Failure mode:** System invariant — dispatch MUST NOT proceed without WAL record  
**Contract citation:** §2.4 (line 787) — "Write intent record BEFORE network dispatch"

---

## VR-015: AGGRESSIVE Patch Human Approval Gate

**Gate ID:** VR-015  
**Trigger:** Patch classified as AGGRESSIVE and `artifacts/HUMAN_APPROVAL.json` missing  
**Enforcement point:** `python/reviewer/daily_ops_review.py`  
**Allowed actions:** None (patch blocked)  
**Forbidden actions:** Applying patch  
**Failure mode:** Patch rejected; log reason; keep current policy  
**Contract citation:** §7.1.3 (line 1463) — "AGGRESSIVE always requires HUMAN_APPROVAL.json"

---

## VR-016: Exchange Health Monitor Gate

**Gate ID:** VR-016  
**Trigger:** Exchange maintenance window start ≤ 60 minutes away (from `/public/get_announcements`)  
**Enforcement point:** `soldier/core/risk/exchange_health.rs` → PolicyGuard via `exchange_health_state`  
**Allowed actions:** Close, Hedge, Cancel  
**Forbidden actions:** Open (new opens blocked even if NetEdge positive)  
**Failure mode:** `RiskState::Maintenance` → ReduceOnly until maintenance window passes  
**Contract citation:** §2.3.1 (lines 750–756) — "If a maintenance window start is ≤ 60 minutes away: Set RiskState::Maintenance"

---

## VR-017: Atomic Churn Circuit Breaker

**Gate ID:** VR-017  
**Trigger:** `EmergencyFlattenGroup` triggered > 2 times in 5 minutes for same `{strategy_id, structure_fingerprint}`  
**Enforcement point:** `soldier/core/risk/churn_breaker.rs`  
**Allowed actions:** Close, Hedge (reduce-only)  
**Forbidden actions:** Open for blacklisted key  
**Failure mode:** Blacklist key for 15 minutes; return `Rejected(ChurnBreakerActive)`  
**Contract citation:** §1.2.2 (lines 384–386) — "If EmergencyFlattenGroup triggers >2 times in 5 minutes… Blacklist that key for 15 minutes"

---

## VR-018: Pending Exposure Reservation Gate

**Gate ID:** VR-018  
**Trigger:** Proposed group's `delta_impact_est` would breach limits when added to pending + current exposure  
**Enforcement point:** `soldier/core/risk/pending_exposure.rs`  
**Allowed actions:** None for this group  
**Forbidden actions:** Dispatching group  
**Failure mode:** Reject intent; must reserve before dispatch, release on terminal outcome  
**Contract citation:** §1.4.2.1 (lines 496–502) — "Attempt reserve(delta_impact_est): If reservation would breach limits → reject the intent"

---

## VR-019: Global Exposure Budget Gate

**Gate ID:** VR-019  
**Trigger:** Portfolio-level exposure (delta/vega/gamma) breaches limits after correlation adjustment  
**Enforcement point:** `soldier/core/risk/exposure_budget.rs`  
**Allowed actions:** None for this trade  
**Forbidden actions:** Opening trade  
**Failure mode:** Reject new opens even if single-instrument gates pass  
**Contract citation:** §1.4.2.2 (lines 517–518) — "Gate new opens if portfolio exposure breaches limits"

---

## VR-020: Inventory Skew Gate

**Gate ID:** VR-020  
**Trigger:** Inventory bias (`current_delta / delta_limit`) requires min_edge or limit_price adjustment  
**Enforcement point:** `soldier/core/execution/gates.rs` (after Net Edge Gate, before pricer)  
**Allowed actions:** Adjusted trade (if still passes)  
**Forbidden actions:** Trade without bias adjustment when near inventory limits  
**Failure mode:** Risk-increasing trades: require higher edge + less aggressive limit; risk-reducing: allow looser  
**Contract citation:** §1.4.2 (lines 469–477) — "BUY intents when inventory_bias > 0: Require higher edge… shift limit_price away from touch"

---

## VR-021: Orderbook Continuity Gate

**Gate ID:** VR-021  
**Trigger:** `prevChangeId != last_change_id[instrument]` for book incremental event  
**Enforcement point:** WS book handler in Soldier  
**Allowed actions:** Close/Hedge/Cancel (during Degraded)  
**Forbidden actions:** Open until snapshot rebuild completes  
**Failure mode:** `RiskState::Degraded`; resubscribe + full REST snapshot; reconcile before resuming  
**Contract citation:** §3.4 (lines 930–938) — "If prevChangeId != last_change_id: Set RiskState::Degraded and pause opens"

---

## VR-022: Trades Continuity Gate

**Gate ID:** VR-022  
**Trigger:** Trade sequence gap (`trade_seq != last_trade_seq + 1`) detected for instrument  
**Enforcement point:** WS trades handler in Soldier  
**Allowed actions:** Close/Hedge/Cancel  
**Forbidden actions:** Open until reconciliation completes  
**Failure mode:** `RiskState::Degraded`; pull REST trades + reconcile; resume only when confirmed no missing fills  
**Contract citation:** §3.4 (lines 940–947) — "If gap or non-monotonic: Set RiskState::Degraded and pause opens"

---

## VR-023: Rate Limit Brownout Gate

**Gate ID:** VR-023a (Pressure Shedding)  
**Trigger:** Token bucket exhausted or 429 burst detected  
**Enforcement point:** `soldier/infra/api/rate_limit.rs`  
**Allowed actions:** CANCEL, HEDGE, EMERGENCY_CLOSE (highest priority)  
**Forbidden actions:** OPEN blocked; DATA shed first  
**Failure mode:** Priority queue preemption; ReduceOnly behavior for opens  
**Contract citation:** §3.3 (lines 883–887) — "shed DATA first; block OPEN next; preserve CANCEL/HEDGE/EMERGENCY_CLOSE"

**Gate ID:** VR-023b (Session Termination)  
**Trigger:** `too_many_requests` (code 10028) or session terminated  
**Enforcement point:** `soldier/infra/api/rate_limit.rs` → PolicyGuard  
**Allowed actions:** None until reconnect + reconcile  
**Forbidden actions:** All trading  
**Failure mode:** `RiskState::Degraded` + `TradingMode::Kill` immediately; backoff → reconnect → 3-way reconcile → resume only when stable  
**Contract citation:** §3.3 (lines 896–900) — "Set RiskState::Degraded and TradingMode = Kill immediately"

---

## VR-024: Status Endpoint Response Gate

**Gate ID:** VR-024  
**Trigger:** (Testing gate) Endpoint `/api/v1/status` must return required fields  
**Enforcement point:** `test_status_endpoint_returns_required_fields()` (§7.0 line 1412)  
**Allowed actions:** N/A (test gate)  
**Forbidden actions:** Deploying without passing endpoint test  
**Failure mode:** CI blocks deployment  
**Contract citation:** §7.0 (lines 1408–1412) — "Any new endpoint introduced by this contract MUST include at least one endpoint-level test"

---

## VR-025: No Market Orders Gate

**Gate ID:** VR-025  
**Trigger:** `type == market` (any instrument kind)  
**Enforcement point:** Preflight guard in trade dispatch path (before API call)  
**Allowed actions:** None for this order  
**Forbidden actions:** Dispatching market order  
**Failure mode:** **REJECT** (no rewrite/normalization); hard reject  
**Contract citation:** §1.4.4 (lines 552–553, 562–563) — "If type == market → REJECT (no rewrite/normalization)"

---

## VR-026: Options Stop Orders Forbidden Gate

**Gate ID:** VR-026  
**Trigger:** `instrument_kind == option` AND (`type in {stop_market, stop_limit}` OR `trigger` present)  
**Enforcement point:** Preflight guard in trade dispatch path  
**Allowed actions:** None for this order  
**Forbidden actions:** Dispatching stop order on options  
**Failure mode:** **REJECT**; hard preflight rejection  
**Contract citation:** §1.4.4 (lines 554–555) — "Stop orders: forbidden (F-01a); Reject any type in {stop_market, stop_limit}"

---

## VR-027: Stop Orders Require Trigger Gate

**Gate ID:** VR-027  
**Trigger:** `instrument_kind in {linear_future, inverse_future, perpetual}` AND `type in {stop_market, stop_limit}` AND `trigger` missing/invalid  
**Enforcement point:** Preflight guard in trade dispatch path  
**Allowed actions:** None without valid trigger  
**Forbidden actions:** Dispatching stop order without mandatory trigger  
**Failure mode:** **REJECT**; trigger must be one of Deribit-allowed triggers (index/mark/last)  
**Contract citation:** §1.4.4 (lines 564–565) — "Stop orders require trigger (F-09); trigger is mandatory"

---

## VR-028: Linked/OCO Orders Gate

**Gate ID:** VR-028  
**Trigger:** `linked_order_type != null` AND (feature flag `ENABLE_LINKED_ORDERS_FOR_BOT != true` OR `linked_orders_supported != true`)  
**Enforcement point:** Preflight guard in trade dispatch path  
**Allowed actions:** None for linked orders (currently NOT SUPPORTED)  
**Forbidden actions:** Dispatching linked/OCO order  
**Failure mode:** **REJECT**; linked orders gated off unless explicitly certified  
**Contract citation:** §1.4.4 (lines 556–557, 566–567) — "Linked/OCO orders: forbidden (F-08); Reject any non-null linked_order_type"
