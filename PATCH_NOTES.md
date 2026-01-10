Workflow Contract Review — Failure Mode Coverage

- Agent declares done early: COMPLETE sentinel now triggers a completion check only; Ralph blocks with a `blocked_incomplete_*` artifact unless all items pass, verify_post is green, and required iteration artifacts exist.
- Agent marks passes without verify: PRD pass flips are harness-only; agent PRD edits are blocked by default; `<mark_pass>` is ignored unless verify_post is green and contract_review.json is pass, and the commit is amended by the harness.
- Baseline red but agent continues: verify_pre failure blocks before any implementation; self-heal retries verify_pre once and blocks if still red, with a blocked artifact.
- PRD corruption: preflight schema validation now enforces required top-level keys, required item fields, acceptance ≥ 3, steps ≥ 5, verify includes `./plans/verify.sh`, and `needs_human_decision` ⇒ `human_blocker`.
- Blocked stories ignored/skipped: not fully addressed by the minimal patch set; active-slice selection still depends on PRD ordering and priority. Remaining risk requires a contract change (e.g., “any needs_human_decision in ACTIVE_SLICE blocks the run”).
- Slice order violated: harness-only pass flips plus active-slice selection prevents advancing slices by manual pass toggles; invalid selection is blocked.
- verify.sh vs CI drift: verify.sh now emits `VERIFY_SH_SHA=...` as the first line; Ralph blocks if verify logs lack the signature, making drift observable and enforced.
- No-progress spin overnight: default `RPH_MAX_ITERS=50` stops with a blocked artifact when exceeded; repeated failures/no-progress already trigger circuit-breaker blocks.
- Contract alignment gate missing or bypassed: Ralph now requires `contract_review.json` after green verify_post and blocks if missing or status=fail, preventing pass flips without contract review.
