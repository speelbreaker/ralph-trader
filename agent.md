# CLAUDE.md — Stoic Trader Project Harness (High‑Signal)

**Purpose:** Make work **verifiable**, **safe**, and **repeatable**.  
**Compounding rule:** if Claude (or a human) causes the same failure twice → add **one** prevention rule to **POLICY.md → Prevention Rules**.

---

## Stoplight: when to proceed vs stop

### 🔴 RED (STOP and ask)
Anything that changes **hot path execution/risk**, **TradingMode precedence**, **WAL/idempotency semantics**, or **gate thresholds**.

### 🟡 YELLOW (proceed, but MUST verify)
CI fixes, formatting/lint, tests, docs, tooling, cold-loop Python changes.

### 🟢 GREEN (proceed)
Pure docs, comments, refactors outside hot path, non-behavioral cleanup.

---

## Session start (every time)
```bash
./plans/init.sh
tail -n 50 plans/progress.txt
git log --oneline -20
./plans/verify.sh
```

**Hard rule:** if `verify.sh` fails → **fix verification first**. Do not start new work.

---

## Definition of Done (DoD)
Before marking a PRD item `passes=true`:

1) All verification gates pass (`./plans/verify.sh`)  
2) Work is scoped to **one PRD item** (minimal diff)  
3) Progress is updated (append‑only): `plans/progress.txt`  
4) If you added/changed an HTTP endpoint → you added an **endpoint‑level test** (see below)

---

## Verification gates (what “verify” means)
Preferred: `./plans/verify.sh` (runs everything below).  
Manual equivalents:

| Gate | Command | Pass criteria |
|---|---|---|
| Rust build | `cargo build --release` | exit 0 |
| Rust lint | `cargo clippy -- -D warnings` | no warnings |
| Rust tests | `cargo test` | all pass |
| Python | `pytest -q && python -m compileall .` | all pass |
| Evidence | `python scripts/check_vq_evidence.py` | exit 0 |
| F1 cert | `python scripts/check_f1_cert.py` | exit 0 (PASS + age < 24h) |

---

## New endpoint rule (HARD)
Any new HTTP endpoint → MUST add an **endpoint‑level test immediately** (same PR).  
No test → endpoint rejected.

---

## Repo map (where things live)
- `crates/` — Rust execution + risk (**HOT PATH**; touch carefully)  
  - `soldier/core/` — trading loop, gates, execution  
  - `infra/` — Deribit API, WAL, rate limiter  
- `python/` — policy + tools (**COLD LOOP**; safer to modify)  
  - `governor/` — replay gatekeeper, canary rollout  
  - `reviewer/` — auto-review, incidents  
- `specs/` — contract/specs (source of truth)  
- `plans/` — agent harness (PRD, progress, verify)  
- `artifacts/` — evidence + certs (**CRITICAL; never delete**)  
  - `F1_CERT.json` — release gate

---

## Guardrails (short list)
- Fail closed: **no evidence → no opens**.
- Never bypass WAL write‑before‑send.
- Don’t weaken gates, thresholds, or staleness rules.
- Don’t delete tests to “make CI green.”

Full policy + gates live in **POLICY.md**.

---

## How to change rules safely
If a change touches anything in 🔴 RED:
1) Patch the relevant spec/contract file first (Spec‑Driven)  
2) Add/adjust tests and gates  
3) Only then implement code changes

