# Plans Harness

## Entry points

- `./plans/bootstrap.sh` — one-time scaffolding for the harness (optional but recommended)
- `./plans/init.sh` — cheap preflight (optional)
- `./plans/verify.sh` — canonical verify gate (CI should call this)
- `./plans/ralph.sh` — harness loop

## Notes

- `plans/prd.json` is the story backlog (machine-readable).
- `plans/progress.txt` is append-only shift handoff log.
