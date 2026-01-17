# SKILL: Post-PR Postmortem (Human-Readable + Reproducible Proof)

Use this every time. It is written for a human reviewer first, with proof kept compact at the end.

0) What shipped
Feature/behavior:
What value it has (what problem it solves, upgrade provides):

1) Constraint (ONE)
How it manifested (2-3 concrete symptoms):
Time/token drain it caused:
Workaround I used this PR (exploit):
Next-agent default behavior (subordinate):
Permanent fix proposal (elevate):
Smallest increment:
Validation (proof it got better): (metric, fewer reruns, faster command, fewer flakes, etc.)

2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.

3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
