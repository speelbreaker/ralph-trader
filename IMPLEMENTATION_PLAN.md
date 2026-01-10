1\) Phase → Slice Mapping Table (contract-aligned)  
| Phase | Goal | Slices Included | Exit Criteria (objective/measurable) | Key Risks | |---|---|---|---|---| | Phase 1 — Foundation (Panic‑Free Deterministic Intents) | Deterministic intent construction: sizing invariants, quantization+idempotency, venue preflight, durable WAL/TLSM, and hard execution gates behind one chokepoint. | Slices 1–5 | (1) build\_order\_intent() gate ordering proven by test; (2) WAL replay proves “no resend after crash”; (3) Market/stop/linked/post-only-crossing are rejected preflight (tests); (4) Liquidity+NetEdge+Fee staleness fail-closed (tests). | Gate bypass via alternate codepaths; float/rounding drift; WAL durability miswired before dispatch. | | Phase 2 — Guardrails (Runtime Safety \+ Recovery) | Atomic containment \+ emergency close, risk budgets (inventory/pending/global/margin), PolicyGuard precedence incl F1 runtime gate, EvidenceGuard, Bunker Mode, plus rate-limit brownout, WS-gap recovery, reconcile, zombie sweep, and required owner endpoints. | Slices 6–9 | (1) Mixed-leg state always contains/neutralizes (tests); (2) PolicyGuard precedence enforces ReduceOnly/Kill correctly incl F1/Evidence/Bunker (tests); (3) 10028/429 behavior preserves emergency actions and blocks opens (tests); (4) New endpoints pass endpoint-level tests. | Recon races causing duplicates; rate limiter starving emergency close; “fail-open” gaps in PolicyGuard. | | Phase 3 — Data Loop (Evidence \+ Replay Inputs) | Produce the contract Evidence Chain: TruthCapsules \+ Decision Snapshots (required replay input) \+ Attribution \+ time drift gate; SVI validity; fill sim \+ slippage calibration. | Slices 10–12 | (1) Every dispatched leg links to truth\_capsule\_id \+ decision\_snapshot\_id; (2) EvidenceChainState RED blocks opens (tested); (3) Attribution completeness \= 100% (rows==fills); (4) Simulator deterministic; calibration converges. | Writer backpressure stalling hot loop; snapshot coverage gaps; join-key drift; time drift mismeasurement. | | Phase 4 — Live Fire Controls (Governance \+ Release Gates) | Replay Gatekeeper (Decision Snapshots required \+ realism penalty), canary rollout, reviews/incidents, retention/watermarks (Patch A semantics), and F1 cert (runtime \+ CI). | Slice 13 | (1) Replay hard-fails if snapshot\_coverage\_pct \< 95%; (2) Canary auto-rollbacks on abort conditions; (3) Disk watermarks enforce: 80% pause full archives only, 85% ReduceOnly, 92% Kill; (4) artifacts/F1\_CERT.json PASS is required for opens (runtime). | False confidence from wrong replay inputs; aggressive patch applied without human approval; watermark logic incorrectly forces Degraded at 80% (must not). |

Global Non‑Negotiables (apply to ALL stories)  
WIP=1: exactly one Story (S{slice}.{n}) in-flight at a time; each Story lands with code \+ tests \+ required artifacts listed up front.  
Fail‑closed: any safety/evidence ambiguity blocks opens (ReduceOnly), never relaxes gates.  
New endpoint ⇒ endpoint-level test (at least one) in the Story plan.  
Single chokepoint: all order construction routes through crates/soldier\_core/execution/build\_order\_intent.rs::build\_order\_intent().  
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
artifacts/ present and python scripts/check\_vq\_evidence.py is runnable (CI later).  
D) Exit Criteria (measurable/testable)  
All tests listed in Slices 1–5 pass in CI.  
test\_gate\_ordering\_call\_log proves ordered gates: preflight→quantize→fee→liquidity→net\_edge→…→WAL→dispatch.  
test\_ledger\_replay\_no\_resend\_after\_crash proves no duplicate sends after restart.  
E) Slices Breakdown (Phase 1\)  
Slice 1 — Instrument Units \+ Dispatcher Invariants  
Slice intent: Encode Deribit sizing semantics to prevent 10–100× exposure errors.

