# Workflow Contract — Ralph Harness (Canonical)

**Purpose (TOC constraint relief):** maximize *contract-aligned, green-verified throughput* with WIP=1 **for Ralph execution iterations**.
If it’s not provably aligned to the contract and provably green, it doesn’t ship.

This contract governs **how we change the repo** (planning → execution → verification → review).
It is separate from the trading behavior contract:

- **Trading Behavior Contract (source of truth):** `CONTRACT.md` (or `specs/CONTRACT.md` if that is canonical)
- **Workflow Contract (source of truth):** this file

Precedence (fail-closed):
- [WF-0.1] Trading behavior rules: `CONTRACT.md` is canonical. If this workflow contract conflicts with `CONTRACT.md` on behavior, STOP and set needs_human_decision=true.
- [WF-0.2] Workflow/process rules: this file is canonical. If other workflow docs conflict with this file, this file wins.

---

## 0) Definitions

### Slice
A large unit from the Implementation Plan. Slices are executed strictly in ascending order (1, 2, 3…).

### Story (PRD item)
A bite-sized, single-commit unit of work that can be completed in one Ralph iteration.

### PRD
A JSON backlog file `plans/prd.json` that contains stories. Ralph executes stories from this file.

### Workflow maintenance task
Changes to the workflow/harness itself (e.g., `specs/WORKFLOW_CONTRACT.md`, `plans/ralph.sh`, `plans/verify.sh`, PRD tooling). These tasks are **not** executed via PRD stories; they are governed by §11 Change Control.

### Contract Kernel (Derived, Optional)
An optional JSON index (`docs/contract_kernel.json`) compiled from `docs/contract_anchors.md` and
`docs/validation_rules.md` (and hash-tracked to `CONTRACT.md` and `IMPLEMENTATION_PLAN.md`).
The kernel is derived-only; it cannot introduce new behavior. Any ambiguity or conflict requires
reading full `CONTRACT.md` (fail-closed).

### “Contract-first”
The trading behavior contract is the source of truth. If a plan/story conflicts with the contract, we **fail closed** and block.

---

## 1) Canonical Files (Required)

### 1.1 Required inputs
- [WF-1.1] `CONTRACT.md` (canonical trading contract)
- [WF-1.2] `IMPLEMENTATION_PLAN.md` (slice map; may be `specs/IMPLEMENTATION_PLAN.md`)

### 1.2 Required workflow artifacts
- [WF-1.3] `plans/prd.json` — story backlog (machine-readable)
- [WF-1.4] `plans/ralph.sh` — execution harness (iterative loop)
- [WF-1.5] `plans/verify.sh` — verification gate (CI must run this)
- [WF-1.6] `plans/progress.txt` — append-only shift handoff log

### 1.3 Optional but recommended
- `plans/bootstrap.sh` — one-time harness scaffolding
- `plans/init.sh` — idempotent “get runnable baseline” script
- `plans/rotate_progress.py` — portability-safe progress rotation
- `plans/update_task.sh` — safe PRD mutation helper (avoid manual JSON edits)
- `plans/profile.sh` — optional profile helper to export Ralph env presets
- `.ralph/` — iteration artifacts directory created by Ralph
- `docs/codebase/*` — lightweight codebase map (stack/architecture/structure/testing/integrations/conventions/concerns)
- `plans/ideas.md` — append-only deferred ideas log (non-PRD)
- `plans/pause.md` — short pause note for mid-story handoffs
- [WF-1.7] `docs/contract_kernel.json` — optional derived index; if present, it MUST be validated before use.

---

## 2) Non-Negotiables (Fail-Closed)

1) [WF-2.1] **Contract alignment is mandatory.**
   - Any change must be 100% aligned with `CONTRACT.md`.
   - Uncertainty → `needs_human_decision=true` → stop.

2) [WF-2.2] **Verification is mandatory.**
   - Every story MUST include `./plans/verify.sh` in its `verify[]`.
   - `passes=true` is allowed ONLY after verify is green.
   - State transition rule (enforced by harness):
     - The Ralph harness (`plans/ralph.sh`), not the agent, is the sole authority to flip passes=false → true.
     - Ralph MUST NOT flip passes=true unless verify_post exits 0 in the same iteration AND a contract review gate has passed (see “Contract Alignment Gate”).
     - Pass flips MUST be bound to the selected story and to a fresh verify on the current HEAD (no stale verify artifacts).

3) [WF-2.3] **WIP = 1 (Ralph execution only).**
   - Exactly one story per Ralph iteration.
   - Exactly one commit per Ralph iteration.
   - Workflow maintenance tasks are outside PRD/WIP scope; they still must follow §11 Change Control and §2.2 Verification.

