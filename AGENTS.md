<!-- AGENTS_STUB_V2 -->
<!-- INPUT_GUARD_V1 -->
<!-- FOLLOWUP_NO_PREFLIGHT_V1 -->
<!-- VERIFY_CI_SATISFIES_V1 -->

# Agent Guide (High-Signal)

Read this first. It is the shortest, enforceable workflow summary.

## Non-negotiables
- Contract alignment is mandatory; if conflict, STOP and output `<promise>BLOCKED_CONTRACT_CONFLICT</promise>` with the violated section.
- Verification is mandatory; never weaken gates or tests.
- No postmortem, no merge: every PR must include a filled postmortem entry under `reviews/postmortems/`.
- MUST declare the governing contract (workflow vs bot) in the PR postmortem; enforced by postmortem check.
- **Pending PRD stories MUST be implemented via Ralph loop ONLY**: If a user asks to implement a PRD story with `passes=false` from `plans/prd.json`, you MUST check the status first, then refuse manual implementation and guide them to run `./plans/ralph.sh`. Output `<promise>BLOCKED_PRD_REQUIRES_RALPH</promise>` if asked to manually implement pending stories. Post-implementation fixes to stories with `passes=true` are allowed. Read-only operations (reviewing PRD, checking status) are allowed.


## Response Protocol

### 1) Input Guard (conditional)
QuickCheck: If critical inputs are missing (target files, scope, or intent), ask 1–2 clarifying questions before acting. If the user explicitly says to proceed without preflight, set NO_PREFLIGHT and continue with stated assumptions.
NO_PREFLIGHT: user requested to skip preflight/clarifications; proceed with best-effort and document assumptions.

### 4) TOC Lens (MUST drive prioritization)
System goal:
- Ship contract-aligned changes safely with minimal rework and fast feedback.

TOC mapping:
- Throughput (T): merge-ready improvements that pass gates/tests.
- Inventory (I): WIP/unvalidated work (open branches, partial refactors, unresolved ambiguity).
- Operating Expense (OE): rework, debugging, handholding CI, churn.

Constraint identification:
- If CI/spec/lint failing → constraint = verification feedback loop.
- If requirements ambiguous/conflicting → constraint = decision clarity.
- If risk is catastrophic (replay/DB/funds) → constraint = safety assurance (proof first).
- If too many parallel tasks → constraint = WIP overload.

Decision rule:
- Prefer the option that increases T at the constraint while reducing rework risk,
  even if it feels slower locally.
- Penalize options that increase I (broad refactors, multi-file churn) without immediate verification.

### 5) Completion footer (only when truly done)
When the task is complete (no further required edits/commands), add:

Next steps:
1) [RECOMMENDED] <step> — Why this best exploits the current constraint and reduces risk
2) <step> — Why it helps less / what it trades off
3) <step> — Why deferred under TOC

Then end with: `<promise>COMPLETE</promise>`

## PRD Authoring Rules

- MUST run `./plans/prd_gate.sh` (not `prd_lint.sh`) when validating PRDs — lint alone misses schema/ref checks.
- MUST validate audit output with `plans/prd_audit_check.sh` before accepting cached results.
- Require `Anchor-###` / `VR-###` IDs when `contract_refs` mention anchor or validation rule titles (enforced by `plans/prd_lint.sh` via `MISSING_ANCHOR_REF`/`MISSING_VR_REF`).

## Start here (only when doing edits / PR work / MED-HIGH risk)
- Read `specs/CONTRACT.md`, `IMPLEMENTATION_PLAN.md`, `specs/WORKFLOW_CONTRACT.md`.
- If running the Ralph loop, read `plans/prd.json` and `plans/progress.txt`.
- Read `docs/skills/workflow.md`.
- Read `WORKFLOW_FRICTION.md` and the relevant files under `SKILLS/`.
- Use `reviews/REVIEW_CHECKLIST.md` when reviewing PRs.
- If running the Ralph loop, run `./plans/init.sh` (if present) then `./plans/verify.sh <mode>`.

For read-only doc reviews: read the target docs first; consult contract/workflow docs only if you detect a conflict or a safety-relevant claim.

## Ralph loop discipline (MANDATORY for PRD stories)