S1.1 — InstrumentKind derivation \+ instrument cache TTL (fail‑closed)  
Allowed paths (globs):  
crates/soldier\_core/venue/\*\*  
crates/soldier\_infra/deribit/public/\*\*  
crates/soldier\_core/risk/state.rs  
New/changed endpoints: none  
Acceptance criteria:  
InstrumentKind derives option|linear\_future|inverse\_future|perpetual from venue metadata.  
Linear perpetuals (USDC‑margined) map to linear\_future for sizing.  
Instrument cache TTL breach sets RiskState::Degraded (opens blocked later by PolicyGuard) and emits a structured log.  
Tests:  
crates/soldier\_core/tests/test\_instrument\_kind\_mapping.rs::test\_linear\_perp\_treated\_as\_linear\_future  
crates/soldier\_core/tests/test\_instrument\_cache\_ttl.rs::test\_stale\_instrument\_cache\_sets\_degraded  
Evidence artifacts: none  
Rollout \+ rollback:  
Rollout behind config instrument\_cache\_ttl\_s; rollback \= set TTL large (still fail-closed if metadata missing).  
Observability hooks: counters instrument\_cache\_hits\_total, instrument\_cache\_stale\_total; gauge instrument\_cache\_age\_s.  
S1.2 — OrderSize canonical sizing \+ notional invariant  
Allowed paths: crates/soldier\_core/execution/order\_size.rs  
New/changed endpoints: none  
Acceptance criteria:  
OrderSize { contracts, qty\_coin, qty\_usd, notional\_usd } implemented exactly.  
Canonical units:  
option|linear\_future: canonical qty\_coin  
perpetual|inverse\_future: canonical qty\_usd  
notional\_usd always populated deterministically.  
Tests:  
crates/soldier\_core/tests/test\_order\_size.rs::test\_order\_size\_option\_perp\_canonical\_amount  
Evidence artifacts: none  
Rollout \+ rollback: core library; rollback via revert commit only.  
Observability hooks: debug log OrderSizeComputed{instrument\_kind, notional\_usd}.  
S1.3 — Dispatcher amount mapping \+ mismatch reject→Degraded  
Allowed paths: crates/soldier\_core/execution/dispatch\_map.rs  
New/changed endpoints: none  
Acceptance criteria:  
Outbound Deribit request sends exactly one canonical amount.  
If both contracts and canonical amount exist and mismatch ⇒ reject intent and set RiskState::Degraded.  
Tests:  
crates/soldier\_core/tests/test\_dispatch\_map.rs::test\_dispatch\_amount\_field\_coin\_vs\_usd  
crates/soldier\_core/tests/test\_order\_size.rs::test\_order\_size\_mismatch\_rejects\_and\_degrades  
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
Tests:  
crates/soldier\_core/tests/test\_quantize.rs::test\_quantization\_rounding\_buy\_sell  
crates/soldier\_core/tests/test\_quantize.rs::test\_rejects\_too\_small\_after\_quantization  
Evidence artifacts: artifacts/deribit\_testnet\_trade\_final\_20260103\_020002.log (F‑03 reference; enforced by evidence-check script)  
Rollout \+ rollback: core; rollback via revert only.  
Observability hooks: counter quantization\_reject\_too\_small\_total.  
S2.2 — Intent hash from quantized fields only  
Allowed paths: crates/soldier\_core/idempotency/hash.rs  
New/changed endpoints: none  
Acceptance criteria:  
Hash excludes wall-clock timestamps.  
Same economic intent through two codepaths yields identical hash.  
Tests: crates/soldier\_core/tests/test\_idempotency.rs::test\_intent\_hash\_deterministic\_from\_quantized  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: none beyond existing logs.  
S2.3 — Compact label schema encode/decode (≤64 chars)  
Allowed paths: crates/soldier\_core/execution/label.rs  
New/changed endpoints: none  
Acceptance criteria:  
s4:{sid8}:{gid12}:{li}:{ih16}; max 64 chars.  
If truncation needed, truncate hashed fields only (never structural).  
Tests: crates/soldier\_core/tests/test\_label.rs::test\_label\_compact\_schema\_length\_limit  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: counter label\_truncated\_total.  
S2.4 — Label match disambiguation; ambiguity→Degraded  
Allowed paths: crates/soldier\_core/recovery/label\_match.rs  
New/changed endpoints: none  
Acceptance criteria:  
Matching algorithm per contract tie-breakers; ambiguity triggers RiskState::Degraded and sets “opens blocked” latch (wired later).  
Tests:  
crates/soldier\_core/tests/test\_label\_match.rs::test\_label\_match\_disambiguation  
crates/soldier\_core/tests/test\_label\_match.rs::test\_label\_match\_ambiguous\_degrades  
Evidence artifacts: none  
Rollout \+ rollback: core.  
Observability hooks: counter label\_match\_ambiguity\_total.  
Slice 3 — Order‑Type Preflight \+ Venue Capabilities (artifact‑backed)  
Slice intent: Hard-reject illegal orders before any API call.

