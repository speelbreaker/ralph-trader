# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Hardened checkpoint skip inputs by covering core spec files in the spec validator hash, stabilized override fingerprints by ignoring run-id artifact paths, stabilized bootstrap acceptance runs (BASE_REF pinned, postmortem gate skipped for bootstrap fixtures), corrected local-full + pre-push guard coverage in acceptance, aligned checkpoint tool fingerprints with PYTHON_BIN + GLOBAL_INVARIANTS_FILE overrides, and allowed postmortem files to bypass scope gate with acceptance coverage.
- What value it has (what problem it solves, upgrade provides): Prevents correctness regressions when specs change and allows cache hits across runs by removing volatile inputs.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Skip cache never hit under default run-id settings; spec validator skip could miss CONTRACT/ARCH_FLOWS/GLOBAL_INVARIANTS changes.
- Time/token drain it caused: Repeated hash computation and full validator runs; risk of incorrect skips.
- Workaround I used this PR (exploit): Removed volatile env keys from the fingerprint and expanded the spec validator dependency manifest.
- Next-agent default behavior (subordinate): When adding new skip inputs, ensure dependency manifests include core spec files and fingerprints avoid per-run paths.
- Permanent fix proposal (elevate): Add checklist item to workflow acceptance to assert core spec inputs + verify fingerprint excludes volatile envs.
- Smallest increment: Add manifest entries + ignore comments + acceptance assertions.
- Validation (proof it got better): New workflow_acceptance tests cover cache persistence, fingerprint stability, and spec validator inputs.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Run `./plans/verify.sh full` (or rely on CI) to validate workflow acceptance with the new tests; consider adding a doc note in workflow docs about volatile env keys and cache behavior.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule: “When adding/changing checkpoint skip inputs, update dependency manifest + acceptance test that asserts core spec inputs, and ensure override fingerprint excludes per-run paths.”