4) [WF-2.4] **Slices are executed in order.**
   - Ralph may only select stories from the currently-active slice (lowest slice containing any `passes=false`).

5) [WF-2.5] **No cheating.**
   - Do not delete/disable tests to “make green”.
   - Do not weaken fail-closed gates or staleness rules.

Observable gate requirement:
- [WF-2.6] plans/ralph.sh MUST exit non-zero on any gate failure and MUST leave a diagnostic artifact under .ralph/ explaining the stop reason.
- [WF-2.7] Promotion-grade verify is required to flip passes=true.
  - Ralph MUST capture verify_post mode + verify_mode in state from verify_post.log.
  - update_task.sh MUST reject passes=true unless verify_post shows mode=full and verify_mode=promotion.
- [WF-2.8] Ralph MUST write `.ralph/artifacts.json` for every run (pass, fail, or blocked), and the manifest MUST be overwritten per run (no stale manifests). The schema is defined in `docs/schemas/artifacts.schema.json`.
- [WF-2.9] **Contract kernel use is fail-closed.**
  - If the kernel is used, `scripts/check_contract_kernel.py` MUST pass (source hashes match current files).
  - If validation fails or kernel is missing, agents MUST read full `CONTRACT.md` or stop.
  - Contract review always compares diffs to `CONTRACT.md`, not the kernel.

---

## 3) PRD Schema (Canonical)

[WF-3.0] The PRD applies **only** to Ralph loop execution (implementation stories). Workflow maintenance tasks are **not** entered into PRD; they are handled via §11 Change Control.

[WF-3.1] `plans/prd.json` MUST be valid JSON with this shape:

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

Schema gating (fail closed, enforced by harness preflight):
- [WF-3.2] Ralph MUST validate required top-level keys exist: project, source, rules, items.
- [WF-3.3] Ralph MUST validate for every item: required fields per §3 are present; acceptance has ≥ 3 entries; steps has ≥ 5 entries; verify[] contains ./plans/verify.sh.
  - Thresholds are floors. They may be raised via PRD_SCHEMA_MIN_ACCEPTANCE / PRD_SCHEMA_MIN_STEPS.
  - Lowering below floors requires PRD_SCHEMA_DRAFT_MODE=1 and is blocked from Ralph execution.
- [WF-3.4] Ralph MUST validate: if needs_human_decision=true then human_blocker object is present.


[WF-3.5] Each item MUST include:

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

scope.create (string[], optional) — new paths expected to be created; must not exist at lint time; parent dir must exist

acceptance (string[]) — ≥ 3, testable

steps (string[]) — deterministic, ≥ 5

verify (string[]) — MUST include ./plans/verify.sh

evidence (string[]) — concrete artifacts

dependencies (string[])

est_size (XS|S|M) — M should be split

risk (low|med|high)

needs_human_decision (bool)

passes (bool; default false)

[WF-3.6] If needs_human_decision=true, item MUST also include:

"human_blocker": {
  "why": "...",
  "question": "...",
  "options": ["A: ...", "B: ..."],
  "recommended": "A|B",
  "unblock_steps": ["..."]
}

---

## 4) Roles (Agents) and Responsibilities

### 4.1 Story Cutter (generator) [WF-4.1]

Creates/extends plans/prd.json from the implementation plan and the contract.

Rules:

MUST read CONTRACT.md first.

MUST populate contract_refs for every story.

MUST block (needs_human_decision=true) when contract mapping is unclear.

### 4.2 Auditor (reviewer) [WF-4.2]

Audits plans/prd.json vs:

contract (contradictions)

plan (slice order, dependency order)

Ralph-readiness (verify/evidence/scope size)

Outputs:

plans/prd_audit.json (machine-readable)

optional plans/prd_audit.md

### 4.3 PRD Patcher (surgical editor) [WF-4.3]

Applies minimal field-level fixes to plans/prd.json based on the audit.
Never rewrites/reorders the file. Never changes IDs. Never flips passes=true.

### 4.4 Implementer (Ralph execution agent) [WF-4.4]

Runs inside the Ralph harness. Implements exactly one story, verifies green, appends progress, commits.
May use a validated kernel for slice-scoped context; ambiguity/conflict requires full `CONTRACT.md`.

### 4.5 Contract Arbiter (post-commit contract check) [WF-4.5]

A review step (human or LLM) that compares the code diff to CONTRACT.md.
If conflict is detected → FAIL CLOSED → revert or block.

### 4.6 Handoff hygiene (who does what and when) [WF-4.6]

