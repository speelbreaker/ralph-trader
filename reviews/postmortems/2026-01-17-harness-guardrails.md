# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Added explicit AGENTS.md harness guardrails + sink focus, enforced via workflow acceptance checks; fixed invalid canonical place value in a prior postmortem; refreshed contract coverage timestamp.
- Contract/plan requirement satisfied: WF-2.2 verification mandatory + WF-11.1 workflow change control in specs/WORKFLOW_CONTRACT.md.
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: Harness guardrails were implicit, causing late failures and re-runs.
- Exploit (what I did now): Codified guardrails in AGENTS.md and enforced them in workflow acceptance.
- Subordinate (workflow changes needed): Keep AGENTS.md guardrails and acceptance checks synchronized on future edits.
- Elevate (permanent fix proposal): Add a lightweight preflight helper to validate postmortem canonical-place values before full verify.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-2.2, WF-2.8, WF-11.1 in specs/WORKFLOW_CONTRACT.md.
- Proof (tests/commands + outputs): `CONTRACT_COVERAGE_OUT=/tmp/contract_coverage.md VERIFY_RUN_ID=20260117_114200 ./plans/verify.sh full` → `=== VERIFY OK (mode=full) ===` (artifacts/verify/20260117_114200).

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): CONTRACT_COVERAGE_OUT override is acceptable for local verify without touching docs/contract_coverage.md -> plans/verify.sh contract coverage step -> Y.

## 4) Friction Log
- Top 3 time/token sinks:
  1) workflow_acceptance.sh full runtime
  2) late postmortem schema failures
  3) contract coverage doc churn from local verify

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: verify failed on invalid canonical place value in reviews/postmortems/2026-01-17-acceptance-fastfail-resume.md → corrected to AGENTS → postmortem_check gate passes.

## 6) Conflict & Change Zoning
- Files/sections changed: AGENTS.md, plans/workflow_acceptance.sh, docs/contract_coverage.md, reviews/postmortems/2026-01-17-acceptance-fastfail-resume.md, reviews/postmortems/2026-01-17-harness-guardrails.md.
- Hot zones discovered: plans/workflow_acceptance.sh (harness tests), reviews/postmortems/*.md (schema gates).
- What next agent should avoid / coordinate on: Avoid overlapping edits in workflow_acceptance test blocks; coordinate postmortem field changes to satisfy schema checks.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): None.
- New "skill" to add/update: None.
- How to apply it (so it compounds): N/A.

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
- Include: Trigger condition, failure mode prevented, and where to enforce.
1)
- Rule: MUST keep fast precheck set limited to schema/self-dep/shellcheck/traceability.
- Trigger: Modifying workflow_acceptance fast set.
- Prevents: fast mode becoming as slow as full suite.
- Enforce: workflow acceptance fast-set check.
2)
- Rule: SHOULD keep workflow_acceptance test IDs stable and listable.
- Trigger: Adding/removing acceptance tests.
- Prevents: selector/resume drift across test IDs.
- Enforce: workflow_acceptance --list stability checks.
3)
- Rule: MUST avoid bash 4+ builtins (mapfile/readarray) in harness scripts.
- Trigger: Editing plans/*.sh harness scripts.
- Prevents: macOS bash 3.2 runtime failures.
- Enforce: workflow_acceptance grep guard.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Add a lightweight preflight helper (or doc section) that validates postmortem canonical-place values before full verify.
- Owner: workflow maintainer
- Effort: S
- Expected gain: prevent late postmortem schema failures.
- Proof of completion: preflight check fails fast on invalid canonical place values.

### Subordinate (cheap wins)
1)
- Change: Document CONTRACT_COVERAGE_OUT override in README/local workflow section.
- Owner: workflow maintainer
- Effort: S
- Expected gain: avoid contract coverage doc churn in local runs.
- Proof of completion: README section references CONTRACT_COVERAGE_OUT usage.

2)
- Change: Add a targeted workflow acceptance selector test for --from/--until bounds.
- Owner: workflow maintainer
- Effort: S
- Expected gain: reduce full reruns for selector regressions.
- Proof of completion: new acceptance test covers selector bounds.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): N/A
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Harness guardrails must be explicit and enforced for workflow edits.
- What is the cheapest automated check that enforces it?: workflow_acceptance grep checks for AGENTS.md guardrails.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): AGENTS
- What would break if we remove your fix?: Guardrails drift and late verify failures would return.
