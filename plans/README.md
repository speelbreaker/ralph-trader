# Plans Harness

## Entry points

- `./plans/bootstrap.sh` — one-time scaffolding for the harness (optional but recommended)
- `./plans/init.sh` — cheap preflight (optional)
- `./plans/verify.sh` — canonical verify gate (CI should call this)
- `./plans/ralph.sh` — harness loop

### workflow_verify.sh

Focused maintenance runner for workflow-only changes (`./plans/workflow_verify.sh`). Runs:
- Bash syntax check on key workflow scripts (`plans/verify.sh`, `plans/ralph.sh`, `plans/update_task.sh`, `plans/workflow_acceptance.sh`)
- Workflow acceptance (full mode)

Use when editing `plans/*.sh` or `specs/WORKFLOW_CONTRACT.md`. Does not run full `./plans/verify.sh` by default; set `RUN_REPO_VERIFY=1` to also run `./plans/verify.sh quick`.

## Notes

- `plans/prd.json` is the story backlog (machine-readable).
- `plans/progress.txt` is append-only shift handoff log.
- `plans/ideas.md` is append-only deferred ideas log (non-PRD).
- Keep `docs/codebase/*` updated when starting a new story or after major refactors.
- Optional presets: set `RPH_PROFILE=fast|thorough|audit|max` to apply default knobs (env overrides win).
- Optional helper: source `plans/profile.sh <profile>` to export the preset env vars in your shell.
- Optional timeout: set `RPH_ITER_TIMEOUT_SECS` to cap agent/verify runtime.
- PRD drafting knobs: PRD schema floors (acceptance/steps) can be raised with `PRD_SCHEMA_MIN_ACCEPTANCE` / `PRD_SCHEMA_MIN_STEPS`; lowering requires `PRD_SCHEMA_DRAFT_MODE=1` and is blocked from Ralph execution.
- PRD scope: use `scope.create[]` for new paths (must not exist yet); scope gating allows `scope.touch` + `scope.create`.
- PRD pipeline: `plans/prd_pipeline.sh` expects `PRD_*_CMD` to be an executable path and supports optional `PRD_*_ARGS` for arguments.

## Workflow discipline

- Run exactly one PRD item per agent session to keep a fresh context per atomic task.
- Start a new session for the next PRD item (do not carry context forward).

## Progress log template (append-only)

- `Sx-yyy`: short description of what changed.
- `Commands`: key commands run.
- `Verify`: `./plans/verify.sh <mode>` (include failures if any).
- `Notes`: status/metrics or blockers (optional).
- `Ack`: confirm you read AGENTS.md and progress.txt.
- `Assumptions`: call out key assumptions made (optional).
- `Open questions`: anything needing a human decision (optional).
- `Next`: next step.

## Pause note (optional)

If you stop mid-story, capture a short pause note in `plans/pause.md` so the next session can resume quickly.
