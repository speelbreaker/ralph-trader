# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: audit parallel caching + merge tooling; workflow acceptance updates (incl. invariants appendix check + PRD ref-skip CI override); contract kernel refresh; verify-worktree push guard + AGENTS clean-worktree rule; Deribit vendor doc; knowledge index; invariants appendix; review checklist skill-use prompt.
- What value it has (what problem it solves, upgrade provides): faster audit runs with cache/merge, clearer vendor + invariant references, and better review discipline.
- Governing contract: workflow (specs/WORKFLOW_CONTRACT.md) + trading behavior (specs/CONTRACT.md).

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): workflow/harness files changed; local verify would fail on dirty tree; multiple doc + tooling changes increased verification surface.
- Time/token drain it caused: delayed local verification; reliance on CI for proof.
- Workaround I used this PR (exploit): bundle changes and rely on CI `./plans/verify.sh full` for clean-tree proof.
- Next-agent default behavior (subordinate): avoid mixing workflow/harness edits with unrelated doc/tooling changes in one commit.
- Permanent fix proposal (elevate): enforce “workflow changes only” commit guidance in reviews/REVIEW_CHECKLIST.md (separate PRs) or add an automated reminder in review templates.
- Smallest increment: split workflow edits into a separate PR or commit before doc/tooling work.
- Validation (proof it got better): fewer CI reruns and faster green verify on clean checkout.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: add a small acceptance test assertion for any new workflow/harness behavior added in this series; validate with CI `./plans/verify.sh full`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: require “skills consulted” to be listed in review summaries (already added to reviews/REVIEW_CHECKLIST.md); prefer separating workflow/harness changes from doc/tooling updates.
