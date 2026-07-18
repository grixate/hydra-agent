# Hydra Blueprint Studio implementation status

Last updated: 2026-07-18

Governing product loop: **Describe -> Build -> Run -> Explore**

This document is the running implementation ledger required by the Blueprint-
first development specification. A checked item means repository evidence was
inspected and the named acceptance criterion is covered; it does not mean the
entire epic or release is complete.

## Current status

- Active epic: **Epic 4 — Population Model and agent compiler**
- Completed epic: **Epic 3 — Automatic Context Pack**
- Next vertical slice: deterministic Population Model, compact agent state, and
  representative selection
- Default product surface: `legacy_simlab`
- Destructive migrations: none
- Legacy route removal: none
- Controlled-pilot status: not ready under the new specification

## Feature flags

All flags are runtime configuration and do not mutate persisted records.

| Environment variable | Default | Purpose |
|---|---:|---|
| `HYDRA_PRODUCT_SURFACE` | `legacy_simlab` | Selects the legacy entry route or the additive Blueprint Studio entry route. |
| `HYDRA_BALANCED_MODE` | `true` | Enables bounded selective model cognition. The new execution contract is not implemented yet. |
| `HYDRA_DEEP_MODE` | `false` | Keeps experimental model-intensive execution disabled. |
| `HYDRA_BLUEPRINT_IMPORT` | `true` | Enables the safe package-import surface and rejects direct imports when disabled. |
| `HYDRA_LEGACY_SIMLAB` | `true` | Preserves the current product routes and records during migration. |

The flag contract is implemented by `HydraAgent.ProductFeatures`. Invalid
enumerated or boolean runtime values fail startup rather than silently changing
product behavior.

## Repository mapping

### Product and persistence objects

| Blueprint-first object | Existing authoritative asset | Reuse and migration decision |
|---|---|---|
| Workspace | `HydraAgent.Runtime.Workspace`, `workspaces` | Reuse as the tenant, knowledge, policy, and simulation boundary. |
| Blueprint | `HydraAgent.Simulations.Blueprint`, `simulation_blueprints` | Implemented as workspace/system-scoped persistence with exact built-in constraints. |
| Blueprint Version | `HydraAgent.Simulations.BlueprintVersion`, `simulation_blueprint_versions` | Implemented as immutable content-addressed versions with active-version integrity triggers. |
| Simulation | `HydraAgent.Simulations.Simulation`, `simulations`; legacy `SimLab.Schemas.Study` | Implemented as the general workspace-scoped identity. Legacy studies remain visible through links and are not rewritten. |
| Simulation Version | `HydraAgent.Simulations.SimulationVersion`, `simulation_versions` | Implemented as an immutable, content-addressed input snapshot linked to the exact Blueprint Version. |
| Context Pack | `HydraAgent.Simulations.ContextPack`; legacy `sim_lab_context_packs`, sources, evidence items, research runs | Implemented as a general immutable Simulation-Version artifact. The bounded legacy retrieval runner and provider boundary are adapted without conflating legacy Study records. |
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
| Durable build jobs | Six `simulation_build_stages`; Oban and SimLab workers | Version-keyed Context research runs and an idempotent Oban worker are implemented on the current research queue. |
| Question interpretation | `HydraAgent.Simulations.ContextBuilder`; legacy `StudyParser` | A bounded deterministic interpreter now produces the Context Pack contract without requiring a provider. Later model assistance must preserve this validated boundary. |
| Bounded research | research planner, safe query abstraction, configured web provider, direct public-URL fetcher, evidence pipeline | Reused behind durable Context research runs with four-lane Quick planning, partial completion, source attribution, and immutable late-result versions. |
| Population fallback | `BehaviorCompiler` | Preserve behind new interface as explicit emergency fallback. |
| Deterministic execution | `SimulationRunner`, `Simulator`, persisted input fingerprint | Reuse mechanisms after the general Script compiler defines stable semantics. |
| Live progress | Phoenix PubSub and SimLab notifications | Add product-stage events without exposing queue or worker names. |
| Cost and usage | `Usage`, `Budgets`, provider usage ledger | Route every generative stage and Balanced decision through the new Budget Governor. |
| Audit | runtime audit export and safety events | Extend exports with Blueprints, versions, Packs, decisions, resources, analyses, and reports. |

