# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Added the required PR postmortem entry so CI postmortem gate passes.
- Contract/plan requirement satisfied: WF-2.8 PR postmortem is mandatory (specs/WORKFLOW_CONTRACT.md).
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: CI failed because no postmortem entry changed under reviews/postmortems.
- Exploit (what I did now): Added a filled postmortem entry using the required template fields.
- Subordinate (workflow changes needed): Keep PR template and verify gate aligned so requirements are explicit.
- Elevate (permanent fix proposal): Add a small helper script to scaffold a postmortem entry on demand.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-2.8
- Proof (tests/commands + outputs): ./plans/postmortem_check.sh (postmortem check: OK)

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): Assumed this is not a recurring issue -> reviews/postmortems/README.md rules -> Y

## 4) Friction Log
- Top 3 time/token sinks:
  1) Identifying the new CI gate and required postmortem fields.
  2) Ensuring template compliance with the parser (field labels and counts).
  3) Re-running local checks to confirm the gate passes.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: CI fails on postmortem gate -> add filled entry -> run ./plans/postmortem_check.sh.

## 6) Conflict & Change Zoning
- Files/sections changed: reviews/postmortems/2026-01-16_verify-postmortem-gate.md
- Hot zones discovered: plans/postmortem_check.sh expectations; postmortem template field labels.
- What next agent should avoid / coordinate on: Do not omit postmortem entry for PRs; follow template strictly.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): None (used existing template).
- New "skill" to add/update: None
- How to apply it (so it compounds): N/A

## 8) What should we add to AGENTS.md?
1)
- Rule: MUST add a PR postmortem entry whenever a PR changes workflow-critical files.
- Trigger: Any change to files in plans/verify.sh:is_workflow_file or reviews/postmortems requirements.
- Prevents: CI failure due to missing postmortem gate.
- Enforce: plans/postmortem_check.sh (called by ./plans/verify.sh).

## 9) Concrete Elevation Plan to reduce Top 3 sinks
### Elevate (permanent fix)
- Change: Add a helper script to scaffold a postmortem entry with required fields.
- Owner: Maintainer
- Effort: S
- Expected gain: Faster compliance and fewer CI retries.
- Proof of completion: Script exists and is referenced in reviews/postmortems/README.md.

### Subordinate (cheap wins)
1)
- Change: Add a checklist reminder in PR template linking to postmortem instructions.
- Owner: Maintainer
- Effort: S
- Expected gain: Fewer missed postmortems.
- Proof of completion: PR template includes a postmortem checklist link.

2)
- Change: Add a brief note in AGENTS.md about postmortem requirement triggers.
- Owner: Maintainer
- Effort: S
- Expected gain: Reduced onboarding confusion.
- Proof of completion: AGENTS.md contains the note.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): none
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Every PR must include a postmortem entry under reviews/postmortems.
- What is the cheapest automated check that enforces it?: plans/postmortem_check.sh in ./plans/verify.sh.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): contract
- What would break if we remove your fix?: CI would keep failing on the postmortem gate for this PR.
