1\) Phase → Slice Mapping Table (contract-aligned)  
| Phase | Goal | Slices Included | Exit Criteria (objective/measurable) | Key Risks | |---|---|---|---|---| | Phase 1 — Foundation (Panic‑Free Deterministic Intents) | Deterministic intent construction: sizing invariants, quantization+idempotency, venue preflight, durable WAL/TLSM, and hard execution gates behind one chokepoint. | Slices 1–5 | (1) build\_order\_intent() gate ordering proven by test; (2) OPEN dispatch blocked when RiskState::Degraded (0 dispatches); (3) WAL replay proves “no resend after crash”; (4) Market/stop/linked/post-only-crossing are rejected preflight (tests); (5) Liquidity+NetEdge+Fee staleness fail-closed (tests). | Gate bypass via alternate codepaths; float/rounding drift; WAL durability miswired before dispatch. | | Phase 2 — Guardrails (Runtime Safety \+ Recovery) | Atomic containment \+ emergency close, risk budgets (inventory/pending/global/margin), PolicyGuard precedence incl F1 runtime gate, EvidenceGuard, Bunker Mode, plus rate-limit brownout, WS-gap recovery, reconcile, zombie sweep, and required owner endpoints. | Slices 6–9 | (1) Mixed-leg state always contains/neutralizes (tests); (2) PolicyGuard precedence enforces ReduceOnly/Kill correctly incl F1/Evidence/Bunker (tests); (3) 10028/429 behavior preserves emergency actions and blocks opens (tests); (4) New endpoints pass endpoint-level tests. | Recon races causing duplicates; rate limiter starving emergency close; “fail-open” gaps in PolicyGuard. | | Phase 3 — Data Loop (Evidence \+ Replay Inputs) | Produce the contract Evidence Chain: TruthCapsules \+ Decision Snapshots (required replay input) \+ Attribution \+ time drift gate; SVI validity; fill sim \+ slippage calibration. | Slices 10–12 | (1) Every dispatched leg links to truth\_capsule\_id \+ decision\_snapshot\_id; (2) EvidenceChainState RED blocks opens (tested); (3) Attribution completeness \= 100% (rows==fills); (4) Simulator deterministic; calibration converges. | Writer backpressure stalling hot loop; snapshot coverage gaps; join-key drift; time drift mismeasurement. | | Phase 4 — Live Fire Controls (Governance \+ Release Gates) | Replay Gatekeeper (Decision Snapshots required \+ realism penalty), canary rollout, reviews/incidents, retention/watermarks (Patch A semantics), and F1 cert (runtime \+ CI). | Slice 13 | (1) Replay hard-fails if snapshot\_coverage\_pct \< 95%; (2) Canary auto-rollbacks on abort conditions; (3) Disk watermarks enforce: 80% pause full archives only, 85% ReduceOnly, 92% Kill; (4) artifacts/F1\_CERT.json PASS is required for opens (runtime). | False confidence from wrong replay inputs; aggressive patch applied without human approval; watermark logic incorrectly forces Degraded at 80% (must not). |

Global Non‑Negotiables (apply to ALL stories)  
Minimum Alert Set (contract): configure/emit alerts for: atomic_naked_events>0; 429_count>0; policy_age_sec>300; decision_snapshot_write_errors>0; truth_capsule_write_errors>0; parquet_queue_overflow_count>0; evidence_guard_blocked_opens_count>0.  

**Metric name parity (contract-required):**

Where the plan uses Prometheus-style *_total counters, we MUST ALSO expose exact contract metric names OR define 1:1 aliases/recording rules and document them here.

Required exact names (contract):
  atomic_naked_events
  429_count
  truth_capsule_write_errors
  decision_snapshot_write_errors
  wal_write_errors
  parquet_write_errors
  parquet_queue_overflow_count
  evidence_guard_blocked_opens_count
  policy_age_sec

EvidenceGuard logic MUST consume the contract names (or their documented 1:1 aliases), not ad-hoc *_total names.

**Ops deliverables (contract §7 Must-use now):**

- Provide Grafana dashboard(s) for: trading_mode, risk_state, evidence_chain_state, parquet_queue_depth_pct, disk_used_pct, mm_util, ws_event_lag_ms.
- Provide Prometheus alert rules for the Minimum Alert Set in the contract.
- Provide a DuckDB query/playbook to inspect Parquet evidence artifacts and reproduce key release metrics.
- Document chrony/NTP requirement and add an operational health check step in runbooks (time drift gate depends on it).

Deribit Venue Facts Addendum: all VERIFIED facts are enforced with artifacts under `artifacts/`, and `python scripts/check_vq_evidence.py` must pass (fail build if not).  

**Plan Parity (Contract Coverage):**
- PolicyGuard precedence, staleness, watchdog kill, critical inputs -> S8.1 + PL-3
- EvidenceGuard GREEN criteria, Degraded, hot-path block -> S8.3
- Rate-limit circuit breaker (local limiter, 429, 10028) -> S9.1 + S9.2
- Kill mode containment rules -> PL-3b
- OpenPermission latch + emergency reduce-only + watchdog trigger -> S9.4 + S8.7
- Execution gate ordering + inventory skew ordering/delta_limit fail-closed -> S5.x + S6.1
- Fee cache staleness + time drift + SVI trip counts -> S5.2 + S10.5 + S11.1
- WAL + trade-id registry -> S4.1 + S4.3



WIP=1: exactly one Story (S{slice}.{n}) in-flight at a time; each Story lands with code \+ tests \+ required artifacts listed up front.  
Fail‑closed: any safety/evidence ambiguity blocks opens (ReduceOnly), never relaxes gates.  
Contract is the single source of truth; the plan MUST NOT weaken contract gates.  
No strategy edits are allowed until spec-lint passes with 0 FAIL (PR rule).  
No runtime bypass switches: contract safety gates MUST NOT be disable-able via runtime flags in production. Rollback for safety logic = revert commit (not “turn gate off”).  
Plan extras must be labeled SAFE_EXTRA or RISKY_EXTRA; this plan currently contains no extras (contract-required items only).  
New endpoint ⇒ endpoint-level test (at least one) in the Story plan.  
Single chokepoint: all order construction routes through crates/soldier\_core/execution/build\_order\_intent.rs::build\_order\_intent().  
Phase 1 Dispatch Authorization Rule (Temporary):  
1\) Every network dispatch attempt MUST go through build\_order\_intent() (single chokepoint).  
2\) If RiskState != Healthy OR any hard gate fails (WAL enqueue failure, label invalid, stale critical input already modeled in Phase 1), then OPEN dispatch MUST be blocked (dispatch count remains 0).  
3\) CLOSE/HEDGE/CANCEL MAY still dispatch (unless separately blocked by existing Phase 1 rules).  
PolicyGuard-derived TradingMode enforcement begins in Phase 2 (Slice 8\); this temporary rule is superseded by PolicyGuard's full precedence ladder.  
2\) Per‑Phase Plans (A–G)  
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
PHASE 2 — Guardrails (Slices 6–9)  
A) Phase Objective  
Implement runtime containment and safety enforcement: inventory/pending/global exposure gates, margin headroom, AtomicGroup execution with bounded rescue and deterministic emergency close, plus PolicyGuard precedence including runtime F1 certification gate, EvidenceGuard, and Bunker Mode. Add resilience (rate limiting \+ WS gaps \+ reconciliation \+ zombie sweeps) and required owner control-plane endpoints.

B) Constraint (TOC)  
Bottleneck: “Messy reality” (partials, outages, jitter, throttling) causing naked risk.  
Relief: bounded containment \+ priority rate limiting \+ OpenPermission latch \+ PolicyGuard as single authoritative mode resolver.

C) Entry Criteria  
Phase 1 exit criteria met.  
Minimal hot loop exists that can call PolicyGuard each tick.  
REST/WS stubs or integration harness for gap/10028 tests.  
D) Exit Criteria  
Mixed-state containment always reaches neutralization path within bounds (tests).  
PolicyGuard tests cover F1 missing/stale/fail; Evidence RED; bunker mode; maintenance.  
Endpoints /api/v1/status, /api/v1/health, and /api/v1/emergency/reduce\_only have endpoint-level tests.  
E) Slices Breakdown (Phase 2\)  
Slice 6 — Inventory Skew \+ Pending Exposure \+ Global Budget \+ Margin Gate  
Slice intent: prevent risk-budget double spend and liquidation.

