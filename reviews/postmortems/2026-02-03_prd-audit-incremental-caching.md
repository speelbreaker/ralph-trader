# PR Postmortem: PRD Audit Incremental Caching

## 0) What shipped
- Feature/behavior: Incremental caching for PRD slice audits with fail-closed semantics
- What value it has: Avoids re-running expensive LLM audits when inputs haven't changed; reduces audit time from O(n) to O(changed slices)
- Governing contract: specs/WORKFLOW_CONTRACT.md (audit integrity)

## 1) Constraint (ONE)
- How it manifested:
  1. Initial implementation had lock fallback that defeated mutual exclusion (os.open failure → mkdir fallback allowed concurrent writers)
  2. BLOCKED decisions skipped cache update, leaving stale PASS/FAIL entries
  3. Review skill checklist didn't catch these failure modes on first pass

- Time/token drain: 3 review iterations to catch all failure modes; ~30 min additional review time

- Workaround I used this PR: Human reviewer caught the bugs; I fixed them reactively

- Next-agent default behavior (subordinate): Run failure-mode-review skill for any caching/locking code before declaring implementation complete

- Permanent fix proposal (elevate): Add "lock fallback enumeration" and "cache invalidation completeness" to failure-mode-review.md checklist

- Smallest increment: Add to failure-mode-review.md:
  ```
  | Lock fallback | Fallback defeats mutual exclusion | Only fall back when lock mechanism unavailable, not when lock is held |
  | Cache skip on special values | Stale entries remain | Write special value to cache, don't skip update |
  ```

- Validation: Next caching PR should have 0 lock/invalidation bugs caught in review

## 2) Best follow-up PR
- **Immediate**: Add cache eviction/rotation (currently unbounded growth)
  - Smallest increment: Delete entries older than 7 days on cache update
  - Validation: Cache file size stays bounded over time

- Worth considering:
  1. Cache warming on CI (pre-compute digests to speed up first run)
  2. Parallel cache updates (currently sequential after parallel audits)
  3. Cache hit/miss metrics for observability

## 3) AGENTS.md rules to add
1. **Lock fallback rule**: When implementing file locking with fallback, enumerate: (a) lock held by another process, (b) lock mechanism unavailable. Only fall back for (b), fail for (a).

2. **Cache update completeness rule**: When a value causes "skip cache update", verify no stale entry remains. Write sentinel value to invalidate, don't skip entirely.

3. **Failure mode review trigger**: For any code touching: caching, file locking, state machines, or aggregation/merge - run /failure-mode-review before marking complete.