### Route migration

| Target route | Current mapping | Migration state |
|---|---|---|
| `/simulations` | General Simulation list plus explicit legacy-study links | Implemented and selected as the Blueprint Studio entry route. Legacy routes preserved. |
| `/simulations/new` | One-question composer | Implemented with optional notes/data, URLs, files, geography, horizon, mode, and Blueprint. |
| `/simulations/:id/*` | Durable Build, Context, Run, Results, and Compare stages | Implemented as deep links with a source/claim/assumption inspector, truthful readiness gates, and shared domain logic. |
| `/blueprints/*` | Blueprint library, detail, editor, test, import, export | Implemented with workspace role boundaries and EN/RU interface copy. |
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
- Epic 1: additive `simulation_blueprints` and
  `simulation_blueprint_versions` tables. Custom records are workspace-scoped;
  the two system built-ins do not use a fake workspace. Database constraints
  and triggers enforce scope, exact built-in slugs, author scope, immutable
  versions, and an active version belonging to its Blueprint.
- Epic 2: additive `simulations`, immutable `simulation_versions`, and durable
  `simulation_build_stages`. Database constraints and triggers enforce active
  author roles, workspace and Blueprint scope, duplicate/legacy provenance,
  immutable Version history, active-Version identity, and immutable Build-stage
  identity. Legacy `sim_lab_studies` are not converted.
- Epic 3: additive `simulation_context_packs` and
  `simulation_context_research_runs`, plus an active Context Pack reference on
  `simulations`. Database constraints and triggers enforce immutable Pack
  content, workspace/Simulation/Version scope, author identity, active-Pack
  lineage, durable research-run identity, provider/status allowlists, and
  bounded lane counts. The follow-up additive constraint migration permits the
  credential-free `direct_sources` retrieval route. No legacy evidence or
  Context Pack row is rewritten.

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
- [x] New product surface is switchable without data loss; Blueprint Studio now routes authenticated entry to `/simulations` while legacy routes remain intact.

### Epic 1 — Blueprint domain and package portability

- [x] Blueprint and immutable Blueprint Version persistence.
- [x] Manifest parser and semantic validator.
- [x] Safe ZIP importer and deterministic exporter.
- [x] Four instruction modules and schema references.
- [x] Exactly two built-in Blueprints.
- [x] List, view, duplicate, edit, test, import, and export UI.
- [x] Malicious archives rejected.
- [x] Mock Blueprint Test miniature result.
- [x] English and Russian visible copy.

Acceptance evidence: built-ins can be duplicated and versioned without
rewriting history; deterministic export/import preserves the semantic content
hash; traversal, symlink, size-bomb, executable, hash, YAML, capability, and
schema-reference attacks are covered; the provider-free miniature validates
three agents and two rounds without publishing.

### Epic 2 — Simple Simulation Studio shell

- [x] Simulations index with explicit legacy-study access.
- [x] One-question composer with optional files, URLs, notes/data, geography,
  horizon, population, mode, and Blueprint selection.
- [x] Atomic Simulation, immutable v1, and six-stage creation.
- [x] Build progress with four instruction cards and exact Blueprint version.
- [x] Honest ready-to-run summary and disabled Run gate.
- [x] Deep-linkable Build, Run, Results, and Compare stages.
- [x] English and Russian visible shell copy.
- [x] New users can create without opening Settings or visiting a generic Home.
- [x] Creation and stage state survive refresh.
- [x] Ordinary viewers do not see mutation controls, job names, queue state, or
  provider internals.
- [x] Optional input is bounded and revalidated at the web and domain boundaries.
- [x] Workspace audit includes provenance without raw notes, file content, or
  Blueprint instruction text.
- [x] Real 390 px browser evidence for the composer and Build hierarchy.

Acceptance evidence: controller journeys cover question-only and fully
specified creation, refresh, deep links, disabled modes, duplicate/archive,
legacy visibility, both locales, and viewer restrictions. Domain and database
tests cover deterministic content hashing, immutable versions, cross-workspace
scope, owner/author authorization, stage identity, tampered inputs, and audit
privacy. Desktop and 390 px browser QA confirm the quiet object-first hierarchy,
truthful zero-provider/disabled-Run states, responsive wrapping, compact Build
title, full-width lifecycle controls, and absence of horizontal document
overflow.