S6.1 — Inventory skew gate  
Allowed paths: crates/soldier\_core/execution/inventory\_skew.rs  
Endpoints: none  
Acceptance criteria: tightens only for risk-increasing, may relax only for risk-reducing.  
Inputs (contract): `current_delta`, `delta_limit`, `side`, `min_edge_usd`, `limit_price`, `fair_price`.  
`delta_limit` MUST be provided by policy/config; missing ⇒ reject OPEN intents (fail-closed).  
Inventory Skew must compute using current + pending exposure, or run after PendingExposure reservation.  
Tests: crates/soldier\_core/tests/test\_inventory\_skew.rs::test\_inventory\_skew\_rejects\_risk\_increasing\_near\_limit  
Evidence artifacts: none  
Rollout/rollback: hot-path; no runtime disable. Rollback for Inventory Skew Gate logic \= revert commit only (contract safety gate).  
Observability: inventory_skew_adjust_total{dir}, gauge inventory_bias.  

**AT-030 (contract-required):**

When inventory_skew_bias == 1.0, the inventory skew gate MUST apply exactly inventory_skew_tick_penalty_max (default 3 ticks) to risk-increasing OPEN pricing.

Add test: crates/soldier_core/tests/test_inventory_skew.rs::test_inventory_skew_tick_penalty_max_is_exactly_3_ticks_at_bias_1_0 (AT-030).

**Ordering + failure semantics (contract §1.4.2):**
- InventorySkew MUST run after NetEdge Gate and before IOC limit pricer.
- If InventorySkew adjusts min_edge_usd, NetEdge MUST be re-evaluated with the adjusted value before dispatch.
- InventorySkew MUST use current+pending exposure (or run after Pending Exposure Reservation).
- If delta_limit is missing for the instrument: reject OPEN intent and set RiskState::Degraded (AT-043).


S6.2 — Pending exposure reservation  
Allowed paths: crates/soldier\_core/risk/pending\_exposure.rs  
Endpoints: none  
Acceptance criteria: reserve before dispatch; release on terminal TLSM; concurrent opens cannot overfill.  
Tests: crates/soldier\_core/tests/test\_pending\_exposure.rs::test\_pending\_exposure\_reservation\_blocks\_overfill  
Rollout/rollback: hot-path; no runtime disable. Rollback for Pending Exposure Reservation logic \= revert commit only (contract safety gate).  
Observability: gauge pending\_delta, counter pending\_reserve\_reject\_total.  
S6.3 — Global exposure budget (corr buckets)  
Allowed paths: crates/soldier\_core/risk/exposure\_budget.rs  
Acceptance criteria: correlation-aware; uses current+pending.  
Contract integration rule: Global Budget MUST be checked using current + pending exposure (no current-only).  
Tests: crates/soldier\_core/tests/test\_exposure\_budget.rs::test\_global\_exposure\_budget\_correlation\_rejects  
Observability: gauge portfolio\_delta\_usd, counter portfolio\_budget\_reject\_total.  
S6.4 — Margin headroom gate  
Allowed paths: crates/soldier\_core/risk/margin\_gate.rs  
Acceptance criteria: 70% reject opens; 85% ReduceOnly; 95% Kill.  
Contract defaults: `mm_util_reduceonly = 0.85` (ReduceOnly allows CLOSE/HEDGE/CANCEL), `mm_util_kill = 0.95`.  
Contract detail: if `mm_util >= mm_util_kill` (default 0.95) ⇒ PolicyGuard MUST force Kill and trigger deterministic emergency flatten (per §3.1) when eligible.  
Tests: crates/soldier\_core/tests/test\_margin\_gate.rs::test\_margin\_gate\_thresholds\_block\_reduceonly\_kill  
Observability: gauge mm\_util, counter margin\_gate\_trip\_total{level}.  
Slice 7 — Atomic Group Executor \+ Emergency Close \+ Sequencer \+ Churn Breaker  
Slice intent: runtime atomicity: bounded rescue then deterministic flatten/hedge fallback.

S7.1 — Group state machine \+ first-fail invariant  
Allowed paths: crates/soldier\_core/execution/{group.rs,atomic\_group\_executor.rs}  
Acceptance criteria: cannot mark Complete until safe; first failure seeds MixedFailed.  
First observed failure (reject/cancel/unfilled/partial mismatch) MUST seed MixedFailed and MUST NOT be overwritten by later async updates.  
Tests: crates/soldier\_core/tests/test\_atomic\_group.rs::test\_atomic\_group\_mixed\_failed\_then\_flattened  
Add test: crates/soldier\_core/tests/test\_atomic\_group.rs::test\_mixed\_failed\_blocks\_opens\_until\_neutral (AT-116)  
Rollout/rollback: staged rollout behind config ENABLE\_ATOMIC\_GROUPS. MUST be enabled before any multi-leg strategy is allowed to trade. Rollback \= revert commit (do not disable as a live “bypass”).  
Observability: counter atomic\_group\_state\_total{state}.  
S7.2 — Bounded rescue (≤2) and no chase loop  
Allowed paths: crates/soldier\_core/execution/atomic\_group\_executor.rs  
Acceptance criteria: max 2 rescue IOC attempts; then flatten.  
Tests: crates/soldier\_core/tests/test\_atomic\_group.rs::test\_atomic\_rescue\_attempts\_limited\_to\_two (AT-117)  
Observability: histogram atomic\_rescue\_attempts.  
S7.3 — Deterministic emergency close \+ hedge fallback  
Allowed paths: crates/soldier\_core/execution/emergency\_close.rs  
Acceptance criteria: 3 tries IOC close; then reduce-only delta hedge; logs AtomicNakedEvent; TradingMode is ReduceOnly during exposure.  
Tests:  
crates/soldier\_core/tests/test\_emergency\_close.rs::test\_emergency\_close\_fallback\_hedge\_after\_retries  
crates/soldier\_core/tests/test\_emergency\_close.rs::test\_emergency\_close\_bypasses\_liquidity\_gate  
crates/soldier\_core/tests/test\_emergency\_close.rs::test\_emergency\_close\_bypasses\_net\_edge\_gate  
Hot-path rollback: caps configurable (close\_max\_attempts, hedge cap) but must remain fail-closed.  
Observability: histogram time\_to\_delta\_neutral\_ms, counter atomic\_naked\_events\_total.  

**Retry pricing rule**: `close_buffer_ticks = 5` on first attempt; on each retry buffer doubles (5 → 10 → 20); max 3 attempts.  

**Containment wiring**: Atomic containment must call this exact emergency close implementation (no separate logic).  

**Required test alias**: Add `test_atomic_containment_calls_emergency_close_algorithm_with_hedge_fallback()`.  

**Reason**: C-3.1-EMERGENCY_CLOSE-001, C-8.2-TEST_SUITE-001  

**PL-3b — Kill Mode Semantics + containment eligibility micro-loop (contract §2.2.3):**

Implement contract §2.2.3 Kill Mode Semantics:

KILL_DISK_FULL: NO containment allowed; NO dispatch at all.

KILL_MARGIN_UTIL: MUST attempt emergency containment only if ALL eligibility predicates are satisfied; otherwise hard-stop.

**Containment Eligibility Predicates (authoritative):**
1. `disk_used_pct < 92%` (not in disk Kill)
2. `EvidenceChainState == GREEN` AND WAL writes are succeeding
3. Session is healthy (`rate_limit_session_kill_active == false`)
4. `bunker_mode_active == false` (Network Jitter Monitor not active)

Containment actions are limited to:
- Cancel only reduce_only == false orders.
- Place only risk-reducing orders (EmergencyClose IOC or reduce-only hedges); no opens.

Micro-loop must be bounded (max 3 attempts; max 2s total) and must exit to Kill hard-stop.

Add tests for eligibility (eligible vs ineligible) and for the disk kill hard-stop overriding containment.

**Required explicit tests:**
- `test_kill_margin_util_runs_containment_only_when_eligible()` — All 4 predicates satisfied → containment allowed
- `test_kill_margin_util_hard_stops_when_ineligible_due_to_evidence_or_wal()` — Any predicate false → hard-stop
- `test_kill_disk_full_forbids_all_dispatch_including_close_hedge_cancel()` — Disk ≥92% → NO dispatch at all
- `test_kill_margin_util_hard_stops_when_bunker_mode_active()` — bunker_mode_active==true → hard-stop (AT-013)



S7.4 — Sequencer ordering rules  
Allowed paths: crates/soldier\_core/execution/sequencer.rs  
Acceptance criteria: close→confirm→hedge.  
Repair path: flatten filled legs first via emergency\_close\_algorithm; hedge only after flatten retries fail and exposure remains above limit.  
Never increase exposure while RiskState != Healthy (includes Degraded/Maintenance/Kill).  
Tests:  
crates/soldier\_core/tests/test\_sequencer.rs::test\_sequencer\_close\_then\_hedge\_ordering  
crates/soldier\_core/tests/test\_sequencer.rs::test\_sequencer\_blocks\_exposure\_increase\_when\_riskstate\_not\_healthy  
crates/soldier\_core/tests/test\_sequencer.rs::test\_sequencer\_repair\_flattens\_before\_hedge  
Observability: counter sequencer\_order\_violation\_total.  
S7.5 — Churn breaker  
Allowed paths: crates/soldier\_core/risk/churn\_breaker.rs  
Acceptance criteria: \>2 flattens/5m \=\> 15m blacklist blocks opens for that key.  
Tests: crates/soldier\_core/tests/test\_churn\_breaker.rs::test\_churn\_breaker\_blacklists\_after\_three  
Observability: counter churn\_breaker\_trip\_total.  
Slice 8 — PolicyGuard \+ Cortex \+ Exchange Health \+ Bunker/Evidence/F1 \+ Owner Endpoints (Patch D)  
Slice intent: one authoritative mode resolver \+ required read-only status endpoint.

