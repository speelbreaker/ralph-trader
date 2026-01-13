# Architect Advisor Report

### 1) State Snapshot
- **Active Slice:** 1 (Foundation)
- **Top Pending Story:** S1-008 "OrderSize discovery" (Priority 95)
- **Status:** The workflow harness is solid (green verify). Codebase has core primitives but they are fragile.
- **Recent Changes:** `plans/verify.sh` and `plans/ralph.sh` were hardened. `OrderSize` struct added.
- **Blocking Artifacts:** `docs/order_size_discovery.md` is **MISSING**.

### 2) TOC: The Constraint Right Now
**Unsafe Primitives (Fragile Foundation):** The `OrderSize` primitive panics on invalid input instead of returning a Result, making it unsafe for the hot loop.

### 3) Directional Advice (Ranked)

**Option A (Ship Next): Execute S1-008 (Discovery) to Audit OrderSize**
- **Benefits:** Documents *why* the current `OrderSize` is unsafe before fixing it, adhering to "Discovery -> Implementation" flow.
- **Costs:** One extra iteration before fixing code.
- **Next 3 Steps:**
  1.  Run `ralph` on **S1-008**.
  2.  Agent analyzes `order_size.rs`, confirms panics, and writes `docs/order_size_discovery.md`.
  3.  Commit artifact to close S1-008.

**Option B (Refactor): Fix S1-004 Code Immediately**
- **Benefits:** Removes the panic faster.
- **Risks:** Bypasses the "Discovery" story (S1-008) in the PRD, creating workflow drift.
- **Verdict:** Stick to Option A. It's cleaner.

**Option C (Later): Jump to S2 (Quantization)**
- **Risks:** Building quantization on a panicking `OrderSize` is technical debt.

### 4) Spec Evolution Radar + Compliance Pulse

**A) GAPS**
- **Panic-Free Invariant:** Contract Phase 1 Goal is "Panic-Free Deterministic Intents". Implementation violates this.
- **Error Handling:** `OrderSize::new` returns `Self` instead of `Result<Self, Error>`.

**B) CONTRADICTIONS**
- None found. Contract and Plan align on "Panic-Free".

**C) COMPLIANCE PULSE (Slice 1 - Foundation)**

| Req/AC | Contract Section | Test Assertion | Status | Notes |
|---|---|---|---|---|
| InstrumentKind derivation | §1.0 Instrument Units & Notional Invariants | `test_instrument_kind_mapping` | ✅ COVERED | Logic maps correctly. |
| Cache TTL Degraded | §1.0.X Instrument Metadata Freshness | `test_stale_instrument_cache_sets_degraded` | ✅ COVERED | `RiskState::Degraded` asserted. |
| OrderSize Canonical | §1.0 Instrument Units & Notional Invariants | `test_order_size_option_perp_canonical_amount` | ⚠️ WEAK | **Happy path only.** No test for invalid input (would panic). |
| Dispatch Mismatch | §1.0 Instrument Units & Notional Invariants | `rejects_contract_mismatch_in_dispatch_map` | ✅ COVERED | Returns `Result::Err` correctly. |

**Evidence artifacts:**
- Required: `docs/order_size_discovery.md` (S1-008), `docs/dispatch_map_discovery.md` (S1-009).
- Check: `ls -l docs/order_size_discovery.md` -> `No such file or directory`.
- Status: **MISSING**.

### 4c) Acceptance Criteria Drift Check (Story S1-004)

**Contract:** "OrderSize struct (MUST implement)... Canonical internal units... Panic-Free"
**PRD AC:** "GIVEN any OrderSize WHEN built THEN notional_usd is always populated..."
**Tests:** `test_order_size.rs` asserts happy path `notional_usd` calculation.
**Implementation:** `crates/soldier_core/src/execution/order_size.rs`

**Drift Findings:**
- **WEAKER:** Test only covers valid inputs.
- **VIOLATION:** Implementation uses `expect()` (panics) on missing fields.
  ```rust
  // crates/soldier_core/src/execution/order_size.rs:21
  let qty_coin = qty_coin.expect("qty_coin required for coin-sized instruments");
  ```
- **Recommendation:** S1-008 must flag this for the next repair story.

### 5) Patch Proposals
*No spec patches required. The violation is in the code (implementation), not the spec.*

### 6) Coaching Notes for a Beginner
- **Rule of Thumb:** If `new()` can fail (e.g. missing inputs), it **must** return `Result<Self>`. Never `expect()` in a library constructor.
- **Focus:** Don't worry about the Dispatcher yet. Fix the data structure (OrderSize) first.
- **Process:** Don't just "fix it" while reviewing. Create the Discovery artifact (S1-008) to *prove* it needs fixing, then fix it. This leaves a trail.

### 7) Next 3 Actions
1.  **Owner: You (Agent):** Execute **S1-008** to generate `docs/order_size_discovery.md`.
2.  **Owner: You (Agent):** Verify the discovery doc explicitly lists the `expect()` panics.
3.  **Owner: You (User):** Review the doc and approve the next story (Repair OrderSize).