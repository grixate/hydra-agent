# Budget Governor and model routing

The Budget Governor is Blueprint Studio's fail-closed authorization boundary
for retrieval and provider work. It is separate from the simulated Resource
Ledger and complements, rather than replaces, Hydra's neutral workspace budgets
and usage records.

## Immutable configuration

A Simulation Version has public, content-addressed model-route and budget
configurations. A Run captures their IDs and snapshots. Changing a route creates
a new configuration for the next Run and is blocked while a Run is active.

The three route roles are:

| Role | Purpose | Quick default |
|---|---|---|
| Build | Structured Context, Population, and Script assistance | Automatic |
| Simulation | Selective model decisions during rounds | Disabled |
| Report | Narrative generation from an Analysis Pack | Automatic |

Automatic routing includes only enabled providers with the required capability
and usable credential posture. Local `mock` and `ollama` routes require no
cloud credential. Public route snapshots omit secret and credential references.

## Presets

| Preset | Retrievals | Build calls | Simulation decisions | Report calls | Runtime | Concurrency |
|---|---:|---:|---:|---:|---:|---:|
| Quick | 8 | 4 | 0 | 1 | 15 min | 4 |
| Balanced | 12 | 6 | 80 | 2 | 15 min | 8 |
| Deep | 20 | 10 | 186 | 4 | 30 min | 8 |

Whole-plan input, output, model-call, retrieval, runtime, concurrency, and
per-stage limits are hard constraints. The defaults are deliberately
conservative and may evolve only through a new immutable plan.

## Price snapshots

`simulation_price_entries` stores provider, model, currency, input, cached
input, output, request minimum, effective date, override status, and safe
metadata. Entries are immutable; a workspace override wins over a global row.

Plan construction captures applicable rows. A hard monetary maximum is emitted
only when every cost-bearing stage has known, compatible pricing. When pricing
is absent or currencies cannot be combined, the interface says price is
unavailable and continues to enforce all non-monetary caps. Local and disabled
routes are priced at zero, but this does not make an unknown retrieval or remote
route free.

## Reservation lifecycle

Before work begins, the caller supplies:

- stage and operation kind;
- exact provider and model where applicable;
- maximum input and output tokens;
- elapsed runtime;
- a stable SHA-256 idempotency key;
- optional Run scope and safe metadata.

Under a database lock, the Governor checks whole-plan and stage limits. It then
returns one of:

- a durable `reserved` record, authorizing the bounded operation;
- a durable `rejected` record plus a safe error;
- a durable `rejected` record with an explicitly selected fallback.

Provider completion must report valid non-negative token usage. Known-price
routes derive actual cost from the captured price unless a valid provider cost
is supplied. Usage or cost beyond the reservation is rejected and the maximum
reservation stays charged. A failed operation is released with its actual
fallback, returning unused capacity.

The first production integration wraps every automatic Context research lane
and direct public-source fetch. Retry attempts use distinct deterministic keys;
an exhausted lane becomes a visible partial result rather than corrupting the
Context Pack.

## Fallback order

Plans capture this deterministic order:

1. deterministic rule;
2. exact cache;
3. policy-signature cache;
4. representative decision;
5. cheaper or local model;
6. conservative action;
7. stop the model lane.

Epic 7 records the selected budget fallback. Balanced execution adds the cache,
representative, and decision-provenance implementations.

## Product behavior

Before a Run, the Run screen shows an honest cost estimate or unavailable
state, the hard provider maximum, model-call and retrieval caps, expected
runtime, the current routes, population, rounds, and deterministic-completion
posture. During and after a Run it adds provider use and remaining cap, model
decisions made and left, fallbacks, and current stage.

The interface intentionally omits reservation IDs, ledger terminology,
credential names, worker names, and queue state. Technical plan and route
snapshots remain available in the immutable Run record for audit.

## Verification

The focused suite exercises exact monetary caps, unknown prices, incompatible
currencies, malformed envelopes, missing credentials, every cap category,
concurrent final-slot reservations, explicit downgrade, provider overrun,
release of unused capacity, research integration, route locking, and historical
price snapshots. The release gate remains `mix precommit`.
