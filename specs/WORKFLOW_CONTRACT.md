# Workflow Contract — Ralph Harness (Canonical)

**Purpose (TOC constraint relief):** maximize *contract-aligned, green-verified throughput* with WIP=1.
If it’s not provably aligned to the contract and provably green, it doesn’t ship.

This contract governs **how we change the repo** (planning → execution → verification → review).
It is separate from the trading behavior contract:

- **Trading Behavior Contract (source of truth):** `CONTRACT.md` (or `specs/CONTRACT.md` if that is canonical)
- **Workflow Contract (source of truth):** this file

If any doc conflicts with this file, **this file wins**.

---

## 0) Definitions

### Slice
A large unit from the Implementation Plan. Slices are executed strictly in ascending order (1, 2, 3…).

### Story (PRD item)
A bite-sized, single-commit unit of work that can be completed in one Ralph iteration.

### PRD
A JSON backlog file `plans/prd.json` that contains stories. Ralph executes stories from this file.

### “Contract-first”
The trading behavior contract is the source of truth. If a plan/story conflicts with the contract, we **fail closed** and block.

---

## 1) Canonical Files (Required)

### 1.1 Required inputs
- `CONTRACT.md` (canonical trading contract)
- `IMPLEMENTATION_PLAN.md` (slice map; may be `specs/IMPLEMENTATION_PLAN.md`)

### 1.2 Required workflow artifacts
- `plans/prd.json` — story backlog (machine-readable)
- `plans/ralph.sh` — execution harness (iterative loop)
- `plans/verify.sh` — verification gate (CI must run this)
- `plans/progress.txt` — append-only shift handoff log

### 1.3 Optional but recommended
- `plans/bootstrap.sh` — one-time harness scaffolding
- `plans/init.sh` — idempotent “get runnable baseline” script
- `plans/rotate_progress.py` — portability-safe progress rotation
- `plans/update_task.sh` — safe PRD mutation helper (avoid manual JSON edits)
- `.ralph/` — iteration artifacts directory created by Ralph

---

## 2) Non-Negotiables (Fail-Closed)

1) **Contract alignment is mandatory.**
   - Any change must be 100% aligned with `CONTRACT.md`.
   - Uncertainty → `needs_human_decision=true` → stop.

2) **Verification is mandatory.**
   - Every story MUST include `./plans/verify.sh` in its `verify[]`.
   - `passes=true` is allowed ONLY after verify is green.

3) **WIP = 1.**
   - Exactly one story per iteration.
   - Exactly one commit per iteration.

4) **Slices are executed in order.**
   - Ralph may only select stories from the currently-active slice (lowest slice containing any `passes=false`).

5) **No cheating.**
   - Do not delete/disable tests to “make green”.
   - Do not weaken fail-closed gates or staleness rules.

---

## 3) PRD Schema (Canonical)

`plans/prd.json` MUST be valid JSON with this shape:

```json
{
  "project": "StoicTrader",
  "source": {
    "implementation_plan_path": "IMPLEMENTATION_PLAN.md",
    "contract_path": "CONTRACT.md"
  },
  "rules": {
    "one_story_per_iteration": true,
    "one_commit_per_story": true,
    "no_prd_rewrite": true,
    "passes_only_flips_after_verify_green": true
  },
  "items": [ ... ]
}
```


Each item MUST include:

id (string): S{slice}-{NNN} (e.g. S2-004)

priority (int): within-slice ordering (higher first; ties allowed)

phase (int)

slice (int)

slice_ref (string)

story_ref (string)

category (string)

description (string)

contract_refs (string[]): MANDATORY, specific contract sections

plan_refs (string[]): MANDATORY, specific plan references (slice/sub-slice labels)

scope.touch (string[])

scope.avoid (string[])

acceptance (string[]) — ≥ 3, testable

steps (string[]) — deterministic, ≥ 5

verify (string[]) — MUST include ./plans/verify.sh

evidence (string[]) — concrete artifacts

dependencies (string[])

est_size (XS|S|M) — M should be split

risk (low|med|high)

needs_human_decision (bool)

passes (bool; default false)

If needs_human_decision=true, item MUST also include:

"human_blocker": {
  "why": "...",
  "question": "...",
  "options": ["A: ...", "B: ..."],
  "recommended": "A|B",
  "unblock_steps": ["..."]
}

4) Roles (Agents) and Responsibilities
4.1 Story Cutter (generator)

Creates/extends plans/prd.json from the implementation plan and the contract.

Rules:

MUST read CONTRACT.md first.

MUST populate contract_refs for every story.

MUST block (needs_human_decision=true) when contract mapping is unclear.

4.2 Auditor (reviewer)

Audits plans/prd.json vs:

contract (contradictions)

plan (slice order, dependency order)

Ralph-readiness (verify/evidence/scope size)

Outputs:

plans/prd_audit.json (machine-readable)

optional plans/prd_audit.md

4.3 PRD Patcher (surgical editor)

Applies minimal field-level fixes to plans/prd.json based on the audit.
Never rewrites/reorders the file. Never changes IDs. Never flips passes=true.

