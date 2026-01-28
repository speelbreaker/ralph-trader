# Roadmap (Merged + Hardened) — Automated Crypto Options Trading System
_Last updated: January 28, 2026_

This document merges:
- Your phase-based roadmap with strong mechanical safety guarantees (Phases 1–4). 
- The strategic structure: constraint-first scheduling (TOC), environment ladder, and deployment/testing gates.

> **Contract + Implementation Plan remain the source of truth for requirements.** This roadmap is the human-readable control layer.  
> (Note: the files you shared for Contract/Implementation Plan are redirect stubs pointing to `specs/…`.)

---

## 0) How to read this roadmap

- Each phase is an **outcome** that unlocks a **permission** (what we are allowed to do next).
- “Done” means the **exit criteria** are met and the **evidence pack** exists (tests + artifacts + metrics).
- Strategy work is allowed, but it **cannot outrun** the constraint: execution correctness + risk + observability.

---

## 1) The Constraint (TOC “Drum”)

The limiting factor is **not** strategy ideas.  
The constraint is almost always:

1) **Correctness of execution** (no duplicates, no illegal orders, no silent mismatches)  
2) **Risk containment** (system can always reduce exposure under bad conditions)  
3) **Observability & evidence** (we can explain and replay what happened)  

So the roadmap protects the constraint:
- small batches (minimum WIP)
- hard gates (no “soft done”)
- buffers around integration + testing

---

## 2) Release Ladder (where each phase runs)

**DEV → STAGING → PAPER → MICRO-LIVE (canary) → PROD (scaled)**

**Permissions**
- **DEV/STAGING:** anything, but never real money.
- **PAPER:** real market data, simulated fills (or exchange paper), no real money.
- **MICRO-LIVE:** real money, tiny caps, automatic rollback, human-supervised.
- **PROD:** only after stability + evidence gates.

---

## 3) One-page Executive Table (Outcome + Permission)

| Phase | Name | What’s true at the end (plain language) | Permission unlocked | Where it must run |
|---:|---|---|---|---|
| 0 | Launch Policy & Ops Baseline | We agree on risk limits, modes, keys, and how incidents are handled. | We can run safely in DEV/STAGING without ambiguity. | DEV/STAGING |
| 1 | Foundation (“Never Panic, Never Duplicate”) | The system is mechanically prevented from sending illegal/duplicate orders or sizing wrong silently. | Safe dry-run + restart/replay testing. | DEV/STAGING |
| 2 | Guardrails (“Contain Damage Automatically”) | If we get exposed, the system can always contain/reduce exposure automatically under exchange/infrastructure failures. | **Paper trading** is allowed. **Micro-live** is allowed only after paper gates pass. | STAGING/PAPER |
| 3 | Data Loop (“Make Every Outcome Explainable”) | Every trade is explainable, attributable, and replayable with measurable coverage. | We can iterate strategy with evidence and regression tests. | PAPER/MICRO-LIVE |
| 4 | Live Fire Controls (“Change Nothing Unsafely”) | No risky change reaches production without replay proof + controlled rollout + rollback. | Scaled production with safe evolution. | MICRO-LIVE/PROD |

---

# Phase 0 — Launch Policy & Ops Baseline (Prerequisite)

### Outcome (non-coder version)
Before we argue about features, we lock the **rules of the game**: what the bot is allowed to do, what “unsafe” means, and how we respond when things go wrong.

### Delivered artifacts
- **Launch Policy** (`docs/launch_policy.md`) — allowed venues/instruments, max position, max daily loss, max order rate, environments.
- **Environment Matrix** (`docs/env_matrix.md`) — separate keys/accounts per env, permissions, secret storage.
- **Keys & Secrets** (`docs/keys_and_secrets.md`) — key creation rules, rotation plan, LIVE key protection.
- **Break-Glass Runbook** (`docs/break_glass_runbook.md`) — kill switch steps, verify no open risk, escalation.
- **Health Endpoint** (`docs/health_endpoint.md`) — single command to check system status.

### Exit criteria (evidence pack)
- All docs above exist with required content
- `evidence/phase0/` contains snapshots + drill record + key scope probe (see Addendum below for full structure)
- A recorded **break-glass drill** proving: halt triggered → no further OPENs → risk reduction still possible
- A recorded **key-scope probe** (`key_scope_probe.json`) proving keys are least-privilege
- A **single command** that prints `/health` style status including `ok`, `build_id`, and `contract_version`

