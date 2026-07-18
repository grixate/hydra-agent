# Quick engine

Hydra's Quick engine is the deterministic, provider-free execution path for a
validated Blueprint Studio Simulation. It interprets the active declarative
Script over the full compiled Population and persists every committed round.

## Execution contract

A run can start only when the Simulation has matching ready artifacts for its
active Version, Context Pack, Population Model, Script, and passed preview. Run
creation captures those exact IDs, the Population seed, the engine version, and
a content-derived Pack hash. The lineage is immutable.

Quick mode has a hard model-call count of zero. There is no provider route,
credential lookup, tool call, or external side effect in the round executor.

Each active run owns a supervised coordinator, a fixed number of state
partitions, and one Resource Ledger. Agents remain compact maps in partitions;
Hydra does not create one process per agent.

## Ordered rounds

The engine evaluates phases in a fixed order:

1. scheduled events before actions;
2. deterministic agent actions;
3. scheduled events after actions;
4. transitions;
5. observations;
6. snapshot.

Agent, action, event, transition, and transaction merges use stable keys.
Weighted decisions use a hash-derived unit value from Pack seed, round, agent,
and policy—not VM randomness. Simulation events receive contiguous per-run
sequence numbers and content-derived idempotency keys.

Bounded relationship-neighbor targets are resolved in stable relationship-ID
order. Relationship effects update weights in the closed `0..1` domain, and
`event.relationship_weight` is supplied to typed transition expressions.
Transition payload filters are exact subset matches. The engine retains every
current-round event for transition evaluation while exposing only a bounded
recent-event view to agent perception and snapshots.

The database commits one round atomically: ordered events, Resource Ledger
transactions, a checksummed full snapshot, simulation progress, and neutral run
state either all advance or none do.

## Resource Ledger

Resources declare precision, minimum and maximum bounds, negative-balance
policy, and whether mint and burn operations are allowed. The ledger uses
`Decimal`; it rounds the transferred amount once to the declared precision
before applying both sides, preserving transfer conservation.

The supported operations are `mint`, `burn`, `transfer`, `reserve`, `release`,
`consume`, `replenish`, and `adjust`. Batches are stable and atomic in memory.
Replayed idempotency keys do not mutate balances twice. Persisted transactions
include source, destination, amount, phase, source reference, tags, and resulting
balances.

## Recovery and terminal outcomes

An initial round-zero snapshot and one snapshot per committed round contain the
full authoritative state, ledger balances, event sequence, schema version,
engine version, state hash, and payload checksum. Recovery rejects incompatible
or corrupted snapshots. It verifies exact run scope, engine version, Pack hash,
seed, round, event sequence, checksum, and authoritative state hash before any
state is restored, then records a visible recovery event before continuing.

The final result hash covers world and agent state, complete resource balances,
relationship state, action counts, and observations. Resource accounts that do
not belong to an agent therefore cannot disappear from replay verification.

Completion, failure, and operator cancellation write terminal status under a
database lock. A terminal fence prevents a worker, retry, or restarted process
from advancing the run again. Cancellation preserves the last fully committed
round.

## Benchmark

Run the durable local acceptance benchmark with:

```sh
mix run priv/benchmarks/quick_engine_10k.exs
```

It temporarily pauses only the simulation queue, creates an isolated workspace,
executes three real 10,000-agent × 20-round runs, and removes all benchmark
records afterward. It measures database-backed execution, event and snapshot
writes, whole-application BEAM memory, and exact replay hashes.

The 18 July 2026 local record is in
`docs/benchmarks/2026-07-18-blueprint-quick-engine-10k.json`: all three result
and final-state hashes matched, durations were 30.874–34.451 seconds, peak
whole-application memory was 1,138,431,469 bytes, and simulation model calls
were zero. The maximum is an initial observed p95 proxy, not a public
performance claim; hosted-environment qualification remains a release gate.
