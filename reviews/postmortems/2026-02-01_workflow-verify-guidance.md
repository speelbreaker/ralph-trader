# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added workflow-verify guidance in AGENTS.md, review checklist evidence requirement, Review Coverage guidance in SKILLS/pr-review, and acceptance checks for the markers.
- What value it has (what problem it solves, upgrade provides): Reduces unnecessary full verify churn during workflow-only iteration while keeping a full gate before PR.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Workflow-only edits triggered repeated full verify runs; reviewers lacked a standard evidence check; guidance was easy to miss.
- Time/token drain it caused: Several minutes per iteration waiting on full workflow acceptance.
- Workaround I used this PR (exploit): Codified the workflow_verify + final full verify pattern and enforced it in review/acceptance.
- Next-agent default behavior (subordinate): Use `./plans/workflow_verify.sh` while iterating on workflow files, then run `./plans/verify.sh full` before PR.
- Permanent fix proposal (elevate): Have workflow_verify print a reminder to run full verify before PR and record last-run metadata in artifacts.
- Smallest increment: This PR (rule + checklist + acceptance checks).
- Validation (proof it got better): `./plans/verify.sh full` passes and workflow acceptance enforces the new markers.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response:
  1. [BEST] Add a short reminder to `plans/workflow_verify.sh` about running `./plans/verify.sh full` before PR. Validate: workflow_verify output includes reminder.
  2. Record workflow_verify run metadata in `artifacts/verify/` to make evidence easier to cite. Validate: artifacts contain a timestamped metadata file.
  3. Add a small doc snippet in `plans/README.md` with the same guidance. Validate: README updated and referenced in AGENTS.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1. Already added: workflow-only changes SHOULD use `./plans/workflow_verify.sh` during iteration and `./plans/verify.sh full` before PR. [WF-VERIFY-RULE]
  2. No additional rules needed.
