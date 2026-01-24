---
name: Spec-Lint Checklist for specs/CONTRACT.md Patches
description: Detailed checklist for validating specs/CONTRACT.md patches.
---
# Spec‑Lint Checklist for specs/CONTRACT.md Patches

## Inputs you must have
(A) specs/CONTRACT.md before your change
(B) specs/CONTRACT.md after your change (or a git diff)

If you’re using git, generate the review artifact first:
`git diff -- specs/CONTRACT.md`

If you aren’t using git: copy the old file and run a diff tool; same idea.

## STOP‑THE‑LINE Rules
- Any **BLOCKER** = reject the patch (do not merge, do not ship).
- Any **MAJOR** = allowed only if explicitly recorded as debt in the patch notes and you didn’t worsen it.
- Any **MINOR** = cleanup debt; ok to ship.

---

### A) Authority & Split‑Brain (BLOCKERS)

#### SL‑A1 — Single source of truth for each algorithm
**What to check**
For every algorithm/decision rule you touched (TradingMode computation, staleness, reconciliation clear criteria, kill semantics, etc.): verify there is exactly one canonical section that defines it.

- **Pass**: Only one section claims “canonical / authoritative / single source / MUST be explicit” for that rule.
- **Fail (BLOCKER)**: The same decision rule is defined in two different sections without an explicit “this is a derived consequence via X in §Y” cross‑reference.
    - *Example pattern to catch*: “PolicyGuard MUST force ReduceOnly…” appears in a non‑PolicyGuard section while §2.2.3 is declared canonical.

**Minimal fix pattern**
Replace the duplicate rule with a one-line cross-reference:
“This condition MUST manifest as <existing canonical input> and be enforced via §2.2.3.”

**Mechanical scan**
Search for “Canonical”, “Single Source”, “authoritative”, “MUST be explicit”, “PolicyGuard MUST force” in the whole file and ensure each topic has one home:
`grep -nE 'Canonical|Single Source|authoritative|MUST be explicit|PolicyGuard MUST force' specs/CONTRACT.md`

#### SL‑A2 — No duplicate enumerations
**What to check**
Any list of allowed values (ModeReasonCode, OpenPermissionReasonCode, TradingMode, RiskState, instrument_kind, etc.) exists in one place and everyone references it.

- **Pass**: There is one authoritative list; other mentions are references.
- **Fail (BLOCKER)**: Two lists exist with different members or different names for the same thing.

**Minimal fix pattern**
Keep one list, and in the other location replace it with:
“Allowed values are defined in §X.Y.Z.”

---

### B) Definitions & Naming (BLOCKERS / MAJOR)

#### SL‑B1 — No undefined terms that affect safety gates
**What to check**
Any new term/field/code you introduced is defined before use (Definitions / Inputs / Allowed values).

- **Pass**: Every referenced symbol is defined somewhere with type/meaning.
- **Fail**:
    - **BLOCKER** if it affects OPEN blocking, TradingMode, or reconciliation.
    - **MAJOR** otherwise.

**Minimal fix pattern**
Add a one-line definition: name, type, meaning, and where produced.

**Mechanical scan**
After patch, search for your new identifier and ensure it appears in a definition block:
`grep -n "<new_identifier>" specs/CONTRACT.md`

#### SL‑B2 — One config knob name per behavior
**What to check**
If a behavior references a parameter (e.g., k, tick_penalty_max), ensure it maps to exactly one canonical config key (prefer Appendix A keys).

- **Pass**: The section uses the Appendix A key names OR explicitly aliases them.
- **Fail (MAJOR)**: Two names appear to refer to the same knob without a binding statement.

**Minimal fix pattern**
Replace the local name with the Appendix A name in the text (smallest change).

---

### C) Fail‑Closed Semantics (BLOCKERS)

#### SL‑C1 — OPEN must fail‑closed on any safety uncertainty
**What to check**
Any new verification, freshness check, artifact check, or metric dependency you add must specify:
1. what happens to OPEN
2. what happens to CLOSE/HEDGE/CANCEL
3. what happens on missing/unknown/uncomputable

- **Pass**: “Missing/stale/unavailable ⇒ block OPEN” is explicit.
- **Fail (BLOCKER)**: Any new gate can fail open because its missing-data case is unspecified.

**Minimal fix pattern**
Add one line:
“If missing/uncomputable ⇒ treat as not‑GREEN / Degraded and block OPEN.”

#### SL‑C2 — TradingMode semantics don’t conflict with pre‑dispatch gates
**What to check**
If you add/modify a pre-dispatch gate (Liquidity, NetEdge, Inventory, Preflight), verify it explicitly states it blocks dispatch even if TradingMode is Active.

- **Pass**: Gate text clearly says “reject the intent (no dispatch)” or equivalent.
- **Fail (MAJOR)**: Gate only changes state but doesn’t explicitly block dispatch.

---

### D) MUST → Acceptance Test Coverage (BLOCKERS / MAJOR)
> This is the highest-leverage spec-lint. This is where contracts go to die if you’re sloppy.

#### SL‑D1 — No new normative requirement without a black‑box AT block
**What to check**
Every line you add/change that introduces a normative keyword:
`MUST` / `MUST NOT` / `SHALL` / `REQUIRED` / `Hard Rule` / `Non‑Negotiable` / `Invariant`
must have an acceptance test that would fail if the requirement is violated.

- **Pass**: For each new/changed MUST, there is a nearby `AT‑###` block with: Given / When / Then / Pass criteria / Fail criteria.
- **Fail**:
    - **BLOCKER** if you added/changed a MUST and didn’t add/adjust an AT block.
    - **MAJOR** if the requirement is safety-critical and only a test name is listed (no behavior).

