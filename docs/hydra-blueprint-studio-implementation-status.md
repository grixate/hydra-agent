# Hydra Blueprint Studio implementation status

Last updated: 2026-07-18

Governing product loop: **Describe -> Build -> Run -> Explore**

This document is the running implementation ledger required by the Blueprint-
first development specification. A checked item means repository evidence was
inspected and the named acceptance criterion is covered; it does not mean the
entire epic or release is complete.

## Current status

- Active epic: **Epic 0 — Repository map and migration safety**
- Next vertical slice: Blueprint and immutable Blueprint Version domain
- Default product surface: `legacy_simlab`
- Destructive migrations: none
- Legacy route removal: none
- Controlled-pilot status: not ready under the new specification

## Feature flags

All flags are runtime configuration and do not mutate persisted records.

| Environment variable | Default | Purpose |
|---|---:|---|
| `HYDRA_PRODUCT_SURFACE` | `legacy_simlab` | Selects `legacy_simlab` or `blueprint_studio` once the Studio shell exists. |
| `HYDRA_BALANCED_MODE` | `true` | Enables bounded selective model cognition. The new execution contract is not implemented yet. |
| `HYDRA_DEEP_MODE` | `false` | Keeps experimental model-intensive execution disabled. |
| `HYDRA_BLUEPRINT_IMPORT` | `true` | Enables package import after the safe importer is implemented. |
| `HYDRA_LEGACY_SIMLAB` | `true` | Preserves the current product routes and records during migration. |

The flag contract is implemented by `HydraAgent.ProductFeatures`. Invalid
enumerated or boolean runtime values fail startup rather than silently changing
product behavior.

## Repository mapping

### Product and persistence objects

| Blueprint-first object | Existing authoritative asset | Reuse and migration decision |
|---|---|---|
| Workspace | `HydraAgent.Runtime.Workspace`, `workspaces` | Reuse as the tenant, knowledge, policy, and simulation boundary. |
| Blueprint | None | Add workspace/system-scoped schema and context. This is a justified new object. |
| Blueprint Version | Agent/skill versioning patterns only | Add immutable schema; reuse versioning conventions, validation, and audit patterns. |
| Simulation | `SimLab.Schemas.Study`, `sim_lab_studies` | Adapt legacy studies first. Add only fields/adapter state the general lifecycle cannot express. |
| Simulation Version | No equivalent | Add immutable snapshot linked to Simulation and Blueprint Version. Do not overwrite studies. |
| Context Pack | `sim_lab_context_packs`, sources, evidence items, research runs | Reuse evidence storage and review semantics; extend grounding classes and link to Simulation Version. |
| Population Model | Personas, action patterns, `BehaviorCompiler` | Introduce a general structured contract. Adapt personas/patterns as legacy archetypes/policies and keep deterministic fallback. |
| Agent Instance | Generated aggregate cohorts and representative traces | Add compact run-owned state, not permanent runtime agent profiles or one process per agent. |
| Representative Persona | `sim_lab_personas` | Reuse presentation and evidence links through an adapter. Do not treat persona count as population size. |
| Simulation Script | Scenario events, executable rules, `ScenarioCompiler` | Add a versioned declarative schema/compiler; translate legacy scenarios as a compatibility input. Never execute arbitrary code. |
| Observation Plan | Snapshot metrics, outcome events, forecast inputs | Add explicit immutable contract while reusing snapshot/outcome calculation code. |
| Budget Plan | Runtime `budgets`, `usage_records`, SimLab cost fields | Reuse accounting and authorization primitives; add per-Pack/run hard-cap allocation and price snapshot. |
| Model Route Plan | Provider configs, credential pools, agent model routes | Reuse provider-neutral adapters and credential references; add Build/Simulation/Report role plan. |
| Simulation Pack | No equivalent; SimLab run `input_snapshot` is closest | Add immutable compiled reference object only after component versions exist. |
| Preview Run | Existing deterministic runner can execute small runs | Add explicit bounded preview state and validation outcome. |
| Run | `sim_lab_runs` plus neutral runtime `runs` | Do not add a third run model. Define an execution adapter/link before schema changes. |
| Run Decision | Pattern decisions summarized; outcome events exist | Add only when Balanced cognition lands; preserve deterministic IDs and provenance. |
| Run Event | Runtime `run_events`, `sim_lab_outcome_events` | Reuse and normalize into a simulation event stream; avoid duplicate append-only logs. |
| Run Snapshot | `sim_lab_snapshots` | Reuse payload/versioning path; add checksum/codec fields if needed. |
| Resource Transaction | None | Add immutable, workspace/run-scoped generic ledger in Quick-engine epic. |
| Analysis Pack | Forecast inputs and `Forecast` calculations | Add deterministic versioned artifact; report generation must consume it rather than raw mutable state. |
| Report | `sim_lab_forecast_reports` | Adapt as legacy reports; add Blueprint/model/language/validation metadata. |
| Calibration | `sim_lab_calibration_records` | Reuse as observed-outcome links without rewriting original predictions. |

