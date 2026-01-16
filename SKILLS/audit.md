# Skill: Audit

Purpose
- Verify contract and workflow alignment before implementation or merge.

When to use
- Before changing workflow/harness files.
- Before flipping passes or approving a PR.

Checklist
- Read CONTRACT.md and specs/WORKFLOW_CONTRACT.md.
- Identify affected WF/contract clauses.
- Confirm enforcement paths (script, contract, test).
- Confirm verify.sh and workflow acceptance coverage where required.
- Record evidence (commands + outputs).

Output
- Short audit notes with contract refs and evidence.