**CRITICAL: Pending PRD stories (`passes=false`) from `plans/prd.json` are ONLY implemented via the Ralph harness.**

### When you are INSIDE a Ralph iteration
You will see context like `.ralph/iter_N_*/selected_item.json` or explicit instructions that Ralph selected a story.
- WIP=1: exactly one PRD item and one commit per iteration.
- Work only the selected PRD item.
- Fail closed on PRD ambiguity; set needs_human_decision=true and stop.
- Follow the PRD scope (scope.touch, scope.create) strictly.

### When asked to implement PENDING PRD stories OUTSIDE Ralph
**FORBIDDEN**: Do NOT manually implement stories with `passes=false`.
- If user says "implement S2-001" and S2-001 has `passes=false` → BLOCK
- Output: `<promise>BLOCKED_PRD_REQUIRES_RALPH</promise>`
- Guide user: "Pending PRD stories must be implemented via Ralph harness. Run: ./plans/ralph.sh"
- How to check: `jq '.items[] | select(.id=="S2-001") | .passes' plans/prd.json`

### ALLOWED: Fixes to already-implemented stories
**Post-implementation corrections are allowed manually:**
- If a story has `passes=true` (already implemented by Ralph)
- User asks to fix/correct/improve the implementation
- Bug fixes or adjustments to previously-completed work
- Still requires: `./plans/verify.sh` must pass before commit

**Example allowed:**
```
User: "S2-001 was implemented but the quantization logic has a bug, please fix it"
Agent: [Checks S2-001 passes=true] → Manual fix is allowed
```

**Example blocked:**
```
User: "implement S2-001"
Agent: [Checks S2-001 passes=false] → BLOCKED, must use Ralph
```

### ALLOWED: Non-PRD work
- Workflow maintenance (`plans/ralph.sh`, `plans/verify.sh`, etc.)
- Bug fixes not tracked in PRD
- Documentation updates
- Ad-hoc tasks outside PRD workflow

### Why this matters
- Ralph enforces WIP=1, contract review, scope gating, verification gates
- Manual implementation of pending stories bypasses critical safety guardrails
- Ralph maintains state, artifacts, and audit trail
- Post-implementation fixes preserve developer agility while maintaining gates

## Repo Path Guardrails (Non-Negotiable)

### Canonical workflow files (use THESE paths)
- Workflow contract: `specs/WORKFLOW_CONTRACT.md`
- Ralph orchestrator: `plans/ralph.sh`
- Verification gate (canonical): `plans/verify.sh`
- Acceptance harness: `plans/workflow_acceptance.sh`
- Initializer: `plans/init.sh`
- PRD backlog: `plans/prd.json`
- Contract review tooling: `plans/contract_check.sh`, `plans/contract_review_validate.sh`

### State + logs (expected runtime artifacts)
- Ralph state directory: `.ralph/`
- Canonical state file: `.ralph/state.json`
- Run logs directory: `plans/logs/`

### Critical ambiguity guard
There is also a `./verify.sh` at repo root. **DO NOT edit or reference it** unless explicitly instructed.
All workflow gating must target **`plans/verify.sh`**.
If root `./verify.sh` exists, it must remain a thin wrapper that delegates to `plans/verify.sh`.

### Contract vs workflow contract
- `specs/CONTRACT.md` = trading engine contract (runtime behavior/safety gates)
- `specs/WORKFLOW_CONTRACT.md` = coding workflow contract (Ralph loop + harness rules)
Do not mix them. If a workflow rule is being enforced, it must cite `specs/WORKFLOW_CONTRACT.md`.

### Changes must be self-proving  <!-- VERIFY_CI_SATISFIES_V1 -->
Any change to workflow/harness files (see allowlist in `plans/verify.sh:is_workflow_file`) must include:
- updated/added assertions in `plans/workflow_acceptance.sh` (or a dedicated gate script invoked by it)
- and a run that passes `./plans/verify.sh`

Verification satisfaction:
- The “passes `./plans/verify.sh`” requirement MAY be satisfied by CI on the PR (clean checkout).
- Local verify is recommended but not required if CI will run and report results.
- If local verify fails due to a dirty worktree, the agent MUST ask for a clean-tree action or CI run; it MUST NOT set `VERIFY_ALLOW_DIRTY` without explicit owner approval recorded in the postmortem.

