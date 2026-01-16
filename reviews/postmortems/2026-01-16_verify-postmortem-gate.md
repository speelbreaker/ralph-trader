# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Hardened verification workflow by enforcing a single verify entrypoint and expanding workflow-change detection.
- Contract/plan requirement satisfied: WF-2.8 PR postmortem is mandatory (specs/WORKFLOW_CONTRACT.md).
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: Split-brain verify behavior and workflow acceptance skipping a critical allowlist file.
- Exploit (what I did now): Added a root verify.sh wrapper, extended workflow allowlist coverage, and validated the wrapper in workflow acceptance.
- Subordinate (workflow changes needed): Keep allowlist/overlay checks aligned with actual workflow-critical files.
- Elevate (permanent fix proposal): Generate allowlist/overlay data from a single source of truth to prevent drift.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-2.8, WF-5.5.1
- Proof (tests/commands + outputs): ./plans/verify.sh full

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): Assumed this is not a recurring issue -> reviews/postmortems/README.md rules -> Y

## 4) Friction Log
- Top 3 time/token sinks:
  1) Resolving workflow-script merge conflicts across verify/acceptance.
  2) Ensuring allowlist/overlay parity for workflow-critical files.
  3) Remembering postmortem gate requirements for workflow PRs.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: Root verify diverges or allowlist omits workflow file -> acceptance can skip/permit drift -> add wrapper + allowlist + acceptance checks -> run ./plans/verify.sh full.

## 6) Conflict & Change Zoning
- Files/sections changed: verify.sh, plans/verify.sh, plans/workflow_acceptance.sh, AGENTS.md, reviews/postmortems/2026-01-16_verify-postmortem-gate.md
- Hot zones discovered: plans/workflow_acceptance.sh allowlist/overlay checks; plans/verify.sh workflow gating.
- What next agent should avoid / coordinate on: Avoid editing root verify.sh beyond wrapper; update allowlist and acceptance together.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): Root wrapper for single-source verify.
- New "skill" to add/update: None (no new skill added)
- How to apply it (so it compounds): Use the wrapper pattern for any future top-level entrypoints.

## 8) What should we add to AGENTS.md?
1)
- Rule: MUST keep root verify.sh as a thin wrapper that delegates to plans/verify.sh.
- Trigger: Any edit to root verify.sh or introduction of a root verify script.
- Prevents: Split-brain verification behavior between root and plans scripts.
- Enforce: plans/workflow_acceptance.sh wrapper checks.
2)
- Rule: SHOULD update plans/verify.sh:is_workflow_file when adding workflow-critical files.
- Trigger: Introducing new workflow/harness files or policy files.
- Prevents: Workflow acceptance skipping changes that must be validated.
- Enforce: plans/workflow_acceptance.sh allowlist check.
3)
- Rule: MUST keep workflow acceptance overlays aligned with workflow-critical script changes.
- Trigger: Modifying scripts used by acceptance harness.
- Prevents: Acceptance running against stale script versions.
- Enforce: plans/workflow_acceptance.sh overlay list.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
### Elevate (permanent fix)
- Change: Auto-generate workflow allowlist/overlay entries from a single canonical list.
- Owner: Maintainer
- Effort: M
- Expected gain: Eliminates drift and reduces conflict resolution time.
- Proof of completion: Script generates allowlist/overlay and is used in plans/workflow_acceptance.sh.

### Subordinate (cheap wins)
1)
- Change: Add a helper script to scaffold a postmortem entry with required fields.
- Owner: Maintainer
- Effort: S
- Expected gain: Faster compliance with postmortem gate.
- Proof of completion: Helper script exists and is referenced in reviews/postmortems/README.md.

2)
- Change: Add a short checklist note in AGENTS.md about updating allowlist/acceptance together.
- Owner: Maintainer
- Effort: S
- Expected gain: Fewer missed allowlist updates.
- Proof of completion: AGENTS.md includes the checklist note.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): none
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Verification must route through plans/verify.sh; root verify.sh may only delegate.
- What is the cheapest automated check that enforces it?: Wrapper checks in plans/workflow_acceptance.sh.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): script
- What would break if we remove your fix?: Root verify could drift and bypass workflow acceptance gating.