S8.1 — PolicyGuard precedence \+ staleness handling  
Implement PolicyGuard Critical Input Freshness (contract §2.2.1.1): if mm_util or disk_used_pct is missing OR (now_ms - *_last_update_ts_ms) > max_age_ms then TradingMode MUST be ReduceOnly and ModeReasonCode MUST include REDUCEONLY_INPUT_MISSING_OR_STALE.  
Add test: test_policyguard_reduceonly_when_mm_util_stale_over_max_age.  
Allowed paths: crates/soldier\_core/policy/guard.rs  
Acceptance criteria: recompute each tick; stale policy \=\> ReduceOnly.  
Critical inputs (contract): `mm_util` with `mm_util_last_update_ts_ms`, `disk_used_pct` with `disk_used_last_update_ts_ms`, `rate_limit_session_kill_active`, `watchdog_last_heartbeat_ts_ms`. Missing/unparseable ⇒ ReduceOnly with `REDUCEONLY_INPUT_MISSING_OR_STALE`.  
Freshness defaults (contract): `mm_util_max_age_ms = 30_000`, `disk_used_max_age_ms = 30_000`.  
PolicyGuard MUST compute TradingMode via `get_effective_mode()` each loop tick (no stored authoritative mode).  
Policy staleness MUST use Commander time: policy\_age\_sec = (now\_ms - python\_policy\_generated\_ts\_ms) / 1000; do not use local receive timestamp.  
Hard rule (contract §2.2.3): policy\_age\_sec MUST be computed as floor((now\_ms - python\_policy\_generated\_ts\_ms)/1000).  
Gate: if policy\_age\_sec > max\_policy\_age\_sec (default 300) => PolicyGuard MUST force ReduceOnly.  
Boundary: policy\_age\_sec == 300 MUST NOT trip; policy\_age\_sec == 301 MUST trip.  
Session termination / rate-limit kill flag must be explicit (no "unknown treated as false"); if missing, treat as critical input missing and force ReduceOnly with REDUCEONLY\_INPUT\_MISSING\_OR\_STALE.  
Tests:  
crates/soldier\_core/tests/test\_policy\_guard.rs::test\_policy\_guard\_late\_policy\_update\_stays\_reduceonly  
crates/soldier\_core/tests/test\_policy\_guard.rs::test\_policy\_guard\_override\_priority  
crates/soldier\_core/tests/test\_policy\_freshness.rs::test\_policy\_age\_sec\_boundary\_300\_no\_trip  
crates/soldier\_core/tests/test\_policy\_freshness.rs::test\_policy\_age\_sec\_301\_trips\_reduceonly  
crates/soldier\_core/tests/test\_policy\_freshness.rs::test\_max\_policy\_age\_sec\_forces\_reduceonly\_after\_300s  
crates/soldier\_core/tests/test\_policy\_guard.rs::test\_mm\_util\_stale\_forces\_reduceonly\_input\_missing\_or\_stale (AT-001)  
crates/soldier\_core/tests/test\_policy\_guard.rs::test\_missing\_watchdog\_heartbeat\_forces\_reduceonly\_input\_missing\_or\_stale (AT-112)  
Observability: gauge policy\_age\_sec, counter policy\_stale\_reduceonly\_total.  

**PL-3 — PolicyGuard full precedence ladder + ModeReasonCode determinism:**

Implement full canonical precedence ladder per contract §2.2.3 (all Kill triggers and all ReduceOnly triggers) and ensure deterministically ordered mode_reasons (no mixing tiers).

Add tests covering precedence across: disk_kill, mm_util_kill, session_kill(10028), evidence_chain_state != GREEN, open_permission_blocked_latch, bunker mode, F1 missing/stale/fail, fee model hard-stale.
Margin thresholds (contract): `mm_util_reject = 0.70`, `mm_util_reduceonly = 0.85`, `mm_util_kill = 0.95` must map to Reject/ReduceOnly/Kill respectively (CLOSE/HEDGE/CANCEL allowed in ReduceOnly).  
Explicit Kill reasons (contract):  
- `KILL_DISK_WATERMARK_KILL` when `disk_used_pct >= 0.92` ⇒ containment forbidden; no dispatch including CLOSE/HEDGE/CANCEL.  
- `KILL_RATE_LIMIT_SESSION_TERMINATION` on 10028/session termination ⇒ containment forbidden.  

**Watchdog heartbeat kill semantics (contract §2.2.3):**
- Add PolicyGuard input: watchdog_last_heartbeat_ts_ms (epoch ms).
- Trigger: if now_ms - watchdog_last_heartbeat_ts_ms > watchdog_kill_s*1000 ⇒ TradingMode::Kill with mode_reasons = [KILL_WATCHDOG_HEARTBEAT_STALE].
- Containment is forbidden under KILL_WATCHDOG_HEARTBEAT_STALE (hard-stop cause).
- Add test: test_watchdog_kill_s_triggers_kill_after_10s_no_health_report().

S8.2 — Runtime F1 gate (HARD): artifacts/F1\_CERT.json  
Binding enforcement (contract v5.1): Runtime MUST treat F1_CERT as INVALID and force ReduceOnly if contract_version in F1_CERT != runtime contract_version (and include as ModeReasonCode).  
Add tests (exact names): test_f1_cert_binding_mismatch_forces_reduceonly, test_f1_cert_no_cache_last_known_good.  
Allowed paths: crates/soldier\_core/policy/guard.rs  
Acceptance criteria: missing/stale/FAIL \=\> ReduceOnly; no grace; no caching last-known-good.  
Explicit identifier: `artifacts/F1_CERT.json` (a.k.a. `f1_cert`); missing/unparseable is a hard ReduceOnly.  
Tests:  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_missing\_forces\_reduceonly  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_fail\_forces\_reduceonly  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_stale\_forces\_reduceonly  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_binding\_mismatch\_forces\_reduceonly (AT-020)  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_no\_last\_known\_good\_bypass (AT-021)  
Evidence artifacts: test fixture crates/soldier\_core/tests/fixtures/F1\_CERT.json  
Observability: gauge f1\_cert\_age\_s, counter f1\_cert\_gate\_block\_opens\_total.  

**PL-2 — Complete F1_CERT binding + canonical runtime_config_hash + MUST NOT gate on policy_hash_at_cert_time:**

Runtime MUST treat F1_CERT as INVALID (ReduceOnly) if any of: build_id, runtime_config_hash, or contract_version differs from runtime.

Define runtime_config_hash = sha256(canonical_json_bytes(runtime_config)) with stable key ordering and no whitespace; UTF-8 bytes.

If F1_CERT contains policy_hash_at_cert_time, it is observability only and MUST NOT be used for runtime validity gating.

Extend test_f1_cert_binding_mismatch_forces_reduceonly to include mismatch cases for build_id and runtime_config_hash.

Add: test_f1_cert_policy_hash_at_cert_time_is_ignored_for_validity().

**AT-012 (contract-required):**

Define runtime contract_version literal as numeric-only (e.g., "5.1"; no "v" prefix, no codename).

Add test: crates/soldier_core/tests/test_f1_gate.rs::test_contract_version_format_numeric_only_rejects_v_prefix (AT-012).



S8.3 — EvidenceGuard (Patch B) enforcement + cooldown  
Encode contract thresholds/hysteresis (strict comparators per contract §2.2.2): trip when parquet_queue_depth_pct > 0.90 for ≥5s; clear only when <0.70 for ≥120s AND after evidenceguard_global_cooldown.  
Explicit windows: `evidenceguard_window_s = 60` (default), `queue_clear_window_s = 120` (default).  

**IMPLEMENTATION GUARDRAIL:** The comparator is strict `> 0.90` (NOT `>= 0.90`). Any implementation using `>=` is non-compliant and MUST be rejected in code review.

**Required boundary test:** Add `test_parquet_queue_trip_comparator_is_strict_gt_not_gte()` — verify that `parquet_queue_depth_pct == 0.90` does NOT trip; `0.9001` trips after ≥5s.