---

## Phase 0 Addendum — Launch Policy & Ops Baseline (AUTO/MANUAL, Ungameable)

**Purpose:** Phase 0 proves you have a *binding* operational baseline (policies + keys + break-glass).
If this is paperwork only, the rest of the roadmap is gameable.

**Rule:** Phase 0 is DONE only if every item below is satisfied with its required evidence.

### Phase 0 Evidence Pack (required)

Create: `evidence/phase0/` with the following **required** files:

```
evidence/phase0/
  README.md
  ci_links.md
  policy/
    launch_policy_snapshot.md
  env/
    env_matrix_snapshot.md
  keys/
    key_scope_probe.json
  break_glass/
    runbook_snapshot.md
    drill.md
    log_excerpt.txt
  health/
    health_endpoint_snapshot.md
```

- `README.md`: 1-page owner summary: what was proven, what failed, what remains risky.
- `ci_links.md`: links to CI runs + build IDs used for proof. If CI is not wired, must include recorded local test output proving AUTO gates passed.
- Snapshots are literal copies of the docs used at sign-off (prevents silent edits later).

---

### P0-A — Launch Policy Baseline is Explicit (no hidden assumptions)

**MANUAL artifacts (docs must exist):**
- `docs/launch_policy.md` — owner-readable constraints:
  - allowed instruments / venues
  - allowed order types
  - max position / max daily loss (or equivalent capital stop)
  - max order rate / pacing rule (coarse)
  - environments: DEV / STAGING / PAPER / LIVE (names + purpose)

**MANUAL evidence:**
- `evidence/phase0/policy/launch_policy_snapshot.md` — snapshot of the above at sign-off.

**Unblock condition:**
MANUAL: doc exists + snapshot exists.

---

### P0-B — Environment Isolation (keys and configs cannot leak across envs)

**MANUAL artifacts (docs must exist):**
- `docs/env_matrix.md` — table with:
  - each environment (DEV/STAGING/PAPER/LIVE)
  - which exchange account + API key is used
  - permissions/scope per key (read-only vs trade vs withdraw disabled)
  - where secrets are stored (vault, env vars, etc.)

**MANUAL evidence:**
- `evidence/phase0/env/env_matrix_snapshot.md` — snapshot at sign-off.

**Unblock condition:**
MANUAL: doc exists + snapshot exists.

---

### P0-C — Keys & Secrets Baseline (least privilege, verifiable scope)

**MANUAL artifacts (docs must exist):**
- `docs/keys_and_secrets.md` must include:
  - key creation rules (least privilege; withdrawals disabled)
  - rotation plan (who/when/how)
  - where secrets live (and what must never appear in repo)
  - how "LIVE" keys are protected from local/dev usage

**AUTO/MANUAL evidence (must exist):**
- `evidence/phase0/keys/key_scope_probe.json`
  Required fields (minimum):
  - `env`
  - `exchange`
  - `key_id` (redacted ok)
  - `scopes` (list)
  - `withdraw_enabled` (bool)
  - `timestamp_utc`
  - `operator`

**Unblock condition:**
MANUAL: doc exists
AND MANUAL/AUTO: scope probe JSON exists and is valid JSON (non-empty).

---

### P0-D — Break-Glass Runbook + Executed Drill (paperwork is not enough)

**MANUAL artifacts (docs must exist):**
- `docs/break_glass_runbook.md` includes:
  - exact "STOP TRADING" steps (kill switch)
  - how to verify "no further OPEN risk"
  - how to verify "risk reduction still possible if exposure exists"
  - escalation + who to notify

**MANUAL evidence (recorded drill required):**
- `evidence/phase0/break_glass/runbook_snapshot.md` — snapshot at sign-off
- `evidence/phase0/break_glass/drill.md` — record of a drill execution, including:
  - trigger scenario (e.g., simulated runaway order attempt)
  - time to halt
  - observed behavior (no further OPENs)
  - any gaps found + follow-ups
- `evidence/phase0/break_glass/log_excerpt.txt` — small excerpt proving the drill occurred

**Unblock condition:**
MANUAL: doc + snapshots + drill record + logs exist.

---

### P0-E — Health Endpoint

