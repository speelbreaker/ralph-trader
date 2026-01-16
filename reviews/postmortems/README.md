# PR Postmortems

Purpose
- Each PR must add a filled postmortem entry based on PR_POSTMORTEM_TEMPLATE.md.
- Entries are structured for parsing and enforcement.

Naming
- Use YYYY-MM-DD_<short-description>.md

Rules
- Every PR must include at least one entry file in this folder.
- If a recurring issue is marked "Y", the PR must also:
  - include a concrete enforcement path (script_check, contract_clarification, or test), and
  - update WORKFLOW_FRICTION.md with the elevation action.
- Postmortems must include the "Apply or it didn't happen" section (invariant + enforcement + canonical place + removal impact).