### Contexts, workers, and events

| Requirement | Existing code | Planned reuse |
|---|---|---|
| Durable build jobs | Oban and SimLab research/simulation workers | Add version-keyed build-stage workers to current Oban queues. |
| Question interpretation | `StudyParser` | Generalize into a structured contract with schema validation. |
| Bounded research | research planner, safe query abstraction, Tavily/configured provider, evidence pipeline | Reuse provider and safety boundary; extend grounding vocabulary. |
| Population fallback | `BehaviorCompiler` | Preserve behind new interface as explicit emergency fallback. |
| Deterministic execution | `SimulationRunner`, `Simulator`, persisted input fingerprint | Reuse mechanisms after the general Script compiler defines stable semantics. |
| Live progress | Phoenix PubSub and SimLab notifications | Add product-stage events without exposing queue or worker names. |
| Cost and usage | `Usage`, `Budgets`, provider usage ledger | Route every generative stage and Balanced decision through the new Budget Governor. |
| Audit | runtime audit export and safety events | Extend exports with Blueprints, versions, Packs, decisions, resources, analyses, and reports. |

### Route migration

| Target route | Current mapping | Migration state |
|---|---|---|
| `/simulations` | `/lab/studies` and workspace study index | New route pending Studio shell. Legacy routes preserved. |
| `/simulations/new` | study creation on workspace index | New one-question composer pending. |
| `/simulations/:id/*` | one large workspace-study controller/template | Split by deep-linkable stage without duplicating domain logic. |
| `/blueprints/*` | none | New routes after Blueprint context and import safety exist. |
| `/settings/*` | `/settings`, `/control/settings`, provider/tool pages | Present product-safe subsections; keep authority-sensitive controls under Operations. |
| `/operations/*` | `/control/*`, `/dashboard`, runtime surfaces | Preserve operator routes; later add safe redirects/aliases. |
| `/lab/*` | current SimLab product | Retained while `HYDRA_LEGACY_SIMLAB=true`. |

### Test assets to reuse

- Ecto/DataCase and workspace fixtures for tenant constraints.
- SimLab persistence, cancellation, idempotency, compiler, forecast, and
  controller coverage.
- Runtime runner, leasing, recovery, policy, usage, and provider tests.
- Browser-worker DNS, proxy, and real-Chromium tests.
- Release/Compose/backup smoke scripts under `ops/`.
- Existing desktop and 390px SimLab screenshots as the legacy baseline.

## Migration plan by existing schema

The following tables are affected conceptually. None is renamed or destructively
converted by Epic 0.

| Existing schema | Planned treatment |
|---|---|
| `workspaces` | Add associations only. |
| `sim_lab_studies` | Legacy Simulation adapter; possible nullable active-version reference after new versions exist. |
| `sim_lab_sources` | Reuse source/provenance rows; raw inclusion remains controlled. |
| `sim_lab_evidence_items` | Reuse reviewed evidence; add/translate Blueprint grounding classes. |
| `sim_lab_context_packs` | Preserve versions; link new Context Pack versions rather than rewrite. |
| `sim_lab_personas` | Legacy representative personas/archetypes. |
| `sim_lab_action_patterns` and join table | Legacy policies/modeled drivers. |
| `sim_lab_scenarios` | Legacy event/script variant input. |
| `sim_lab_runs` | Existing simulation execution record; candidate for additive Pack/replay/engine fields. |
| `sim_lab_snapshots` | Reuse for compatible snapshots; add checksum/codec/version only if required. |
| `sim_lab_outcome_events` | Candidate normalized simulation event source. |
| `sim_lab_forecast_reports` | Legacy report adapter; original rows remain immutable. |
| `sim_lab_calibration_records` | Reuse observed outcomes. |
| `sim_lab_research_runs` | Reuse durable research ledger; add build-stage/version keys if needed. |
| `runs`, `run_steps`, `run_events` | Reuse for orchestration/provider work; define link to simulation run before change. |
| `provider_configs`, credential pools | Reuse model-neutral routing and env-backed secrets. |
| `usage_records`, `budgets` | Reuse accounting data; augment with immutable Plan and price snapshot. |
| knowledge graph tables | Reuse optional workspace evidence/memory references. |
| safety/audit tables | Extend event categories without replacing history. |