- Implementer (agent or human) updates `docs/codebase/*` when a story touches new areas or changes architecture/structure/testing/integrations.
- Implementer appends non-PRD follow-ups to `plans/ideas.md` as they arise.
- Implementer fills `plans/pause.md` only when stopping mid-story.
- Implementer appends a `plans/progress.txt` entry after each iteration; include assumptions or open questions when relevant.
- Maintainers may refresh `docs/codebase/*` after major refactors or when onboarding new contributors.

### 4.7 Workflow skill memory (manual, versioned) [WF-4.7]

- All agents MUST read `docs/skills/workflow.md` before starting a task.
- Updates are manual-only and allowed only when a new repeated pattern is discovered (soft requirement; manual judgment).
- No automation is allowed to update or validate the content of this document; automation for workflow contract traceability (for example, tracking WF-* rules, including WF-4.7) is allowed.

---

## 5) Ralph Harness Protocol (Canonical Loop)

[WF-5.0] Ralph is the only allowed automation for “overnight” changes. This loop applies to PRD execution only; workflow maintenance tasks follow §11 and do not require PRD items.

### 5.1 Preflight invariants (before iteration 1) [WF-5.1]

Ralph MUST fail if:

plans/prd.json is missing or invalid JSON

PRD schema check fails (plans/prd_schema_check.sh)

git working tree is dirty (unless explicitly overridden in code, which is discouraged)

required tools (git, jq) missing

Ralph lock is held (.ralph/lock exists) to prevent concurrent runs

required harness scripts are missing or not executable: ./plans/verify.sh, ./plans/update_task.sh

