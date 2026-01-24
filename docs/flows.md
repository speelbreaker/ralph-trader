# Flow Audit Workflow

How you use it

1) List flows
```sh
python3 scripts/extract_contract_excerpts.py --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --list-flows
```

2) Create a bundle for a flow (recommended)
```sh
python3 scripts/extract_contract_excerpts.py \
  --contract specs/CONTRACT.md \
  --flows specs/flows/ARCH_FLOWS.yaml \
  --flow-id ACF-003 \
  --bundle \
  --out bundle_ACF-003.md \
  --line-numbers
```

3) Extract excerpts for a flow (excerpt-only)
```sh
python3 scripts/extract_contract_excerpts.py \
  --contract specs/CONTRACT.md \
  --flows specs/flows/ARCH_FLOWS.yaml \
  --flow-id ACF-003 \
  --out excerpts_ACF-003.md \
  --line-numbers
```

4) Print the flow block (so you can paste it into the audit prompt)
```sh
python3 scripts/extract_contract_excerpts.py \
  --flows specs/flows/ARCH_FLOWS.yaml \
  --flow-id ACF-003 \
  --emit-flow-spec
```

Your new "one-flow audit packet" routine

For any flow:

- --emit-flow-spec -> copy FLOW_SPEC
- --flow-id ... --line-numbers -> copy CONTRACT_EXCERPTS

Paste both into the Flow Completeness Audit prompt.

That eliminates the manual scavenger hunt entirely.

One rule to make this work

specs/flows/ARCH_FLOWS.yaml must list complete section coverage for each flow, for example:

```yaml
refs:
  sections: ["2.2", "2.2.3", "Definitions", "Appendix A"]
```

If refs.sections is incomplete, audits will miss dependencies and report false gaps.