S3.1 — Preflight guard (market/stop/linked rules)  
Allowed paths:  
crates/soldier\_core/execution/preflight.rs  
crates/soldier\_core/execution/order\_type\_guard.rs  
New/changed endpoints: none  
Acceptance criteria:  
Reject market orders for all instruments (policy).  
Options: allow limit only; reject stops; reject any trigger\*; reject linked orders.  
Futures/perps: allow limit only; if stop types appear in codepath, require trigger (but bot policy still rejects market).  
Tests:  
crates/soldier\_core/tests/test\_preflight.rs::test\_options\_market\_order\_rejected  
crates/soldier\_core/tests/test\_preflight.rs::test\_perp\_market\_order\_rejected  
crates/soldier\_core/tests/test\_preflight.rs::test\_options\_stop\_order\_rejected\_preflight  
crates/soldier\_core/tests/test\_preflight.rs::test\_linked\_orders\_gated\_off  
crates/soldier\_core/tests/test\_preflight.rs::test\_perp\_stop\_requires\_trigger  
Evidence artifacts (must remain valid):  
artifacts/T-TRADE-02\_response.json (F‑01a)  
artifacts/deribit\_testnet\_trade\_20260103\_015804.log (F‑01b policy conflict)  
artifacts/T-OCO-01\_response.json (F‑08)  
artifacts/T-STOP-01\_response.json, artifacts/T-STOP-02\_response.json (F‑09)  
Rollout \+ rollback: core invariant (no rollback except revert).  
Observability hooks: counter preflight\_reject\_total{reason}.  
S3.2 — Post‑only crossing guard  
Allowed paths: crates/soldier\_core/execution/post\_only\_guard.rs  
New/changed endpoints: none  
Acceptance criteria: If post\_only=true and price crosses touch, reject preflight (deterministic).  
Tests: crates/soldier\_core/tests/test\_post\_only\_guard.rs::test\_post\_only\_crossing\_rejected  
Evidence artifacts: artifacts/deribit\_testnet\_trade\_final\_20260103\_020002.log (F‑06)  
Rollout \+ rollback: core; revert only.  
Observability hooks: counter post\_only\_cross\_reject\_total.  
S3.3 — Capabilities matrix \+ feature flags  
Allowed paths: crates/soldier\_core/venue/capabilities.rs  
New/changed endpoints: none  
Acceptance criteria: linked/OCO impossible by default; only enabled with explicit feature flag \+ capability.  
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
Tests: crates/soldier\_infra/tests/test\_ledger\_replay.rs::test\_ledger\_replay\_no\_resend\_after\_crash  
Evidence artifacts: none  
Rollout \+ rollback: creates local DB; rollback (dev-only) \= delete DB; production rollback \= revert binary (keep WAL).  
Observability hooks: histogram wal\_append\_latency\_ms; counter wal\_write\_errors\_total.  
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
S4.4 — Dispatch requires durable WAL barrier (when configured)  
Allowed paths: crates/soldier\_infra/store/ledger.rs, crates/soldier\_core/execution/\*\*  
New/changed endpoints: none  
Acceptance criteria: dispatch path blocks until durable marker when enabled.  
Tests: crates/soldier\_infra/tests/test\_dispatch\_durability.rs::test\_dispatch\_requires\_wal\_durable\_append  
Evidence artifacts: none  
Rollout \+ rollback: feature flag require\_wal\_fsync\_before\_dispatch; rollback \= disable (riskier; use only for perf debugging).  
Observability hooks: histogram wal\_fsync\_latency\_ms.  
Slice 5 — Liquidity Gate \+ Fee Model \+ Net Edge \+ Gate Ordering \+ Pricer  
Slice intent: Deterministic reject/price logic before any order leaves the process.

S5.1 — Liquidity Gate (book-walk WAP, reject sweep)  
Allowed paths: crates/soldier\_core/execution/gate.rs  
New/changed endpoints: none  
Acceptance criteria: compute WAP & slippage\_bps; reject if exceeds MaxSlippageBps; log WAP+slippage.  
Tests: crates/soldier\_core/tests/test\_liquidity\_gate.rs::test\_liquidity\_gate\_rejects\_sweep  
Evidence artifacts: none  
Rollout \+ rollback: hot-path; rollback \= feature flag ENABLE\_LIQUIDITY\_GATE (default true; turning off is non-compliant for live).  
Observability hooks: histogram expected\_slippage\_bps; counter liquidity\_gate\_reject\_total.  
S5.2 — Fee cache staleness (soft buffer / hard ReduceOnly latch)  
Allowed paths: crates/soldier\_infra/deribit/account\_summary.rs, crates/soldier\_core/strategy/fees.rs  
New/changed endpoints: none (uses Deribit private account summary)  
Acceptance criteria: soft stale \=\> fee buffer applied; hard stale \=\> state flag forcing ReduceOnly (PolicyGuard consumes later).  
Tests:  
crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_cache\_soft\_buffer\_tightens  
crates/soldier\_core/tests/test\_fee\_staleness.rs::test\_fee\_cache\_hard\_forces\_reduceonly  
Evidence artifacts: none  
Rollout \+ rollback: rollback \= increase polling frequency / widen hard threshold only via config (still fail-closed at hard).  
Observability hooks: gauge fee\_model\_cache\_age\_s; counter fee\_model\_refresh\_fail\_total.  
S5.3 — NetEdge gate  
Allowed paths: crates/soldier\_core/execution/gates.rs  
New/changed endpoints: none  
Acceptance criteria: reject if gross\_edge \- fee \- expected\_slippage \< min\_edge.  
Tests: crates/soldier\_core/tests/test\_net\_edge\_gate.rs::test\_net\_edge\_gate\_blocks\_when\_fees\_plus\_slippage  
Evidence artifacts: none  
Rollout \+ rollback: hot-path; rollback \= none (core safety).  
Observability hooks: counter net\_edge\_reject\_total.  
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
Tests: crates/soldier\_core/tests/test\_gate\_ordering.rs::test\_gate\_ordering\_call\_log  
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
Endpoints /api/v1/status and /api/v1/emergency/reduce\_only have endpoint-level tests.  
E) Slices Breakdown (Phase 2\)  
Slice 6 — Inventory Skew \+ Pending Exposure \+ Global Budget \+ Margin Gate  
Slice intent: prevent risk-budget double spend and liquidation.

