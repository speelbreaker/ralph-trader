# Ralph Loop Playbook

Purpose
- Practical guidance for running and maintaining the Ralph harness.
- Focus on failure recovery and operational hygiene.

Quickstart
- Ensure clean tree: `git status --porcelain` is empty.
- Baseline green: `./plans/verify.sh` (or `./plans/verify.sh full`).
- Run: `./plans/ralph.sh 1` for a single iteration.

Bootstrap Mode
- Use only when the workspace is intentionally missing and `verify_pre` would fail (e.g., no `Cargo.toml` yet).
- Enable with `RPH_BOOTSTRAP_MODE=1`.
- Behavior: `verify_pre` is skipped, bootstrap preflight runs instead:
- `./plans/preflight.sh --strict`
- `./plans/prd_preflight.sh --strict "$PRD_FILE"`
- `./plans/run_prd_auditor.sh`
- `./plans/prd_audit_check.sh`
- Safety: pass flips are forbidden in bootstrap mode; once the workspace exists, run normal `verify_pre` and a full verify before promotion.
- Diagnostics: `.ralph/verify_pre.log` records `VERIFY_SH_SHA` and `bootstrap_skip_reason`.

Failure Recovery
- Stale lock: if no active run but `.ralph/lock/` exists, remove it and retry.
- Interrupted run: state files are unlocked on exit; if they remain read-only, `chmod u+w .ralph/state.json plans/prd.json`.

Metrics Rotation
- Metrics are written to `.ralph/metrics.jsonl`.
- Size cap: `RPH_METRICS_MAX_BYTES` (default 5MB). Set `0` to disable rotation.
- Rotation behavior: when the cap is reached, the metrics file is renamed with a timestamp and a new file is created.

Iteration Archive
- Old iteration dirs are archived under `.ralph/archive/` when `RPH_ARCHIVE_OLD_ITERS=1`.
- If archiving fails, the original iteration directory is kept and a warning is logged.

Notes
- Harness changes require updated assertions in `plans/workflow_acceptance.sh` and a passing `./plans/verify.sh`.
