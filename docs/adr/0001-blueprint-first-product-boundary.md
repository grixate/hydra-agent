# ADR 0001: Blueprint-first product boundary

- Status: Accepted
- Date: 2026-07-18
- Governing specification: `Hydra_Simulations_Blueprint_First_Development_Spec_2026-07-18.md`

## Context

The repository already contains two substantial layers:

1. a neutral Phoenix/OTP agent runtime with workspaces, providers, policies,
   durable runs, usage, budgets, tools, memory, knowledge, jobs, audit, and
   operations surfaces;
2. a Decision Replay-oriented `HydraAgent.SimLab` product layer with studies,
   sources, evidence, Context Packs, personas, action patterns, scenarios,
   deterministic aggregate simulations, snapshots, forecasts, calibrations,
   research workers, and an Observatory.

The Blueprint-first specification expands the product into a general-purpose
simulation studio. It explicitly forbids a second simulation platform and a
destructive rewrite of existing records.

## Decision

Hydra will implement Blueprint Studio as an additive product boundary over the
existing runtime and SimLab assets.

- The normal product is **Hydra Simulations** with the visible loop
  **Describe -> Build -> Run -> Explore**.
- `Blueprint` and immutable `Blueprint Version` are new domain objects because
  no current schema represents reusable simulation-building instructions,
  schemas, examples, compatibility, and defaults.
- The future general simulation domain will live under
  `HydraAgent.Simulations`. It may call existing `HydraAgent.SimLab` functions
  through explicit adapters while migration is in progress.
- Existing `sim_lab_*` tables are preserved. Stable tables are not renamed for
  presentation terminology.
- Existing studies map to legacy Simulations; personas and action patterns map
  to legacy archetypes and policies; scenarios map to legacy event scripts;
  forecasts and calibrations map to legacy reports and observed outcomes.
- The deterministic five-persona/twenty-rule compiler remains an emergency
  fallback behind the new population and policy contracts. It is not a new
  universal product constraint.
- Runtime workspaces, provider adapters, usage records, policy enforcement,
  authentication, audit, Oban, PubSub, health, metrics, backup, and operator
  controls are reused.
- A compiled Simulation Pack is immutable and references versioned inputs.
  Generative build stages must have structured contracts, validation, bounded
  retries, provenance, and deterministic fallback or recoverable failure.
- Simulation actions remain side-effect free in V1. Runtime tools and external
  actions are not callable from the declarative Simulation Script.
- Product-surface selection is runtime configuration only. It cannot mutate or
  convert data. Legacy routes remain available while migration flags allow it.

## Migration shape

1. Add Blueprint and Blueprint Version persistence, package validation, and
   built-ins.
2. Add the simple Studio shell and one-question persisted Simulation adapter.
3. Introduce immutable build artifacts only where existing schemas cannot
   express the required contract.
4. Reuse existing evidence, jobs, provider, usage, and deterministic simulation
   code behind new interfaces.
5. Keep legacy `/lab/*` routes until the new surface passes controlled-pilot
   gates and an explicit retirement migration is approved.

## Consequences

### Positive

- Current customer and operator data remains intact.
- Proven runtime, security, and deterministic-engine behavior is reused.
- Blueprint and Pack portability can be tested independently of advanced UI.
- Product language can change without risky table renames.
- Feature flags permit reversible rollout from the same release artifact.

### Costs and constraints

- Domain adapters will temporarily bridge general terms and `sim_lab_*`
  storage.
- Two run concepts currently exist: neutral runtime runs and SimLab simulation
  runs. The general simulation execution adapter must define their relationship
  explicitly before adding another run table.
- The current Decision Replay UI is not the target information architecture.
  It remains a legacy surface, not a source for duplicating product logic.
- Migration completion requires explicit compatibility tests, not only route
  redirects or presentation renames.

## Rejected alternatives

- **Build a new application or service:** rejects the verified runtime and
  violates the one-codebase directive.
- **Rename or rewrite all `sim_lab_*` tables immediately:** creates avoidable
  migration risk and no user value.
- **Keep Decision Replay as the universal model:** cannot represent the locked
  general simulation contract.
- **Make Blueprints raw YAML-only:** violates the shallow normal experience and
  four-card editor requirement.
