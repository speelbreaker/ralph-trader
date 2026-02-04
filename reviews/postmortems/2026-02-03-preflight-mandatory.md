# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Mandatory workflow preflight gate in `plans/verify.sh`, hardened preflight exit codes, and acceptance coverage.
- What value it has (what problem it solves, upgrade provides): Catches schema/shell/postmortem issues in <30s before expensive gates; fail-closed behavior is consistent and observable.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Late discovery of postmortem/schema/shell failures only after full verify; repeated reruns of heavy gates; unclear exit-code semantics from preflight.
- Time/token drain it caused: Multiple full verify reruns + manual debugging to discover basic issues.
- Workaround I used this PR (exploit): Added a mandatory preflight gate to fail early with clear logs and exit codes.
- Next-agent default behavior (subordinate): Always get a fast preflight result before expensive gates.
- Permanent fix proposal (elevate): Keep preflight mandatory and enforce via acceptance + workflow contract mapping.
- Smallest increment: Ensure preflight runs in verify and exits 2 on setup errors.
- Validation (proof it got better): `plans/verify.sh` now runs `preflight` first and acceptance tests cover strict/base-ref and setup-error exit code.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Update `plans/README.md` to document mandatory preflight; add an acceptance check for README mention. Validate via `./plans/workflow_acceptance.sh --mode full`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: When adding a workflow gate, update `specs/WORKFLOW_CONTRACT.md`, `plans/workflow_contract_map.json`, and `plans/workflow_acceptance.sh` in the same change; verify by running `./plans/workflow_contract_gate.sh`.