CONTRACT.md or IMPLEMENTATION_PLAN.md is missing (fallbacks to specs/* allowed if present)

RPH_AGENT_CMD is empty or not executable when RPH_DRY_RUN!=1

RPH_CHEAT_ALLOWLIST is set while RPH_ALLOW_CHEAT_ALLOWLIST!=1

### 5.2 Active slice gating [WF-5.2]

At each iteration:

Compute ACTIVE_SLICE = min(slice) among items where passes=false

Only stories from ACTIVE_SLICE are eligible

### 5.3 Selection modes [WF-5.3]

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

### 5.4 Hard stop on human decision [WF-5.4]

If selected story has needs_human_decision=true:

Ralph MUST stop immediately

Ralph MUST write a blocked artifact snapshot in .ralph/blocked_*

Human clears block by:

editing the story to remove ambiguity, OR

splitting into discovery story + implementation story

### 5.5 Verify gates (pre/post) [WF-5.5]

Each iteration MUST perform:

verify_pre: run ./plans/verify.sh before implementing new work

verify_post: run ./plans/verify.sh after implementation and before considering completion

If verify fails:

default: stop (fail closed)

optional: self-heal behavior (see §5.8)

Baseline integrity (fail closed):
- If verify_pre fails, Ralph MUST NOT run implementation steps.
- If RPH_SELF_HEAL=1, Ralph MAY attempt a reset and rerun verify_pre once, but MUST stop if verify_pre remains red.

Output discipline (token-safe):
- Ralph MUST capture full verify output in verify_pre.log/verify_post.log.
- Ralph MUST limit console output to a tail (pass/fail) plus a grep summary.
- Ralph MUST write verify_summary.txt (grep error:/FAILED/panicked) alongside the verify log and use it for console output.
- RPH_VERIFY_PASS_TAIL, RPH_VERIFY_FAIL_TAIL, and RPH_VERIFY_SUMMARY_MAX control the limits.
Mode separation:
- verify_pre/verify_post use RPH_VERIFY_MODE by default.
- When a pass is requested, verify_post uses RPH_PROMOTION_VERIFY_MODE (default full).
- Final verification uses RPH_FINAL_VERIFY_MODE (default full), independent of iteration mode.

[WF-5.5.1] verify.sh MUST enforce the endpoint-level test gate: if endpoint-ish files change, corresponding tests must change, unless ENDPOINT_GATE=0 in a non-CI run.

Workflow acceptance policy (local throughput, CI non-bypass):
- verify.sh MAY skip workflow acceptance locally when no workflow-critical files changed.
- verify.sh MUST always run workflow acceptance in CI.
- Local override: WORKFLOW_ACCEPTANCE_POLICY=auto|always|never (never ignored in CI).
- The workflow-critical allowlist is defined in plans/verify.sh:is_workflow_file and is authoritative.

### 5.6 Story verify requirement gate [WF-5.6]

Ralph MUST block any story missing ./plans/verify.sh in its verify[].

### 5.7 Story verify allowlist gate [WF-5.7]

Story-specific verify commands (verify[] entries other than ./plans/verify.sh) MUST be allowlisted in plans/story_verify_allowlist.txt unless RPH_ALLOW_UNSAFE_STORY_VERIFY=1.

### 5.8 Optional self-heal [WF-5.8]

If RPH_SELF_HEAL=1 and verification fails:

Ralph SHOULD reset hard to last known good commit and clean untracked files

Ralph SHOULD preserve failure logs in .ralph/ iteration artifacts

Self-heal must never continue building new features on top of a red baseline.

### 5.9 Completion [WF-5.9]

Ralph considers the run complete if and only if:
- all PRD items have passes=true, AND
- the most recent verify_post is green (exit code 0), AND
- required iteration artifacts for the final iteration exist.

If an agent outputs the sentinel COMPLETE, Ralph MUST treat it only as a request to check the completion conditions above.
If completion conditions are not met, Ralph MUST stop (non-zero) and write a .ralph/blocked_incomplete_* artifact explaining why.

Anti-spin safeguard (fail closed) [WF-5.9]:
- Ralph MUST support RPH_MAX_ITERS (default 50) and MUST stop with a blocked artifact when exceeded.

### 5.10 Scope enforcement gate [WF-5.10]

Ralph MUST enforce scope.touch, scope.create, and scope.avoid: any changed file outside scope.touch/scope.create or matching scope.avoid MUST block the iteration.

### 5.11 Rate limiting and circuit breaker [WF-5.11]

Ralph MUST enforce rate limiting on agent calls (RPH_RATE_LIMIT_*), and MUST stop with a blocked artifact when circuit breaker thresholds are exceeded (RPH_MAX_SAME_FAILURE, RPH_MAX_NO_PROGRESS).

### 5.12 Iteration timeouts (optional) [WF-5.12]

If RPH_ITER_TIMEOUT_SECS > 0, Ralph MUST apply a wall-clock timeout to agent execution and verify steps. A timeout MUST be treated as a failure and recorded in iteration logs/artifacts.

### 5.13 Profiles (optional presets) [WF-5.13]

RPH_PROFILE MAY set default values for verify mode, timeouts, and other harness knobs. Explicit env vars MUST take precedence over profile defaults. Optional helper: source plans/profile.sh to export a profile's env vars.

---

## 6) Iteration Artifacts (Required for Debuggability)

### 6.1 Iteration artifacts [WF-6.1]

Every iteration MUST write [WF-6.1]:

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

### 6.2 Blocked artifacts [WF-6.2]

Blocked cases MUST write:

.ralph/blocked_*/prd_snapshot.json

.ralph/blocked_*/blocked_item.json

.ralph/blocked_*/verify_pre.log (best effort when verify.sh is available/executable)

### 6.3 Optional diagnostics [WF-6.3]

When applicable, Ralph SHOULD also write:

.ralph/iter_*/story_verify.log

.ralph/iter_*/diff_for_cheat_check.patch

.ralph/iter_*/diff_for_cheat_check.filtered.patch

.ralph/iter_*/progress_appended.txt

.ralph/iter_*/verify_pre_after_heal.log

---

## 7) Contract Alignment Gate (Default)

This is mandatory even if initially performed by a human reviewer.

[WF-7.1] Rule: after a story is implemented and verify_post is green, a contract check MUST occur.

Enforcement (fail closed, artifact-based):
- [WF-7.2] Each iteration with verify_post green MUST produce: .ralph/iter_*/contract_review.json
- [WF-7.3] The artifact MUST conform to: docs/schemas/contract_review.schema.json (decision PASS|FAIL|BLOCKED) and the validator MUST load that schema.
- [WF-7.4] If the contract review artifact is missing or decision!="PASS",
  Ralph MUST stop and MUST NOT flip passes=true.

Acceptable implementations:

./plans/contract_check.sh (deterministic checks) + optional LLM arbiter

LLM Contract Arbiter producing .ralph/iter_*/contract_review.json
  (schema: docs/schemas/contract_review.schema.json)

Fail-closed triggers:

Any weakening of fail-closed gates

Any removal/disablement of tests required by contract/workflow

Any change that contradicts explicit contract invariants

---

## 8) CI Policy (Single Source of Truth)

[WF-8.1] CI MUST execute:

./plans/verify.sh (preferred as single source of truth)

Policy:

Either CI calls ./plans/verify.sh directly, OR

CI mirrors it, but then ./plans/verify.sh must be updated alongside CI changes.

If CI and verify drift, the repo is lying to itself. Fix drift immediately.

Drift observability requirement:
- [WF-8.2] ./plans/verify.sh MUST print a single line at start: VERIFY_SH_SHA=<hash>.
- [WF-8.3] Ralph MUST capture this line in .ralph/iter_*/verify_pre.log and verify_post.log.
- [WF-8.4] CI logs (or CI artifacts) MUST contain the same VERIFY_SH_SHA line for the run.

CI gate source requirement:
- [WF-8.5] ./plans/verify.sh MUST fail with <promise>BLOCKED_CI_COMMANDS</promise> if CI_GATES_SOURCE is not github/verify and no .github/workflows directory is present.

---

## 9) Progress Log (Shift Handoff)

[WF-9.1] plans/progress.txt is append-only and MUST include per-iteration entries:

timestamp

story id

summary

commands run

evidence produced

next suggestion / gotchas

Recommended fields (when relevant):
- verify mode/result (e.g., ./plans/verify.sh full)
- assumptions made
- open questions requiring human decision

Optional: rotate to prevent token bloat, but keep an archive (plans/progress_archive.txt).

---

## 10) Human Unblock Protocol (How blocks get cleared)

[WF-10.1] When Ralph stops on a blocked story:

Read .ralph/blocked_*/blocked_item.json

Decide:

clarify story with exact contract refs and paths, OR

split into discovery + implementation

Re-run Story Cutter/Auditor/Patcher as needed

Restart Ralph

---

## 11) Change Control

[WF-11.1] This file is canonical. Any workflow changes MUST be:

made here first

reflected in scripts (plans/ralph.sh, plans/verify.sh) second

enforced in CI third

[WF-11.2] Workflow maintenance tasks (changes to this contract or harness scripts) are not PRD stories and are outside the Ralph WIP=1 rule, but they still must honor §2.1 Contract alignment and §2.2 Verification.

---

## 12) Acceptance Tests (REQUIRED)

Workflow Contract Acceptance Tests (checklist) [WF-12.1]

Preflight / PRD validation [WF-12.1]

[ ] Running ./plans/ralph.sh with missing plans/prd.json exits non-zero and writes a .ralph/* stop artifact.
[ ] Running ./plans/ralph.sh with invalid JSON in plans/prd.json exits non-zero before any implementation work.
[ ] Running ./plans/ralph.sh with a PRD item missing required fields (e.g., empty contract_refs, missing verify, acceptance < 3, steps < 5, missing ./plans/verify.sh in verify[]) exits non-zero.

Baseline integrity [WF-12.2]

[ ] If ./plans/verify.sh fails during verify_pre, Ralph performs no implementation steps and stops (observable via .ralph/iter_*/verify_pre.log + no code diff beyond reset).
[ ] If RPH_SELF_HEAL=1 and verify_pre remains red after one reset attempt, Ralph stops non-zero.