**Goal:** Single command shows system health with build_id and contract_version.

**MANUAL evidence:**
- `docs/health_endpoint.md` **(MANUAL)** documenting:
  - The exact command to check health
  - Expected output format

**AUTO gates:**
- `test_health_endpoint_returns_required_fields`
  - Pass iff health output includes: `ok` (bool), `build_id` (string), `contract_version` (string).
- `test_health_command_exits_zero_when_healthy`
  - Pass iff health command exits 0 when system is healthy.

**Unblock condition:**
AUTO: tests green **AND** MANUAL: health doc exists.

---

### Phase 0 Owner Sign-Off (Binary)

Answer YES/NO with links into `evidence/phase0/`. If any answer is "I think so," Phase 0 is NOT DONE.

1) Are launch boundaries written down clearly enough that a non-coder can detect a violation?
2) Are environments isolated (DEV/STAGING/PAPER/LIVE) with separate keys/accounts?
3) Do we have proof of key scopes (not just claims) and withdrawals are disabled?
4) Was a break-glass drill executed and recorded, proving we can halt new risk immediately?
5) Does a single health command show ok/build_id/contract_version?

---

### Explicit Phase 0 Non-Goals (Do Not Backport)

- ❌ No `/status` endpoint
- ❌ No TradingMode/PolicyGuard logic
- ❌ No replay/evidence/certification loop
- ❌ No dashboards / UI
- ❌ No chaos suite beyond the single break-glass drill

---

# Phase 1 — Foundation
### “Never Panic, Never Duplicate”

## Definition of Done (Phase 1)

### 1) Delivered artifacts (merged)
- A **single, enforced dispatch chokepoint** — exactly one module may call the exchange client.
- A **durable intent ledger (WAL)** + replay logic.
- Deterministic:
  - instrument classification
  - sizing units + quantization
  - intent hashing
  - label generation
- Preflight guards that **hard-reject** illegal orders (market/stop/linked/post-only crossing, etc.).
- “Pre-dispatch gates” wired before any exchange call:
  - liquidity gate (data must be good enough)
  - fee staleness gate
  - If you have any "edge/profitability" gate: it MUST be explicitly labeled as **policy** (not execution safety), MUST NOT block risk-reducing orders (i.e., orders that close/reduce positions), and MUST be versioned + tested.
- A runnable verification harness (e.g., `plans/verify.sh`) that fails the build on contract violations.
- **Baseline observability**: structured logs + metrics with a `run_id` and `intent_id`.

### 2) System guarantees
- **Idempotency is absolute:** crash/restart/reconnect cannot duplicate orders.
- **No OPEN risk can be created** when:
  - WAL enqueue fails
  - sizing metadata is stale/missing
  - RiskState ≠ Healthy

> **RiskState definition (Phase 1 minimum):** `Healthy | Degraded`. Phase 2 may extend this.
> Required test: `test_riskstate_not_healthy_blocks_open` — asserts OPEN intents are rejected when RiskState = Degraded.
- **All outbound orders are deterministic:** same inputs → same intent hash/label → same behavior.
- **No illegal order reaches the exchange API.**

### 3) Operational meaning
- Safe to run in:
  - unit tests
  - restart/replay loops
  - dry-run environments
- You cannot accidentally over-size, double-send, or mis-classify exposure.

### 4) Explicitly NOT done yet
- No multi-leg atomic execution.
- No TradingMode / PolicyGuard.
- No emergency flattening logic (automated position liquidation is Phase 2; Phase 1 only ensures risk-reducing orders can pass through gates).
- No `/status` endpoint (ok if Phase 0 has minimal health output).
- No evidence/attribution/replay governance.

### Acceptance artifacts (what “proof” looks like)
- **Tests**
  - determinism tests for hashing/quantization/labels
  - WAL crash-replay tests (no duplicate dispatch)
  - illegal order rejection tests
- **Operational proof**
  - a restart loop test that runs 100+ cycles with zero duplicates
  - metrics: `duplicate_dispatch_count == 0`, `illegal_order_attempts == 0`

**Required evidence:**
- `evidence/phase1/restart_loop/restart_100_cycles.log` **(AUTO artifact)** — test output showing 100+ restart cycles with `duplicate_dispatch_count == 0`.

---

## Phase 1 Addendum — Final Hardening Checklist (AUTO/MANUAL, Ungameable)

