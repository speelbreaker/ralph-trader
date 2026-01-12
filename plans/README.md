# Plans Harness

## Entry points

- `./plans/bootstrap.sh` — one-time scaffolding for the harness (optional but recommended)
- `./plans/init.sh` — cheap preflight (optional)
- `./plans/verify.sh` — canonical verify gate (CI should call this)
- `./plans/ralph.sh` — harness loop

## Notes

- `plans/prd.json` is the story backlog (machine-readable).
- `plans/progress.txt` is append-only shift handoff log.
- `plans/ideas.md` is append-only deferred ideas log (non-PRD).
- Keep `docs/codebase/*` updated when starting a new story or after major refactors.

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