Pass flipping integrity [WF-12.3]

[ ] If any PRD item flips passes from false→true, the same iteration contains .ralph/iter_*/verify_post.log showing exit code 0.
[ ] If .ralph/iter_*/contract_review.json is missing or has decision!="PASS", Ralph does not flip passes=true and stops non-zero.
[ ] Exactly one PRD item’s passes flips per iteration (compare .ralph/iter_*/prd_before.json vs prd_after.json).

Slice gating / blocked behavior [WF-12.4]

[ ] With any passes=false item in slice N, Ralph never selects an item from slice > N (observable via .ralph/iter_*/selected.json).
[ ] If the selected story has needs_human_decision=true, Ralph stops immediately and writes .ralph/blocked_*/blocked_item.json.

Completion semantics (no fail-open) [WF-12.5]

[ ] If the agent outputs COMPLETE while any PRD item has passes=false, Ralph stops non-zero and writes a .ralph/blocked_incomplete_* artifact.
[ ] Ralph only exits “complete” when all items have passes=true and the most recent verify_post is green.

Anti-spin [WF-12.6]

[ ] With RPH_MAX_ITERS=2, a scenario that would otherwise continue past 2 iterations stops at the limit and writes a blocked artifact documenting the stop reason.

CI / verify drift observability [WF-12.7]

[ ] ./plans/verify.sh emits VERIFY_SH_SHA=... as the first line.
[ ] .ralph/iter_*/verify_pre.log and verify_post.log contain that same VERIFY_SH_SHA=....
[ ] CI logs/artifacts for a run contain the same VERIFY_SH_SHA=... line.

Traceability / drift gate [WF-12.8]

[ ] plans/workflow_contract_gate.sh fails if any WF-* rule_id in specs/WORKFLOW_CONTRACT.md is unmapped or lacks enforcement + artifact metadata.
[ ] plans/workflow_acceptance.sh runs the traceability gate.
