PHASE 1 — Foundation (Slices 1–5)  
A) Phase Objective  
Build the deterministic “intent → gated → priced → WAL-recorded” pipeline. This phase encodes Deribit unit invariants, deterministic quantization+label idempotency, venue preflight hard rejects, and the WAL/TLSM/trade-id dedupe needed to be restart-safe. Execution gates (liquidity, net-edge, fee staleness) are enforced behind a single chokepoint so there is exactly one correct dispatch path.

B) Constraint (TOC)  
Bottleneck: “Multiple ways to dispatch” \+ “non-deterministic rounding” \+ “no durable truth.”  
Relief: (1) make build\_order\_intent() the only constructor; (2) quantize before hash; (3) append intent to WAL before any network; (4) tests assert gate ordering \+ replay safety.

C) Entry Criteria  
Rust workspace exists with crates/soldier\_core, crates/soldier\_infra.  
Test harness configured (cargo test \--workspace).  
artifacts/ present and python scripts/check\_vq\_evidence.py is runnable.  
D) Exit Criteria (measurable/testable)  
All tests listed in Slices 1–5 pass in CI.  
test\_gate\_ordering\_call\_log proves ordered gates: preflight→quantize→fee→liquidity→net\_edge→…→WAL→dispatch.  
test\_phase1\_degraded\_blocks\_opens proves: Given RiskState::Degraded, when an OPEN intent is evaluated for dispatch, then it is blocked (0 dispatches).  
test\_ledger\_replay\_no\_resend\_after\_crash proves no duplicate sends after restart.  
E) Slices Breakdown (Phase 1\)  
Slice 1 — Instrument Units \+ Dispatcher Invariants  
Slice intent: Encode Deribit sizing semantics to prevent 10–100× exposure errors.

