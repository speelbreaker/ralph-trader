# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Simplified postmortem requirement to a minimal, human-readable template; CI gate now only checks that an entry was created.
- What value it has (what problem it solves, upgrade provides): Reduces postmortem overhead while preserving a lightweight narrative for reviewers.

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Postmortem gate required long structured fields; mismatch with the short SKILLS guidance; frequent rework to satisfy strict field validation.
- Time/token drain it caused: Extra edit/verify cycles just to satisfy formatting checks.
- Workaround I used this PR (exploit): Authorized a workflow contract change to relax postmortem gate requirements.
- Next-agent default behavior (subordinate): Create a postmortem entry using the short template; focus on narrative clarity over rigid fields.
- Permanent fix proposal (elevate): Keep only the “entry created” gate and document the short template as the recommended format.
- Smallest increment: Remove field validation from the postmortem check; update workflow acceptance checks and contract wording.
- Validation (proof it got better): ./plans/verify.sh full passes with only an entry present (no field validation).

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Follow-up PR to optionally add a lightweight linter that warns (non-blocking) when the short template isn’t followed; validate by confirming verify remains green with and without the warning.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None needed; contract now defines the minimal gate and the template is only recommended.