### Epic 3 — Automatic Context Pack

- [x] Deterministic bounded question interpretation and four-lane Quick plan.
- [x] Every new Simulation atomically receives a usable immutable Context Pack
  v1, including a no-data question with explicit priors, assumptions, and gaps.
- [x] Durable, retryable research runs adapt the existing bounded retrieval
  provider and create a new Pack version for completed or late results.
- [x] Supplied public HTTPS URLs can be retrieved without search-provider
  credentials through a DNS-pinned, redirect-free, size- and timeout-bounded
  path.
- [x] The six required grounding classes are enforced; source attribution,
  excerpts, content hashes, and publication dates survive normalization.
- [x] Model priors and assumptions remain distinct and visible.
- [x] A failed retrieval lane or individual source becomes a visible gap and
  does not corrupt or block the usable Pack.
- [x] Historical cutoff excludes later evidence; Decision Replay also excludes
  evidence without a verified publication date.
- [x] Source exclusion creates immutable Pack v2+, removes dependent claims,
  preserves the exclusion for later research, and resets downstream stages.
- [x] Retrieved/uploaded content is inert, active markup is stripped, and
  instruction-like content is flagged and quarantined before claim extraction.
- [x] Context content is bounded, deduplicated, content-addressed, workspace
  scoped, and included in privacy-preserving audit exports.
- [x] English and Russian Context inspectors expose sources, claims, priors,
  assumptions, research status, plan, gaps, and honest qualitative confidence.
- [x] Ordinary viewers can inspect but cannot mutate; provider, worker, queue,
  and credential internals remain absent from the product surface.
- [x] Real desktop and 390 px browser QA confirms no horizontal overflow and a
  usable Build/Context hierarchy in both locales.

Acceptance evidence: the focused Context suite covers deterministic no-data
builds, all grounding boundaries, attribution, accumulation caps, partial
lanes, supplied-URL success and failure without search credentials, historical
cutoffs, prompt-injection quarantine, source exclusion and no-op rebuilds,
automatic enqueue behavior, immutable database triggers, audit redaction,
authorization, and both locales. The full release gate is recorded below.

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

The exact Epic 1 worktree passed `mix precommit` on 2026-07-18: compilation
with warnings as errors, dependency lock hygiene and audit, formatting,
Sobelow with no high-confidence findings, and 575 ExUnit tests with zero
failures (seed 115287, 8.8 seconds). The 42-test Blueprint-focused suite includes
package safety, manifest and JSON Schema validation, tenant persistence,
immutable versioning, controller journeys, feature-flag boundaries, and
provider-free testing.

The exact current Epic 2 worktree passed `mix precommit` on 2026-07-18:
compilation with warnings as errors, dependency lock hygiene and audit,
formatting, Sobelow with no high-confidence findings, and 595 ExUnit tests with
zero failures (seed 406574, 8.6 seconds). The Epic 2-focused coverage includes
the durable domain, web journeys, tenant and author triggers, input safety,
audit privacy, locale behavior, and the Blueprint Studio default-route switch.
`mix assets.build` also passes. A real runtime startup smoke with
`HYDRA_PRODUCT_SURFACE=blueprint_studio` resolves the surface to
`blueprint_studio` and serves the Studio routes.

The exact Epic 3 worktree passed `mix precommit` on 2026-07-18: compilation with
warnings as errors, dependency lock hygiene and audit, formatting, Sobelow with
only the repository's reviewed low-confidence findings, and 611 ExUnit tests
with zero failures (seed 445065, 8.8 seconds). Its 47-test focused Context suite
also passes, as does `mix assets.build`. Live production-provider staging
evidence remains intentionally open: mocks and credential-free direct-source
retrieval prove failure and lineage behavior, but no public performance, cost,
or provider-compatibility claim is authorized until the real-provider staging
matrix is executed.

The current legacy visual baseline is captured at desktop and 390px mobile in:

