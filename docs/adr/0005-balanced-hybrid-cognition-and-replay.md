# ADR 0005: Balanced hybrid cognition and recorded-decision replay

- Status: Accepted
- Date: 2026-07-18

## Context

Quick execution is deliberately provider-free, but some simulations benefit
from model judgment where deterministic rules are uncertain or materially
disagree. Calling a model for every agent would make outcomes expensive,
unbounded, difficult to reproduce, and hard to inspect. Retrying a round after
a provider response also creates a duplicate-call risk unless the decision is
durable before the round is committed.

## Decision

Balanced mode is an orchestration layer around the deterministic Script
engine, not a second mutable simulator.

- Script agent types use a validated `hybrid` policy with declared candidate
  actions and a deterministic fallback policy.
- Agents are grouped by a stable, versioned policy signature. The signature
  includes type, archetype, bucketed relevant state, recent event types,
  allowed actions, relationship class, Script hash, and route version.
- A scored, bounded set of signatures is eligible for a model decision. Hard
  whole-plan, Simulation-stage, per-round, per-type, per-agent, runtime, token,
  cost, and concurrency limits remain authoritative.
- Provider output must match the exact six-field decision contract and select
  a declared action. Invalid output, provider failure, timeout, missing route,
  or exhausted budget records and applies a deterministic safe action.
- Decisions and affected-agent mappings are append-only, workspace-scoped, and
  written before the corresponding round snapshot. A retry reuses recorded
  decisions; interrupted reservations are closed conservatively and cannot
  silently disappear from usage.
- Exact replay copies recorded decisions and uses no provider. It requires the
  same Pack, seed, engine, configuration, and completed source run. Fresh rerun
  uses the current Pack with a new seed and new decision lane.
- The replay manifest hashes only applied decision content and agent mappings,
  so an exact replay has the same manifest and authoritative result even though
  its execution accounting correctly records zero new provider calls.

## Consequences

Balanced outcomes remain bounded and inspectable, and routine behavior retains
the deterministic engine's recovery semantics. Signature reuse lets one model
decision cover many agents without pretending those agents are independent
respondents. Exact replay is reproducible without credentials or a live
provider.

The append-only mapping table can be large because traceability is explicit.
Writes are batched and reads use aggregate queries, but hosted retention and
compression still require qualification. A provider request cannot be made
transactionally atomic with an external service; Hydra therefore favors
at-most-one retry behavior and conservative reserved-envelope accounting after
an interrupted dispatch.