Dirty worktree policy (default):
- The agent MUST NOT automatically rerun verify with `VERIFY_ALLOW_DIRTY=1`.
- The agent MUST present options:
  1) [RECOMMENDED] Rely on CI verify on the PR (clean checkout).
  2) Clean the tree (stash/commit unrelated changes), then rerun verify normally.
  3) Owner-approved exception: run locally with `VERIFY_ALLOW_DIRTY=1`, list dirty files, record approval + rationale in postmortem, and still require CI verify before merge.

Operational notes:
- Do not edit `plans/workflow_acceptance.sh` without running `./plans/verify.sh full` OR relying on CI verify for proof.
- MUST update workflow acceptance coverage when changing `plans/verify.sh` mode defaults.
- Keep WF-* IDs synchronized across `specs/WORKFLOW_CONTRACT.md` and `plans/workflow_contract_map.json`.
- Workflow acceptance runs in CI (smoke when no workflow-critical changes; full when workflow changes or detection fails); locally it may skip when no workflow-critical files changed (WORKFLOW_ACCEPTANCE_POLICY=auto). Force with WORKFLOW_ACCEPTANCE_POLICY=always.

### Fail-closed default
If a required script/artifact is missing or invalid, the workflow must produce a deterministic BLOCKED outcome (not a silent pass).

## Harness guardrails
- MUST keep fast precheck set limited to schema/self-dep/shellcheck/traceability.
- SHOULD keep workflow_acceptance test IDs stable and listable.
- MUST avoid brittle acceptance checks that grep long prose sentences; prefer stable markers (the HTML comments at top) and short headers.

## Top time/token sinks (fix focus)
- `plans/workflow_acceptance.sh` full runtime → keep acceptance tests targeted; avoid unnecessary workflow file edits; batch changes before full runs.
- Late discovery of PRD/schema/shell issues → run fast precheck early (schema/self-dep/shellcheck/traceability only).
- Re-running full verify after small harness tweaks → minimize harness churn; group harness edits and validate once.

## Handoff hygiene (when relevant)
- Update `docs/codebase/*` with verified facts if you touched new areas.
- Append deferred ideas to `plans/ideas.md`.
- If pausing mid-story, fill `plans/pause.md`.
- Append to `plans/progress.txt`; include Assumptions/Open questions when applicable.
- Update `docs/skills/workflow.md` only when a new repeated pattern is discovered (manual judgment).
- Add a PR postmortem entry using `reviews/postmortems/PR_POSTMORTEM_TEMPLATE.md`.
- If a recurring issue is flagged, update `WORKFLOW_FRICTION.md` with the elevation action.

## Repo map
- `crates/` - Rust execution + risk (`soldier_core/`, `soldier_infra/`).
- `plans/` - harness (PRD, progress, verify, ralph).
- `docs/codebase/` - codebase maps.
- `SKILLS/` - one file per workflow skill (audit, patch-only edits, diff-first review).
- `reviews/postmortems/` - PR postmortem entries (agent-filled).

## MCP Tools Available

### Context7 (documentation lookup)
Up-to-date, version-specific documentation for libraries and frameworks.

**Usage:** Add "use context7" to any prompt:
```
use context7 to look up the tokio::sync::mpsc API
use context7 for the latest jsonschema validation in Python
```

**When to use:**
- Before using an external library API (prevents hallucinated APIs)
- When unsure about function signatures, return types, or feature flags
- For crates listed in `specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml`

### Sequential-thinking (complex reasoning)
Structured multi-step reasoning for complex problems.

**When to use:**
- Debugging intricate state machine transitions
- Analyzing race conditions or concurrency issues
- Working through contract compliance questions
- Any problem requiring careful step-by-step analysis

**Config:** `.claude/mcp.json` (local, gitignored)

## Sentinel outputs
- When blocked: `<promise>BLOCKED_CI_COMMANDS</promise>`
- When done: `<promise>COMPLETE</promise>`

## Don'ts
- Never use skip-permissions.
- Never delete/disable tests or weaken fail-closed gates.