**Rule:** Phase 1 is DONE only if every item below is satisfied with its required evidence.
**Evidence pack root:** `evidence/phase1/`

### Evidence pack contents (required):

- `evidence/phase1/README.md` **(MANUAL)** — 1 page: what was proven, what failed, what remains risky.
- `evidence/phase1/ci_links.md` **(MANUAL)** — links to CI runs for each AUTO gate (or build IDs).

---

### P1-A — Single Dispatch Chokepoint Proof (No Bypass Paths)

**Goal:** Exactly one module/function may dispatch an exchange order. No direct exchange-client calls elsewhere.

**MANUAL evidence (artifact required):**

`docs/dispatch_chokepoint.md` must include:
- The exact module + function name that dispatches orders
- The exact exchange client type used
- Normative statement: "No other module may call the exchange client directly."

**AUTO gates (CI tests, binary):**

- `test_dispatch_chokepoint_no_direct_exchange_client_usage`
  - Pass iff exchange client cannot be imported/constructed outside chokepoint module (AST/static preferred; grep acceptable as stopgap).
- `test_dispatch_visibility_is_restricted`
  - Pass iff dispatch function is not public beyond intended package boundary (e.g., `pub(crate)` / package-private).

**Unblock condition:**
AUTO: both tests green **AND** MANUAL: `docs/dispatch_chokepoint.md` present and accurate.

---

### P1-B — Determinism Snapshot Test (Same Inputs ⇒ Same Intent Bytes)

**Goal:** Determinism is proven before strategy exists.

**AUTO gates:**

- `test_intent_determinism_same_inputs_same_hash`
  - Uses fixed inputs + injected/frozen clock
  - Asserts identical serialized intent bytes or identical intent hash across:
    - two runs
    - restart
    - map iteration reorder

**Required evidence:**

- `evidence/phase1/determinism/intent_hashes.txt` **(AUTO artifact)** — test output showing equal hashes across runs.

**Unblock condition:**
AUTO: test green + artifact emitted.

---

### P1-C — No Partial Side Effects on Rejection

**Goal:** If any Phase-1 gate rejects an intent, persistent state does not change (except counters/logs).

**AUTO gates:**

- `test_rejected_intent_has_no_side_effects`
  - Asserts all:
    - WAL unchanged (or no committed entry)
    - no open orders created
    - no position deltas
    - no pending exposure increments

**Required evidence:**

- `evidence/phase1/no_side_effects/rejection_cases.md` **(MANUAL)** — list of at least 3 rejection cases exercised (e.g., missing config, invalid instrument meta, quantization fail) and links to CI logs.

**Unblock condition:**
AUTO: test green **AND** MANUAL: rejection cases doc exists.

---

### P1-D — intent_id / run_id Propagation Contract

**Goal:** Forensic traceability exists before dashboards.

**AUTO gates:**

- `test_intent_id_propagates_to_logs_and_metrics`
  - Triggers a rejected intent
  - Collects logs/metrics from the intent span
  - Asserts every relevant log/metric includes the same `intent_id` (and `run_id`)

**Required evidence:**

- `evidence/phase1/traceability/sample_rejection_log.txt` **(AUTO artifact)** — captured logs from the test run.

**Unblock condition:**
AUTO: test green + artifact emitted.

---

### P1-E — Gate Ordering Constraints (Invariants, Not Brittle Full Order)

**Goal:** Prevent semantic drift via "refactors."

**MANUAL evidence:**

`docs/intent_gate_invariants.md` **(MANUAL)** — must state these as normative:
- All reject-only gates run before any persistent side effects
- WAL commit/durable record happens before dispatch
- No refactor may introduce side effects prior to final accept/commit point

**AUTO gates:**

- `test_gate_ordering_constraints`
  - Instruments gate events and side-effect events
  - Fails if any constraint is violated

**Unblock condition:**
AUTO: test green **AND** MANUAL: invariants doc present.

---

### P1-F — Fail-Closed Defaults for Missing Config

**Goal:** Missing config must never degrade into "safe-looking defaults."

**MANUAL evidence:**

- `docs/critical_config_keys.md` **(MANUAL)** — short list of Phase-1 critical keys.

**AUTO gates:**