S6.1 — Inventory skew gate  
Allowed paths: crates/soldier\_core/execution/inventory\_skew.rs  
Endpoints: none  
Acceptance criteria: tightens only for risk-increasing, may relax only for risk-reducing.  
Tests: crates/soldier\_core/tests/test\_inventory\_skew.rs::test\_inventory\_skew\_rejects\_risk\_increasing\_near\_limit  
Evidence artifacts: none  
Rollout/rollback: hot-path; rollback via flag ENABLE\_INVENTORY\_SKEW (default true for live).  
Observability: inventory\_skew\_adjust\_total{dir}, gauge inventory\_bias.  
S6.2 — Pending exposure reservation  
Allowed paths: crates/soldier\_core/risk/pending\_exposure.rs  
Endpoints: none  
Acceptance criteria: reserve before dispatch; release on terminal TLSM; concurrent opens cannot overfill.  
Tests: crates/soldier\_core/tests/test\_pending\_exposure.rs::test\_pending\_exposure\_reservation\_blocks\_overfill  
Rollout/rollback: rollback \= disable reservation (non-compliant for live).  
Observability: gauge pending\_delta, counter pending\_reserve\_reject\_total.  
S6.3 — Global exposure budget (corr buckets)  
Allowed paths: crates/soldier\_core/risk/exposure\_budget.rs  
Acceptance criteria: correlation-aware; uses current+pending.  
Tests: crates/soldier\_core/tests/test\_exposure\_budget.rs::test\_global\_exposure\_budget\_correlation\_rejects  
Observability: gauge portfolio\_delta\_usd, counter portfolio\_budget\_reject\_total.  
S6.4 — Margin headroom gate  
Allowed paths: crates/soldier\_core/risk/margin\_gate.rs  
Acceptance criteria: 70% reject opens; 85% ReduceOnly; 95% Kill.  
Tests: crates/soldier\_core/tests/test\_margin\_gate.rs::test\_margin\_gate\_thresholds\_block\_reduceonly\_kill  
Observability: gauge mm\_util, counter margin\_gate\_trip\_total{level}.  
Slice 7 — Atomic Group Executor \+ Emergency Close \+ Sequencer \+ Churn Breaker  
Slice intent: runtime atomicity: bounded rescue then deterministic flatten/hedge fallback.

S7.1 — Group state machine \+ first-fail invariant  
Allowed paths: crates/soldier\_core/execution/{group.rs,atomic\_group\_executor.rs}  
Acceptance criteria: cannot mark Complete until safe; first failure seeds MixedFailed.  
Tests: crates/soldier\_core/tests/test\_atomic\_group.rs::test\_atomic\_group\_mixed\_failed\_then\_flattened  
Rollout/rollback: feature ENABLE\_ATOMIC\_GROUPS; rollback \= disable (single-leg only).  
Observability: counter atomic\_group\_state\_total{state}.  
S7.2 — Bounded rescue (≤2) and no chase loop  
Allowed paths: crates/soldier\_core/execution/atomic\_group\_executor.rs  
Acceptance criteria: max 2 rescue IOC attempts; then flatten.  
Tests: crates/soldier\_core/tests/test\_atomic\_group.rs::test\_atomic\_rescue\_attempts\_limited\_to\_two  
Observability: histogram atomic\_rescue\_attempts.  
S7.3 — Deterministic emergency close \+ hedge fallback  
Allowed paths: crates/soldier\_core/execution/emergency\_close.rs  
Acceptance criteria: 3 tries IOC close; then reduce-only delta hedge; logs AtomicNakedEvent.  
Tests: crates/soldier\_core/tests/test\_emergency\_close.rs::test\_emergency\_close\_fallback\_hedge\_after\_retries  
Hot-path rollback: caps configurable (close\_max\_attempts, hedge cap) but must remain fail-closed.  
Observability: histogram time\_to\_delta\_neutral\_ms, counter atomic\_naked\_events\_total.  
S7.4 — Sequencer ordering rules  
Allowed paths: crates/soldier\_core/execution/sequencer.rs  
Acceptance criteria: close→confirm→hedge; never increase exposure while Degraded.  
Tests: crates/soldier\_core/tests/test\_sequencer.rs::test\_sequencer\_close\_then\_hedge\_ordering  
Observability: counter sequencer\_order\_violation\_total.  
S7.5 — Churn breaker  
Allowed paths: crates/soldier\_core/risk/churn\_breaker.rs  
Acceptance criteria: \>2 flattens/5m \=\> 15m blacklist blocks opens for that key.  
Tests: crates/soldier\_core/tests/test\_churn\_breaker.rs::test\_churn\_breaker\_blacklists\_after\_three  
Observability: counter churn\_breaker\_trip\_total.  
Slice 8 — PolicyGuard \+ Cortex \+ Exchange Health \+ Bunker/Evidence/F1 \+ Owner Endpoints (Patch D)  
Slice intent: one authoritative mode resolver \+ required read-only status endpoint.

