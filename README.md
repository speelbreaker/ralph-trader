# ralph-trader

## Quickstart

1) Run one-time bootstrap to scaffold the harness:

```bash
./plans/bootstrap.sh
```

2) See `plans/README.md` for the harness workflow entrypoints.

## CI Note

- Contract coverage strictness is enabled in CI after promotion. Run `./plans/contract_coverage_promote.sh` once you’re ready to enforce it.