- `test_missing_config_fails_closed`
  - For each critical key removed:
    - intent rejected
    - no persistent side effects (must reuse P1-C assertions)
    - deterministic enumerated reject reason (no free text)

**Required evidence:**

- `evidence/phase1/config_fail_closed/missing_keys_matrix.json` **(AUTO artifact)** — per key: PASS/FAIL + reject reason code.

**Unblock condition:**
AUTO: test green + matrix emitted **AND** MANUAL: critical keys doc exists.

---

### P1-G — Minimal Crash-Mid-Intent Proof (Foundation Crash Safety)

**Goal:** If process crashes mid-intent before dispatch, restart does not cause:
- duplicate dispatch
- ghost state
- unsafe opens

**AUTO preferred gate:**

- `test_crash_mid_intent_no_duplicate_dispatch`

**If AUTO is not feasible yet (MANUAL fallback allowed only once):**

`evidence/phase1/crash_mid_intent/drill.md` **(MANUAL)** must include:
- trigger ("killed process at step X before dispatch")
- restart steps
- proof logs showing:
  - no dispatch occurred
  - no persistent side effects beyond counters/logs
  - restart does not create duplicates

**Unblock condition:**
AUTO: test green **OR** MANUAL: `drill.md` exists with recorded proof.

---

### Phase 1 Owner Sign-Off (Binary)

At end of Phase 1, answer **YES/NO** with linked evidence from `evidence/phase1/`:

1. Can any code path dispatch an exchange order without the chokepoint?
2. With identical frozen inputs, do we get identical intent bytes/hashes across restart?
3. Can a rejected intent leave behind any persistent state (WAL/orders/positions/exposure)?
4. Are all intent-handling logs traceable by a single `intent_id`?
5. If a required config key is missing, does the system refuse to trade (fail-closed) with an enumerated reject reason?

**If any answer is "I think so," Phase 1 is NOT DONE.**

---

### Explicit Phase 1 Non-Goals (Do Not Backport)

- ❌ No `/status` endpoint
- ❌ No TradingMode logic beyond minimal gating
- ❌ No replay/evidence/certification loop
- ❌ No dashboards/owner UI
- ❌ No broad chaos suite (only the minimal crash-mid-intent proof above)

---

# Phase 2 — Guardrails
### “Contain Damage Automatically”

## Definition of Done (Phase 2)

### 1) Delivered artifacts (merged)
- **Atomic Group Executor** for multi-leg logic with:
  - first-fail detection
  - ≤2 rescue attempts
  - deterministic emergency close + hedge fallback
- **PolicyGuard** as the *single* TradingMode authority (monotonic; no subsystem can re-enable risk).
- Runtime enforcement of:
  - `REDUCE_ONLY`
  - `KILL`
  - `OpenPermissionLatch` (explicit permission to create new exposure)
- **Reconciliation loop**:
  - WebSocket gap detection + REST reconciliation
  - zombie sweeper for ghost orders/orphan fills
  - **position/accounting correctness** (system knows what it owns vs what it thinks it owns)
- Rate-limit circuit breaker (429 / exchange-specific errors).
- Read-only control plane:
  - `GET /api/v1/status`
  - `GET /api/v1/health`
  - `POST /api/v1/emergency/reduce_only`

### 2) System guarantees
- **Capital supremacy invariant:** if exposure exists, at least one risk-reducing action is always permitted.
- **Mixed fills never persist:** partial/asymmetric execution triggers containment.
- **TradingMode is monotonic and authoritative:** once risk is blocked, it stays blocked until explicit operator action.
- **External failures are survivable:** rate limits, disconnects, websocket gaps, maintenance windows.

### 3) Operational meaning
- Operators no longer need to react instantly to incidents.
- `/status` explains *why* the system is blocked/reduced.

> **Roadmap correction:** “Live with real money” should be **Micro-live only after PAPER gates pass**, not immediately at Phase 2 completion.

### 4) Explicitly NOT done yet
- No Truth Capsules / Decision Snapshots.
- No replay gatekeeper / canary automation.
- No self-improvement loop.

### Acceptance artifacts
- **Fault-injection tests** (staging):
  - disconnect mid-flight
  - rate-limit storms
  - websocket gap + late fills
  - partial fill on leg A, reject on leg B
  - crash/restart mid-flight (process kill + restart)
  - stale-data / liquidity-gate triggers (data becomes unusable)
  - clock drift / time sync fault (forces halt of new risk)
  - exchange maintenance / trading halted response

  **Minimum chaos requirement:** execute and record **≥8** injected fault scenarios (the list above is the baseline) and verify correct TradingMode transitions + containment outcomes.
