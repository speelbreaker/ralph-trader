# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Added quiet console mode for verify with artifact-first logs and failure excerpts.
- Contract/plan requirement satisfied: specs/WORKFLOW_CONTRACT.md WF-8.2/WF-12.7 (VERIFY_SH_SHA first line) preserved while adding artifact-first logging.
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: CI log noise from verify output makes debugging and review harder.
- Exploit (what I did now): Added VERIFY_CONSOLE=auto with quiet-by-default in CI and log excerpts on failure.
- Subordinate (workflow changes needed): Keep console output minimal and rely on artifacts for deep logs.
- Elevate (permanent fix proposal): Enforce quiet/summary behavior via workflow acceptance checks.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-8.2 (VERIFY_SH_SHA first line), WF-12.7 (verify_sh_sha observability), WF-5.5 (output discipline alignment).
- Proof (tests/commands + outputs): `./plans/verify.sh full` -> "VERIFY OK (mode=full)" (artifact logs under `artifacts/verify/<run_id>/`).

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): CI sets `CI=1` -> CI workflow env -> N (assumed standard CI behavior).

## 4) Friction Log
- Top 3 time/token sinks:
  1) CI log spam from verify output.
  2) Manual log scrolling to find first error signal.
  3) Re-running verify just to extract error context.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: None. Potential risk: quiet mode hides context locally; fix via VERIFY_CONSOLE=verbose; enforced by workflow acceptance checks for tail+summary behavior.

## 6) Conflict & Change Zoning
- Files/sections changed: `plans/verify.sh` (logging/run_logged), `plans/workflow_acceptance.sh` (verify quiet-mode checks).
- Hot zones discovered: `run_logged` in `plans/verify.sh`.
- What next agent should avoid / coordinate on: Avoid overlapping edits to `run_logged` without updating workflow acceptance checks.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): `emit_fail_excerpt` helper for artifact-first failure output.
- New "skill" to add/update: None (no new repeated pattern).
- How to apply it (so it compounds): Reuse `emit_fail_excerpt` when adding new quiet log modes.

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
1)
- Rule: MUST preserve artifact-first verify logging (quiet in CI, tail+summary on failure).
- Trigger: Editing `plans/verify.sh` logging or `run_logged` behavior.
- Prevents: CI log bloat and missing failure context.
- Enforce: `plans/workflow_acceptance.sh` verify quiet-mode checks.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Enforce verify quiet mode + failure excerpts via workflow acceptance checks.
- Owner: agent
- Effort: S
- Expected gain: Reduced CI log volume and faster error triage.
- Proof of completion: workflow acceptance passes with VERIFY_CONSOLE checks present.

### Subordinate (cheap wins)
1)
- Change: Add VERIFY_FAIL_TAIL_LINES/VERIFY_FAIL_SUMMARY_LINES knobs.
- Owner: agent
- Effort: S
- Expected gain: Tunable, concise failure context without reruns.
- Proof of completion: verify quiet-mode excerpt uses the knobs (grep in verify.sh).

2)
- Change: Document VERIFY_CONSOLE usage in verify.sh header.
- Owner: agent
- Effort: S
- Expected gain: Faster local override when debugging.
- Proof of completion: verify.sh header lists VERIFY_CONSOLE and failure excerpt env vars.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): none
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Quiet verify runs must still produce artifact logs and surface tail+summary on failure.
- What is the cheapest automated check that enforces it?: grep-based checks in `plans/workflow_acceptance.sh`.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): script
- What would break if we remove your fix?: CI logs would bloat again and failures would lack quick context.
