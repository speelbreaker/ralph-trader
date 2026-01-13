# Workflow Skill Memory (Manual)

Purpose
- Capture recurring corrections and preferred patterns for the workflow harness.
- Manual-only; no automation. Update when a pattern repeats.

Usage policy
- Read before starting any task.
- Update only when a new repeated pattern is discovered (manual judgment).
- Keep it versioned and lightweight; no new gates or automation.

How to use
- Add an entry only after it has happened at least twice.
- Keep entries short, specific, and testable.
- Prefer "Do/Don't" phrasing with an example.

## Rules (Stable)
- [x] Rule: Always run `cargo fmt` after making Rust code changes
  - Do: Run `cargo fmt` immediately after editing any Rust source files, before running verify.sh
  - Don't: Skip formatting and rely on verify.sh to catch it (wastes iteration time)
  - Example: After editing crates/soldier_core/src/venue/cache.rs, run `cargo fmt` before `./plans/verify.sh full`
  - Related files: plans/verify.sh (includes cargo fmt check), any .rs files
  - Added: 2026-01-13 (observed in S1-003, S1-004, S1-005 iterations)

- [x] Rule: Run `./plans/init.sh` before `./plans/verify.sh` when starting work
  - Do: Always run init.sh first to ensure environment is ready
  - Don't: Skip init and assume the environment is correct from last time
  - Example: Start each session with `./plans/init.sh && ./plans/verify.sh full`
  - Related files: plans/init.sh, plans/verify.sh
  - Added: 2026-01-13 (consistent pattern across all story executions)

## Pitfalls (Recent)
- [x] Pitfall: Forgetting to format before verify causes wasted iteration
  - Symptom: verify.sh fails on `cargo fmt --check` even though tests pass
  - Root cause: Developer edited .rs files but didn't run cargo fmt before verification
  - Fix: Run `cargo fmt` immediately after any Rust code edit, before verify.sh
  - Added: 2026-01-13 (S1-003, S1-004)

## Test Harness Notes
- [x] Note: verify.sh includes cargo fmt check as a gate
  - Context: plans/verify.sh is the canonical verification script
  - Expected behavior: It runs `cargo fmt --check` and fails if formatting is needed
  - Assertion: Zero exit code from verify.sh means all gates pass including formatting
  - Added: 2026-01-13 (observed in all story verification runs)

## Terminology (Local)
- [x] Term: Story
  - Definition: A bite-sized, single-commit unit of work from plans/prd.json
  - Source: specs/WORKFLOW_CONTRACT.md, IMPLEMENTATION_PLAN.md
  - Added: 2026-01-13

- [x] Term: Slice
  - Definition: A large unit grouping multiple stories, executed in ascending order
  - Source: IMPLEMENTATION_PLAN.md Phase breakdown
  - Added: 2026-01-13

## Retired
(No retired entries yet)