Missing required metric values (queue depth / write error counters) MUST be treated as Evidence RED (fail-closed).  
Add test: test_evidence_guard_queue_depth_missing_fails_closed.  
Allowed paths:  
crates/soldier\_core/policy/guard.rs  
crates/soldier\_core/analytics/evidence\_chain\_state.rs  
Acceptance criteria: evidence chain not GREEN \=\> ReduceOnly; CLOSE/HEDGE/CANCEL allowed; cooldown after recovery.  
EvidenceChainState GREEN must be computed over evidenceguard_window_s (default 60s) rolling window and requires all of:  
- truth_capsule_write_errors == 0  
- decision_snapshot_write_errors == 0  
- wal_write_errors == 0  
- parquet_queue_overflow_count not increasing  
- parquet_queue_depth_pct defined and below thresholds (missing metrics fail-closed)  
On EvidenceChainState != GREEN: set RiskState::Degraded in addition to PolicyGuard ReduceOnly.  
Tests:  
crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_evidence\_guard\_blocks\_opens\_allows\_closes  
crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_evidence\_guard\_cooldown\_after\_recovery  
crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_evidenceguard\_window\_boundary\_60s (AT-105)  
crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_wal\_write\_errors\_force\_not\_green (AT-107)  
Observability: gauge evidence\_chain\_state, counter evidence\_guard\_blocked\_opens\_total.  

**Erratum (contract wins)**: EvidenceGuard trip comparator is **strict**: trip occurs only when `parquet_queue_depth_pct > 0.90` (not >= 0.90) for >= 5s.  

**Hot‑path enforcement REQUIRED**: In `build_order_intent()` (or the last pre-dispatch gate), if intent kind is OPEN and `EvidenceChainState != GREEN`, the intent MUST be rejected before WAL append and before any API call.  
PolicyGuard `get_effective_mode()` MUST include EvidenceGuard in precedence ordering.  

**Metric name alignment**: Ensure emitted metrics include the contract alert names (or 1:1 aliases) for `parquet_queue_overflow_count` and `evidence_guard_blocked_opens_count`.  

**Reason**: C-2.2.2-EVIDENCE_GUARD-001, C-7.EXT-ALERTS-001  

**PL-1 — EvidenceGuard strict threshold + required metrics + AT-005:**

**Contract requirement (contract §2.2.2):** Implement strict trip only when parquet_queue_depth_pct > 0.90 continuously for ≥5s; clear only when < 0.70 continuously for ≥120s.

**Required metric names (1:1):**
Emit gauges (exact names): parquet_queue_depth (count), parquet_queue_capacity (count). Derived: parquet_queue_depth_pct = parquet_queue_depth / max(parquet_queue_capacity, 1).

Emit counters (exact names or 1:1 aliases): parquet_queue_overflow_count, evidence_guard_blocked_opens_count.

**AT-005 (non-fill attribution exception):**
AT-005 rule (contract-required): An OPEN intent with zero fills MUST NOT require an attribution row and MUST NOT flip EvidenceChainState to not-GREEN solely due to missing attribution.

