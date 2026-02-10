# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added a Phase 1 missing-config CI test that fails closed per critical key, emits a config-matrix evidence artifact, and documents the critical keys.
- What value it has (what problem it solves, upgrade provides): Proves missing critical inputs are rejected deterministically with enumerated reasons and no side effects; produces auditable evidence for config fail-closed behavior.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): No existing CI test mapped missing config to a single evidence matrix; evidence file was stale/manual; test needed a deterministic writer.
- Time/token drain it caused: Extra investigation to find a safe fail-closed path without adding new runtime gates.
- Workaround I used this PR (exploit): Reused existing gate rejection paths (quantize/liquidity/net-edge/fee staleness) and wrote evidence via `tools/phase1_evidence.py`.
- Next-agent default behavior (subordinate): When adding Phase 1 evidence, prefer `tools/phase1_evidence.py` helpers and keep reason codes enumerated.
- Permanent fix proposal (elevate): Add a small test helper in soldier_core to standardize evidence writes and avoid per-test shelling.
- Smallest increment: A shared Rust helper that calls the evidence writer via `std::process::Command` with PYTHON fallback.
- Validation (proof it got better): `cargo test -p soldier_core --test test_missing_config` writes the matrix and passes.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a focused test for a safety-critical config key without an Appendix A default (e.g., dd_limit) once the gate exists in core; validate by asserting `CONFIG_MISSING` and zero side effects in the same matrix.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require evidence writers in tests to use `PYTHON` env fallback to avoid `python` not found failures on macOS.
