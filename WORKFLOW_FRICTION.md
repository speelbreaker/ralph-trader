# WORKFLOW_FRICTION

Purpose
- Rolling list of the top workflow constraints.
- Each recurring item must name a next elevation action (script check, contract clarification, or test).

How to use
- Keep the Active list to the top 3 constraints only.
- Rank by TOC impact (1 = highest constraint).
- Each entry must include Constraint, Exploit, Elevate, and Next action.

## Active (Top 3)
| Rank | Constraint | Exploit (what we do now) | Elevate (permanent fix) | Next action | Owner | Proof target |
|---|---|---|---|---|---|---|
| 1 | workflow_acceptance.sh full runtime is slow | Keep acceptance tests targeted; batch workflow changes before full runs; use `--only N` for focused tests | Add acceptance tests that simulate change sets to validate gate routing without full run | Add helper in workflow_acceptance.sh to set CHANGED_FILES and assert gates skip/run | maintainer | workflow_acceptance.sh includes routing test that passes |
| 2 | Workflow acceptance fixture/overlay drift | Manually keep fixture paths synced with acceptance tests; add assertions when changing fixtures | Add workflow acceptance self-check that fails if fixture files referenced in tests are missing from overlays | Add overlay-fixture alignment check to workflow_acceptance.sh | maintainer | workflow_acceptance.sh fails on missing overlay fixture |

## Resolved
| Date resolved | Constraint | Resolution | Evidence |
|---|---|---|---|
| 2026-02-03 | Late discovery of postmortem/schema/shell issues | Created plans/preflight.sh with Tier 1 (git, tools, files) and Tier 2 (shell syntax, PRD schema, postmortem) checks | `./plans/preflight.sh` runs in <30s, catches issues before full verify |