Add test (exact): crates/soldier_core/tests/test_evidence_guard.rs::test_evidence_guard_non_fill_does_not_require_attribution (or alias to the contract's AT-005).

**Boundary test for strictness:**
Add boundary test: verify parquet_queue_depth_pct == 0.90 does not trip; 0.9001 trips after ≥5s.


S8.4 — Bunker Mode network jitter monitor (Patch C)  
Allowed paths: crates/soldier\_core/risk/network\_jitter.rs, crates/soldier\_core/policy/guard.rs  
Acceptance criteria: jitter thresholds \=\> ReduceOnly; stable cooldown required to exit.  
Fail-closed metric rule (contract): if `ws_event_lag_ms` is missing/uncomputable, set `bunker_mode_active = true` and block OPENs (AT-205).  
Tests:  
crates/soldier\_core/tests/test\_bunker\_mode.rs::test\_ws\_event\_lag\_breach\_blocks\_opens  
crates/soldier\_core/tests/test\_bunker\_mode.rs::test\_bunker\_mode\_cooldown\_then\_exit  
crates/soldier\_core/tests/test\_bunker\_mode.rs::test\_bunker\_mode\_exit\_after\_stable\_window (AT-115)  
crates/soldier\_core/tests/test\_bunker\_mode.rs::test\_bunker\_mode\_http\_p95\_three\_consecutive\_breaches (AT-345)  
Observability: gauge ws\_event\_lag\_ms, deribit\_http\_p95\_ms, counter bunker\_mode\_trip\_total.  

**Thresholds (contract-fixed)**:  
- Enter ReduceOnly if `http_p95_ms > 750` for 3 consecutive windows OR `ws_event_lag_ms > 2000` OR `request_timeout_rate > 0.02`.  
- Exit only after 120s stable below thresholds.  
- Add boundary tests for each threshold comparator.  

**Reason**: C-2.3.2-BUNKER-001  

S8.5 — Cortex enforcement  
Allowed paths: crates/soldier\_core/reflex/cortex.rs  
Acceptance criteria: DVOL/spread/depth shocks \=\> ReduceOnly; WS gap blocks risk-increasing cancel/replace.  
Tests: crates/soldier\_core/tests/test\_cortex.rs::test\_cortex\_dvol\_spike\_force\_reduceonly  
Add test: crates/soldier\_core/tests/test\_cortex.rs::test\_ws\_gap\_blocks\_risk\_increasing\_cancel\_replace (AT-119).  
Add test: crates/soldier\_core/tests/test\_cortex.rs::test\_cortex\_force\_kill\_on\_spread\_or\_depth (AT-045).  
Observability: counter `cortex_override_total{kind}`.  

**Make thresholds explicit**: DVOL jump uses `dvol_jump_pct >= 0.10` within `dvol_jump_window_s <= 60`; spread and depth use `spread_max_bps` and `depth_min`.  

**Required test aliases**: Add/alias:  
- `test_cortex_spread_max_bps_forces_reduceonly()`  
- `test_cortex_depth_min_forces_reduceonly()`  

**Reason**: C-2.3-CORTEX-001, C-8.2-TEST_SUITE-001  

**Risk-increasing cancel/replace definition (contract §2.3):**
Risk-increasing cancel/replace means any cancel/replace that increases absolute net exposure, increases exposure in the current risk direction, or removes reduce_only protection on a closing/hedging order. When ws_gap_flag==true, block these at the single chokepoint; allow risk-reducing cancels/replaces and closes.

S8.6 — Exchange maintenance monitor  
Allowed paths: crates/soldier\_core/risk/exchange\_health.rs  
Acceptance criteria: maint within 60m \=\> set RiskState::Maintenance; PolicyGuard forces ReduceOnly; /api/v1/status reports risk_state=Maintenance; opens blocked.  
Fail-closed handling (contract): if `/public/get_announcements` unreachable/invalid for `exchange_health_stale_s` (default 180s), set `cortex_override = ForceReduceOnly` and block OPENs (AT-204).  
Tests: crates/soldier\_core/tests/test\_exchange\_health.rs::test\_exchange\_health\_maintenance\_blocks\_opens  
Add test: crates/soldier\_core/tests/test\_exchange\_health.rs::test\_exchange\_health\_stale\_announcements\_force\_reduceonly (AT-204).  
S8.7 — Endpoint: POST /api/v1/emergency/reduce\_only (existing plan)  
Allowed paths: crates/soldier\_infra/http/\*\*, crates/soldier\_core/policy/watchdog.rs  
New/changed endpoints: POST /api/v1/emergency/reduce\_only  
Required endpoint-level tests: yes  
Acceptance criteria: flips to ReduceOnly; cancels only non-reduce-only opens; preserves closes/hedges.  
Tests: crates/soldier\_infra/tests/test\_http\_emergency.rs::test\_post\_emergency\_reduce\_only\_endpoint  
Observability: counter http\_emergency\_reduce\_only\_calls\_total.  

**Emergency reduce-only cooldown semantics (contract §2.2/§3.2):**
- Track emergency_reduceonly_until_ts_ms = now_ms + emergency_reduceonly_cooldown_s*1000 on POST.
- PolicyGuard treats emergency_reduceonly_active = (now_ms < emergency_reduceonly_until_ts_ms).
- While active: cancel reduce_only==false orders; preserve reduce_only closes/hedges; if exposure breaches limit, submit reduce-only hedge.
- Request fields like {reason, invoked_by, ts} are optional and used for observability only.
- Clear condition: cooldown expiry AND reconciliation confirms exposure is safe when reconciliation is required by the trigger (for example, open\_permission\_requires\_reconcile == true).

**Smart Watchdog trigger (contract §3.2):**
- If ws\_silence\_ms > 5000, invoke the same handler as POST /api/v1/emergency/reduce\_only (do not duplicate logic).
- Add test: test\_watchdog\_silence\_over\_5s\_calls\_emergency\_reduceonly\_handler().
S8.8 — Owner endpoint: GET /api/v1/status (Patch D)  
Add wrapper test with exact required name: test_status_endpoint_returns_required_fields() asserting all required keys exist.  
Allowed paths: crates/soldier\_infra/http/{router.rs,status.rs} and read-only state accessors  
New endpoint: GET /api/v1/status  
Required endpoint-level tests: yes  
Acceptance criteria: HTTP 200 JSON includes keys (contract §7.0):  
- status\_schema\_version (int; current=1)  
- trading\_mode, risk\_state, evidence\_chain\_state, bunker\_mode\_active  
- connectivity\_degraded (true iff bunker_mode_active or any reconcile-required open-permission code present)  
- policy\_age\_sec, last\_policy\_update\_ts (epoch ms; MUST equal python\_policy\_generated\_ts\_ms)  
- f1\_cert\_state, f1\_cert\_expires\_at  
- disk\_used\_pct, disk\_used\_last\_update\_ts\_ms  
- mm\_util, mm\_util\_last\_update\_ts\_ms  
- snapshot\_coverage\_pct (MUST be computed over replay\_window\_hours)  
- atomic\_naked\_events\_24h, 429\_count\_5m  
- deribit\_http\_p95\_ms, ws\_event\_lag\_ms  
- mode\_reasons (ModeReasonCode[]; MUST be [] iff trading\_mode==Active)  
- open\_permission\_blocked\_latch (bool)  
- open\_permission\_reason\_codes (OpenPermissionReasonCode[]; MUST be [] iff latch==false)  
- open\_permission\_requires\_reconcile (bool; MUST equal open\_permission\_blocked\_latch for v5.1)  
Tests (endpoint-level \+ semantic invariants):  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_endpoint\_returns\_required\_fields  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_mode\_reasons\_empty\_iff\_active  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_mode\_reasons\_tier\_purity\_and\_ordering  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_open\_permission\_latch\_invariants  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_policy\_timestamp\_consistency  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_snapshot\_coverage\_pct\_uses\_replay\_window\_hours  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_schema\_version\_is\_1 (AT-405)  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_includes\_all\_required\_fields (AT-023)  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_mode\_reasons\_empty\_iff\_active (AT-024)  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_mode\_reasons\_tier\_purity\_and\_ordering (AT-025, AT-026)  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_open\_permission\_latch\_invariants (AT-027)  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_policy\_timestamp\_consistency (AT-028)  
crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_snapshot\_coverage\_pct\_uses\_replay\_window\_hours (AT-029)  
Observability: counter http\_status\_calls\_total.  

**PL-5 — /status f1_cert_expires_at semantics + endpoint-level test:**

**Contract requirement (contract §7.0 / AT-003):**

f1_cert_expires_at MUST be computed for **any F1_CERT that is present and parseable**:

  f1_cert_expires_at = f1_cert.generated_ts_ms + (f1_cert_freshness_window_s * 1000)

This MUST NOT depend on f1_cert_state (PASS/FAIL/STALE/INVALID).

f1_cert_expires_at may be null ONLY when F1_CERT is missing or unparseable.

Add test (AT-003): crates/soldier_core/tests/test_status_endpoint.rs::test_status_endpoint_f1_cert_expires_at_matches_generated_plus_window

Include cases for PASS, FAIL, STALE, INVALID with parseable cert.

S8.9 — Owner endpoint: GET /api/v1/health (minimal, read-only)  
Add wrapper test with exact required name: test_health_endpoint_returns_minimal_payload() calling existing health endpoint assertions.  
Allowed paths: crates/soldier\_infra/http/{router.rs,health.rs}  
New endpoint: GET /api/v1/health  
Required endpoint-level tests: yes  
Acceptance criteria: HTTP 200 JSON includes keys (contract §7.0):  
- ok (bool; MUST be true when process is up)  
- build\_id (string)  
- contract\_version (string)  
Tests: crates/soldier\_infra/tests/test\_http\_health.rs::test\_health\_endpoint\_returns\_minimal\_payload (AT-022)  
Observability: counter http\_health\_calls\_total.  

**Watchdog heartbeat side-effect (contract §2.2.3/§3.2):**
Each successful /api/v1/health response MUST update watchdog_last_heartbeat_ts_ms = now_ms in memory for PolicyGuard evaluation (no persistence; does not alter trading state).
Slice 9 — Rate Limit Circuit Breaker \+ WS Gaps \+ Reconcile \+ Zombie Sweeper  
Slice intent: survive throttling and data gaps; block opens until safe.

S9.1 — Rate limiter priority \+ brownout  
Allowed paths: crates/soldier\_infra/api/rate\_limit.rs  
Acceptance criteria: priority EMERGENCY\_CLOSE\>CANCEL\>HEDGE\>OPEN\>DATA; shed DATA first; block OPEN under pressure.  
Tests: crates/soldier\_infra/tests/test\_rate\_limiter.rs::test\_rate\_limiter\_priority\_preemption  
Evidence artifacts: artifacts/deribit\_testnet\_trade\_final\_20260103\_020002.log (F‑05)  
Observability: gauge rate\_limiter\_tokens, counter rate\_limiter\_shed\_total{class}.  

**Rate-limit headers**: Do not rely on rate-limit headers; enforce local limiter + retry/backoff.  
Add test: crates/soldier_infra/tests/test_rate_limiter.rs::test_rate_limiter_ignores_rate_limit_headers.  

**Dynamic limits**: Poll `get_account_summary` every 60s to update local credit/token limits; map `tokens_per_sec = rate`, `burst = burst`.  
Repeated failure rule (contract): if limits fetch fails `limits_fetch_failures_trip_count = 3` within `limits_fetch_failure_window_s = 300`, set `RiskState::Degraded`.  

**429 behavior (contract §3.3)**: any single observed HTTP 429 response from Deribit immediately sets RiskState::Degraded (do not wait for repeated 429s). Trigger brownout throttles in the same tick.

Add test: crates/soldier_infra/tests/test_rate_limiter.rs::test_429_triggers_degraded_on_first_observation.

**Reason**: C-3.3-RATE_LIMIT-001  

**Rate limit repeated inability test:**

Add test: test_rate_limit_dynamic_limits_repeated_refresh_failures_force_degraded (AT-106)
Add test: test_rate_limit_dynamic_limits_no_trip_when_failures_outside_window (AT-133)

Define "repeated" as 3 consecutive polls of `/private/get_account_summary` fail → RiskState::Degraded.


S9.2 — 10028/too\_many\_requests \=\> Kill \+ reconnect \+ reconcile  
Allowed paths: crates/soldier\_infra/api/\*\*, crates/soldier\_core/recovery/reconcile.rs  
Acceptance criteria: 10028 triggers rate\_limit\_session\_kill\_active == true, TradingMode == Kill, RiskState == Degraded immediately; backoff; reconcile before resume.  
Tests: crates/soldier\_infra/tests/test\_rate\_limiter.rs::test\_rate\_limit\_10028\_triggers\_kill\_and\_reconnect  
Observability: counter rate\_limit\_10028\_total.  

**On 10028**: set open permission latch reason `SESSION_TERMINATION_RECONCILE_REQUIRED` and require full reconcile before unlatching.  

**Reason**: C-3.3-RATE_LIMIT-001, C-2.2.4-OPEN_PERMISSION_LATCH-001  

S9.3 — WS gap detection (book/trades/private) \=\> Degraded \+ REST snapshots  
Allowed paths: crates/soldier\_core/recovery/ws\_gap.rs  
Acceptance criteria: per-channel continuity rules; gap \=\> Degraded \+ resubscribe \+ snapshot rebuild.  
Tests:  
crates/soldier\_core/tests/test\_ws\_gap.rs::test\_orderbook\_gap\_triggers\_resubscribe\_and\_snapshot  
crates/soldier\_core/tests/test\_ws\_gap.rs::test\_trades\_gap\_triggers\_reconcile  
Observability: counter ws\_gap\_count\_total{channel}.  
Contract §3.4 requires CorrectiveActions enumeration:  
- CancelStaleOrder(order_id)  
- ReplaceIOC(intent_hash, new_limit_price)  
- EmergencyFlattenGroup(group_id)  
- ReduceOnlyDeltaHedge(target_delta=0, max_size=cap)  
Add tests to assert each action is produced deterministically given its trigger input.  
S9.4 — OpenPermission latch  
Define reconciliation success criteria explicitly (contract §2.2.4): (1) in-flight intents match exchange open orders by label; (2) positions match within epsilon; (3) no missing trades in lookback; (4) all reason codes cleared.  
Defaults (contract Appendix A): position\_reconcile\_epsilon = max(instrument min\_amount, 1e-6); reconcile\_trade\_lookback\_sec = 300.  
Hard rule: open_permission_reason_codes MUST NOT include F1_CERT or EvidenceChain failures (those belong in mode_reasons).  
Allowed paths: crates/soldier\_core/risk/open\_permission.rs  
Acceptance criteria (contract §2.2.4 / CP-001):  
- On startup: `open_permission_blocked_latch = true` with reason code `RESTART_RECONCILE_REQUIRED`.  
- When latch is true: OPEN intents are blocked; CLOSE/HEDGE/CANCEL remain allowed.  
- `open_permission_reason_codes == []` iff `open_permission_blocked_latch == false`.  
- `open_permission_requires_reconcile` MUST equal `open_permission_blocked_latch` (v5.1 reconcile-only reasons).  
- Latch adds reconcile-required reason codes on WS gaps / session termination and clears only after reconciliation success.  
Allowed reason codes (reconcile-only list):  
- `RESTART_RECONCILE_REQUIRED`  
- `WS_BOOK_GAP_RECONCILE_REQUIRED`  
- `WS_TRADES_GAP_RECONCILE_REQUIRED`  
- `INVENTORY_MISMATCH_RECONCILE_REQUIRED`  
- `SESSION_TERMINATION_RECONCILE_REQUIRED`  
Hard rule: F1_CERT and EvidenceChain failures MUST NOT appear in `open_permission_reason_codes`.  
Tests: crates/soldier\_core/tests/test\_open\_permission.rs::test\_open\_permission\_blocks\_opens\_until\_reconciled  
crates/soldier\_core/tests/test\_reconcile.rs::test\_position\_reconcile\_epsilon\_tolerates\_1e\_6\_qty\_diff  
crates/soldier\_core/tests/test\_reconcile.rs::test\_reconcile\_trade\_lookback\_sec\_queries\_300s\_history  
crates/soldier\_core/tests/test\_open\_permission.rs::test\_open\_permission\_latch\_blocks\_opens\_allows\_closes (AT-010)  
crates/soldier\_core/tests/test\_open\_permission.rs::test\_open\_permission\_clears\_after\_reconcile (AT-011)  
crates/soldier\_core/tests/test\_open\_permission.rs::test\_reduce\_only\_missing\_treated\_as\_open (AT-110)  
crates/soldier\_core/tests/test\_open\_permission.rs::test\_risk\_increasing\_cancel\_blocked\_when\_degraded (AT-120)  

**OpenPermission exclusion test:**

Add test: test_open_permission_reason_codes_excludes_f1_and_evidence

Given PolicyGuard has F1_CERT invalid AND EvidenceChainState != GREEN, assert that `open_permission_reason_codes` contains neither F1 nor Evidence-related codes (those belong only in `mode_reasons`).

S9.5 — Zombie sweeper (ghost orders \+ orphan fills)  
Allowed paths: crates/soldier\_core/recovery/zombie\_sweeper.rs  
Acceptance criteria: cancel ghost s4: orders lacking ledger; reconcile orphan fills via REST; no duplicates via trade-id registry.  
Ghost order rule (AT-122): if exchange open order has label `s4:` and no matching ledger intent, issue `CancelStaleOrder` and log `GhostOrderCanceled`.  
Orphan fill rule (AT-121): REST trade reconcile updates TLSM and later WS trade is ignored via `processed_trade_ids`.  
Tests:  
crates/soldier\_core/tests/test\_reconcile.rs::test\_orphan\_fill\_reconciles\_and\_no\_duplicate  
crates/soldier\_core/tests/test\_zombie\_sweeper.rs::test\_zombie\_sweeper\_cancels\_ghost\_order  
crates/soldier\_core/tests/test\_zombie\_sweeper.rs::test\_ghost\_order\_canceled\_logs\_event (AT-122)  
crates/soldier\_core/tests/test\_reconcile.rs::test\_orphan\_fill\_rest\_updates\_and\_ws\_ignored (AT-121)  
crates/soldier\_core/tests/test\_zombie\_sweeper.rs::test\_sweeper\_marks\_failed\_when\_no\_open\_and\_no\_trade (AT-123)  
crates/soldier\_core/tests/test\_zombie\_sweeper.rs::test\_stale\_order\_canceled\_no\_replace\_when\_degraded (AT-124)  
Observability: counter ghost\_order\_canceled\_total, orphan\_fill\_reconciled\_total.  

**Deterministic stale cancel**: If open order age > `stale_order_sec` and `reduce_only == false`, cancel it (do not cancel reduce-only closes/hedges).  

**Required test alias**: Add `test_stale_order_sec_cancels_non_reduce_only_orders()`.  

**Reason**: C-3.5-ZOMBIE_SWEEPER-001, C-8.2-TEST_SUITE-001  

F) Dependencies DAG (Phase 2\)  
Slice 6 → Slice 7 (budgets inform execution)  
Slice 7 (emergency close) required before enabling atomic groups  
Slice 8 precedes Slice 9 resume logic (mode enforcement \+ latches)  
Slice 9 reconciliation required before OpenPermission can clear  
G) De-scope line (Phase 2\)  
No Parquet truth/attribution production, no replay/canary/reviews yet, no SVI/simulator/calibration yet.  
PHASE 3 — Data Loop (Slices 10–12)  
A) Phase Objective  
Implement the Evidence Chain end-to-end: TruthCapsules written before dispatch, Decision Snapshots as required replay input (Patch A), Attribution with PnL decomposition, and time drift gates. Add SVI stability/arb guards and deterministic fill simulation \+ slippage calibration to support realism-penalized replay.