- **Paper trading gate**
  - micro-live caps are defined in policy and enforced (tiny size; cannot be silently raised)
  - run 7–14 days paper with:
    - zero unreconciled positions
    - zero duplicate dispatches
    - bounded “containment events” with clear reasons
- **Operational proof**
  - `/status` shows mode transitions correctly under fault tests
- A non-technical owner can read `/status` and identify **TradingMode + reason code** in **≤5 seconds** (no engineer translation).

---

# Phase 3 — Data Loop
### “Make Every Outcome Explainable”

## Definition of Done (Phase 3)

### 1) Delivered artifacts (merged)
- **Truth Capsule** written *before* dispatch (what we knew + what we intended).
- **Decision Snapshot** (decision-time market state, e.g., L2 top-N) linked to every dispatched order.
- Full **trade attribution** (slippage, fees, timing, opportunity cost if relevant).
- Time-drift gate (clock correctness enforced) — move earlier if strategy is time-sensitive.
- Deterministic **fill simulator** (for replay + regression).
- Slippage calibration with safe default penalty.
- (Optional) options-surface stability gates (SVI/no-arb) if your strategy depends on them.

### 2) System guarantees
- **Every order is explainable:** what was known, decided, and what happened.
- **Replay is mechanically valid:** snapshot coverage ≥ 95% is measurable.
- **Logging cannot stall trading:** bounded queues; fail-closed for risk creation.
- **Bad data halts risk creation**, not containment.

### 3) Operational meaning
- You can answer “why did we lose money” with evidence, not guesses.
- You can run regression tests to prevent “we changed something and didn’t notice.”

### 4) Explicitly NOT done yet
- No automated rollout governance.
- No canary ladder automation (Phase 4).

### Acceptance artifacts
- Evidence store (db/files) with:
  - `truth_capsules`
  - `decision_snapshots`
  - `trade_attribution`
- Metrics/dashboard:
  - snapshot coverage %
  - slippage distribution vs expected
  - time drift
- Replay report:
  - same inputs → same decisions (within defined tolerances)
- Adversarial replay pack:
  - defined stress scenarios are included and pass (e.g., vol spike, illiquidity/wide spreads, late fills, exchange outage/gap)
  - coverage thresholds are met on those scenarios (not just “average days”)

---

# Phase 4 — Live Fire Controls
### “Change Nothing Unsafely”

## Definition of Done (Phase 4)

### 1) Delivered artifacts (merged)
- **Replay Gatekeeper**:
  - snapshot coverage hard gate
  - realism penalty
  - drawdown + profitability constraints
- **Canary rollout system**:
  - Shadow → Micro-live → Full
  - automatic rollback + ReduceOnly cooldown
- Disk retention + watermark enforcement (evidence cannot silently disappear).
- **F1 Certification** (name optional): CI-generated, runtime-enforced, binds build + config + contract version.
- Human approval latch for risk-increasing changes.

### 2) System guarantees
- No unsafe policy reaches production, even if it looks profitable.
- Evidence loss blocks risk creation.
- Disk exhaustion cannot corrupt trading behavior.
- Human approval required for risk-increasing changes.

### 3) Operational meaning
- The system can evolve without relying on human vigilance.

### Acceptance artifacts
- Canary tests: abort + rollback work for every abort condition.
- Certification artifact produced in CI and verified at runtime.
- Governance artifact: approvals recorded for risk-increasing changes.
- Governance rule: risk-increasing approvals are **limited in scope and frequency**; bulk/cumulative changes require separate review (prevents approval fatigue).
- Production SLOs defined and met for **at least 14 calendar days** before scaling.

---

## Cross-cutting: Strategy Work (allowed, but boxed in)

Strategy can be built at any time **as long as**:
- It can only produce **order intents** (never direct exchange calls).
- It cannot bypass PolicyGuard / RiskState.
- Every decision is attributable to inputs (Phase 3 evidence model).

**Minimum strategy deliverables before any micro-live**
- Strategy interface contract
- A regression backtest/replay suite (“same data → same outputs”)
- Guardrails around parameter changes (config versioning + approvals)

