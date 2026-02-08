# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Hardened checkpoint skip behavior and acceptance around enforce/dry_run, schema-complete gate entries, and errexit-safe helper execution paths.
- What value it has (what problem it solves, upgrade provides): Prevents false negatives in acceptance, avoids helper-side shell-option regressions, and keeps skip cache entries structurally valid for downstream readers.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms):
  - `30.4` acceptance could pass/fail intermittently from budget/timing context drift.
  - Helper functions that temporarily disabled `set -e` could re-enable it unexpectedly for callers.
  - Unscheduled gate entries could miss required fields and rely on reader tolerance.
- Time/token drain it caused:
  - Repeated long verify runs to isolate small behavioral differences in checkpoint decisions.
- Workaround I used this PR (exploit):
  - Tightened acceptance fixture env and explicit rc assertions, then validated in a clean snapshot full verify.
- Next-agent default behavior (subordinate):
  - Preserve caller shell options in helpers that run embedded Python and explicitly assert decision rc/reason in checkpoint acceptance tests.
- Permanent fix proposal (elevate):
  - Standardize a shared helper wrapper for shell-option preservation and require it in checkpoint helper functions.
- Smallest increment:
  - Add one reusable `with_errexit_preserved` shell helper in `plans/lib/verify_utils.sh` and migrate checkpoint helper call sites.
- Validation (proof it got better): (metric, fewer reruns, faster command, fewer flakes, etc.)
  - `./plans/verify.sh full` passed in clean snapshot with stable `30.*` results; push hook quick verify also passed with workflow acceptance.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response:
  - Best follow-up PR: extract and adopt shared shell-option preservation utility for verify helpers.
  - Upgrade 1: unify checkpoint decision telemetry formatting across verify and helper scripts.
  - Upgrade 2: add targeted acceptance for helper wrapper misuse detection.
  - Validation: `./plans/workflow_verify.sh` plus clean-snapshot `VERIFY_ALLOW_LOCAL_FULL=1 ./plans/verify.sh full`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  - Require any new acceptance fixture that checks skip decisions to assert both reason and return code.
  - Require helper functions that call subprocess/Python to preserve and restore caller `errexit` state.
  - Require schema-touching writes to populate required nested fields even for unscheduled/empty branches.