**Minimal fix pattern**
Add one AT block right under the requirement (don’t reorganize sections).

**Mechanical scan**
Find normative lines:
`grep -nE '\b(MUST NOT|MUST|SHALL|REQUIRED|Hard Rule|Non[- ]Negotiable|Invariant)\b' specs/CONTRACT.md`

Find AT blocks:
`grep -nE '^AT-[0-9]+' specs/CONTRACT.md`

If you introduced a MUST but AT count didn’t increase or the AT doesn’t mention it → likely FAIL.

#### SL‑D2 — Threshold changes require boundary AT coverage
**What to check**
If you change any threshold/default (e.g., 0.85, 92%, 300s, 50ms), you must include an AT that checks:
1. just below threshold (no trip)
2. at threshold (trip or not, explicitly)
3. just above threshold (trip)

- **Pass**: Contract text + AT make equality behavior unambiguous (>= vs >).
- **Fail (BLOCKER)**: You changed a threshold but equality semantics are unclear or untested.

**Minimal fix**
Add one AT that exercises all three boundary points.

#### SL‑D3 — No new “test-name-only” acceptance references for new behavior
**What to check**
Existing contract may contain lists of test_* names. Don’t expand that debt.

- **Pass**: Any new behavior uses `AT‑###` format, not only a test_* name.
- **Fail (MAJOR)**: You added a new test_* reference without an AT‑### behavioral definition.

**Mechanical scan**
`grep -nE '^\s*-\s*test_[a-zA-Z0-9_]+' specs/CONTRACT.md`

---

### E) Observability Truthfulness (MAJOR / BLOCKER if safety-critical)

#### SL‑E1 — If the contract requires /status or /health fields, they must be test‑bound
**What to check**
If you add/remove any required field in /status or /health, you must update the acceptance test text that asserts required keys.

- **Pass**: Required field list and the test text remain aligned.
- **Fail**:
    - **MAJOR** if the list changed but tests didn’t.
    - **BLOCKER** if the field affects safety enforcement (e.g., mode reasons, latch flags, F1_CERT state) and isn’t test-bound.

**Minimal fix**
Update the acceptance test description in §7.0 (keep it small).

#### SL‑E2 — Operator‑facing reason codes must be complete and “tier‑pure”
**What to check**
If you add a new ModeReasonCode:
1. add it to the allowed list
2. ensure the rules still state Kill reasons never mix with ReduceOnly reasons, and ordering is deterministic
3. update tests (or add an AT) for tier purity & ordering

- **Pass**: Code appears in the authoritative registry and is covered by a tier-purity test.
- **Fail (MAJOR)**: Reason introduced but not registered, or registered but not test-bound.

---

### F) Appendix A Defaults & Missing‑Config Behavior (MAJOR / BLOCKER)

#### SL‑F1 — Every new safety‑critical parameter must exist in Appendix A
**What to check**
Any config name you add that affects gating/safety must appear in Appendix A with a default and an acceptance test.

- **Pass**: Parameter is listed with: Default, unit, purpose, acceptance test.
- **Fail**:
    - **BLOCKER** if the parameter affects OPEN blocking / TradingMode / reconciliation.
    - **MAJOR** otherwise.

**Minimal fix**
Add the parameter to Appendix A (do not refactor).

#### SL‑F2 — No contradictory defaults
**What to check**
The same parameter must not have two different defaults in two places.

- **Pass**: One default (prefer Appendix A), other locations reference it.
- **Fail (MAJOR)**: Conflicting defaults.

---

### G) Cross‑Reference & Drift Control (MINOR / MAJOR)

#### SL‑G1 — Section references must resolve
**What to check**
Any “see §X.Y” reference you add points to an existing heading.

- **Pass**: Section exists.
- **Fail**:
    - **MAJOR** if it points to a safety-critical section (PolicyGuard, latch, kill semantics, reconciliation).
    - **MINOR** otherwise.

#### SL‑G2 — Patch Summary must not introduce norms
**What to check**
If you add normative language in Patch Summary, it’s a trap (it becomes a second contract).

- **Pass**: Patch Summary remains informational only; normative text lives in sections.
- **Fail (MAJOR)**: New MUST/REQUIRED introduced only in summary.

**Minimal fix**
Move the MUST into the proper section; rewrite summary line to be descriptive.

---

### H) Patch Hygiene (MINOR / MAJOR)

#### SL‑H1 — No stealth schema renames
**What to check**
Renaming keys (e.g., /status field names, reason codes, input names) is only allowed if you also:
1. update all references
2. update acceptance tests
3. explicitly call out the rename in the contract text

- **Pass**: Rename is explicit and test-bound.
- **Fail (MAJOR)**: Silent rename creates split‑brain between readers/tests/implementation.

#### SL‑H2 — Minimality
**What to check**
No large reformatting, no rearranging sections unless the patch goal requires it.

- **Pass**: Diff is localized.
- **Fail (MINOR)**: Excess churn makes audits impossible.

---

## The “Spec‑Lint Output” you should produce for every patch

Create a short block in your PR/patch notes:
```
Spec‑Lint Result: PASS / FAIL
Blockers: 0 / N
Majors: 0 / N (list IDs)
Minors: 0 / N (list IDs)
New ATs added: AT‑### …
New/changed config keys: … (confirm Appendix A updated)
```
This is your drum-buffer-rope: it prevents contract entropy from becoming the constraint that throttles every future change.