4.4 Implementer (Ralph execution agent)

Runs inside the Ralph harness. Implements exactly one story, verifies green, appends progress, commits.

4.5 Contract Arbiter (post-commit contract check)

A review step (human or LLM) that compares the code diff to CONTRACT.md.
If conflict is detected → FAIL CLOSED → revert or block.

5) Ralph Harness Protocol (Canonical Loop)

Ralph is the only allowed automation for “overnight” changes.

5.1 Preflight invariants (before iteration 1)

Ralph MUST fail if:

plans/prd.json is missing or invalid JSON

git working tree is dirty (unless explicitly overridden in code, which is discouraged)

required tools (git, jq) missing

5.2 Active slice gating

At each iteration:

Compute ACTIVE_SLICE = min(slice) among items where passes=false

Only stories from ACTIVE_SLICE are eligible

5.3 Selection modes

Ralph supports two selection modes:

RPH_SELECTION_MODE=harness (default):

selects highest priority passes=false in ACTIVE_SLICE

RPH_SELECTION_MODE=agent:

Ralph provides candidates and requires output exactly:
<selected_id>ITEM_ID</selected_id>

Ralph validates:

item exists

passes=false

slice == ACTIVE_SLICE

invalid selection → block and stop

5.4 Hard stop on human decision

If selected story has needs_human_decision=true:

Ralph MUST stop immediately

Ralph MUST write a blocked artifact snapshot in .ralph/blocked_*

Human clears block by:

editing the story to remove ambiguity, OR

splitting into discovery story + implementation story

5.5 Verify gates (pre/post)

Each iteration MUST perform:

verify_pre: run ./plans/verify.sh before implementing new work

verify_post: run ./plans/verify.sh after implementation and before considering completion

If verify fails:

default: stop (fail closed)

optional: self-heal behavior (see §5.7)

5.6 Story verify requirement gate

If RPH_REQUIRE_STORY_VERIFY=1:

Ralph MUST block any story missing ./plans/verify.sh in its verify[].

5.7 Optional self-heal

If RPH_SELF_HEAL=1 and verification fails:

Ralph SHOULD reset hard to last known good commit and clean untracked files

Ralph SHOULD preserve failure logs in .ralph/ iteration artifacts

Self-heal must never continue building new features on top of a red baseline.

5.8 Completion

Ralph considers the run complete if either:

the agent outputs the exact sentinel: <promise>COMPLETE</promise> (single line), OR

all PRD items have passes=true

6) Iteration Artifacts (Required for Debuggability)

Every iteration MUST write:

.ralph/iter_*/selected.json (active slice, selection mode, chosen story)

.ralph/iter_*/prd_before.json

.ralph/iter_*/prd_after.json

.ralph/iter_*/progress_tail_before.txt

.ralph/iter_*/progress_tail_after.txt

.ralph/iter_*/head_before.txt

.ralph/iter_*/head_after.txt

.ralph/iter_*/diff.patch

.ralph/iter_*/prompt.txt

.ralph/iter_*/agent.out

.ralph/iter_*/verify_pre.log (if run)

.ralph/iter_*/verify_post.log (if run)

.ralph/iter_*/selection.out (if agent selection mode is used)

Blocked cases MUST write:

.ralph/blocked_*/prd_snapshot.json

.ralph/blocked_*/blocked_item.json

.ralph/blocked_*/verify_pre.log (best effort)

7) Contract Alignment Gate (Default)

This is mandatory even if initially performed by a human reviewer.

Rule: after a story is implemented and verify_post is green, a contract check MUST occur.

Acceptable implementations:

./plans/contract_check.sh (deterministic checks) + optional LLM arbiter

LLM Contract Arbiter producing .ralph/iter_*/contract_review.json

Fail-closed triggers:

Any weakening of fail-closed gates

Any removal/disablement of tests required by contract/workflow

Any change that contradicts explicit contract invariants

8) CI Policy (Single Source of Truth)

CI MUST execute:

./plans/verify.sh (preferred as single source of truth)

Policy:

Either CI calls ./plans/verify.sh directly, OR

CI mirrors it, but then ./plans/verify.sh must be updated alongside CI changes.

If CI and verify drift, the repo is lying to itself. Fix drift immediately.

9) Progress Log (Shift Handoff)

plans/progress.txt is append-only and MUST include per-iteration entries:

timestamp

story id

summary

commands run

evidence produced

next suggestion / gotchas

Optional: rotate to prevent token bloat, but keep an archive (plans/progress_archive.txt).

10) Human Unblock Protocol (How blocks get cleared)

When Ralph stops on a blocked story:

Read .ralph/blocked_*/blocked_item.json

Decide:

clarify story with exact contract refs and paths, OR

split into discovery + implementation

Re-run Story Cutter/Auditor/Patcher as needed

Restart Ralph

11) Change Control

This file is canonical. Any workflow changes MUST be:

made here first

reflected in scripts (plans/ralph.sh, plans/verify.sh) second

enforced in CI third