B) Constraint (TOC)  
Bottleneck: evidence/logging I/O cannot stall the hot loop; missing snapshots break replay.  
Relief: bounded queues \+ writer isolation; EvidenceGuard consumes writer health; Decision Snapshots are small and must continue even when full archives are paused.

C) Entry Criteria  
Phase 2 exit criteria met; PolicyGuard can enforce ReduceOnly via EvidenceGuard.  
Dispatch path goes exclusively via build\_order\_intent().  
D) Exit Criteria  
Every dispatched order has truth\_capsule\_id and decision\_snapshot\_id and joins to attribution.  
EvidenceChainState RED blocks opens (tests).  
Fill simulator deterministic; slippage calibration converges with safe defaults.  
E) Slices Breakdown (Phase 3\)  
Slice 10 — Truth Capsules \+ Attribution \+ Time Drift \+ Decision Snapshots (required)  
S10.1 — TruthCapsule write-before-dispatch (bounded queue)  
Allowed paths: crates/soldier\_core/analytics/truth\_capsule.rs, crates/soldier\_core/execution/\*\*  
Acceptance criteria: capsule enqueued before first leg dispatch; enqueue/write failure flips EvidenceChainState RED.  
Hot loop MUST enqueue to a bounded queue; dedicated writer thread/process drains writes (no hot-loop stall).  
Any dispatched order MUST already have a truth\_capsule\_id linked by `(group_id, leg_idx, intent_hash)`; no dispatch without linkage.  
On queue overflow or writer error: increment `truth_capsule_write_errors` (and `parquet_write_errors` if applicable) and enter ReduceOnly.  
Tests:  
crates/soldier\_core/tests/test\_truth\_capsule.rs::test\_truth\_capsule\_written\_before\_dispatch\_and\_fk\_linked  
crates/soldier\_core/tests/test\_truth\_capsule.rs::test\_truth\_capsule\_write\_failure\_forces\_reduceonly  
crates/soldier\_core/tests/test\_truth\_capsule.rs::test\_no\_dispatch\_without\_truth\_capsule\_id (AT-046)  
Rollout/rollback: hot-path; rollback \= disable trading opens (ReduceOnly) if writer unstable (must remain fail-closed).  
Observability: gauge parquet\_queue\_depth, counter truth\_capsule\_write\_errors\_total.  
S10.2 — Decision Snapshot capture/persist/link (Patch A requirement)  
Allowed paths: crates/soldier\_core/analytics/decision\_snapshot.rs, crates/soldier\_core/analytics/truth\_capsule.rs  
Acceptance criteria: L2 top‑N snapshot persisted; `decision_snapshot_id` stored in TruthCapsule; every dispatched intent MUST reference `decision_snapshot_id`; `l2_snapshot_id` MUST NOT be emitted; failure treated as evidence failure (opens blocked).  
Tests:  
crates/soldier\_core/tests/test\_decision\_snapshot.rs::test\_decision\_snapshot\_is\_required\_and\_linked  
crates/soldier\_core/tests/test\_decision\_snapshot.rs::test\_decision\_snapshot\_write\_failure\_blocks\_opens  
crates/soldier\_core/tests/test\_decision\_snapshot.rs::test\_decision\_snapshot\_id\_present\_and\_l2\_snapshot\_id\_absent (AT-044)  
Observability: counter decision\_snapshot\_written\_total, decision\_snapshot\_write\_errors\_total.  
S10.3 — Attribution rows \== fills (+ joins)  
Allowed paths: crates/soldier\_core/analytics/attribution.rs  
Acceptance criteria: for each fill, one attribution row with truth\_capsule\_id and friction fields.  
Required fields include `fair_price_at_signal`, `exchange_ts`, `local_send_ts`, `local_recv_ts`, `drift_ms`.  
Tests: crates/soldier\_core/tests/test\_attribution.rs::test\_attribution\_row\_links\_truth\_capsule  
Contract §4.4: Shadow mode MUST write the SAME Parquet schema as live with field mode = shadow|live.  
Add test: crates/soldier\_core/tests/test\_parquet\_schema.rs::test\_shadow\_and\_live\_schema\_parity\_includes\_mode\_field  
S10.4 — PnL decomposition units enforced (Python)  
Allowed paths: python/analytics/pnl\_attribution.py  
Acceptance criteria: theta/day, vega/1pct; raw+normalized stored.  
Tests: python/tests/test\_pnl\_attribution.py::test\_pnl\_decomposition\_theta\_units  
Contract §4.3: If S_fill == S_signal and IV_fill == IV_signal then delta_pnl approx 0 and vega_pnl approx 0; residual must not explode.  
Add test: python/tests/test\_pnl\_attribution.py::test\_pnl\_decomposition\_zero\_when\_no\_move  
S10.5 — Time drift gate \=\> ReduceOnly  
Allowed paths: crates/soldier\_core/risk/time\_drift\_gate.rs  
Acceptance criteria: if drift\_ms > time\_drift\_threshold\_ms then set RiskState::Degraded and PolicyGuard forces ReduceOnly; exposed in /status.  
Default threshold (contract): `time_drift_threshold_ms = 50` (configurable).  
Tests: crates/soldier\_core/tests/test\_time\_drift.rs::test\_time\_drift\_gate\_forces\_reduceonly  
Add test: crates/soldier\_core/tests/test\_time\_drift.rs::test\_time\_drift\_forces\_policyguard\_reduceonly (AT-108)  
Slice 11 — SVI Stability Gates \+ Arb Guards  
S11.1 — RMSE/drift gates (liquidity-aware)  
Allowed paths: crates/soldier\_core/quant/svi\_fit.rs  
Acceptance criteria:  
Gate 0 (liquidity-aware thresholds): if depth\_topN < depth\_min, set rmse\_max = 0.08 and drift\_max = 0.40; otherwise rmse\_max = 0.05 and drift\_max = 0.20.  
Explicit identifiers: `depth_topn` (top-N depth) and `depth_min` (minimum depth).  
Gate 1 (RMSE): rmse > rmse\_max ⇒ reject new fit.  
Gate 2 (Drift): params drift > drift\_max ⇒ reject new fit and hold last valid.  
SVI Math Guard and Arb Guards do not loosen under low depth.  
Tests:  
crates/soldier\_core/tests/test\_svi.rs::test\_svi\_rmse\_drift\_gates  
crates/soldier\_core/tests/test\_svi.rs::test\_svi\_depth\_min\_applies\_loosened\_thresholds  

