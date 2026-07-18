# Balanced cognition operations

Balanced mode adds selective model judgment to the deterministic Simulation
Script engine. It does not create one process or one model call per agent.

## Execution contract

For each round Hydra:

1. restores the last verified snapshot and checks for interrupted provider
   reservations;
2. groups hybrid-policy agents by a versioned policy signature;
3. reuses an eligible within-run signature decision when available;
4. ranks remaining groups by novelty, uncertainty, influence, downstream
   impact, deterministic disagreement, user importance, representative
   sampling, and cache miss;
5. reserves the maximum request envelope before dispatching selected calls;
6. validates the exact decision JSON contract;
7. saves the immutable decision and affected-agent mappings; and
8. lets the deterministic engine apply only declared actions and typed effects.

The provider response contract is:

```json
{
  "action_id": "declared_action",
  "parameters": {},
  "reason_codes": ["bounded_reason"],
  "short_rationale": "A short operator-readable rationale.",
  "memory_updates": {},
  "uncertainty": 0.25
}
```

Unknown keys, undeclared actions, malformed values, oversized maps, and invalid
uncertainty are rejected. Raw credentials are never stored in a decision.

## Failure and accounting behavior

- A request is reserved before provider work.
- Valid usage closes the reservation with actual tokens and price.
- Once dispatch may have occurred, missing or malformed usage closes against
  the reserved envelope. It is never released as if the call were free.
- A request known not to have been dispatched may be released.
- Budget rejection is retained as an audited fallback.
- A run can finish deterministically after all model capacity is exhausted.

Operators should investigate non-zero fallback counts, repeated invalid-output
reasons, or active reservations after a terminal run. A terminal Balanced run
should have only completed, released, or rejected reservations.

## Replay choices

`Replay exactly` uses the same Pack, seed, engine, ordering, and recorded
decisions. It makes zero new provider calls and should match the source result
and decision-manifest hashes.

`Run again` is a fresh rerun. It uses the current active Pack, increments the
seed by default, and permits new provider decisions under the current immutable
Budget and Model Route Plans. It is intentionally labeled as a different run.

## Capacity evidence

The repository acceptance test executes 5,000 agents for 12 rounds with a
deterministic structured mock provider. It asserts the 80-call Simulation cap,
the two-decisions-per-agent limit, multi-agent signature reuse, terminal usage,
and the 60-second engine-overhead target. Real-provider latency, output quality,
pricing, and rate-limit behavior remain staging qualifications rather than
claims derived from the mock.