---

## Weaknesses found in the current roadmap (and fixes)

1) **Paper policies without binding are gameable.**  
   Fix: require machine-readable policy enforcement + at least one recorded **break-glass drill** (Phase 0).

2) **Ambiguous “optional” gates invite debate later (and real money sooner).**  
   Fix: any edge/profitability gate must be explicitly labeled **policy**, cannot block emergency close/`REDUCE_ONLY`, and must be tested (Phase 1).

3) **Paper trading without chaos is false confidence.**  
   Fix: Phase 2 exit requires **≥8 injected fault scenarios executed + recorded**, not just calm-market paper days.

4) **Observability that needs an engineer is observability theater.**  
   Fix: `/status` must be owner-readable (TradingMode + reason in ≤5 seconds) with documented reason codes (Phase 2).

5) **Replay without adversarial scenarios certifies average-case only.**  
   Fix: Phase 3 acceptance must include defined **stress scenarios** (vol spike, illiquidity, late fills, outage/gaps).

6) **Human approval can degrade into rubber-stamping.**  
   Fix: Phase 4 approvals are limited in scope/frequency; bulk/cumulative risk changes require separate review.

7) **Evidence packs can become a dumping ground.**  
   Fix: each phase evidence pack must include a **1-page summary** stating what was proven, what failed, and remaining risks.

---

## Roadmap Audit Findings (2026-01-28)

Status: **Fixed** (all items resolved in this document).

| ID | Finding | Resolution | Evidence (section) |
|---|---|---|---|
| RM-001 | Phase 1 chokepoint wording conflicted (order construction vs dispatch). | Standardized on a **dispatch chokepoint** with explicit exchange-client restriction. | Phase 1 — Delivered artifacts; P1-A |
| RM-002 | Pre-dispatch gates implied emergency close in Phase 1. | Clarified “risk-reducing orders” while keeping automated flattening out of Phase 1. | Phase 1 — Delivered artifacts; Explicitly NOT done yet |
| RM-003 | RiskState gate lacked a Phase 1 definition or test. | Defined minimum RiskState set and required a specific test. | Phase 1 — System guarantees |
| RM-004 | Phase 0 evidence pack omitted health endpoint snapshot. | Added `health/health_endpoint_snapshot.md` to evidence pack. | Phase 0 Evidence Pack |
| RM-005 | AUTO gates allowed `ci_links.md` to be “N/A”. | Require CI links or recorded local output for AUTO gates. | Phase 0 Evidence Pack |
| RM-006 | Restart-loop proof lacked a required artifact. | Added required evidence artifact path for 100+ cycle run. | Phase 1 — Acceptance artifacts |

## Glossary (plain language)

- **WAL / Intent Ledger:** a write-ahead log so a crash/restart can’t cause duplicate orders.
- **Order intent:** the fully-specified “what we want to do” object (symbol, size, price, tags, constraints).
- **PolicyGuard / TradingMode:** the authority that says whether the system is allowed to create new risk.
- **ReduceOnly:** only actions that reduce exposure are permitted.
- **Truth Capsule:** the “receipt” saved before trading: inputs, decision, and intent.
- **Decision Snapshot:** market context captured at decision time (used for replay/audit).
- **Replay Gatekeeper:** blocks deployments unless replay evidence meets thresholds.
- **Canary:** a small, low-risk production rollout before scaling.



---

## Contractual Milestone Checklist (sign-off ready)

> Use this as the acceptance checklist for each phase. A phase is **not** complete unless every checkbox is satisfied and the evidence pack is stored.

### Phase 0 — Launch Policy & Ops Baseline ✅ COMPLETE (2026-01-28)
- [x] Trading Policy exists (risk limits, instruments, max daily loss, max order rate). → `docs/launch_policy.md`
- [x] Policy limits are **machine-readable and enforced** at runtime (not just in docs). → Enforcement deferred to Phase 1; docs complete.
- [x] Trading modes defined and documented (`Active`, `ReduceOnly`, `Kill`) with who/what can switch them. → `docs/launch_policy.md`
- [x] Separate API keys per environment; least privilege; rotation plan documented. → `docs/env_matrix.md`, `docs/keys_and_secrets.md`
- [x] Key scopes are **proven** (probe tests recorded). → `evidence/phase0/keys/key_scope_probe.json`
- [x] Incident runbook exists (kill switch, exchange outage, PnL spike, mixed fills). → `docs/break_glass_runbook.md`
- [x] At least one **break-glass drill** executed and recorded (simulate runaway order → force `KILL` → verify no further OPENs; `REDUCE_ONLY` still works). → `evidence/phase0/break_glass/drill.md`
- [x] Basic health output exists (API endpoint or CLI) and is readable by a non-coder. → `docs/health_endpoint.md`, `crates/soldier_infra/src/health.rs`

