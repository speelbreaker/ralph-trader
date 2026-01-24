---
name: Spec-Lint Checklist for IMPLEMENTATION_PLAN.md (Fail-Closed)
description: Detailed checklist for validating IMPLEMENTATION_PLAN.md against safety contracts.
---
# Spec-Lint Checklist for IMPLEMENTATION_PLAN.md (Fail-Closed)

### 0) Scope & Authority (2-minute sanity)
*   **Single source of truth declared**: Plan explicitly states CONTRACT wins and plan must not weaken contract gates.
*   **No strategy edits allowed until safety lint passes** (explicit PR rule).
*   **All plan “rollback” guidance is non-bypass**: rollback for safety logic is revert commit, never “turn gate off” or “loosen thresholds.”

**Fail if**: any section says rollback = loosening TTLs/thresholds/feature flags for safety gates.

### 1) Split-Brain Detector (primary constraint killer)
**Goal**: eliminate contradictory instructions inside the plan.

*   **No conflicting comparators for any gate**: for each thresholded rule, search for >= vs > and <= vs < on the same metric.
    *   *Example*: EvidenceGuard >0.90 must not coexist with >=0.90.
*   **No legacy schedule lines survive alongside overrides** (Canary, cooldowns, retention).
*   **If you must keep legacy text**, it must be marked `OBSOLETE` + `MUST NOT` be implemented and the obsolete line must not contain a runnable rule (prefer deletion).

**Fail if**: the plan contains two different values/semantics for the same gate anywhere in the doc.

### 2) Gate Canonicalization (make safety computable, not vibes)
For each safety gate section, confirm all four are present:

#### 2.1 Gate Definition
*   **Exact inputs named** (metric names / config keys / artifacts).
*   **Exact comparator & threshold** (including inclusive/exclusive).
*   **Duration semantics** (e.g., “> 0.90 continuously for ≥5s”).
*   **Hysteresis / exit criteria** (e.g., “<0.70 for ≥120s”).

**Fail if**: any gate says “high/low/stale/degraded” without numerical or boolean criteria.

#### 2.2 Gate Effect
*   **Gate outcome is explicit**: Active / ReduceOnly / Kill.
*   **Dispatch constraints explicitly stated when relevant**:
    *   Disk Kill: no dispatch including close/hedge/cancel
    *   Kill containment: allowed only if eligible, else hard-stop
*   **Reason codes split**: what goes in `mode_reasons` vs `open_permission_reason_codes` (and explicit exclusions).

**Fail if**: effect is described with narrative words (“should block opens”) but not with TradingMode and dispatch rules.

#### 2.3 Precedence & Chokepoint Enforcement
*   **Every gate participates in a single precedence ladder** (PolicyGuard), not scattered “local decisions.”
*   **Plan states the one chokepoint** where opens are allowed/blocked (e.g., “build_order_intent() is the only intent builder and it is guarded by PolicyGuard result + OpenPermission latch”).
*   **No feature flag can bypass the chokepoint**.

**Fail if**: any section introduces an alternate dispatch path (“temporary bypass”) or “manual override” without contract-defined approvals.

#### 2.4 Test Proof
*   **Every MUST / MUST NOT has an explicit test name** or measurable acceptance criteria.
*   **Boundary tests exist for every threshold with > or >=**:
    *   exactly at threshold should behave correctly (0.90 vs 0.9001)
*   **Cooldown windows tested** (e.g., no exit at 119s, exit allowed at ≥120s).
*   **Where contract names tests**, plan either lists the exact name or says “wrapper alias required.”

**Fail if**: a gate is defined but not tied to a test.

### 3) “Must Not Leak” Reason-Code Hygiene (common silent failure)
*   Plan explicitly states: **F1_CERT and EvidenceChain failures MUST NOT appear in open_permission_reason_codes**; they belong in `mode_reasons`.
*   Plan includes a **test asserting this exclusion**.
*   **Reason-code lists are deterministic order** (stable output) to prevent flaky diffs and debugging confusion.

