# Story Cutter Guidance Update

Summary:
- Added scope/path validation to avoid broad globs and incorrect Rust paths.
- Required every contract_ref to be enforced by acceptance or mark needs_human_decision.
- Added forward-dependency guard when acceptance/steps rely on later slices.

Rationale:
- Recent audit findings showed over-broad scope globs, incorrect file paths, and contract refs not enforced by acceptance criteria.
- The new rules make these failures explicit at cutter time to prevent downstream FAIL/BLOCKED audits.
