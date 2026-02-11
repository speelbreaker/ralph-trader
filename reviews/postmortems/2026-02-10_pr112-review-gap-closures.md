# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Closed review gaps from PR112 by adding quantize raw-input fail-closed validation, replacing synthetic intent-id propagation assertions with runtime-captured metric lines, hardening reset-lock liveliness precedence, sanitizing vendor-doc artifact paths, and fixing CI verify exit-code propagation through `tee`.
- What value it has (what problem it solves, upgrade provides): Removes silent invalid-input coercion risk, makes traceability assertions meaningful, prevents stale-live lock deletion, avoids local-path leakage in artifacts, and ensures CI cannot report success when `./plans/verify.sh` fails.
- Governing contract: specs/WORKFLOW_CONTRACT.md | specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Findings existed but were not closed into red-green tests; CI verify step could emit `FAIL:` while job stayed green; lock reset stale logic treated age as stronger than liveness.
- Time/token drain it caused: Repeated review cycles and extra manual verification to prove runtime behavior instead of relying on nominal check output.
- Workaround I used this PR (exploit): Added failing tests/acceptance assertions first, then minimal production fixes; patched CI workflow to persist `verify_rc` via `PIPESTATUS` and fail on non-zero output.
- Next-agent default behavior (subordinate): Convert every P1/P2 review finding into a failing test or acceptance assertion before coding.
- Permanent fix proposal (elevate): Add explicit workflow acceptance assertions for verify-step exit propagation and keep lock-liveness precedence covered.
- Smallest increment: Keep the new `workflow_acceptance` checks for `verify_rc` and stale-live lock behavior as mandatory guards.
- Validation (proof it got better): Targeted soldier_core tests pass; stale-live lock repro now fails closed (`rc=1`); workflow acceptance `--only 0k` passed in clean worktree with new CI assertions.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Best follow-up PR is to add an acceptance test that runs a tiny fixture workflow verifying `verify_rc` behavior end-to-end (not grep-only). Smallest increment is a fixture plus one assertion in `plans/workflow_acceptance.sh`; validate by forcing a failing verify command in fixture and confirming workflow exits non-zero.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1) MUST convert every review finding at severity P1/P2 into a failing test/acceptance assertion before implementation. Trigger: code review fixes. Prevents: “found but not closed” regressions. Enforce: review checklist + CI test evidence.
  2) MUST preserve piped command exit codes in CI verify steps (`set -o pipefail` + explicit capture when using `tee`). Trigger: workflow edits with piped gates. Prevents: false-green CI runs. Enforce: workflow acceptance assertion on `.github/workflows/ci.yml`.