## Migrations

- Epic 0: no database migration.
- Next proposed migration: create `simulation_blueprints` and
  `simulation_blueprint_versions` only. It must be additive, workspace-scoped
  for custom Blueprints, and support system built-ins without a fake workspace.

## Acceptance ledger

### Epic 0 — repository map and migration safety

- [x] Repository contexts, schemas, routes, workers, and test assets mapped.
- [x] Reusable Decision Replay code identified.
- [x] ADR records the Blueprint-first boundary.
- [x] Runtime feature-flag contract added.
- [x] Implementation-status document created.
- [x] Current screenshots captured for the 18 July baseline.
- [x] Current Quick-engine benchmark recorded against the exact worktree.
- [x] Legacy routes remain present.
- [x] No duplicate domain object is proposed without justification.
- [x] Migration plan names affected existing schemas.
- [x] Full existing `mix precommit` suite passes after this slice.
- [ ] New product surface is switchable after the Studio shell exists; current flags are data-neutral but do not yet route to an unfinished surface.

### Epic 1 — Blueprint domain and package portability

- [ ] Blueprint and immutable Blueprint Version persistence.
- [ ] Manifest parser and semantic validator.
- [ ] Safe ZIP importer and deterministic exporter.
- [ ] Four instruction modules and schema references.
- [ ] Exactly two built-in Blueprints.
- [ ] List, view, duplicate, edit, test, import, and export UI.
- [ ] Malicious archives rejected.
- [ ] Mock Blueprint Test miniature result.
- [ ] English and Russian visible copy.

## Baseline evidence

The previous production-readiness pass recorded 543 tests, 75.04% line
coverage, 11/11 browser-worker checks including real Chromium, production image
and asset builds, release/Compose smoke, and an encrypted disposable restore.
Those measurements predate this Blueprint-first slice and are historical
context only.

The exact Epic 0 worktree passed `mix precommit` on 2026-07-18: dependency
audit clean, Sobelow completed with only the repository's reviewed
low-confidence allowlisted findings, and 548 ExUnit tests passed with zero
failures (seed 207823, 8.9 seconds).

The current legacy visual baseline is captured at desktop and 390px mobile in:

- `docs/screenshots/blueprint-baseline-2026-07-18/legacy-simulations-desktop.png`;
- `docs/screenshots/blueprint-baseline-2026-07-18/legacy-observatory-desktop.png`;
- `docs/screenshots/blueprint-baseline-2026-07-18/legacy-observatory-mobile-390.png`.

The browser console reported no errors on the captured demo index. The images
are migration evidence, not approval of the legacy information architecture.

The exact-worktree aggregate Quick-engine baseline is recorded in
`docs/benchmarks/2026-07-18-quick-engine-10k.json`. On the recorded arm64
environment, ten measured 10k-population runs after two warmups produced a
0.236 ms p50 and 0.362 ms p95, conserved all 10,000 agents, made zero provider
calls, and recorded 40,000 deterministic pattern decisions over four rounds.
This measures the compact existing cohort engine; the future general Script
engine must earn its own 10k result.

## Known incompatibilities and open decisions

- The new `/simulations` and `/blueprints` surfaces do not exist yet.
- Current navigation exposes runtime management to ordinary authenticated users;
  the specification limits the normal navigation to Simulations, Blueprints,
  and Settings.
- Current SimLab lifecycle and terminology are Decision Replay-oriented.
- Existing Context Pack grounding terms differ from the new six-class contract.
- Current scenarios are not a general versioned declarative Script.
- Current aggregate outcomes do not include a generic Resource Ledger.
- Balanced and Deep execution contracts are not implemented under the new hard
  Budget Plan.
- Exact replay currently covers deterministic saved inputs but not recorded
  model decisions.
- Analysis Pack and claim-validated report regeneration are missing.
- English/Russian product localization infrastructure is not established.
- The relationship between neutral runtime `runs` and `sim_lab_runs` must be
  defined before the general Run contract changes.

## Remaining release gates

Internal alpha, controlled pilot, hosted beta, and enterprise-private gates are
tracked in sections 26 and 27 of the governing specification. No Blueprint-
first gate is claimed complete until its exact current-worktree evidence is
recorded here.