**SVI trip window semantics (contract §4.1):**
- Maintain a rolling window counter of SVI gate trips over svi_guard_trip_window_s.
- If trips >= svi_guard_trip_count within the window: set RiskState::Degraded and pause opens until stable.
- Required tests: test_svi_guard_trip_count_triggers_degraded_after_3_trips() and test_svi_guard_trip_window_s_counts_over_300s().
S11.2 — Arb guards (convexity/calendar/density)  
Allowed paths: crates/soldier\_core/quant/svi\_arb.rs  
Acceptance criteria:  
On any arb-guard failure: invalidate fit, hold last valid, increment svi\_arb\_guard\_trips.  
If trips >= svi\_guard\_trip\_count within svi\_guard\_trip\_window\_s: set RiskState::Degraded and pause opens.  
Tests:  
crates/soldier\_core/tests/test\_svi.rs::test\_svi\_arb\_guard\_convexity\_rejects  
crates/soldier\_core/tests/test\_svi.rs::test\_svi\_arb\_guard\_trip\_count\_triggers\_degraded\_after\_3\_trips  
crates/soldier\_core/tests/test\_svi.rs::test\_svi\_arb\_violation\_rejects\_and\_holds\_last\_fit  
S11.3 — NaN/Inf guard holds last fit  
Allowed paths: crates/soldier\_core/quant/svi\_fit.rs  
Tests: crates/soldier\_core/tests/test\_svi.rs::test\_svi\_nan\_guard\_holds\_last\_fit  
(Observability for Slice 11: gauges svi\_rmse, svi\_drift\_pct, counters svi\_guard\_trips\_total, svi\_arb\_guard\_trips\_total.)

Slice 12 — Fill Simulator \+ Slippage Calibration  
S12.1 — Deterministic fill simulator (book-walk \+ fees)  
Allowed paths: crates/soldier\_core/sim/exchange.rs  
Acceptance criteria: given fixed L2 snapshot + size, simulator outputs deterministic WAP and `slippage_bps`.  
Tests: crates/soldier\_core/tests/test\_fill\_sim.rs::test\_fill\_simulator\_deterministic\_wap  
crates/soldier\_core/tests/test\_fill\_sim.rs::test\_fill\_simulator\_deterministic\_slippage\_bps  
S12.2 — Slippage calibration \+ safe default (1.3)  
Allowed paths: crates/soldier\_core/analytics/slippage\_calibration.rs, python/commander/analytics/slippage\_calibration.py  
Contract requirement: Replay Gatekeeper MUST apply this realism penalty factor (see §5.2).  
Tests:  
crates/soldier\_core/tests/test\_slippage\_calibration.rs::test\_slippage\_calibration\_penalty\_factor\_converges  
crates/soldier\_core/tests/test\_slippage\_calibration.rs::test\_realism\_penalty\_default\_applied\_when\_missing  
(Observability: gauge realism\_penalty\_factor{bucket}, counter slippage\_calibration\_samples\_total.)

F) Dependencies DAG (Phase 3\)  
S10.1 → S10.2 → S10.3 (capsule \+ snapshot IDs before attribution)  
S12.1 → S12.2 (calibration depends on simulator)  
Slice 10 required before Slice 13 replay correctness.  
G) De-scope line (Phase 3\)  
No replay/canary/reviews application yet; no disk watermark enforcement beyond metrics.  
PHASE 4 — Live Fire Controls (Slice 13\)  
A) Phase Objective  
Implement governance and release gates: replay gatekeeper using Decision Snapshots (required) with realism penalty; staged canary rollout with abort/rollback \+ ReduceOnly cooldown; daily/incident reviewer with human approval for aggressive patches; disk retention and watermark behavior per Patch A; F1 cert generation used by CI and by runtime F1 gate.

B) Constraint (TOC)  
Bottleneck: avoiding “false pass” governance.  
Relief: hard fail on snapshot\_coverage\_pct \< 95%; penalized replay profitability gate; F1 cert PASS required for opens.

C) Entry Criteria  
Phase 3 evidence \+ snapshots \+ calibration working.  
/status reports snapshot coverage and F1 state.  
D) Exit Criteria  
Replay gatekeeper \+ canary \+ reviewer \+ watermarks \+ F1 cert tests all green.  
artifacts/F1\_CERT.json PASS produced and required for opens.  
E) Slice Breakdown (Phase 4\)  
Slice 13 — Replay Gatekeeper \+ Canary \+ Reviews \+ Retention \+ F1 Cert  
S13.1 — Replay Gatekeeper (Decision Snapshots required; coverage hard gate)  
Define snapshot_coverage_pct per contract and include boundary test at 94.9% fail / 95.0% pass.  
Add missing hard gates: replay_atomic_naked_events==0; max_drawdown <= dd_limit; profitability > 0; apply realism penalty.  
Allowed paths: python/governor/replay\_gatekeeper.py  
Acceptance criteria: uses Decision Snapshots (required); hard fail if coverage \<95%; apply realism\_penalty\_factor; require penalized PnL \> 0\.  
`dd_limit` MUST be explicitly configured; missing/unparseable ⇒ hard fail (fail-closed).  
Bad policy must fail due to realism penalty (profit flips ≤ 0).  
Tests:  
python/tests/test\_replay\_gatekeeper.py::test\_replay\_gatekeeper\_penalized\_pnl\_gate  
python/tests/test\_replay\_gatekeeper.py::test\_replay\_fails\_when\_snapshot\_coverage\_below\_95  
python/tests/test\_replay\_gatekeeper.py::test\_replay\_passes\_at\_snapshot\_coverage\_95 (AT-002)  
python/tests/test\_replay\_gatekeeper.py::test\_replay\_hard\_fails\_when\_dd\_limit\_missing (AT-034, AT-040)  
Evidence artifacts: artifacts/policy\_patches/\<ts\>\_result.json  
Observability: log ReplayGatekeeperResult{coverage\_pct, net\_pnl\_penalized, pass}.  
S13.2 — Disk retention \+ watermarks (Patch A semantics)  
Clarify: when disk_used_pct >= 92%, trading loop MUST hard-stop (no dispatch occurs, including close/hedge/cancel) to protect evidence integrity.  
Add test: test_disk_kill_pct_hard_stops_at_92_pct (exact contract name).  
Implement retention_reclaim() background task with: trigger at 80% best-effort, at 85% mandatory repeat; only deletes cold partitions beyond retention windows; MUST NOT delete WAL; MUST NOT delete Decision Snapshots intersecting replay window.  
Reclaim MUST run as a background/low-priority task and MUST NOT stall the hot loop.  
Evidence: each reclaim run writes artifacts/disk_reclaim/<ts>_reclaim.json with reclaimed_bytes, cutoff_ts per dataset, disk_used_pct_before, disk_used_pct_after.  
Add tests for: (a) WAL never deleted; (b) snapshots in replay window preserved.  
Allowed paths: crates/soldier\_infra/storage/retention.rs, crates/soldier\_core/infra/disk\_watermarks.rs  
Acceptance criteria:  
80% disk: pause full tick/L2 archives only; Decision Snapshots continue; does NOT force Degraded by itself.  
85% disk: force ReduceOnly (Degraded).  
92% disk: Kill.  
Tests: crates/soldier\_core/tests/test\_disk\_watermark\_stops\_tick\_archives\_and\_forces\_reduceonly  
Observability: gauge disk_used_pct, counter tick_archive_paused_total.  