**Fail if**: plan describes the rule but no test exists.

### 4) Artifact & Path Canon (auditability buffer)
For each required artifact class (F1_CERT, TruthCapsule, DecisionSnapshot, reviews, incidents):
*   **Exact file paths match contract canonical paths**.
*   **Schema keys listed** (at least required keys).
*   **Write timing stated relative to dispatch** (e.g., “write BEFORE dispatch”).
*   **Failure effect stated** (writer failure ⇒ EvidenceChainState RED ⇒ blocks opens).
*   **A test exists that validates the artifact exists and includes keys**.

**Fail if**: plan uses alternative paths without explicitly stating contract-canonical artifacts also exist.

### 5) Time & Freshness Semantics (second-most common ambiguity)
*   Every “stale” concept defines:
    *   timestamp field name (`*_ts_ms`)
    *   freshness window in seconds
    *   staleness formula (`now_ms - ts_ms > window_ms`)
*   **Poll intervals are explicit** (fee model: 5 min; rate limits: 60s; etc.)
*   **“Repeated inability” is quantified** (e.g., 3 consecutive polls fail ⇒ Degraded) + test exists.

**Fail if**: plan says “periodically” / “often” / “repeated” without numbers.

### 6) Kill Semantics Hardening (catastrophic-risk gate)
*   **Disk Kill**: containment forbidden, no dispatch.
*   **Kill containment eligibility predicates are fully enumerated** in one place and referenced everywhere (no “only if eligible” hand-wave).
*   **Micro-loop bounds are explicit** (max attempts + max time).
*   **Tests cover**:
    *   eligible containment permitted
    *   ineligible containment forbidden
    *   disk kill forbids containment unconditionally

**Fail if**: Kill rules are scattered across sections or missing predicates.

### 7) Rollout/Promotion Governance (don’t sabotage the constraint)
*   **Canary stage durations match contract ranges** (no legacy schedule lines).
*   **Abort triggers are listed** and wired to rollback + cooldown.
*   **Replay gate and review artifacts are explicit gates** to promotion.
*   **No “shortcut” to Full exists**.

**Fail if**: plan defines a canary schedule inconsistent with contract, even if an “override” exists elsewhere.

### 8) Plan Extras Risk Scan (keep strategy from contaminating safety)
*   Any extra work not required by contract is labeled:
    *   **SAFE_EXTRA** (tooling/observability/refactor)
    *   **RISKY_EXTRA** (introduces bypass, new behavior path, changes gate semantics)
*   **RISKY_EXTRAs must include**:
    *   explicit “cannot weaken gates” statement
    *   feature flag defaults fail-closed
    *   tests proving no bypass

**Fail if**: extras touch dispatch, gate ordering, or thresholds without explicit safety proofs.

### 9) TOC Enforcement Rule (your PR workflow)
Before merging strategy logic changes:
1.  **Spec-lint passed with 0 FAIL**.
2.  **All safety gates have**: definition + effect + precedence + tests.
3.  **Only then are strategy changes allowed**.

**Fail if**: a PR changes strategy while any safety lint FAIL exists.

---

### Ultra-Short “Gatekeeper” Version (paste into PR template)
*   [ ] **No split-brain**: no duplicate/legacy thresholds, schedules, or retention rules
*   [ ] **Every safety gate has**: exact comparator+threshold+duration+exit criteria
*   [ ] **PolicyGuard precedence ladder is explicit** + deterministically ordered reason codes
*   [ ] **Kill semantics**: disk kill forbids all dispatch; eligibility predicates enumerated; micro-loop bounded; tests exist
*   [ ] **OpenPermission reason exclusion enforced** + test exists
*   [ ] **Artifacts paths+schemas canonical** + “write before dispatch” semantics + tests exist
*   [ ] **Freshness/polling/repeated-failure quantified** + tests exist
*   [ ] **No rollback-by-bypass** (revert commit only)