S8.1 — PolicyGuard precedence \+ staleness handling  
Allowed paths: crates/soldier\_core/policy/guard.rs  
Acceptance criteria: recompute each tick; stale policy \=\> ReduceOnly.  
Tests:  
crates/soldier\_core/tests/test\_policy\_guard.rs::test\_policy\_guard\_late\_policy\_update\_stays\_reduceonly  
crates/soldier\_core/tests/test\_policy\_guard.rs::test\_policy\_guard\_override\_priority  
Observability: gauge policy\_age\_sec, counter policy\_stale\_reduceonly\_total.  
S8.2 — Runtime F1 gate (HARD): artifacts/F1\_CERT.json  
Allowed paths: crates/soldier\_core/policy/guard.rs  
Acceptance criteria: missing/stale/FAIL \=\> ReduceOnly; no grace; no caching last-known-good.  
Tests:  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_missing\_forces\_reduceonly  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_fail\_forces\_reduceonly  
crates/soldier\_core/tests/test\_f1\_gate.rs::test\_f1\_cert\_stale\_forces\_reduceonly  
Evidence artifacts: test fixture crates/soldier\_core/tests/fixtures/F1\_CERT.json  
Observability: gauge f1\_cert\_age\_s, counter f1\_cert\_gate\_block\_opens\_total.  
S8.3 — EvidenceGuard (Patch B) enforcement \+ cooldown  
Allowed paths:  
crates/soldier\_core/policy/guard.rs  
crates/soldier\_core/analytics/evidence\_chain\_state.rs  
Acceptance criteria: evidence chain not GREEN \=\> ReduceOnly; closes allowed; cooldown after recovery.  
Tests:  
crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_evidence\_guard\_blocks\_opens\_allows\_closes  
crates/soldier\_core/tests/test\_evidence\_guard.rs::test\_evidence\_guard\_cooldown\_after\_recovery  
Observability: gauge evidence\_chain\_state, counter evidence\_guard\_blocked\_opens\_total.  
S8.4 — Bunker Mode network jitter monitor (Patch C)  
Allowed paths: crates/soldier\_core/risk/network\_jitter.rs, crates/soldier\_core/policy/guard.rs  
Acceptance criteria: jitter thresholds \=\> ReduceOnly; stable cooldown required to exit.  
Tests:  
crates/soldier\_core/tests/test\_bunker\_mode.rs::test\_ws\_event\_lag\_breach\_blocks\_opens  
crates/soldier\_core/tests/test\_bunker\_mode.rs::test\_bunker\_mode\_cooldown\_then\_exit  
Observability: gauge ws\_event\_lag\_ms, deribit\_http\_p95\_ms, counter bunker\_mode\_trip\_total.  
S8.5 — Cortex overrides  
Allowed paths: crates/soldier\_core/reflex/cortex.rs  
Acceptance criteria: DVOL/spread/depth shocks \=\> ReduceOnly; WS gap blocks risk-increasing cancel/replace.  
Tests: crates/soldier\_core/tests/test\_cortex.rs::test\_cortex\_dvol\_spike\_force\_reduceonly  
Observability: counter cortex\_override\_total{kind}.  
S8.6 — Exchange maintenance monitor  
Allowed paths: crates/soldier\_core/risk/exchange\_health.rs  
Acceptance criteria: maint within 60m \=\> ReduceOnly; opens blocked.  
Tests: crates/soldier\_core/tests/test\_exchange\_health.rs::test\_exchange\_health\_maintenance\_blocks\_opens  
S8.7 — Endpoint: POST /api/v1/emergency/reduce\_only (existing plan)  
Allowed paths: crates/soldier\_infra/http/\*\*, crates/soldier\_core/policy/watchdog.rs  
New/changed endpoints: POST /api/v1/emergency/reduce\_only  
Required endpoint-level tests: yes  
Acceptance criteria: flips to ReduceOnly; cancels only non-reduce-only opens; preserves closes/hedges.  
Tests: crates/soldier\_infra/tests/test\_http\_emergency.rs::test\_post\_emergency\_reduce\_only\_endpoint  
Observability: counter http\_emergency\_reduce\_only\_calls\_total.  
S8.8 — Owner endpoint: GET /api/v1/status (Patch D)  
Allowed paths: crates/soldier\_infra/http/{router.rs,status.rs} and read-only state accessors  
New endpoint: GET /api/v1/status  
Required endpoint-level tests: yes  
Acceptance criteria: HTTP 200 JSON includes keys:  
trading\_mode, risk\_state, evidence\_chain\_state, bunker\_mode\_active  
policy\_age\_sec, last\_policy\_update\_ts  
f1\_cert\_state, f1\_cert\_expires\_at  
disk\_used\_pct, snapshot\_coverage\_pct  
atomic\_naked\_events\_24h, 429\_count\_5m  
deribit\_http\_p95\_ms, ws\_event\_lag\_ms  
Tests: crates/soldier\_infra/tests/test\_http\_status.rs::test\_status\_endpoint\_returns\_required\_fields  
Observability: counter http\_status\_calls\_total.  
Slice 9 — Rate Limit Circuit Breaker \+ WS Gaps \+ Reconcile \+ Zombie Sweeper  
Slice intent: survive throttling and data gaps; block opens until safe.

