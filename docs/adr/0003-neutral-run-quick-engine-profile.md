# ADR 0003: Neutral Run profile for deterministic simulation execution

- Status: Accepted
- Date: 2026-07-18
- Governing specification: `Hydra_Simulations_Blueprint_First_Development_Spec_2026-07-18.md`

## Context

Hydra already has a neutral workspace-scoped `runs` model and append-oriented
`run_events`. Legacy SimLab also has a domain-specific run model. Adding a third
general run identity for Blueprint Studio would split lifecycle, audit,
authorization, and operations behavior. Reusing the legacy model would couple
the neutral runtime to Decision Replay terminology and aggregate-only state.

The general Quick engine also needs exact immutable simulation lineage, a
deterministic seed, engine metadata, ordered phases, recovery snapshots, and an
authoritative resource ledger. Those fields do not belong on every neutral run.

## Decision

The neutral `runs` row is the execution identity and source of lifecycle truth.
Each Blueprint Studio execution has exactly one `simulation_run_records` profile
that references its exact Simulation Version, Context Pack, Population Model,
and Simulation Script. The profile records the seed, deterministic Pack hash,
engine version, progress, replay hashes, recovery count, and a hard zero model-
call count for Quick mode.

The existing `run_events` stream is extended with optional simulation ordering
and provenance fields. Simulation events require a positive per-run sequence,
round, phase, and idempotency key. Neutral non-simulation events remain
compatible.

`run_snapshots` and `resource_transactions` are append-only run-owned records.
Snapshots carry content and state hashes plus a checksum. Resource transactions
use decimal amounts, stable idempotency keys, provenance, resulting balances,
and a closed operation allowlist. Run lineage cannot change after creation.

Quick execution uses one dynamically supervised tree per active run: one
coordinator, four configurable state partitions, and one authoritative Resource
Ledger. Agent instances are compact data, never permanent processes. Each round
is committed in one database transaction; events, resource transactions,
snapshot, progress, and neutral run state advance together. A failed,
completed, or canceled status is a terminal fence.

Quick mode never invokes a provider. Process or node failure resumes from the
latest verified snapshot through supervised restart and durable Oban retry.
Legacy SimLab run records remain unchanged compatibility records.

## Consequences

### Positive

- One execution identity powers authorization, operations, audit, and product
  status across the neutral runtime.
- Exact simulation lineage is inspectable without polluting every run schema.
- Deterministic replay has explicit seed, Pack, engine, state, and result hashes.
- Recovery never relies on hidden in-memory orchestration.
- Resource supply changes and transfers are explicit, decimal, and retry-safe.

### Costs and constraints

- Consumers must join the simulation profile when they need simulation-specific
  progress or lineage.
- Full snapshots trade storage for simple, exact recovery; retention and codec
  evolution need an explicit later policy.
- Quick mode is intentionally deterministic. Model-assisted cognition belongs
  to a separately budgeted Balanced contract, not this engine.

## Rejected alternatives

- **Add another general run table:** duplicates neutral lifecycle and audit.
- **Promote legacy SimLab runs:** leaks Decision Replay assumptions into the
  runtime core.
- **Keep the event stream in memory:** loses inspectability and crash recovery.
- **One process per agent:** makes the 10,000-agent baseline operationally
  wasteful without adding semantic value.
- **Floating-point resource balances:** cannot provide authoritative accounting
  or predictable retry behavior.