**Explicitly list retention defaults** referenced in contract (tick/L2 archives 72h; parquet analytics 30d; decision snapshots 30d with minimum bound ≥2d per contract §7.2).  
Decision Snapshots retention window is REQUIRED for replay validity; `decision_snapshot_retention_days >= ceil(replay_window_hours / 24)` (default ≥2d).  

**IMPLEMENTATION GUARDRAIL:** Decision Snapshot retention is `decision_snapshot_retention_days = 30` with minimum bound `≥ ceil(replay_window_hours / 24)` (default ≥2d). This is NOT "retain only replay window" (48h). The replay window must be preserved within the larger 30d retention.


**Test naming**: Ensure the contract-required test name `test_disk_kill_pct_hard_stops_at_92_pct()` exists (may wrap any more specific test).  

**Reason**: C-7.2-DISK_RETENTION-001, C-8.2-TEST_SUITE-001  

**PL-8 — Retention defaults explicit (decision snapshots 30d, ≥2d bound):**

Explicit defaults per contract §7.2: decision snapshots retained 30 days with minimum bound ≥2 days (do not 'align to replay window').

Add deletion test: test_decision_snapshot_retention_days_deletes_after_30_days() already required by Appendix A.


S13.3 — Canary rollout (Shadow→Canary→Full) \+ abort/rollback  
Abort conditions must include (contract §5.3): atomic_naked_events>0; p95_slippage_bps breach; fill_rate below floor with min attempts; net_pnl_usd below floor.  
On abort: rollback + enforce ReduceOnly cooldown duration per contract.  
Add tests for each abort reason.  
Allowed paths: python/governor/canary\_rollout.py  
Tests: python/tests/test\_canary\_rollout.py::test\_canary\_rollout\_aborts\_on\_slippage  
Abort threshold parameters (contract): `slippage_limit`, `fill_rate_floor`, `canary_min_attempts`, `pnl_floor`.  
All four MUST be provided by configuration; if any missing/unparseable ⇒ immediate rollback + ReduceOnly cooldown (AT-035).  
Add tests: python/tests/test\_canary\_rollout.py::test\_canary\_rollout\_missing\_thresholds\_aborts (AT-035)  
python/tests/test\_canary\_rollout.py::test\_canary\_rollout\_aborts\_when\_slippage\_exceeds\_limit (AT-036)  

**Stage schedule (contract §5.3)**: Shadow 6-24h → Canary 2-6h → Full.  

**IMPLEMENTATION GUARDRAIL:** The Canary stage duration is **2-6h**. Any longer duration violates the governance constraint. The PL-6 schedule below provides the authoritative schedule.


**PolicyStage plumbing**: Soldier must consume PolicyStage and refuse scaling to "Full" if earlier stages not passed.  

**Reason**: C-5.3-CANARY-001  

**PL-6 — Canary stage schedule (contract §5.3):**

Stage 0 Shadow PASS duration 6–24h

Stage 1 Testnet micro-canary PASS duration 2–6h

Any abort trigger → rollback + ReduceOnly cooldown

Add tests asserting stage durations are within contract ranges and that abort triggers enforce rollback+cooldown.


S13.4 — AutoReviewer daily \+ incident reports \+ human approval gate  
Allowed paths: python/reviewer/{daily\_ops\_review.py,incident\_review.py}  
Tests: python/tests/test\_reviewer.py::test\_autoreviewer\_blocks\_aggressive\_without\_human\_approval  
Contract rule: AGGRESSIVE patch without `artifacts/HUMAN_APPROVAL.json` MUST NOT apply (even if replay/canary pass).  

**Artifacts required**:  
- `artifacts/decision_log.jsonl`  
- `artifacts/policy_patches/<ts>_patch.json` and `<ts>_result.json`  
- `artifacts/reviews/<date>_daily_ops.md` + `.json`  
- `artifacts/incidents/<ts>_<id>.md` + `.json`  
- `artifacts/HUMAN_APPROVAL.json`  

**Reason**: C-7.1-REVIEW_LOOP-001  

**PL-7 — Review artifacts + reviewer outputs schema (contract-canonical):**

Write contract-canonical artifacts (do not replace; add if you keep existing paths):

artifacts/reviews/<YYYY-MM-DD>/daily_review.json

artifacts/reviews/<YYYY-MM-DD>/daily_review.md

artifacts/reviews/<YYYY-MM-DD>/incident_report.md

Daily review JSON MUST include required output fields: review_decision (PASS_WITH_CHANGES / FAIL_BLOCKED / FAIL_DANGEROUS), recommended_patches[] with patch_meta.impact (SAFE/NEUTRAL/AGGRESSIVE), and human_approval_required.

Add tests verifying:
- file paths and required keys exist
- FAIL_* blocks Full promotion until human approval latch clears
- incident report generation triggers ReduceOnly cooldown


S13.5 — F1 cert generation \+ CI gate  
Implement Contract §8.1 Release Gate Metrics: compute and enforce all listed metrics/thresholds per stage (shadow/testnet/live). F1_CERT PASS requires all thresholds satisfied.  
Explicit metrics (contract §8.1):  
- Rate Limits: `429_count == 0` AND `10028_count == 0`.  
- Time Drift: `p99_clock_drift <= 50ms`.  
- Fee Drag Ratio: `fee_drag_usd / gross_edge_usd (rolling 7d) < 0.35`.  
- Net Edge After Fees: rolling 7d avg(`net_edge_usd`) > 0.  
Add tests validating each threshold boundary (>= vs >) per contract.  
Allowed paths: python/tools/f1\_certify.py  
Tests: python/tests/test\_f1\_certify.py::test\_f1\_cert\_fail\_on\_atomic\_naked\_event  
Add test: python/tests/test\_f1\_certify.py::test\_runtime\_config\_hash\_canonicalization (AT-113).  
Evidence artifacts: artifacts/F1\_CERT.json, artifacts/F1\_CERT.md  

**PL-9 — Add missing REQUIRED named tests (exact names):**

Add REQUIRED named tests (exact):

test_release_gate_fee_drag_ratio_blocks_scaling()

test_svi_depth_min_applies_loosened_thresholds()

If implementation uses different internal test names, add wrapper/alias tests with these exact names calling the real ones.

**PL-10 — f1_certify CLI + F1_CERT schema completeness (contract):**

Implement scripts/f1_certify.py --out artifacts/F1_CERT.json (exact CLI) and ensure F1_CERT includes required schema keys: status, generated_ts_ms, build_id, runtime_config_hash, contract_version, expires_at_ts_ms, release_gate_metrics.

**Path compliance (contract-required):**

Canonical tool MUST remain: python/tools/f1_certify.py

If scripts/f1_certify.py exists, it MUST be a thin wrapper that invokes python/tools/f1_certify.py with identical CLI args.

CI MUST call python python/tools/f1_certify.py (contract example).



**PL-11 — Release metrics windows + tests (make §8.1 computable, not vibes):**

Define exact metric windows per contract:

- atomic_naked_events_24h over trailing 24h
- replay coverage over replay_window_hours (48h)
- p95 slippage bps, fee drag ratio, p99 clock drift (explicit windows as defined in §8.1)

Add tests that assert thresholds exactly match contract comparators (≤ vs <, ==0, etc.).

F) Dependencies DAG (Phase 4\)  
Slice 10 \+ Slice 12 → S13.1  
S13.1 → S13.3 (replay pass required before canary)  
S13.2 \+ S13.4 \+ S13.5 must be in place before any “enable live” decision.  
G) De-scope line (Phase 4\)
