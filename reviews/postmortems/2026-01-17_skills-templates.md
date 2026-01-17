# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Updated SKILLS /plan and post-PR postmortem templates; added PR postmortem entry
- Contract/plan requirement satisfied: WF-2.8 PR postmortem requirement (process)
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: Template drift between provided copy and in-repo SKILLS guidance
- Exploit (what I did now): Replaced SKILLS templates with the provided canonical text
- Subordinate (workflow changes needed): Treat user-provided SKILLS template text as source of truth for updates
- Elevate (permanent fix proposal): Add a canonical templates directory and a sync check to prevent drift

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-2.8 (postmortem required), WF-2.2 (verification)
- Proof (tests/commands + outputs): ./plans/verify.sh (mode=quick), artifacts/verify/20260116_180705
  - ./plans/verify.sh (mode=quick)
    - VERIFY_SH_SHA=dace58729e64364469fa91168add7476f0d96983ebb6a17b4b08664e2d5ca23b
    - postmortem check: no changes detected
    - === VERIFY OK (mode=quick) ===
    - artifacts/verify/20260116_180705

## 3) Guesses / Assumptions
- SKILLS template updates do not require contract/workflow changes -> specs/WORKFLOW_CONTRACT.md -> Validated? N

## 4) Friction Log
- Top 3 time/token sinks:
  1) Running plans/verify.sh for doc-only updates
  2) Manual template transcription from attachments
  3) Filling PR template/postmortem fields

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: None

## 6) Conflict & Change Zoning
- Files/sections changed: SKILLS/plan.md, SKILLS/post_pr_postmortem.md, reviews/postmortems/2026-01-17_skills-templates.md, docs/contract_coverage.md
- Hot zones discovered: SKILLS/*.md templates (frequent edits)
- What next agent should avoid / coordinate on: Avoid parallel edits to SKILLS templates in the same window

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): Updated SKILLS templates for /plan and post-PR postmortem
- New "skill" to add/update: SKILLS/plan.md, SKILLS/post_pr_postmortem.md
- How to apply it (so it compounds): Use the templates verbatim when producing plans and postmortems

## 8) What should we add to AGENTS.md?
- Propose 1-3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
1)
- Rule: MUST treat user-provided SKILLS template text as the source of truth when updating SKILLS
- Trigger: Updating any SKILLS/*.md content from an attachment or paste
- Prevents: Template drift and reviewer mismatch
- Enforce: reviews/REVIEW_CHECKLIST.md (Compounding gate)
2)
- Rule: MUST include a PR postmortem entry for every PR
- Trigger: Preparing a PR (gh pr create)
- Prevents: Postmortem gate failure in plans/verify.sh
- Enforce: plans/verify.sh postmortem gate
3)
- Rule: SHOULD summarize changes using the repository PR template
- Trigger: Writing PR description
- Prevents: Missing required sections (evidence/compounding)
- Enforce: reviews/REVIEW_CHECKLIST.md

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Add canonical SKILLS templates under docs/templates and a script check that diffs SKILLS/*.md against the canonical copies
- Owner: Workflow
- Effort: M
- Expected gain: Prevents template drift and cuts review back-and-forth
- Proof of completion: New script passes in CI; diff check fails when templates diverge

### Subordinate (cheap wins)
1)
- Change: Add a short note in AGENTS.md pointing to docs/templates as the source for SKILLS updates
- Owner: Workflow
- Effort: S
- Expected gain: Fewer manual copy errors
- Proof of completion: AGENTS.md updated with pointer

2)
- Change: Add a PR checklist item reminding to paste user-provided template text verbatim for SKILLS updates
- Owner: Workflow
- Effort: S
- Expected gain: Reduced rework on template edits
- Proof of completion: reviews/REVIEW_CHECKLIST.md updated

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): N/A
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: SKILLS template updates must match the provided canonical text
- What is the cheapest automated check that enforces it?: Diff check between SKILLS/*.md and docs/templates
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): SKILLS + script check
- What would break if we remove your fix?: Templates drift and reviewers reject PRs for mismatched guidance