S9.1 — Rate limiter priority \+ brownout  
Allowed paths: crates/soldier\_infra/api/rate\_limit.rs  
Acceptance criteria: priority EMERGENCY\_CLOSE\>CANCEL\>HEDGE\>OPEN\>DATA; shed DATA first; block OPEN under pressure.  
Tests: crates/soldier\_infra/tests/test\_rate\_limiter.rs::test\_rate\_limiter\_priority\_preemption  
Evidence artifacts: artifacts/deribit\_testnet\_trade\_final\_20260103\_020002.log (F‑05)  
Observability: gauge rate\_limiter\_tokens, counter rate\_limiter\_shed\_total{class}.  
S9.2 — 10028/too\_many\_requests \=\> Kill \+ reconnect \+ reconcile  
Allowed paths: crates/soldier\_infra/api/\*\*, crates/soldier\_core/recovery/reconcile.rs  
Acceptance criteria: 10028 triggers Kill immediately; backoff; reconcile before resume.  
Tests: crates/soldier\_infra/tests/test\_rate\_limiter.rs::test\_rate\_limit\_10028\_triggers\_kill\_and\_reconnect  
Observability: counter rate\_limit\_10028\_total.  
S9.3 — WS gap detection (book/trades/private) \=\> Degraded \+ REST snapshots  
Allowed paths: crates/soldier\_core/recovery/ws\_gap.rs  
Acceptance criteria: per-channel continuity rules; gap \=\> Degraded \+ resubscribe \+ snapshot rebuild.  
Tests:  
crates/soldier\_core/tests/test\_ws\_gap.rs::test\_orderbook\_gap\_triggers\_resubscribe\_and\_snapshot  
crates/soldier\_core/tests/test\_ws\_gap.rs::test\_trades\_gap\_triggers\_reconcile  
Observability: counter ws\_gap\_count\_total{channel}.  
S9.4 — OpenPermission latch  
Allowed paths: crates/soldier\_core/risk/open\_permission.rs  
Acceptance criteria: opens paused until explicit reconcile success clears latch.  
Tests: crates/soldier\_core/tests/test\_open\_permission.rs::test\_open\_permission\_blocks\_opens\_until\_reconciled  
S9.5 — Zombie sweeper (ghost orders \+ orphan fills)  
Allowed paths: crates/soldier\_core/recovery/zombie\_sweeper.rs  
Acceptance criteria: cancel ghost s4: orders lacking ledger; reconcile orphan fills via REST; no duplicates via trade-id registry.  
Tests:  
crates/soldier\_core/tests/test\_reconcile.rs::test\_orphan\_fill\_reconciles\_and\_no\_duplicate  
crates/soldier\_core/tests/test\_zombie\_sweeper.rs::test\_zombie\_sweeper\_cancels\_ghost\_order  
Observability: counter ghost\_order\_canceled\_total, orphan\_fill\_reconciled\_total.  
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
Tests:  
crates/soldier\_core/tests/test\_truth\_capsule.rs::test\_truth\_capsule\_written\_before\_dispatch\_and\_fk\_linked  
crates/soldier\_core/tests/test\_truth\_capsule.rs::test\_truth\_capsule\_write\_failure\_forces\_reduceonly  
Rollout/rollback: hot-path; rollback \= disable trading opens (ReduceOnly) if writer unstable (must remain fail-closed).  
Observability: gauge parquet\_queue\_depth, counter truth\_capsule\_write\_errors\_total.  
S10.2 — Decision Snapshot capture/persist/link (Patch A requirement)  
Allowed paths: crates/soldier\_core/analytics/decision\_snapshot.rs, crates/soldier\_core/analytics/truth\_capsule.rs  
Acceptance criteria: L2 top‑N snapshot persisted; decision\_snapshot\_id stored in TruthCapsule; failure treated as evidence failure (opens blocked).  
Tests:  
crates/soldier\_core/tests/test\_decision\_snapshot.rs::test\_decision\_snapshot\_is\_required\_and\_linked  
crates/soldier\_core/tests/test\_decision\_snapshot.rs::test\_decision\_snapshot\_write\_failure\_blocks\_opens  
Observability: counter decision\_snapshot\_written\_total, decision\_snapshot\_write\_errors\_total.  
S10.3 — Attribution rows \== fills (+ joins)  
Allowed paths: crates/soldier\_core/analytics/attribution.rs  
Acceptance criteria: for each fill, one attribution row with truth\_capsule\_id and friction fields.  
Tests: crates/soldier\_core/tests/test\_attribution.rs::test\_attribution\_row\_links\_truth\_capsule  
S10.4 — PnL decomposition units enforced (Python)  
Allowed paths: python/analytics/pnl\_attribution.py  
Acceptance criteria: theta/day, vega/1pct; raw+normalized stored.  
Tests: python/tests/test\_pnl\_attribution.py::test\_pnl\_decomposition\_theta\_units  
S10.5 — Time drift gate \=\> ReduceOnly  
Allowed paths: crates/soldier\_core/risk/time\_drift\_gate.rs  
Acceptance criteria: drift threshold triggers ReduceOnly; exposed in /status.  
Tests: crates/soldier\_core/tests/test\_time\_drift.rs::test\_time\_drift\_gate\_forces\_reduceonly  
Slice 11 — SVI Stability Gates \+ Arb Guards  
S11.1 — RMSE/drift gates (liquidity-aware)  
Allowed paths: crates/soldier\_core/quant/svi\_fit.rs  
Tests: crates/soldier\_core/tests/test\_svi.rs::test\_svi\_rmse\_drift\_gates, ...::test\_low\_depth\_accepts\_looser\_thresholds  
S11.2 — Arb guards (convexity/calendar/density)  
Allowed paths: crates/soldier\_core/quant/svi\_arb.rs  
Tests: crates/soldier\_core/tests/test\_svi.rs::test\_svi\_arb\_guard\_convexity\_rejects  
S11.3 — NaN/Inf guard holds last fit  
Allowed paths: crates/soldier\_core/quant/svi\_fit.rs  
Tests: crates/soldier\_core/tests/test\_svi.rs::test\_svi\_nan\_guard\_holds\_last\_fit  
(Observability for Slice 11: gauges svi\_rmse, svi\_drift\_pct, counters svi\_guard\_trips\_total, svi\_arb\_guard\_trips\_total.)

