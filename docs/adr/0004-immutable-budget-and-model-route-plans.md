# ADR 0004: Immutable budget and model-route plans

- Status: Accepted
- Date: 2026-07-18
- Governing specification: `Hydra_Simulations_Blueprint_First_Development_Spec_2026-07-18.md`

## Context

Blueprint Studio needs predictable provider use across research, Build,
simulation cognition, and Report generation. Hydra already has neutral runtime
budgets, usage records, provider configurations, credential pools, and provider
adapters. Those remain authoritative general-purpose primitives, but they do
not capture the exact prices, model routes, stage allocations, and fallback
policy used by one immutable Simulation configuration.

Execution spend is also distinct from the Script's simulated Resource Ledger.
Combining them would make a world-state transfer capable of affecting real
provider authorization, or make provider usage appear inside simulated results.

## Decision

Each Simulation Version receives an immutable `ModelRoutePlan` and
`BudgetPlan`. A route edit creates another immutable Run configuration for the
same Version; it never rewrites an existing plan or active Run. The Run record
captures both plan IDs, their public snapshots, and their content hashes. The
Quick Pack hash includes those configuration hashes.

Model routes are resolved separately for Build, Simulation, and Report.
Automatic routing uses enabled, capability-compatible, operationally configured
providers. Quick always disables the Simulation route. Route snapshots include
provider kind, model, capabilities, locality, and route version, but never a
secret value or credential reference.

Provider prices are immutable, effective-dated global or workspace entries.
Workspace entries win over global entries for the same provider and model.
The Budget Plan captures the applicable price rows and derives conservative
stage and whole-plan maxima. Local and disabled routes are zero-cost. Unknown
pricing, incomplete pricing, or incompatible currencies produce no monetary
hard-cap claim; token, call, retrieval, runtime, and concurrency caps still
apply.

Every cost-bearing operation reserves its maximum envelope through the Budget
Governor before it begins. The Governor locks the Budget Plan row, reads all
effective reservations, and either inserts one reservation or one audited
rejection in the same transaction. Completion records actual usage and releases
unused capacity. Invalid or over-envelope provider usage fails closed and keeps
the conservative reservation. Idempotency keys are unique per plan.

The fallback policy is ordered and persisted. An exhausted operation may
explicitly choose a recorded deterministic fallback instead of failing the
entire Simulation. Ordinary rejection does not silently count as a fallback.

Existing neutral runtime budgets and usage records are not replaced. A
simulation reservation may reference the corresponding neutral usage record;
the immutable Budget Plan is the per-Simulation authorization envelope and
historical snapshot.

Interactive Codex CLI authentication is not treated as a server deployment
credential. It has a user-session lifecycle and no Hydra provider usage
contract. A separately implemented local adapter could use a CLI process as an
explicit local route, but it must provide bounded requests, health, provenance,
usage reporting, cancellation, and fail-closed policy enforcement before it can
participate in automatic routing.

## Consequences

### Positive

- Historical Runs retain the exact routes and prices that governed them.
- Concurrent requests cannot oversubscribe the same remaining cap.
- Unknown and mixed-currency pricing cannot become a fictional monetary limit.
- Quick research and future model-assisted stages share one inspectable
  authorization boundary.
- Local deployment remains useful without requiring cloud credentials.
- Provider failure or budget exhaustion can preserve deterministic execution.

### Costs and constraints

- Price changes append rows and affect only plans created afterward.
- Operators must keep provider capability and price metadata current.
- A provider call is not complete until valid usage is recorded; missing usage
  cannot be interpreted as zero.
- Budget Plan row locks intentionally serialize reservations for one plan.
- Balanced replay must record decisions in addition to the budget reservation;
  the Budget Governor alone is not a replay log.

## Rejected alternatives

- **Use only the neutral daily budget:** it cannot reproduce one Run's exact
  route, price, and stage allocation.
- **Check usage after a provider call:** a hard cap could already have been
  exceeded.
- **Store only current prices:** historical cost would change when pricing
  changes.
- **Assume an unknown route costs zero:** this creates a false monetary
  guarantee.
- **Treat a rejected call as an implicit fallback:** the product could claim a
  deterministic downgrade that never actually ran.
- **Use the world Resource Ledger:** it violates the boundary between real and
  simulated economies.