- `docs/screenshots/blueprint-baseline-2026-07-18/legacy-simulations-desktop.png`;
- `docs/screenshots/blueprint-baseline-2026-07-18/legacy-observatory-desktop.png`;
- `docs/screenshots/blueprint-baseline-2026-07-18/legacy-observatory-mobile-390.png`.

The browser console reported no errors on the captured demo index. The images
are migration evidence, not approval of the legacy information architecture.

Epic 1 browser QA at 1280×720 is captured in:

- `docs/screenshots/blueprint-studio-epic1-2026-07-18/blueprint-library-en-desktop.jpg`;
- `docs/screenshots/blueprint-studio-epic1-2026-07-18/blueprint-detail-ru-desktop.jpg`;
- `docs/screenshots/blueprint-studio-epic1-2026-07-18/blueprint-test-ru-desktop.jpg`.

The evidence covers the English library, Russian detail hierarchy, localized
test result, ordinary navigation, deterministic zero-provider test disclosure,
sample reveal, and built-in restore interaction. Blueprint-specific narrow
viewport capture remains part of Epic 2 mobile-shell acceptance.

Epic 2 desktop browser QA is captured in:

- `docs/screenshots/simulation-studio-epic2-2026-07-18/simulations-index-en-desktop.jpg`;
- `docs/screenshots/simulation-studio-epic2-2026-07-18/simulation-composer-en-desktop.jpg`;
- `docs/screenshots/simulation-studio-epic2-2026-07-18/simulation-build-en-desktop.jpg`;
- `docs/screenshots/simulation-studio-epic2-2026-07-18/simulation-build-ru-desktop.jpg`;
- `docs/screenshots/simulation-studio-epic2-2026-07-18/simulation-run-gate-en-desktop.jpg`;
- `docs/screenshots/simulation-studio-epic2-2026-07-18/simulation-composer-en-mobile-390-frame.png`;
- `docs/screenshots/simulation-studio-epic2-2026-07-18/simulation-build-en-mobile-390-frame.png`.

The captures cover the direct Simulations index, first-viewport question
composer, localized Build hierarchy, six durable stages, Blueprint instruction
inspection, exact version/hash, and the disabled Run checkpoint. DOM inspection
reported the expected labels and no internal worker terminology.
The narrow frame measured exactly 390×844 CSS pixels with a 390 px document
width on both screens. The mobile pass also led to a smaller workbench title and
removal of automatic field focus, avoiding an unsolicited on-screen keyboard.

The exact-worktree aggregate Quick-engine baseline is recorded in
`docs/benchmarks/2026-07-18-quick-engine-10k.json`. On the recorded arm64
environment, ten measured 10k-population runs after two warmups produced a
0.236 ms p50 and 0.362 ms p95, conserved all 10,000 agents, made zero provider
calls, and recorded 40,000 deterministic pattern decisions over four rounds.
This measures the compact existing cohort engine; the future general Script
engine must earn its own 10k result.

## Known incompatibilities and open decisions

- The `/simulations` shell is implemented, but its Build stages are not yet
  connected to Epic 3 Context Pack workers; no Pack or runnable state is
  claimed.
- Normal Blueprint navigation is limited to Simulations, Blueprints, and
  Settings. Operations is role-gated to system administrators and workspace
  owners/administrators.
- Current SimLab lifecycle and terminology are Decision Replay-oriented.
- Existing Context Pack grounding terms differ from the new six-class contract.
- Current scenarios are not a general versioned declarative Script.
- Current aggregate outcomes do not include a generic Resource Ledger.
- Balanced and Deep execution contracts are not implemented under the new hard
  Budget Plan.
- Exact replay currently covers deterministic saved inputs but not recorded
  model decisions.
- Analysis Pack and claim-validated report regeneration are missing.
- English/Russian copy and locale persistence are established across Blueprint
  and Simulation Studio shells; future Pack inspectors must extend the same
  contract.
- The relationship between neutral runtime `runs` and `sim_lab_runs` must be
  defined before the general Run contract changes.

## Remaining release gates

Internal alpha, controlled pilot, hosted beta, and enterprise-private gates are
tracked in sections 26 and 27 of the governing specification. No Blueprint-
first gate is claimed complete until its exact current-worktree evidence is
recorded here.