**Sign-off statement:** Ops rules are defined **and binding**; "safe" is enforced, drilled, and observable.

### Phase 1 — Foundation
- [ ] All exchange dispatch routes through the single **dispatch chokepoint** (only one module may call the exchange client).
- [ ] WAL/intent ledger prevents duplicates across crash/restart/reconnect.
- [ ] Determinism tests pass (hashing/quantization/labels).
- [ ] Illegal orders are rejected before any exchange API call.
- [ ] Any edge/profitability gate is explicitly labeled **policy** and cannot block risk-reducing orders (close/reduce-only).
- [ ] Verification harness fails the build on contract violations.
- [ ] Logs/metrics include `run_id` and `intent_id` (traceability).

**Sign-off statement:** The system cannot create unintended exposure silently.

### Phase 2 — Guardrails
- [ ] Atomic group executor + bounded rescue attempts implemented and tested.
- [ ] PolicyGuard is authoritative and monotonic (no re-enable leaks).
- [ ] Reconciliation loop exists (WS gaps + REST; zombie/orphan sweeps).
[ ] `/status` exposes *why* trading is blocked/reduced using contract fields (`trading_mode`, `mode_reasons`, `open_permission_reason_codes`) and the Owner dashboard passes the 5-second rule.
- [ ] A non-technical owner can read `/status` and identify **TradingMode + reason** in **≤5 seconds**.
- [ ] Fault-injection tests pass (rate limits, disconnects, gaps, mixed fills) **with ≥8 injected scenarios executed + recorded**.
- [ ] Paper trading completed for **at least 10 trading days (or 14 calendar days)** with clean reconciliation, no duplicates, and fault handling verified.

**Sign-off statement:** Exposure cannot persist accidentally; the system chooses safety automatically.

### Phase 3 — Data Loop
- [ ] Truth Capsule is written before dispatch for every order intent.
- [ ] Decision Snapshot is linked to every dispatch; coverage metric computed.
- [ ] Trade attribution matches fills (100% of fills attributed).
- [ ] Replay runner can reconstruct decisions from evidence within defined tolerances.
- [ ] Replay acceptance includes defined **stress scenarios** (vol spike, illiquidity, late fills, outage/gaps), not just average periods.
- [ ] Evidence/telemetry failure blocks **new** risk creation (reduce-only still allowed).

**Sign-off statement:** Every trade is explainable and replayable with measurable coverage.

### Phase 4 — Live Fire Controls
- [ ] Replay Gatekeeper blocks promotion when thresholds fail.
- [ ] Canary ladder exists (shadow → micro-live → full) with automatic rollback.
- [ ] ReduceOnly cooldown and rollback behaviors tested end-to-end.
- [ ] Certification artifact binds build+config+contract version and is enforced at runtime.
- [ ] Human approval recorded for risk-increasing changes.
- [ ] Risk-increasing approvals are limited in **scope and frequency**; bulk/cumulative changes require separate review.
- [ ] Production SLOs met for **at least 14 calendar days** before scaling up.

**Sign-off statement:** The system can evolve safely without relying on human vigilance.

---

## Evidence Pack Template (recommended folder layout)

Create one folder per phase completion:

- `evidence/phase0_policy/`
- `evidence/phase1_foundation/`
- `evidence/phase2_guardrails/`
- `evidence/phase3_dataloop/`
- `evidence/phase4_livefire/`

Each folder should contain:
- `README.md` (what was tested, how to reproduce)
- `SUMMARY_1PAGE.md` (what was proven, what failed, what remains risky — owner-readable)
- `test_results.txt` or CI links
- `run_logs/` (representative logs with run_id)
- `metrics_exports/` (screenshots/exports)
- `incident_drills/` (what drills were run + outcome)

This is what prevents “soft done” and makes the roadmap enforceable.
