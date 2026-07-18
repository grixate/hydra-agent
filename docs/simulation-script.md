# Declarative Simulation Script

Epic 5 turns the exact immutable Simulation Version, Context Pack, and
Population Model into an inspectable execution contract. The Script describes
what the simulation may do. It is data, never Elixir, JavaScript, shell, a
template language, or a runtime tool request.

## Durable lineage

Every Script belongs to one workspace, Simulation, Simulation Version, Context
Pack, Population Model, and author. It records its schema and compiler versions,
the complete canonical Script, semantic validation report, bounded generation
metadata, status, and content hash.

`simulation_scripts` is append-only. PostgreSQL triggers reject cross-workspace
or cross-Simulation references, mismatched Version/Context/Population lineage,
unauthorized authors, mutation, and activation against anything other than the
Simulation's exact active inputs. An unchanged rebuild is content-addressed and
returns the active artifact. Changed upstream inputs produce and activate a new
immutable Script in the same transaction as the new Context or Population.

The separate `simulation_script_previews` table records the result of the exact
Script and Population pair: status, requested and completed rounds, bounded
agent count, seed, safe summary, safe errors, and result hash. Preview history
is immutable and audit-visible.

## V1 contract

A valid Script has every one of these top-level sections:

1. metadata;
2. clock;
3. world;
4. agent types;
5. relationships;
6. resources;
7. scheduled events;
8. actions;
9. perception;
10. policies;
11. transitions;
12. observations;
13. stopping conditions.

The clock is discrete and bounded. Actions declare eligible actor types,
preconditions, costs, effects, and emitted events. Perception lists bounded
world, self, relationship, and recent-event views. Policies are fixed,
weighted, ordered rule sets, or a separately budgeted hybrid with a declared
deterministic fallback.

Conditions and numeric expressions are typed abstract syntax trees with depth,
node, and arity limits. Effects come from a closed operation allowlist. State,
attribute, world, resource, relationship, action, policy, perception, agent-
type, and event references must point to declared values. Semantic validation
also rejects impossible resource balances, unreachable actions, oversized
contracts, unbounded relationship targets, event-emission cycles, and hybrid
cognition without a model budget.

There is no arbitrary expression evaluation, dynamic module lookup, tool call,
HTTP request, filesystem operation, process spawn, or side effect in the Script
boundary.

## Generation and repair

The production-safe path is a deterministic provider-free builder. It derives
agent types, actions, resources, relationship views, and observations from the
active Population Model, and derives the bounded round count from the
Simulation horizon. It records zero model calls.

A future model-assisted builder may propose the same typed contract. Validation
may invoke one bounded repair callback at most once. The repaired contract must
pass the same semantic validator. If it does not, the result remains failed;
Hydra never loops repairs or silently executes the invalid proposal. The
deterministic builder remains the provider-independent fallback.

## Miniature preview

Every generated Script is checked with a deterministic, side-effect-free
preview before it can contribute to a runnable Pack. The preview uses at most
12 structured representatives, exactly the Population Model seed, and at most
two rounds. It applies scheduled events, decision policies, action costs,
effects, transitions, and observations through closed interpreter functions.

The preview makes zero model calls and no external calls. A failure stores a
stable safe error code and corrective product copy. It does not expose raw
agent state or exception text. A failed preview activates an inspectable
blocked Script so the problem can be diagnosed, but later Pack compilation and
full execution must fail closed.

## Interface and portability

`GET /simulations/:id/script` is the English/Russian Script inspector. It leads
with the validation and preview outcome, then explains the clock, shared state,
choices, bounded resources, scheduled timeline, policies, and recorded outputs
in product language. Technical lineage is collapsed. Researchers can request
an idempotent rebuild; viewers can inspect and export but cannot mutate.

The exact canonical Script is downloadable as deterministic pretty JSON or
readable YAML:

- `GET /simulations/:id/script/export/json`
- `GET /simulations/:id/script/export/yaml`

Exports contain no provider credentials or hidden executable payload. Workspace
audit exports include exact lineage, safe counts, validation and generation
metadata, and a Script fingerprint rather than the full potentially sensitive
world contract. Preview exports include safe summaries and errors.

## Release boundary

Epic 5 proves Script persistence, schema and semantic validation, bounded
repair, deterministic preview, authorization, audit, portability, and the
responsive inspector. A passed preview does not by itself make a Simulation
runnable. Later epics must compile the exact Context, Population, Script,
Observation, Budget, and Model Route artifacts into an immutable Simulation
Pack before the Run control can unlock.
