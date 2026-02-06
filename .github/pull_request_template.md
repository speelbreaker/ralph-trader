# PR Summary

## Postmortem entry (required)
- Path: reviews/postmortems/...

## 0) What shipped
- Feature/behavior:
- What value it has (what problem it solves, upgrade provides):

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms):
- Time/token drain it caused:
- Workaround I used this PR (exploit):
- Next-agent default behavior (subordinate):
- Permanent fix proposal (elevate):
- Smallest increment:
- Validation (proof it got better): (metric, fewer reruns, faster command, fewer flakes, etc.)

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response:

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:

## 4) Architectural Risk Lens (required)
For each item below, provide at least one concrete case. If none, write `none` plus explicit rationale.

1. Architectural-level failure modes (not just implementation bugs)
- Failure mode:
- Trigger:
- Blast radius:
- Detection signal:
- Containment:

2. Systemic risks and emergent behaviors
- Cross-component interaction:
- Emergent behavior risk:
- Propagation path:
- Containment:

3. Compounding failure scenarios
- Chain: A -> B -> C
- Escalation condition:
- Breakpoints/guards that stop compounding:
- Evidence (test/log/validation):

4. Hidden assumptions that could be violated
- Assumption:
- How it can be violated:
- Detection:
- Handling/fail-closed behavior:

5. Long-term maintenance hazards
- Hazard:
- Why it compounds over time:
- Owner:
- Smallest follow-up:
- Validation plan:

## Evidence (optional but recommended)
- Command:
  - Key output:
  - Artifact/log path:
