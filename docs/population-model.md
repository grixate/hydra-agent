# Deterministic Population Model

Epic 4 turns one immutable Simulation Version and its active Context Pack into
a compact, inspectable Population Model. It does not ask a model to write one
biography per agent. A deterministic compiler instantiates the requested
population from bounded distributions only when execution or inspection needs
the structured state.

## Durable contract

Every new Simulation is created atomically with Population Model v1. Each model
belongs to one workspace, Simulation, immutable Simulation Version, and exact
Context Pack. It records:

- agent types, weights, declared attributes, resources, actions, and grounding;
- archetypes, weights, distributions, goals, constraints, initial state,
  resources, policy references, memory seeds, and grounding;
- conditional distributions;
- relationship-generation and representative-selection rules;
- optional pseudonymized imported agents and relationship edges;
- compile and import summaries, compiler identity, seed, status, and semantic
  content hash.

`simulation_population_models` is append-only. PostgreSQL triggers enforce
workspace and lineage scope, authorized authorship, immutability, and an active
model that belongs to the Simulation's active Version and Context Pack. A
Context Pack change creates and activates a new Population Model in the same
transaction. Generated and row-imported models rebuild from the deterministic
fallback contract. A user-authored JSON Population Model retains its custom
contract, revalidates grounding against the new Pack, recompiles, and becomes a
new immutable version rather than being silently replaced.

An explicit rebuild against unchanged Context is idempotent. This is especially
important for imported JSON contracts: the action revalidates the custom model
and returns its existing version when semantic content is unchanged. Resetting
to Hydra's generated fallback would require a separate explicit product action;
it is never inferred from a generic rebuild.

The authoritative model remains compact. It stores definitions and imported
structured rows, not all generated agents or biography text. The compile
summary stores exact counts, stable hashes, and at most 32 structured
representatives.

## Compiler behavior

The compiler uses hash-derived random positions and never mutates a process-
global random-number generator. The same Population Model, compiler version,
population size, and seed produce the same:

- exact type and archetype counts by deterministic largest-remainder
  apportionment;
- attribute and resource values;
- conditions and state;
- relationship graph;
- representative set;
- agent-set and relationship hashes.

V1 supports only constant, categorical, uniform, bounded normal, beta, integer
range, and weighted-list distributions. It rejects arbitrary probability
programs. Correlation comes from archetype membership and bounded conditional
distributions.

Relationship rules support `none`, `random`, `small_world`, `hierarchical`,
`bipartite`, and `imported`. Validation estimates generated edge count before
compilation and rejects rules that would exceed 500,000 generated edges. This
prevents a valid-looking high-degree model from causing an unbounded memory
spike. Imported edges are separately capped at 100,000.

The provider-free builder defines a 10,000-agent model with zero model calls.
It is the safe default and failure fallback. A later model-assisted builder may
improve the contract in one call or a small bounded set, but it must return the
same schema, pass the semantic validator, and compile deterministically.

## Representative projections

Representatives are selected deterministically per archetype, by influence,
and as bounded outliers. Their structured cards contain traits, goals,
constraints, state, resources, important relationships, and Context grounding.
The compiler removes declared sensitive attributes from representative state.

Readable prose is not created for the population. It is materialized only when
an authorized researcher requests a representative card. The immutable
`simulation_persona_projections` row records the structured projection,
generator, lazy-generation flag, prose, and content hash. The interface labels
the result as a readable projection, not authoritative state or a biography of
a real person.

## Imports

The import boundary accepts:

- CSV or JSON agents;
- a complete JSON Population Model;
- CSV or JSON relationship edge lists.

CSV mapping supports agent ID, type, archetype, attributes, resources, initial
state, relationship source and target, relationship type, weight, and
direction. JSON Population Models are schema- and semantics-validated before
persistence.

Files are UTF-8, at most 5 MB, at most 100 columns, and have bounded cell size.
Agent files are capped at 10,000 rows and relationship files at 100,000 rows.
Overflow is rejected rather than silently truncated. Valid rows continue when
other rows fail. Error records contain row, field, stable code, and safe copy;
they never include the rejected value.

External agent IDs are converted to stable SHA-256-derived pseudonyms at the
import boundary. A later relationship file produces the same pseudonym, so
edges still join correctly without persisting or displaying the source ID.
Compilation creates separate runtime IDs and retains only another one-way
source fingerprint.

## Sensitive-attribute boundary

The default builder never infers protected or sensitive traits to manufacture
variety. CSV and JSON agent-row imports reject sensitive attribute names because
they cannot carry the required governance contract. A complete Population
Model may declare a sensitive attribute only when it records all of the
following:

- the value is observed and supplied, not inferred;
- a specific necessity explanation;
- a lawful basis;
- aggregate-only use;
- no individual exposure.

The Population inspector exposes this rationale next to the attribute. Users
can remove any non-final attribute; Hydra strips its definitions, conditional
rules, and imported values, recompiles, and activates a new immutable model
version. Individual consequential recommendations are rejected at semantic
validation.

Audit exports include Population and projection lineage, safe definitions,
counts, hashes, compiler metadata, and fingerprints. They do not include raw
imported values, source agent IDs, representative structured values, or Persona
prose.

## Product interface

`GET /simulations/:id/population` is the English/Russian Population inspector.
It presents exact counts before prose, then types, attributes, archetypes,
grounding, topology, structured representatives, and import state. Mutation
controls are available only to researchers; viewers receive the same
inspectable contract without build, import, attribute-removal, or prose-
generation actions.

The page deliberately avoids false precision and demographic theater. Numeric
representative values are rendered as qualitative levels, raw IDs are absent,
import failures use corrective copy, and advanced mapping stays in a collapsed
disclosure until requested.

## Release boundary

Epic 4 proves the local deterministic compiler, persistence, safety, import,
authorization, audit, and responsive interface contracts. It does not yet make
a Simulation runnable. Epic 5 must produce a valid declarative Simulation
Script and pass a bounded preview before the Run gate can open.
