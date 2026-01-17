# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Added workflow acceptance runner controls (list/only/resume/fast), fast prechecks, and state/status tracking with new contract + map coverage.
- Contract/plan requirement satisfied: WF-11.1 change control + WF-13.* workflow acceptance runner requirements.
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: Long workflow acceptance runs surfaced cheap mistakes late.
- Exploit (what I did now): Added fast prechecks + targeted reruns with resume/state/status to fail fast and reduce reruns.
- Subordinate (workflow changes needed): Add a compatibility guard for bash 3.2 builtins to prevent local harness failures.
- Elevate (permanent fix proposal): Enforce bash-compatibility and selector semantics in workflow acceptance tests.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-11.1, WF-2.2, WF-13.1–WF-13.6 in specs/WORKFLOW_CONTRACT.md.
- Proof (tests/commands + outputs): `./plans/verify.sh full` → `Workflow acceptance tests passed` and `=== VERIFY OK (mode=full) ===` (artifacts/verify/20260117_101902).

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): macOS bash is 3.2 and lacks mapfile/readarray -> workflow acceptance run on mac -> Y (mapfile failure repro, fixed).

## 4) Friction Log
- Top 3 time/token sinks:
  1) workflow_acceptance.sh full runtime
  2) late discovery of PRD/schema/shell issues
  3) re-running full verify after small harness tweaks

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: Running workflow acceptance on mac failed with `mapfile: command not found` → replaced mapfile/awk parsing with sed/while loop → verified via `./plans/verify.sh full`.

## 6) Conflict & Change Zoning
- Files/sections changed: specs/WORKFLOW_CONTRACT.md, plans/workflow_contract_map.json, plans/workflow_acceptance.sh.
- Hot zones discovered: plans/workflow_acceptance.sh (high-churn harness script).
- What next agent should avoid / coordinate on: Avoid concurrent edits in workflow_acceptance runner + tests; coordinate on test IDs and selectors.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): None.
- New "skill" to add/update: None.
- How to apply it (so it compounds): N/A.

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
- Include: Trigger condition, failure mode prevented, and where to enforce.
1)
- Rule: MUST avoid bash 4+ builtins (mapfile/readarray) in harness scripts.
- Trigger: Editing files under plans/*.sh.
- Prevents: macOS bash 3.2 runtime failures.
- Enforce: plans/workflow_acceptance.sh grep check for mapfile/readarray.
2)
- Rule: SHOULD keep workflow_acceptance test IDs stable and listable.
- Trigger: Adding/removing acceptance tests.
- Prevents: selector/resume list drift.
- Enforce: plans/workflow_acceptance.sh --list test (Test 0l).
3)
- Rule: MUST keep fast precheck set limited to schema/self-dep/shellcheck/traceability.
- Trigger: Modifying workflow_acceptance fast set.
- Prevents: fast mode becoming as slow as full suite.
- Enforce: plans/workflow_acceptance.sh fast tests (0h/0i/0j/12).

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Add explicit bash-compatibility guard (grep for mapfile/readarray) in workflow acceptance.
- Owner: workflow maintainer
- Effort: S
- Expected gain: prevent macOS harness breaks before full verify.
- Proof of completion: workflow_acceptance test fails when mapfile is introduced.

### Subordinate (cheap wins)
1)
- Change: Add AGENTS.md rule about bash 3.2 compatibility for harness scripts.
- Owner: workflow maintainer
- Effort: S
- Expected gain: reduce recurrence of incompatible bash features.
- Proof of completion: AGENTS.md updated + referenced in postmortem.

2)
- Change: Add a small test that exercises --from/--until selection on the acceptance runner.
- Owner: workflow maintainer
- Effort: S
- Expected gain: prevent selector regressions without full reruns.
- Proof of completion: new acceptance test in plans/workflow_acceptance.sh.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): N/A
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Harness scripts must remain bash 3.2-compatible on macOS.
- What is the cheapest automated check that enforces it?: grep for mapfile/readarray in plans/*.sh.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): AGENTS
- What would break if we remove your fix?: Local verify would fail on macOS before workflow acceptance runs.