S1.0 — Repo verification harness (plans/verify.sh) \+ safety-critical config defaults (Appendix A)  
Commitment: implement ALL Appendix A defaults exactly (no omissions) and add/ensure Appendix A Default Tests that are Phase 1-implementable exist and pass in CI; Phase 2/3/4 wrapper tests land in their slices.  
Allowed paths:  
plans/verify.sh  
crates/soldier_infra/config/**  
crates/soldier_infra/tests/test_config_defaults.rs  
New/changed endpoints: none  
Acceptance criteria:  
`plans/verify.sh` exists, is executable, and is runnable from repo root. It MUST invoke `cargo test --workspace` as part of its core gate.  
CI guardrail: `python scripts/check_vq_evidence.py` MUST be invoked by `plans/verify.sh` (or equivalent CI step) and build MUST fail if it fails.  
If a safety-critical config value is missing at runtime, apply the Appendix A default (fail-closed; no “None/0 means safe”).  
Required default application proof (minimum): start with config missing `instrument_cache_ttl_s` and `evidenceguard_global_cooldown` and verify defaults are applied.  
Tests:  
crates/soldier_infra/tests/test_config_defaults.rs::test_defaults_applied_when_missing  
Evidence artifacts: none  
Rollout \+ rollback: repo harness; rollback via revert only.  
Observability hooks: none.

**Test suite parity table (contract §8.2):**
Add an explicit mapping list in this plan: "contract test name → actual test function path" and add thin wrapper tests when internal names differ. This removes ambiguity from "Add/ensure Appendix A Default Tests."  
Rule: Wrapper/alias tests are added in the slice where the underlying behavior exists; Phase 1 MUST NOT require Phase 2/3/4 behavior to pass.  

Minimum Test Suite (contract §8.2 A) mapping:
- test\_truth\_capsule\_written\_before\_dispatch\_and\_fk\_linked() -> crates/soldier\_core/tests/test\_truth\_capsule.rs::test\_truth\_capsule\_written\_before\_dispatch\_and\_fk\_linked
- test\_atomic\_containment\_calls\_emergency\_close\_algorithm\_with\_hedge\_fallback() -> crates/soldier\_core/tests/test\_atomic\_group.rs::test\_atomic\_containment\_calls\_emergency\_close\_algorithm\_with\_hedge\_fallback
- test\_disk\_watermark\_stops\_tick\_archives\_and\_forces\_reduceonly() -> crates/soldier\_core/tests/test\_disk\_watermark\_stops\_tick\_archives\_and\_forces\_reduceonly.rs::test\_disk\_watermark\_stops\_tick\_archives\_and\_forces\_reduceonly
- test\_release\_gate\_fee\_drag\_ratio\_blocks\_scaling() -> python/tests/test\_f1\_certify.py::test\_release\_gate\_fee\_drag\_ratio\_blocks\_scaling
- test\_atomic\_qty\_epsilon\_tolerates\_float\_noise\_but\_rejects\_mismatch() -> crates/soldier\_core/tests/test\_order\_size.rs::test\_atomic\_qty\_epsilon\_tolerates\_float\_noise\_but\_rejects\_mismatch
- test\_cortex\_spread\_max\_bps\_forces\_reduceonly() -> crates/soldier\_core/tests/test\_cortex.rs::test\_cortex\_spread\_max\_bps\_forces\_reduceonly
- test\_cortex\_depth\_min\_forces\_reduceonly() -> crates/soldier\_core/tests/test\_cortex.rs::test\_cortex\_depth\_min\_forces\_reduceonly
- test\_svi\_depth\_min\_applies\_loosened\_thresholds() -> crates/soldier\_core/tests/test\_svi.rs::test\_svi\_depth\_min\_applies\_loosened\_thresholds
- test\_stale\_order\_sec\_cancels\_non\_reduce\_only\_orders() -> crates/soldier\_core/tests/test\_zombie\_sweeper.rs::test\_stale\_order\_sec\_cancels\_non\_reduce\_only\_orders

Appendix A Default Tests mapping:
- test\_contracts\_amount\_match\_tolerance\_rejects\_mismatches\_above\_0\_001() -> crates/soldier\_core/tests/test\_order\_size.rs::test\_contracts\_amount\_match\_tolerance\_rejects\_mismatches\_above\_0\_001
- test\_instrument\_cache\_ttl\_s\_expires\_after\_3600s() -> crates/soldier\_core/tests/test\_instrument\_cache\_ttl.rs::test\_instrument\_cache\_ttl\_s\_expires\_after\_3600s
- test\_inventory\_skew\_k\_and\_tick\_penalty\_max\_adjust\_prices() -> crates/soldier\_core/tests/test\_inventory\_skew.rs::test\_inventory\_skew\_k\_and\_tick\_penalty\_max\_adjust\_prices
- test\_rescue\_cross\_spread\_ticks\_uses\_2\_ticks\_default() -> crates/soldier\_core/tests/test\_emergency\_close.rs::test\_rescue\_cross\_spread\_ticks\_uses\_2\_ticks\_default
- test\_f1\_cert\_freshness\_window\_s\_forces\_reduceonly\_after\_86400s() -> crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_freshness\_window\_s\_forces\_reduceonly\_after\_86400s
- test\_mm\_util\_max\_age\_ms\_forces\_reduceonly\_after\_30000ms() -> crates/soldier\_core/tests/test\_policy\_guard.rs::test\_mm\_util\_max\_age\_ms\_forces\_reduceonly\_after\_30000ms
- test\_disk\_used\_max\_age\_ms\_forces\_reduceonly\_after\_30000ms() -> crates/soldier\_core/tests/test\_policy\_guard.rs::test\_disk\_used\_max\_age\_ms\_forces\_reduceonly\_after\_30000ms
- test\_watchdog\_kill\_s\_triggers\_kill\_after\_10s\_no\_health\_report() -> crates/soldier\_core/tests/test\_policy\_guard.rs::test\_watchdog\_kill\_s\_triggers\_kill\_after\_10s\_no\_health\_report
- test\_mm\_util\_reject\_opens\_blocks\_opens\_at\_70\_pct() -> crates/soldier\_core/tests/test\_margin\_gate.rs::test\_mm\_util\_reject\_opens\_blocks\_opens\_at\_70\_pct
- test\_mm\_util\_reduceonly\_forces\_reduceonly\_at\_85\_pct() -> crates/soldier\_core/tests/test\_margin\_gate.rs::test\_mm\_util\_reduceonly\_forces\_reduceonly\_at\_85\_pct
- test\_mm\_util\_kill\_forces\_kill\_at\_95\_pct() -> crates/soldier\_core/tests/test\_margin\_gate.rs::test\_mm\_util\_kill\_forces\_kill\_at\_95\_pct
- test\_evidenceguard\_global\_cooldown\_blocks\_opens\_for\_120s() -> crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_evidenceguard\_global\_cooldown\_blocks\_opens\_for\_120s
- test\_position\_reconcile\_epsilon\_tolerates\_1e\_6\_qty\_diff() -> crates/soldier\_core/tests/test\_reconcile.rs::test\_position\_reconcile\_epsilon\_tolerates\_1e\_6\_qty\_diff
- test\_reconcile\_trade\_lookback\_sec\_queries\_300s\_history() -> crates/soldier\_core/tests/test\_reconcile.rs::test\_reconcile\_trade\_lookback\_sec\_queries\_300s\_history
- test\_parquet\_queue\_trip\_pct\_triggers\_evidenceguard\_at\_90\_pct() -> crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_parquet\_queue\_trip\_pct\_triggers\_evidenceguard\_at\_90\_pct
- test\_parquet\_queue\_clear\_pct\_resumes\_opens\_below\_70\_pct() -> crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_parquet\_queue\_clear\_pct\_resumes\_opens\_below\_70\_pct
- test\_parquet\_queue\_trip\_window\_s\_measures\_over\_5s() -> crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_parquet\_queue\_trip\_window\_s\_measures\_over\_5s
- test\_queue\_clear\_window\_s\_requires\_120s\_stability() -> crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_queue\_clear\_window\_s\_requires\_120s\_stability
- test\_disk\_pause\_archives\_pct\_stops\_tick\_writes\_at\_80\_pct() -> crates/soldier\_core/tests/test\_disk\_watermark.rs::test\_disk\_pause\_archives\_pct\_stops\_tick\_writes\_at\_80\_pct
- test\_disk\_degraded\_pct\_forces\_reduceonly\_at\_85\_pct() -> crates/soldier\_core/tests/test\_disk\_watermark.rs::test\_disk\_degraded\_pct\_forces\_reduceonly\_at\_85\_pct
- test\_disk\_kill\_pct\_hard\_stops\_at\_92\_pct() -> crates/soldier\_core/tests/test\_disk\_watermark.rs::test\_disk\_kill\_pct\_hard\_stops\_at\_92\_pct
- test\_time\_drift\_threshold\_ms\_forces\_reduceonly\_above\_50ms() -> crates/soldier\_core/tests/test\_time\_drift.rs::test\_time\_drift\_threshold\_ms\_forces\_reduceonly\_above\_50ms
- test\_max\_policy\_age\_sec\_forces\_reduceonly\_after\_300s() -> crates/soldier\_core/tests/test\_policy\_guard.rs::test\_max\_policy\_age\_sec\_forces\_reduceonly\_after\_300s
- test\_close\_buffer\_ticks\_uses\_5\_ticks\_on\_first\_attempt() -> crates/soldier\_core/tests/test\_emergency\_close.rs::test\_close\_buffer\_ticks\_uses\_5\_ticks\_on\_first\_attempt
- test\_max\_slippage\_bps\_rejects\_trades\_above\_10bps() -> crates/soldier\_core/tests/test\_liquidity\_gate.rs::test\_max\_slippage\_bps\_rejects\_trades\_above\_10bps
- test\_fee\_cache\_soft\_s\_applies\_buffer\_after\_300s() -> crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_cache\_soft\_s\_applies\_buffer\_after\_300s
- test\_fee\_cache\_hard\_s\_forces\_degraded\_after\_900s() -> crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_cache\_hard\_s\_forces\_degraded\_after\_900s
- test\_fee\_stale\_buffer\_multiplies\_fees\_by\_1\_20() -> crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_stale\_buffer\_multiplies\_fees\_by\_1\_20
- test\_svi\_guard\_trip\_count\_triggers\_degraded\_after\_3\_trips() -> crates/soldier\_core/tests/test\_svi.rs::test\_svi\_guard\_trip\_count\_triggers\_degraded\_after\_3\_trips
- test\_svi\_guard\_trip\_window\_s\_counts\_over\_300s() -> crates/soldier\_core/tests/test\_svi.rs::test\_svi\_guard\_trip\_window\_s\_counts\_over\_300s
- test\_dvol\_jump\_pct\_triggers\_reduceonly\_at\_10\_pct\_spike() -> crates/soldier\_core/tests/test\_cortex.rs::test\_dvol\_jump\_pct\_triggers\_reduceonly\_at\_10\_pct\_spike
- test\_dvol\_jump\_window\_s\_measures\_over\_60s() -> crates/soldier\_core/tests/test\_cortex.rs::test\_dvol\_jump\_window\_s\_measures\_over\_60s
- test\_dvol\_cooldown\_s\_blocks\_opens\_for\_300s() -> crates/soldier\_core/tests/test\_cortex.rs::test\_dvol\_cooldown\_s\_blocks\_opens\_for\_300s
- test\_spread\_depth\_cooldown\_s\_blocks\_opens\_for\_120s() -> crates/soldier\_core/tests/test\_cortex.rs::test\_spread\_depth\_cooldown\_s\_blocks\_opens\_for\_120s
- test\_decision\_snapshot\_retention\_days\_deletes\_after\_30\_days() -> crates/soldier\_infra/tests/test\_retention.rs::test\_decision\_snapshot\_retention\_days\_deletes\_after\_30\_days
- test\_replay\_window\_hours\_checks\_coverage\_over\_48h() -> python/tests/test\_replay\_gatekeeper.py::test\_replay\_window\_hours\_checks\_coverage\_over\_48h
- test\_tick\_l2\_retention\_hours\_deletes\_after\_72h() -> crates/soldier\_infra/tests/test\_retention.rs::test\_tick\_l2\_retention\_hours\_deletes\_after\_72h
- test\_parquet\_analytics\_retention\_days\_deletes\_after\_30\_days() -> crates/soldier\_infra/tests/test\_retention.rs::test\_parquet\_analytics\_retention\_days\_deletes\_after\_30\_days

S1.1 — InstrumentKind derivation \+ instrument cache TTL (fail‑closed)  
Allowed paths (globs):  
crates/soldier\_core/venue/\*\*  
crates/soldier\_infra/deribit/public/\*\*  
crates/soldier\_core/risk/state.rs  
New/changed endpoints: none  
Acceptance criteria:  
InstrumentKind derives option|linear\_future|inverse\_future|perpetual from venue metadata.  
Linear perpetuals (USDC‑margined) map to linear\_future for sizing.  
Instrument cache TTL breach sets RiskState::Degraded (opens blocked by Phase 1 dispatch authorization rule) and emits a structured log.  
Quantization inputs `tick_size`, `amount_step`, `min_amount`, and `contract_multiplier` MUST come from `/public/get_instruments` metadata (no hardcoded defaults).  
Tests:  
crates/soldier\_core/tests/test\_instrument\_kind\_mapping.rs::test\_linear\_perp\_treated\_as\_linear\_future  
crates/soldier\_core/tests/test\_instrument\_cache\_ttl.rs::test\_stale\_instrument\_cache\_sets\_degraded  
crates/soldier\_core/tests/test\_instrument\_cache\_ttl.rs::test\_instrument\_cache\_ttl\_blocks\_opens\_allows\_closes (AT-104)  
Evidence artifacts: none  
Rollout \+ rollback:  
Rollout behind config instrument_cache_ttl_s; Rollback for TTL safety behavior = revert commit; TTL changes are not a safety bypass mechanism (still fail-closed if metadata missing).  
Observability hooks: counters instrument\_cache\_hits\_total, instrument\_cache\_stale\_total, instrument\_cache\_refresh\_errors\_total; gauge instrument\_cache\_age\_s.  

**Source-of-truth**: Instrument metadata MUST be fetched from Deribit `/public/get_instruments` and MUST NOT be hardcoded (tick_size, amount_step, min_amount).  

**Required tests**: Add/alias:  
- `test_instrument_metadata_uses_get_instruments()`  
- `test_instrument_cache_ttl_blocks_opens_allows_closes()`  

**Reason**: C-1.0-INSTKIND-001, C-8.2-TEST_SUITE-001  

S1.2 — OrderSize canonical sizing \+ notional invariant  
Allowed paths: crates/soldier\_core/execution/order\_size.rs  
New/changed endpoints: none  
Acceptance criteria:  
OrderSize { contracts, qty\_coin, qty\_usd, notional\_usd } implemented exactly.  
Canonical units:  
option|linear\_future: canonical qty\_coin  
perpetual|inverse\_future: canonical qty\_usd  
notional\_usd always populated deterministically.  
Explicit identifiers: `instrument_kind`, `qty_coin`, `qty_usd`; for `instrument_kind == option`, `qty_usd` MUST be unset.  
Tests:  
crates/soldier\_core/tests/test\_order\_size.rs::test\_order\_size\_option\_perp\_canonical\_amount  
Evidence artifacts: none  
Rollout \+ rollback: core library; rollback via revert commit only.  
Observability hooks: debug log OrderSizeComputed{instrument\_kind, notional\_usd}.  

**Threshold**: Set `contracts_amount_match_tolerance = 0.001` and enforce: if both contracts-derived amount and canonical amount exist and mismatch beyond tolerance ⇒ reject + RiskState::Degraded.  
If both `contracts` and `amount` are provided, they MUST match within tolerance (contract_multiplier-based check).  

**Required test alias**: Add/alias `test_atomic_qty_epsilon_tolerates_float_noise_but_rejects_mismatch()`.  

**Reason**: C-1.0-ORDER_SIZE-001, C-8.2-TEST_SUITE-001  

S1.3 — Dispatcher amount mapping \+ mismatch reject→Degraded  
Allowed paths: crates/soldier\_core/execution/dispatch\_map.rs  
New/changed endpoints: none  
Acceptance criteria:  
Outbound Deribit request sends exactly one canonical amount.  
If both contracts and canonical amount exist and mismatch ⇒ reject intent and set RiskState::Degraded.  
Outbound Deribit reduce_only flag MUST be set from intent classification:  
- CLOSE/HEDGE intents -> reduce_only=true  
- OPEN intents -> reduce_only=false or omitted  
This flag MUST NOT be derived from TradingMode.  
Tests:  
crates/soldier\_core/tests/test\_dispatch\_map.rs::test\_dispatch\_amount\_field\_coin\_vs\_usd  
crates/soldier\_core/tests/test\_order\_size.rs::test\_order\_size\_mismatch\_rejects\_and\_degrades  
crates/soldier\_core/tests/test\_dispatch\_map.rs::test\_reduce\_only\_flag\_set\_by\_intent\_classification  
Evidence artifacts: none  
Rollout \+ rollback: core; rollback via revert only (hot-path invariant).  
Observability hooks: counter order\_intent\_reject\_unit\_mismatch\_total.  
Slice 2 — Quantization \+ Labeling \+ Idempotency  
Slice intent: Deterministic quantization and idempotency across restarts/reconnects.

S2.1 — Integer tick/step quantization (safer direction)  
Allowed paths: crates/soldier\_core/execution/quantize.rs  
New/changed endpoints: none  
Acceptance criteria:  
qty\_q \= round\_down(raw\_qty, amount\_step).  
BUY limit\_price\_q rounds down to tick; SELL rounds up to tick.  
Reject if qty\_q \< min\_amount.  
Reject with Rejected(InstrumentMetadataMissing) and no dispatch occurs if tick\_size/amount\_step/min\_amount is missing or unparseable (fail-closed).  
Tests:  
crates/soldier\_core/tests/test\_quantize.rs::test\_quantization\_rounding\_buy\_sell  
crates/soldier\_core/tests/test\_quantize.rs::test\_rejects\_too\_small\_after\_quantization  
crates/soldier\_core/tests/test\_quantize.rs::test\_missing\_metadata\_rejects\_open (AT-926)  
Evidence artifacts: artifacts/deribit\_testnet\_trade\_final\_20260103\_020002.log (F‑03 reference; enforced by evidence-check script)  
Rollout \+ rollback: core; rollback via revert only.  
Observability hooks: counter quantization\_reject\_too\_small\_total.  
S2.2 — Intent hash from quantized fields only  
Allowed paths: crates/soldier\_core/idempotency/hash.rs  
New/changed endpoints: none  
Acceptance criteria:  
Hash excludes wall-clock timestamps.  
Same economic intent through two codepaths yields identical hash.  
If intent\_hash already exists in WAL, treat as NOOP (no dispatch; no new WAL entry).  
This NOOP check occurs after hash computation and before WAL append + before any dispatch attempt.  
Tests:  
crates/soldier\_core/tests/test\_idempotency.rs::test\_intent\_hash\_deterministic\_from\_quantized (AT-343; must assert hash stability across wall-clock time)  
crates/soldier\_core/tests/test\_idempotency.rs::test\_intent\_hash\_noop\_when\_already\_in\_wal (AT-928)  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: none beyond existing logs.  
Hard rule (contract Definitions): If an intent cannot be classified, it MUST be treated as OPEN (fail-closed).  
Add test: crates/soldier\_core/tests/test\_build\_order\_intent.rs::test\_unclassifiable\_intent\_defaults\_to\_open\_and\_is\_blocked\_when\_opens\_blocked  
Phase 1 blocks OPEN when RiskState != Healthy per Phase 1 Dispatch Authorization Rule.  
S2.3 — Compact label schema encode/decode (≤64 chars)  
Allowed paths: crates/soldier\_core/execution/label.rs  
New/changed endpoints: none  
Acceptance criteria:  
s4:{sid8}:{gid12}:{li}:{ih16}; max 64 chars.  
All outbound orders to Deribit MUST use the s4: format (no exceptions).  
Truncation MUST NOT occur; if computed s4 label would exceed 64 chars, hard-reject before any API call.  
Hard rule (contract §1.1): Expanded (human-readable) label format is for logs only and MUST NOT be sent to the exchange.  
Tests:  
crates/soldier\_core/tests/test\_label.rs::test\_label\_compact\_schema\_length\_limit (assert s4 format and <=64 chars)  
crates/soldier\_core/tests/test\_label.rs::test\_label\_parser\_extracts\_components (AT-216; must assert sid8/gid12/li/ih16 extraction)  
crates/soldier\_core/tests/test\_label.rs::test\_expanded\_label\_never\_sent\_to\_exchange  
crates/soldier\_core/tests/test\_label.rs::test\_label\_rejects\_over\_64\_no\_truncation (AT-041, AT-921; must assert Rejected(LabelTooLong) + RiskState::Degraded)  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: counter label\_truncated\_total.  
S2.4 — Label match disambiguation; ambiguity→Degraded  
Allowed paths: crates/soldier\_core/recovery/label\_match.rs  
New/changed endpoints: none  
Acceptance criteria:  
Matching algorithm per contract tie-breakers; ambiguity triggers RiskState::Degraded and sets “opens blocked” latch (wired later).  
Tests:  
crates/soldier\_core/tests/test\_label\_match.rs::test\_label\_match\_disambiguation (AT-217; must cover tie-breakers)  
crates/soldier\_core/tests/test\_label\_match.rs::test\_label\_match\_ambiguous\_degrades  
crates/soldier\_core/tests/test\_label\_match.rs::test\_label\_match\_ambiguity\_sets\_degraded\_and\_blocks\_open (AT-217; unresolved ambiguity => Degraded + opens blocked)  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: counter label\_match\_ambiguity\_total.  
Slice 3 — Order‑Type Preflight \+ Venue Capabilities (artifact‑backed)  
Slice intent: Hard-reject illegal orders before any API call.

S3.1 — Preflight guard (market/stop/linked rules)  
Stop orders are NOT SUPPORTED for perps/futures: reject any type in {stop_market, stop_limit} regardless of trigger presence.  
Add/alias regression test name required by contract: perp_stop_order_is_rejected_preflight.  
Allowed paths:  
crates/soldier\_core/execution/preflight.rs  
crates/soldier\_core/execution/order\_type\_guard.rs  
New/changed endpoints: none  
Acceptance criteria:  
Reject market orders for all instruments (policy); **no normalization/rewrite** is allowed.  
Options: allow limit only; reject stops; reject any trigger\*; reject linked orders.  
Futures/perps: allow limit only; if stop types appear in codepath, require trigger (but bot policy still rejects market).  
Linked/OCO gating (contract explicit):  
- `linked_orders_supported == false` for v5.1 (fail-closed).  
- `ENABLE_LINKED_ORDERS_FOR_BOT == false` by default.  
- Reject any non-null `linked_order_type` (OCO) unless both flags are true.  
Tests:  
crates/soldier\_core/tests/test\_preflight.rs::test\_options\_market\_order\_rejected  
crates/soldier\_core/tests/test\_preflight.rs::test\_perp\_market\_order\_rejected  
crates/soldier\_core/tests/test\_preflight.rs::test\_options\_stop\_order\_rejected\_preflight  
crates/soldier\_core/tests/test\_linked\_orders\_gated\_off  
crates/soldier\_core/tests/test\_preflight.rs::test\_perp\_stop\_requires\_trigger  
crates/soldier\_core/tests/test\_preflight.rs::test\_market\_order\_forbidden\_reason (AT-913)  
crates/soldier\_core/tests/test\_preflight.rs::test\_stop\_order\_forbidden\_reason (AT-914)  
crates/soldier\_core/tests/test\_preflight.rs::test\_linked\_order\_forbidden\_reason (AT-915)  

**Contract test name parity (required):**

Add thin wrapper tests (exact names) that call the existing tests:
  options_market_order_is_rejected (AT-016)
  perp_market_order_is_rejected (AT-017)
  options_stop_order_is_rejected_preflight (AT-018)
  perp_stop_order_is_rejected_preflight (AT-019)
  linked_orders_oco_is_gated_off (AT-004)

Evidence artifacts (must remain valid):  
artifacts/T-TRADE-02\_response.json (F‑01a)  
artifacts/deribit\_testnet\_trade\_20260103\_015804.log (F‑01b policy conflict)  
artifacts/T-OCO-01\_response.json (F‑08)  
artifacts/T-STOP-01\_response.json, artifacts/T-STOP-02\_response.json (F‑09)  
Rollout \+ rollback: core invariant (no rollback except revert).  
Observability hooks: counter preflight\_reject\_total{reason}.  

**Clarification**: For futures/perps, stop orders remain REJECTED regardless of trigger presence. Any "trigger required" validation is informational only and MUST NOT enable stop order acceptance.  

**Required regression test alias**: Add (or alias) `test_perp_stop_order_is_rejected_preflight()` that asserts rejection both with and without trigger.  

**Reason**: C-1.4.4-PREFLIGHT-001  

S3.2 — Post‑only crossing guard  
Allowed paths: crates/soldier\_core/execution/post\_only\_guard.rs  
New/changed endpoints: none  
Acceptance criteria: If `post_only == true` and price crosses touch, reject preflight with `Rejected(PostOnlyWouldCross)` (deterministic).  
Explicit identifier: `post_only` is the venue flag (must not be renamed/aliased).  
Tests: crates/soldier\_core/tests/test\_post\_only\_guard.rs::test\_post\_only\_crossing\_rejected (AT-916; must assert Rejected(PostOnlyWouldCross))  
Evidence artifacts: artifacts/deribit\_testnet\_trade\_final\_20260103\_020002.log (F‑06)  
Rollout \+ rollback: core; revert only.  
Observability hooks: counter post\_only\_cross\_reject\_total.  
S3.3 — Capabilities matrix \+ feature flags  
Allowed paths: crates/soldier\_core/venue/capabilities.rs  
New/changed endpoints: none  
Acceptance criteria: linked/OCO impossible by default; only enabled with explicit feature flag \+ capability.  
Defaults (contract): `linked_orders_supported = false`; `ENABLE_LINKED_ORDERS_FOR_BOT = false` (fail-closed if missing).  
Tests: crates/soldier\_core/tests/test\_capabilities.rs::test\_oco\_not\_supported  
Evidence artifacts: none  
Rollout \+ rollback: compile/runtime flag.  
Observability hooks: none (configuration enforced).  
Slice 4 — Durable WAL \+ TLSM \+ Trade‑ID Registry  
Slice intent: Crash-safe truth source \+ panic-free lifecycle.

S4.1 — WAL append \+ replay no-resend  
Allowed paths: crates/soldier\_infra/store/ledger.rs  
New/changed endpoints: none  
Acceptance criteria: intent recorded before dispatch; replay reconstructs in-flight without resending.  
Contract path mapping: `soldier/infra/store/ledger.rs` ⇒ `crates/soldier\_infra/store/ledger.rs`.  
Tests: crates/soldier\_infra/tests/test\_ledger\_replay.rs::test\_ledger\_replay\_no\_resend\_after\_crash  
Evidence artifacts: none  
Rollout \+ rollback: creates local DB; rollback (dev-only) \= delete DB; production rollback \= revert binary (keep WAL).  
Observability hooks: histogram wal\_append\_latency\_ms; counter wal\_write\_errors\_total.  

**Persisted record schema (contract §2.4, minimum):**
WAL records MUST include at least: intent_hash, group_id, leg_idx, instrument, side, qty, limit_price, tls_state, created_ts, sent_ts, ack_ts, last_fill_ts, exchange_order_id (if known), last_trade_id (if known). Extra fields are allowed.
S4.2 — TLSM out‑of‑order events (fill-before-ack)  
Allowed paths: crates/soldier\_core/execution/state.rs, crates/soldier\_core/execution/tlsm.rs  
New/changed endpoints: none  
Acceptance criteria: never panics; converges to correct terminal state; WAL records transitions.  
Tests: crates/soldier\_core/tests/test\_tlsm.rs::test\_tlsm\_fill\_before\_ack\_no\_panic  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: counter tlsm\_out\_of\_order\_total.  
S4.3 — Trade‑ID registry dedupe  
Allowed paths: crates/soldier\_infra/store/trade\_id\_registry.rs  
New/changed endpoints: none  
Acceptance criteria: trade\_id appended first; duplicates NOOP across WS/REST.  
Tests: crates/soldier\_infra/tests/test\_trade\_id\_registry.rs::test\_trade\_id\_registry\_dedupes\_ws\_trade  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: counter trade\_id\_duplicates\_total.  

**Trade-ID mapping payload (contract §2.4, minimum):**
Persist mapping: trade_id -> { group_id, leg_idx, ts, qty, price } to support deterministic replay and audit.
S4.4 — Dispatch requires durable WAL barrier (when configured)  
Allowed paths: crates/soldier\_infra/store/ledger.rs, crates/soldier\_core/execution/\*\*  
New/changed endpoints: none  
Acceptance criteria: dispatch path blocks until durable marker when enabled.  
If WAL enqueue fails or WAL queue is full, OPEN dispatch is blocked, wal\_write\_errors increments, and the hot loop continues ticking (no stall) until enqueue succeeds.  
EvidenceChainState coupling is enforced in Phase 2 EvidenceGuard; Phase 1 enforces the OPEN block via dispatch authorization + wal\_write\_errors.  
Persistence levels (contract §2.4):  
- **RecordedBeforeDispatch** is mandatory for every dispatch (intent recorded before any API call).  
- **DurableBeforeDispatch** is required only when the durability barrier is configured/enabled.  
Tests:  
crates/soldier\_infra/tests/test\_dispatch\_durability.rs::test\_dispatch\_requires\_wal\_durable\_append  
crates/soldier\_infra/tests/test\_dispatch\_durability.rs::test\_open\_blocked\_when\_wal\_enqueue\_fails (AT-906)  
Evidence artifacts: none  
Rollout \+ rollback: config require\_wal\_fsync\_before\_dispatch controls DurableBeforeDispatch behavior; RecordedBeforeDispatch remains mandatory. Rollback \= config change (or revert commit), not a safety bypass.  
Observability hooks: histogram wal\_fsync\_latency\_ms.  
Slice 5 — Liquidity Gate \+ Fee Model \+ Net Edge \+ Gate Ordering \+ Pricer  
Slice intent: Deterministic reject/price logic before any order leaves the process.

S5.1 — Liquidity Gate (book-walk WAP, reject sweep)  
Allowed paths: crates/soldier\_core/execution/gate.rs  
New/changed endpoints: none  
Acceptance criteria: compute WAP & slippage\_bps; reject if exceeds `max_slippage_bps`; log WAP+slippage.  
If L2 snapshot is missing/unparseable/stale: reject OPEN with `Rejected(LiquidityGateNoL2)`; CANCEL-only allowed; CLOSE/HEDGE order placement rejected.  
Contract path mapping: `soldier/core/execution/gate` ⇒ `crates/soldier\_core/execution/gate.rs`.  
Tests:  
crates/soldier\_core/tests/test\_liquidity\_gate.rs::test\_liquidity\_gate\_rejects\_sweep  
crates/soldier\_core/tests/test\_liquidity\_gate.rs::test\_liquidity\_gate\_no\_l2\_blocks\_open (AT-344)  
crates/soldier\_core/tests/test\_liquidity\_gate.rs::test\_liquidity\_gate\_no\_l2\_reject\_reason (AT-909)  
crates/soldier\_core/tests/test\_liquidity\_gate.rs::test\_liquidity\_gate\_no\_l2\_blocks\_close\_hedge\_allows\_cancel (AT-421)  
Evidence artifacts: none  
Rollout \+ rollback: hot-path; no runtime disable. Rollback for Liquidity Gate logic \= revert commit only (contract safety gate).  
Observability hooks: histogram expected\_slippage\_bps; counter liquidity\_gate\_reject\_total.  

**Scope**: Liquidity Gate applies to OPEN intents (normal \+ rescue) and MUST NOT block emergency close paths.  
Does NOT apply to Deterministic Emergency Close (§3.1) or containment Step B; emergency close MUST NOT be blocked by profitability gates.  
Phase 1: document-only constraint; enforcement tests land in Phase 2 S7.3.  

S5.2 — Fee cache staleness (soft buffer / hard ReduceOnly latch)  
Allowed paths: crates/soldier\_infra/deribit/account\_summary.rs, crates/soldier\_core/strategy/fees.rs  
New/changed endpoints: none (uses Deribit private account summary)  
Acceptance criteria: soft stale \=\> fee buffer applied; hard stale \=\> RiskState::Degraded and OPENs blocked by Phase 1 dispatch authorization rule (PolicyGuard consumes later in Phase 2).  
Explicit identifiers: `fee_model_cache_age_s` (derived from epoch ms) and `fee_model_cached_at_ts_ms` (epoch ms).  
Default buffer (contract): `fee_stale_buffer = 0.20` in the soft-stale window.  
Tests:  
crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_cache\_soft\_buffer\_tightens  
crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_cache\_hard\_forces\_reduceonly  
crates/soldier\_core/tests/test\_fee\_cache.rs::test\_fee\_cache\_timestamp\_missing\_or\_unparseable\_forces\_degraded  
crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_soft\_stale\_applies\_buffer\_0\_20 (AT-032)  
crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_hard\_stale\_forces\_reduceonly (AT-033)  
crates/soldier\_core/tests/test\_fee\_cache.rs::test\_fee\_cache\_timestamp\_missing\_or\_unparseable\_forces\_reduceonly (AT-042)  
crates/soldier\_core/tests/test\_fee\_cache.rs::test\_fee\_cache\_fresh\_uses\_actual\_rates (AT-244)  
crates/soldier\_core/tests/test\_fee\_cache.rs::test\_fee\_tier\_change\_updates\_net\_edge\_within\_one\_cycle (AT-246)  
In Phase 1 these wrappers assert OPEN dispatch count == 0 via RiskState::Degraded; TradingMode assertions begin Phase 2.  
Evidence artifacts: none  
Rollout \+ rollback: rollback \= revert commit only; config may tighten polling/thresholds but MUST NOT loosen safety gates.  
Observability hooks: gauge fee\_model\_cache\_age\_s; counter fee\_model\_refresh\_fail\_total.  

**Contract-accurate staleness actions (§4.2):**
- Soft stale (age_s > fee_cache_soft_s && age_s <= fee_cache_hard_s): apply fee_stale_buffer multiplier; do not change RiskState.
- Hard stale (age_s > fee_cache_hard_s): set RiskState::Degraded; Phase 1 dispatch authorization blocks OPENs until refresh succeeds (PolicyGuard ReduceOnly begins in Phase 2).
- If fee_model_cached_at_ts_ms is missing/unparseable: treat as hard stale.

**PL-4 — Fee model polling explicit (contract §4.2):**

Fee model polling interval MUST be **every 60s**.

Rationale: staleness thresholds (fee_cache_soft_s / fee_cache_hard_s) are independent of polling cadence; polling slower than 60s violates §4.2.

Poll /private/get_account_summary for fee model inputs every 60s (contract §4.2) and store fee_model_cached_at_ts_ms.

Staleness arithmetic uses now_ms - fee_model_cached_at_ts_ms with soft/hard thresholds already listed.

**AT-031 (contract-required):** fee_model_cached_at_ts_ms MUST be epoch milliseconds (wall-clock), and staleness MUST compute correctly across process restart.

Add test: crates/soldier_core/tests/test_fee_cache.rs::test_fee_cache_epoch_ms_survives_restart (or alias implementing AT-031).

S5.3 — NetEdge gate  
Allowed paths: crates/soldier\_core/execution/gates.rs  
New/changed endpoints: none  
Acceptance criteria: reject if gross\_edge \- fee \- expected\_slippage \< min\_edge.  
If any of gross\_edge\_usd, fee\_usd, expected\_slippage\_usd, or min\_edge\_usd is missing/unparseable -> reject with `Rejected(NetEdgeInputMissing)`.  
Tests:  
crates/soldier\_core/tests/test\_net\_edge\_gate.rs::test\_net\_edge\_gate\_blocks\_when\_fees\_plus\_slippage  
crates/soldier\_core/tests/test\_net\_edge\_gate.rs::test\_net\_edge\_gate\_rejects\_low\_edge (AT-015)  
crates/soldier\_core/tests/test\_net\_edge\_gate.rs::test\_net\_edge\_gate\_rejects\_missing\_inputs (AT-932)  
crates/soldier\_core/tests/test\_net\_edge\_gate.rs::test\_net\_edge\_gate\_rejects\_when\_fees\_exceed\_gross\_edge (AT-243)  
Evidence artifacts: none  
Rollout \+ rollback: hot-path; rollback \= none (core safety).  
Observability hooks: counter net\_edge\_reject\_total.  

**Scope**: NetEdge gate applies to OPEN intents (normal + rescue) and MUST NOT block emergency close paths.  
Phase 1: document-only constraint; enforcement tests land in Phase 2 S7.3.  

**Required test alias**: Add/alias `test_net_edge_gate_rejects_low_edge()` (can wrap existing test_net_edge_gate_blocks_when_fees_plus_slippage).  
Tie to AT-015: `test_net_edge_gate_rejects_low_edge()` must assert `net_edge_usd < min_edge_usd` rejects OPEN.  

**Reason**: C-1.4.1-NETEDGE-001, C-8.2-TEST_SUITE-001  

S5.4 — IOC limit pricer clamp (guarantee min edge at limit)  
Allowed paths: crates/soldier\_core/execution/pricer.rs  
New/changed endpoints: none  
Acceptance criteria: clamp per contract; never “market-like”.  
Tests: crates/soldier\_core/tests/test\_pricer.rs::test\_pricer\_sets\_ioc\_limit\_with\_min\_edge  
Evidence artifacts: none  
Rollout \+ rollback: hot-path; rollback \= none (contract).  
Observability hooks: histogram pricer\_limit\_vs\_fair\_bps.  
S5.5 — Enforce single chokepoint build\_order\_intent() (gate ordering)  
Allowed paths: crates/soldier\_core/execution/build\_order\_intent.rs  
New/changed endpoints: none  
Acceptance criteria: ordering enforced and tested:  
preflight → quantize → fee\_cache → liquidity → net\_edge → (inventory/margin/pending added Phase 2\) → pricer → WAL append → dispatch  
Phase 1 Dispatch Authorization (Temporary, Conservative):  
If RiskState != Healthy, OPEN dispatch MUST be blocked at the chokepoint.  
CLOSE/HEDGE/CANCEL remain allowed (subject to existing gates).  
Tests:  
crates/soldier\_core/tests/test\_gate\_ordering.rs::test\_gate\_ordering\_call\_log  
crates/soldier\_core/tests/test\_phase1\_dispatch\_auth.rs::test\_phase1\_degraded\_blocks\_opens  
Evidence artifacts: none  
Rollout \+ rollback: make dispatch helpers pub(crate) so other modules cannot bypass; rollback requires code revert.  
Observability hooks: log GateSequence{steps,result}.  
F) Dependencies DAG (Phase 1\)  
S1.1 → S1.2 → S1.3  
S2.1 → S2.2 → S2.3 → S2.4  
S3.1 → S3.2 → S3.3  
S4.1 → S4.2 → S4.3 → S4.4  
S5.1 → S5.2 → S5.3 → S5.4 → S5.5  
Hard: S2.\* \+ S3.\* \+ S4.\* must exist before S5.5 is “complete”.  
G) De-scope line (Phase 1\)  
No multi-leg atomic execution, no PolicyGuard/Cortex, no endpoints, no replay/canary/F1 cert generation, no Parquet truth/attribution yet.  