Slice 12 — Fill Simulator \+ Slippage Calibration  
S12.1 — Deterministic fill simulator (book-walk \+ fees)  
Allowed paths: crates/soldier\_core/sim/exchange.rs  
Tests: crates/soldier\_core/tests/test\_fill\_sim.rs::test\_fill\_simulator\_deterministic\_wap  
S12.2 — Slippage calibration \+ safe default (1.3)  
Allowed paths: crates/soldier\_core/analytics/slippage\_calibration.rs, python/commander/analytics/slippage\_calibration.py  
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
Allowed paths: python/governor/replay\_gatekeeper.py  
Acceptance criteria: uses Decision Snapshots; hard fail if coverage \<95%; apply realism\_penalty\_factor; require penalized PnL \> 0\.  
Tests:  
python/tests/test\_replay\_gatekeeper.py::test\_replay\_gatekeeper\_penalized\_pnl\_gate  
python/tests/test\_replay\_gatekeeper.py::test\_replay\_fails\_when\_snapshot\_coverage\_below\_95  
Evidence artifacts: artifacts/policy\_patches/\<ts\>\_result.json  
Observability: log ReplayGatekeeperResult{coverage\_pct, net\_pnl\_penalized, pass}.  
S13.2 — Disk retention \+ watermarks (Patch A semantics)  
Allowed paths: crates/soldier\_infra/storage/retention.rs, crates/soldier\_core/infra/disk\_watermarks.rs  
Acceptance criteria:  
80% disk: pause full tick/L2 archives only; Decision Snapshots continue; does NOT force Degraded by itself.  
85% disk: force ReduceOnly (Degraded).  
92% disk: Kill.  
Tests: crates/soldier\_core/tests/test\_disk\_watermarks.rs::test\_disk\_watermark\_stops\_tick\_archives\_and\_forces\_reduceonly  
Observability: gauge disk\_used\_pct, counter tick\_archive\_paused\_total.  
S13.3 — Canary rollout (Shadow→Canary→Full) \+ abort/rollback  
Allowed paths: python/governor/canary\_rollout.py  
Tests: python/tests/test\_canary\_rollout.py::test\_canary\_rollout\_aborts\_on\_slippage  
S13.4 — AutoReviewer daily \+ incident reports \+ human approval gate  
Allowed paths: python/reviewer/{daily\_ops\_review.py,incident\_review.py}  
Tests: python/tests/test\_reviewer.py::test\_autoreviewer\_blocks\_aggressive\_without\_human\_approval  
S13.5 — F1 cert generation \+ CI gate  
Allowed paths: python/tools/f1\_certify.py  
Tests: python/tests/test\_f1\_certify.py::test\_f1\_cert\_fail\_on\_atomic\_naked\_event  
Evidence artifacts: artifacts/F1\_CERT.json, artifacts/F1\_CERT.md  
F) Dependencies DAG (Phase 4\)  
Slice 10 \+ Slice 12 → S13.1  
S13.1 → S13.3 (replay pass required before canary)  
S13.2 \+ S13.4 \+ S13.5 must be in place before any “enable live” decision.  
G) De-scope line (Phase 4\)  
No “mainnet enable” switch is included; Phase 4 delivers controls and gates only.  
3\) PATCH PLAN for specs/IMPLEMENTATION\_PLAN.md (patch-style edits)  
Goal: add per-phase structure without renumbering Slices 1–13; incorporate contract Patch A–D; keep slice numbering intact.

Patch 3.1 — Insert Phase Structure \+ WIP=1 immediately after “Global invariants”  
Insert after the existing section: Global invariants (apply across slices):

\+\#\# Phase Structure (Contract §6)  
\+  
\+\*\*WIP=1 (NON-NEGOTIABLE):\*\* Only one Story (S{slice}.{n}) may be in-flight at a time. Each Story lands with code \+ named tests \+ required artifacts/evidence \+ rollout/rollback notes.  
\+  
\+\#\#\# Phase → Slice Mapping Table  
\+| Phase | Goal | Slices Included | Exit Criteria | Key Risks |  
\+|---|---|---|---|---|  
\+| Phase 1 — Foundation | Deterministic intents \+ WAL/TLSM \+ initial gates behind chokepoint | Slices 1–5 | Gate ordering test passes; WAL replay no resend; preflight rejects illegal orders | Gate bypass; rounding drift; WAL durability bug |  
\+| Phase 2 — Guardrails | Atomic containment \+ PolicyGuard (F1/Evidence/Bunker) \+ reconcile/rate-limit \+ endpoints | Slices 6–9 | Mixed-state containment tests pass; endpoint tests pass; 10028 recovery tests pass | Recon races; rate limiter starvation; fail-open |  
\+| Phase 3 — Data Loop | TruthCapsules \+ Decision Snapshots (required) \+ attribution \+ sim/calibration \+ SVI validity | Slices 10–12 | 100% capsule+snapshot linkage; evidence failure blocks opens | Writer backpressure; snapshot gaps |  
\+| Phase 4 — Live Fire Controls | Replay gatekeeper \+ canary \+ reviews \+ watermarks \+ F1 cert | Slice 13 | Replay coverage\>=95% hard gate; F1 cert PASS required for opens | Replay wrong inputs; governance bypass |  
Patch 3.2 — Add phase headers without moving slice numbering  
Replace the single header before slices:

\-\#\# Vertical Slices (Ship Order)  
\+\#\# Vertical Slices (Ship Order)  
\+  
\+\#\# Phase 1 — Foundation (Slices 1–5)  
Insert before \#\#\# Slice 6...:

\+\#\# Phase 2 — Guardrails (Slices 6–9)  
Insert before \#\#\# Slice 10...:

\+\#\# Phase 3 — Data Loop (Slices 10–12)  
Insert before \#\#\# Slice 13...:

\+\#\# Phase 4 — Live Fire Controls (Slice 13\)  
Patch 3.3 — Amend Slice 8 to include Patch B/C/D \+ runtime F1 gate \+ endpoint test  
Within Slice 8 “Acceptance criteria:” append:

\+ \- PolicyGuard MUST enforce runtime F1 gate by reading \`artifacts/F1\_CERT.json\`: missing/stale/FAIL \=\> ReduceOnly (no opens), no grace.  
\+ \- EvidenceGuard (Patch B): EvidenceChainState \!= GREEN \=\> ReduceOnly, block opens; closes/hedges/cancels allowed; cooldown after recovery.  
\+ \- Bunker Mode (Patch C): network jitter thresholds \=\> ReduceOnly until stable cooldown.  
\+ \- Owner status endpoint (Patch D): provide read-only \`GET /api/v1/status\` and include an endpoint-level test.  
Within Slice 8 “Tests:” append:

\+ \- test\_status\_endpoint\_returns\_required\_fields (endpoint-level)  
\+ \- test\_f1\_cert\_missing\_forces\_reduceonly  
\+ \- test\_f1\_cert\_fail\_forces\_reduceonly  
\+ \- test\_f1\_cert\_stale\_forces\_reduceonly  
\+ \- test\_evidence\_guard\_blocks\_opens\_allows\_closes  
\+ \- test\_bunker\_mode\_ws\_event\_lag\_breach\_blocks\_opens  
Patch 3.4 — Amend Slice 10 to explicitly require Decision Snapshots (Patch A replay input prerequisite)  
Within Slice 10 “Acceptance criteria:” append:

\+ \- Decision Snapshots (decision-time L2 top-N) MUST be persisted and linked by \`decision\_snapshot\_id\` for every dispatched intent.  
\+ \- If Decision Snapshot persistence fails, treat as evidence failure: block opens and enter ReduceOnly (fail-closed).  
Patch 3.5 — Amend Slice 13 replay semantics to match Patch A (archives optional; snapshots required)  
Within Slice 13 “Acceptance criteria:” append:

\+ \- Replay Gatekeeper MUST use Decision Snapshots as REQUIRED replay input and MUST HARD FAIL if \`snapshot\_coverage\_pct \< 95%\`.  
\+ \- Full tick/L2 archives are OPTIONAL; pausing them due to disk watermarks MUST NOT force Degraded by itself (only snapshot failure/coverage failure does).  
Patch 3.6 — (If needed) Add one file without adding a new slice (no renumbering)  
If Slice 10 currently lacks an explicit Decision Snapshot module, add file reference (still Slice 10):

\+File list (Slice 10):  
\+ \- crates/soldier\_core/analytics/decision\_snapshot.rs  
Justification: Patch A makes Decision Snapshots a required replay input; this is implementation detail within Slice 10, not a new slice.

If you want, I can also output a single, topologically ordered global Story landing order (S1.1 → … → S13.5) that enforces WIP=1 mechanically (one PR at a time), but the phase DAGs above are already consistent with that constraint.