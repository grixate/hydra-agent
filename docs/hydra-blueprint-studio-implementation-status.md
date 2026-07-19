# Hydra Blueprint Studio implementation status

Last updated: 2026-07-18

Governing product loop: **Describe -> Build -> Run -> Explore**

This document is the running implementation ledger required by the Blueprint-
first development specification. A checked item means repository evidence was
inspected and the named acceptance criterion is covered; it does not mean the
entire epic or release is complete.

## Current status

- Active epic: **Epic 12 — Pilot hardening**
- Completed epic: **Epic 11 — Portable Simulation Pack and Run Pack**
- Next vertical slice: deployment-owned real-provider probe, manual
  assistive-technology review, and off-host restore evidence
- Default product surface: `legacy_simlab`
- Destructive migrations: none
- Legacy route removal: none
- Controlled-pilot status: application ready for environment qualification;
  external credential, assistive-technology, and independent-storage gates open

## Feature flags

All flags are runtime configuration and do not mutate persisted records.

| Environment variable | Default | Purpose |
|---|---:|---|
| `HYDRA_PRODUCT_SURFACE` | `legacy_simlab` | Selects the legacy entry route or the additive Blueprint Studio entry route. |
| `HYDRA_BALANCED_MODE` | `true` | Enables bounded selective model cognition with immutable decisions and replay. |
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
| Population Model | `HydraAgent.Simulations.PopulationModel`; legacy personas, action patterns, `BehaviorCompiler` | Implemented as an immutable Context-bound structured contract with a provider-free deterministic builder. Legacy SimLab records remain separate compatibility inputs. |
| Agent Instance | `HydraAgent.Simulations.PopulationCompiler`; generated aggregate cohorts and representative traces | Implemented as compact deterministic materialization, not permanent runtime profiles or one process per agent. Run-owned persistence waits for the Script/engine boundary. |
| Representative Persona | `HydraAgent.Simulations.PersonaProjection`; legacy `sim_lab_personas` | Implemented as an immutable lazy projection of representative structured state. Persona count is never population size. |
| Simulation Script | `HydraAgent.Simulations.SimulationScript`; legacy scenario events, executable rules, `ScenarioCompiler` | Implemented as a versioned typed declarative contract with semantic validation, exact upstream lineage, and no arbitrary execution. Legacy scenarios remain compatibility inputs. |
| Observation Plan | Script observations; legacy snapshot metrics, outcome events, forecast inputs | Implemented inside Script V1 as explicit typed metrics and trace selection. A separately versioned Pack reference remains for the portable-Pack epic. |
| Budget Plan | Runtime `budgets`, `usage_records`, SimLab cost fields | Implemented as an immutable per-Simulation authorization envelope and price snapshot; neutral budgets and usage remain the general accounting primitives. |
| Model Route Plan | Provider configs, credential pools, agent model routes | Implemented as immutable Build/Simulation/Report role selection and public resolution over the existing provider-neutral adapters. |
| Simulation Pack | Deterministic `.hydra-simpack` assembled from the exact immutable components | Implemented as a content-addressed portable artifact; import recompiles and previews before one atomic destination Simulation commit. No duplicate database object is needed. |
| Preview Run | `HydraAgent.Simulations.ScriptPreview`; existing deterministic runner assets | Implemented as a separate immutable, exact-lineage two-round result with at most 12 representatives, zero model calls, safe errors, and a deterministic result hash. |
| Run | neutral runtime `runs`; legacy `sim_lab_runs` | Neutral `runs` is the execution identity. A one-to-one simulation profile captures exact lineage and deterministic execution metadata; legacy records remain compatibility assets. |
| Run Decision | `HydraAgent.Simulations.RunDecision`, `simulation_run_decisions`, affected-agent mappings | Implemented as append-only, budget-linked, exact-contract decisions with stable signatures, typed actions, replay lineage, and explicit fallback provenance. |
| Run Event | Runtime `run_events`, legacy `sim_lab_outcome_events` | Runtime events now carry optional simulation sequence, round, phase, targets, source, provenance, and idempotency fields. Simulation events fail closed when ordering fields are absent. |
| Run Snapshot | General `run_snapshots`; legacy `sim_lab_snapshots` | Implemented as append-only, checksummed, engine/schema-versioned full recovery state owned by the neutral run. Legacy snapshots remain unchanged. |
| Resource Transaction | `resource_transactions` | Implemented as an append-only Decimal ledger with stable ordering, provenance, resulting balances, and retry-safe idempotency. |
| Analysis Pack | `HydraAgent.Simulations.AnalysisPack`; forecast inputs and `Forecast` calculations | Implemented as a bounded immutable artifact derived only from a verified completed Run. Legacy forecast calculations remain separate compatibility inputs. |
| Report | `HydraAgent.Simulations.SimulationReport`; `sim_lab_forecast_reports` | Implemented as immutable per-attempt model interpretation with exact Analysis/Blueprint/route/price lineage and strict claim validation. Legacy reports are unchanged. |
| Calibration | `sim_lab_calibration_records` | Reuse as observed-outcome links without rewriting original predictions. |

### Contexts, workers, and events

| Requirement | Existing code | Planned reuse |
|---|---|---|
| Durable build jobs | Six `simulation_build_stages`; Oban and SimLab workers | Version-keyed Context research runs and an idempotent Oban worker are implemented on the current research queue. |
| Question interpretation | `HydraAgent.Simulations.ContextBuilder`; legacy `StudyParser` | A bounded deterministic interpreter now produces the Context Pack contract without requiring a provider. Later model assistance must preserve this validated boundary. |
| Bounded research | research planner, safe query abstraction, configured web provider, direct public-URL fetcher, evidence pipeline | Reused behind durable Context research runs with four-lane Quick planning, partial completion, source attribution, and immutable late-result versions. |
| Population fallback | `HydraAgent.Simulations.PopulationBuilder`; legacy `BehaviorCompiler` | A zero-provider deterministic general builder is active. Legacy behavior compilation remains isolated. |
| Deterministic execution | `SimulationRunner`, `Simulator`, persisted input fingerprint | Reuse mechanisms after the general Script compiler defines stable semantics. |
| Live progress | Phoenix PubSub and SimLab notifications | Add product-stage events without exposing queue or worker names. |
| Cost and usage | `Usage`, `Budgets`, provider usage ledger | Immutable Budget Plans and atomic reservations are implemented; Context retrieval is governed now and every future generative stage must use the same boundary. |
| Audit | runtime audit export and safety events | Blueprint, Simulation, Context, Population, and Persona-projection lineage now export with raw instructions, inputs, imported values, identifiers, and prose fingerprinted or omitted. Later epics add decisions, resources, analyses, and reports. |

### Route migration

| Target route | Current mapping | Migration state |
|---|---|---|
| `/simulations` | General Simulation list plus explicit legacy-study links | Implemented and selected as the Blueprint Studio entry route. Legacy routes preserved. |
| `/simulations/new` | One-question composer | Implemented with optional notes/data, URLs, files, geography, horizon, mode, and Blueprint. |
| `/simulations/:id/*` | Durable Build, Context, Population, Script, Run, Results, and Compare stages | Implemented as deep links with Context, Population, and Script inspectors, truthful readiness gates, deterministic YAML/JSON export, and shared domain logic. |
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
- Epic 4: additive immutable `simulation_population_models` and
  `simulation_persona_projections`, plus an active Population Model reference
  on `simulations`. Database constraints and triggers enforce exact
  workspace/Simulation/Version/Context lineage, author scope, active-model
  integrity, immutable content, and immutable lazy projections. No legacy
  persona, action-pattern, cohort, or run row is rewritten.
- Epic 5: additive immutable `simulation_scripts` and
  `simulation_script_previews`, plus an active Script reference on
  `simulations`. Database constraints and triggers enforce exact
  workspace/Simulation/Version/Context/Population lineage, author scope,
  immutable content and preview evidence, and active-Script integrity. No
  legacy scenario, run, event, or snapshot row is rewritten. A follow-up
  additive constraint migration tightens the preview population to the engine's
  exact 12-representative bound. A second hardening migration requires matching
  passed/ready or failed/blocked Preview evidence before a Script can become
  active.
- Epic 6: additive one-to-one `simulation_run_records`, append-only
  `run_snapshots`, and append-only `resource_transactions`; additive optional
  ordering and provenance fields on neutral `run_events`. Database constraints
  enforce Quick-only zero-model execution, bounded progress, immutable exact
  lineage, checksum/hash formats, closed ledger operations, and simulation-event
  sequencing. Legacy SimLab runs, events, and snapshots are not rewritten.
- Epic 7: additive effective-dated `simulation_price_entries`, immutable
  `simulation_model_route_plans`, immutable `simulation_budget_plans`, and
  mutable-lifecycle/immutable-identity `simulation_budget_reservations`;
  additive route, budget, usage, and fallback snapshots on Simulation Run
  records. Database constraints and triggers enforce workspace/Simulation/
  Version scope, plan immutability, reservation-to-Run scope, fixed request
  envelopes, idempotency, non-negative usage, bounded configuration, and Run
  references. Existing Versions and Runs receive conservative unknown-price
  backfills without changing their execution history.
- Epic 8: additive append-only `simulation_run_decisions` and
  `simulation_run_decision_agents`; additive replay lineage, decision-policy,
  and manifest fields on Simulation Run records. Database triggers enforce
  exact workspace/Run/reservation scope, immutable decision provenance,
  stable affected-agent mappings, strict replay-source compatibility, and
  immutable Run lineage after creation. Quick Run constraints remain intact.
- Epic 9: additive immutable `simulation_analysis_packs` and lifecycle-governed
  `simulation_reports`. Database constraints and triggers require exact
  completed-Run lineage, one Analysis per Run, bounded reference-addressable
  content, at most eight Report attempts per Analysis, enabled workspace-valid
  providers, exact regeneration-source scope, immutable route and reservation
  envelopes, valid state transitions, and immutable terminal Report history.
- Epic 10: no database migration. `hydra-observatory/v1` and
  `hydra-observatory-agent/v1` are deterministic presentation protocols derived
  from existing immutable Analysis Packs and Run snapshots. Workspace scope,
  completion, comparison identity, and agent selection are enforced at the
  domain and controller boundaries.
- Epic 11: no database migration. `.hydra-simpack`, `.hydra-run`, and manual
  external-model JSON are deterministic transport artifacts assembled from and
  validated into existing immutable records. Import adds only ordinary
  workspace-scoped Simulation/Blueprint/component rows through existing schema
  constraints and atomic transactions.

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

### Epic 4 — Population Model and agent compiler

- [x] Every new Simulation atomically receives Population Model v1 tied to its
  exact immutable Version and Context Pack.
- [x] Agent types, archetypes, weights, declared attributes, goals,
  constraints, state, resources, policies, memory seeds, conditional
  distributions, grounding, relationship rules, and representative rules are
  semantically validated.
- [x] Constant, categorical, uniform, bounded normal, beta, integer-range, and
  weighted-list distributions compile from deterministic hash-derived samples.
- [x] Largest-remainder apportionment produces exact type and archetype counts.
- [x] `none`, `random`, `small_world`, `hierarchical`, `bipartite`, and
  `imported` relationship topology rules compile deterministically.
- [x] Generated relationship capacity is rejected before compilation above a
  500,000-edge bound; imported edges are capped at 100,000.
- [x] A provider-free builder defines and instantiates 10,000 agents with zero
  model calls; repeat compilation produces the same hashes and state.
- [x] Only bounded representatives retain structured cards. Readable prose is
  generated on demand and persisted as an immutable, explicitly
  non-authoritative projection.
- [x] Representative cards expose structured traits, goals, constraints,
  current state, resources, grouped important relationships, grounding, and
  lazy-projection status.
- [x] CSV/JSON agent imports, JSON Population Model imports, and CSV/JSON edge
  lists support explicit mapping, bounded files/rows/cells, partial valid-row
  persistence, and safe row-level diagnostics.
- [x] Source agent IDs are deterministically pseudonymized before persistence;
  audit exports fingerprint imported state and Persona prose.
- [x] Sensitive traits fail closed unless a full Population Model declares
  observed source, necessity, lawful basis, aggregate-only use, and no
  individual exposure. Individual consequential use is prohibited.
- [x] Attribute removal and Context change produce new immutable Population
  versions. Custom JSON contracts survive Context rebasing and revalidate
  grounding instead of silently reverting to the fallback builder.
- [x] English and Russian Population inspectors provide exact counts, quiet
  corrective import feedback, role-gated mutations, and no internal runtime
  terminology or raw IDs.
- [x] Real 1280px and 390px browser QA confirms no horizontal overflow, clean
  console state, legible hierarchy, keyboard focus treatment, collapsed
  advanced mapping, and successful on-demand projection.

Acceptance evidence: the focused Epic 4 suite covers all distributions and
topologies, exact replay, capacity rejection, sensitive-use boundaries, CSV
and JSON behavior, overflow rejection, pseudonymization, partial import,
attribute removal, immutable triggers, custom-model rebasing, projection
idempotency, workspace audit privacy, controller journeys, both locales, and
viewer restrictions. The exact 10k acceptance smoke is recorded in
`docs/benchmarks/2026-07-18-population-compiler-10k.json`; the full release gate
is recorded below.

### Epic 5 — Simulation Script DSL, validation, and preview

- [x] Every new Simulation atomically receives Script v1 tied to its exact
  immutable Version, Context Pack, and Population Model.
- [x] Metadata, round clock, world state, agent types, relationships, resources,
  events, actions, perception, policies, transitions, observations, and stopping
  conditions are required and bounded.
- [x] Conditions and numeric expressions use typed, depth- and node-bounded
  abstract syntax trees; arbitrary code, dynamic evaluation, tools, and external
  side effects are absent.
- [x] Semantic validation catches missing references, undeclared state paths,
  impossible resource balances, unreachable actions, unbounded targets,
  oversized contracts, event cycles, and hybrid cognition without a budget.
- [x] Generation has a provider-free deterministic fallback. A future generated
  proposal receives at most one repair attempt and must pass the same validator.
- [x] A valid Script completes a deterministic two-round preview with at most 12
  representatives, the exact Population seed, zero model calls, and no external
  effects.
- [x] A failed preview persists a safe corrective explanation, marks the Script
  blocked, and cannot silently fall through to later execution.
- [x] Context and Population changes atomically create exact-lineage Script and
  preview versions; identical explicit rebuilds are content-addressed and
  idempotent.
- [x] Scripts and previews are immutable and workspace scoped; cross-Simulation
  and stale-lineage database writes fail closed.
- [x] Deterministic readable YAML and canonical JSON exports preserve the exact
  Script contract.
- [x] Workspace audit includes safe lineage, counts, validation, generation and
  preview evidence while fingerprinting the full Script and excluding raw state.
- [x] English and Russian Script inspectors lead with preview outcome and explain
  clock, choices, resources, timeline, policies, measurements, and portability
  without runtime or DSL jargon.
- [x] Ordinary viewers can inspect and export but cannot rebuild; Run remains
  disabled until the complete immutable Simulation Pack exists.
- [x] Real 1280px and 390px browser QA confirms exact readiness values, no
  horizontal overflow, clean console state, localized derived labels, and a
  quiet responsive hierarchy.

Acceptance evidence: focused Script/domain and controller suites cover schema
and semantic validation, deterministic preview/replay, bounded repair, safe
failure, immutable triggers, exact lineage, idempotent rebuild, exports, audit
privacy, authorization, both locales, and the truthful Run checkpoint. Full
release-gate totals are recorded below.

### Epic 6 — Quick engine and world economy

- [x] Neutral runtime `runs` is the single execution identity; a one-to-one
  immutable simulation profile records exact component lineage, Pack hash,
  seed, engine version, and progress.
- [x] Quick mode interprets the full compiled Population without provider,
  credential, tool, or external-effect access and enforces zero model calls in
  both changeset and database constraints.
- [x] One dynamically supervised tree per active run owns a coordinator, four
  configurable state partitions, and one authoritative Resource Ledger; agents
  are compact state rather than permanent processes.
- [x] Stable policy selection, action/event ordering, merge keys, and phase
  order make the same Pack and seed produce identical result and final-state
  hashes.
- [x] Relationship effects, bounded neighbor targets, transition payload
  filters, and `event.relationship_weight` execute deterministically in both
  preview and Quick paths; current-round transition input is not truncated by
  the bounded perception history.
- [x] Simulation events extend the neutral append stream with contiguous
  sequence, round, phase, targets, source, provenance, and idempotency.
- [x] Decimal resources enforce declared precision, bounds, negative policy,
  mint/burn permission, conservative transfer rounding, stable batches, and
  idempotent retry behavior.
- [x] Each round atomically commits events, ledger transactions, a checksummed
  snapshot, simulation progress, and neutral run state.
- [x] Initial and every-round full snapshots support verified resume after a
  killed coordinator; supervised process recovery and Oban retry share the same
  durable boundary.
- [x] Snapshot restore fails closed on run scope, schema/engine version, Pack
  hash, seed, round, event sequence, payload checksum, and authoritative state
  hash. Final hashes include all resource accounts and relationship state.
- [x] Completion, safe failure, and operator cancellation establish a locked
  terminal fence that retries cannot cross.
- [x] Run creation, progress, exact engine/Pack disclosure, cancellation, and
  terminal outcome are exposed in a quiet English/Russian Run stage without
  queue, worker, provider, or internal-process language.
- [x] A real 10,000-agent × 20-round durable benchmark completed three samples
  in 30.874–34.451 seconds with matching hashes, zero model calls, and
  1,138,431,469-byte peak whole-application memory.

Acceptance evidence: focused tests cover ordered commits, replay equality,
bounded Decimal conservation, precision rounding, forbidden supply changes,
overdraft rejection, idempotent retry, relationship execution, transition
targeting, snapshot tamper rejection, killed-coordinator recovery, operator
cancellation, terminal fencing, and specific creation errors. Architecture and
operations are recorded in ADR 0003 and `docs/quick-engine.md`; the exact local
benchmark is `docs/benchmarks/2026-07-18-blueprint-quick-engine-10k.json`.

### Epic 7 — Budget Governor and model routing

- [x] Effective-dated global and workspace price rows capture provider, model,
  input, cached input, output, request minimum, currency, effective time, and
  operator-override provenance.
- [x] Every Simulation Version receives immutable, content-addressed Model Route
  and Budget Plans; edits create a new next-Run configuration and lock while a
  Run is active.
- [x] Build, Simulation, and Report roles resolve automatically or explicitly
  by capability. Quick forces zero Simulation model calls, local routes are
  preferred for Simulation, and unusable remote credentials are excluded.
- [x] Run snapshots contain exact public provider/model/capability/route-version
  provenance without credentials or secret references.
- [x] Quick, Balanced, and Deep plans enforce whole-plan token, model-call,
  retrieval, runtime, concurrency, and per-stage call/token limits.
- [x] A monetary cap is claimed only when every active price is known and
  currencies are compatible. Unknown, partial, and mixed-currency pricing stay
  explicit while non-monetary caps remain active.
- [x] Atomic plan-row locking prevents concurrent oversubscription. Every
  attempt is idempotent and records a reservation or audited rejection before
  provider work begins.
- [x] Completion records actual usage, returns unused capacity, and rejects
  malformed, negative, or over-envelope provider usage without releasing the
  conservative reservation.
- [x] The deterministic fallback order is captured in each plan; exhaustion can
  record and return a downgrade instead of failing the deterministic Run.
- [x] Every automatic Context research lane and direct public-source request is
  budgeted. Exhaustion or provider failure yields a partial Pack safely.
- [x] Historical Runs retain their exact plan and price snapshot after later
  price changes.
- [x] The Run screen shows estimated or unavailable price, hard maximum, call
  and retrieval caps, expected runtime, population/rounds, model routes, and
  deterministic-completion posture before Run; it shows spend/remaining,
  decisions, fallbacks, and stage after Run creation.
- [x] English and Russian budget and route copy avoids reservation, credential,
  provider-internal, worker, and queue terminology.

Acceptance evidence: the focused 59-test Budget, Context, Quick-engine,
Simulation-domain, and Run-controller suite passes with zero failures. It
covers concurrent final-slot reservation, exact and unknown pricing, mixed
currencies, malformed usage, provider overrun, every hard-cap family, explicit
fallback, credential readiness, historical price snapshots, governed research,
route configuration locking, final usage snapshots, and both locales.
Architecture and operations are recorded in ADR 0004 and
`docs/budget-governor.md`. The exact implementation worktree passed
`mix precommit` on 2026-07-18: compilation with warnings as errors, dependency
lock hygiene and audit, formatting, Sobelow with only the repository's reviewed
low-confidence findings, and 664 ExUnit tests with zero failures (seed 70277,
24.9 seconds). `mix assets.build` also passes.

### Epic 8 — Balanced hybrid cognition

- [x] Balanced Scripts compile explicit hybrid policies with declared candidate
  actions and deterministic weighted fallbacks; Quick Scripts remain unchanged.
- [x] Stable versioned policy signatures group agents by type, archetype,
  bucketed relevant state, recent events, action set, relationship class,
  Script hash, and model-route version.
- [x] Novelty, uncertainty, influence, downstream impact, deterministic
  disagreement, user importance, representative sampling, and cache miss feed
  a deterministic priority score.
- [x] Global, per-round, per-type, per-agent, token, call, cost, runtime, and
  concurrency limits are checked before dispatch. Requests run in bounded
  batches so active reservations cannot oversubscribe the concurrency cap.
- [x] The six-field decision JSON contract rejects unknown keys, undeclared
  actions, malformed reason codes, oversized parameters/memory, long rationale,
  and out-of-range uncertainty.
- [x] Invalid output, provider error, timeout, missing route, and exhausted
  budget produce a recorded deterministic fallback without corrupting state.
  Dispatched failures close against the conservative reserved envelope.
- [x] Decisions and affected-agent mappings are append-only and exact-workspace/
  Run scoped. They are durable before a round snapshot and reused on retry.
- [x] Within-Run signature reuse lets one representative decision cover many
  agents; per-agent coverage remains capped and inspectable.
- [x] Exact replay uses the same Pack, seed, engine, ordering, and recorded
  decisions with zero new provider calls; result, final-state, and decision-
  manifest hashes match. Fresh rerun uses the current Pack and a new seed.
- [x] The Run surface exposes an editable Simulation route only for Balanced,
  quiet decision/reuse/coverage/fallback summaries, recent decisions, and
  clearly differentiated exact/fresh replay actions in English and Russian.
- [x] A 5,000-agent × 12-round acceptance run completed locally in 19.1905
  seconds against the 60-second engine target, stayed under 80 model calls and
  two decisions per agent, and proved multi-agent signature reuse.

Focused domain and controller coverage passes for valid cognition, malformed
provider output, conservative budget closure, exact replay, fresh rerun,
5,000-agent scale, route editing/locking, and bilingual operator copy.
Architecture and operations are recorded in ADR 0005 and
`docs/balanced-cognition.md`; the local scale evidence is
`docs/benchmarks/2026-07-18-balanced-engine-5k.json`. The exact implementation
worktree passed `mix precommit` on 2026-07-18: warnings-as-errors compilation,
dependency lock hygiene and audit, formatting, Sobelow with only the
repository's reviewed low-confidence findings, and 670 ExUnit tests with zero
failures (seed 667028, 44.5 seconds). `mix assets.build` also passes.

### Epic 9 — Analysis Pack and Report Blueprint

- [x] A completed Run publishes one immutable, content-addressed Analysis Pack
  without making Report generation part of Run success.
- [x] Analysis verifies exact lineage and authoritative snapshots before
  deriving bounded metrics, segments, timeline, resource flows, pivotal events,
  representative traces, model decisions, scenario deltas, robustness,
  uncertainty, grounding, usage, and limitations.
- [x] Every reportable artifact has a stable reference and numeric variants;
  rebuilding the same Run produces the same Analysis content hash.
- [x] Report attempts record exact Analysis, Blueprint, instructions, language,
  audience, length, provider/model route, price, token, and cost envelopes.
- [x] Queuing is atomic with its durable job, each Analysis allows at most eight
  attempts, and regeneration appends a new immutable version without rerunning.
- [x] Duplicate first-attempt delivery never redispatches an active provider
  request; an ambiguous retry fails visibly instead of risking duplicate cost.
- [x] Structured validation rejects unknown fields or references, unsupported
  numbers, invented URLs, unsupported quotations, and unreferenced numeric
  prose before a Report can become ready.
- [x] Report failure and provider interruption leave both the completed Run and
  immutable Analysis unchanged.
- [x] English and Russian Reports preserve the exact nine-section contract;
  the interface localizes generation, failure, version, evidence, and flash
  states independently from the selected Report language.
- [x] Analysis JSON, metrics CSV, events CSV, transactions CSV, Report Markdown,
  and escaped printable HTML preserve provenance and content hashes.
- [x] The Results surface provides a quiet, responsive Analysis/Report hierarchy,
  explicit synthetic-evidence warning, progressive reference disclosure,
  report history, and 44 px mobile generation controls.

Focused Analysis and Results coverage passes 26 tests with zero failures. It
covers deterministic construction, append-only Analysis, valid English/Russian
generation, immutable terminal Reports, at-most-once duplicate delivery,
attempt caps, invalid claims, Run isolation, exports, localized UI, and the
complete controller journey. Architecture and operations are recorded in ADR
0006 and `docs/analysis-and-reports.md`. The Analysis/Report migration was
applied, rolled back, and applied again on the development database. The exact
implementation worktree passed `mix precommit` on 2026-07-18: warnings-as-errors
compilation, dependency lock hygiene and audit, formatting, Sobelow with only
the repository's reviewed low-confidence findings, and 678 ExUnit tests with
zero failures (seed 841782, 48.8 seconds). `mix assets.build` also passes.

### Epic 10 — State, Flow, and Explain Observatory

- [x] Results lead with a concise computed result and a three-lens State, Flow,
  and Explain hierarchy before governed Report generation.
- [x] State presents density/cohort aggregation, exact final state and resource
  distributions, population/model-decision/persona/relationship scale, bounded
  representative samples, and semantic zoom without one object per agent.
- [x] Flow presents a compact metric timeline, keyboard round control, pivotal
  events, aggregate resource movement, and an optional comparison path.
- [x] Explain ranks bounded modeled drivers, high-reach model decisions,
  grounding, uncertainty, limitations, and representative traces while
  explicitly rejecting causal interpretation.
- [x] Agent detail loads only after selection and includes bounded structured
  profile, history, resources, relationships, actions, perceived context,
  decision/reuse provenance, optional persona, grounding, and a synthetic-agent
  disclosure. Full snapshots and memory seeds are never returned.
- [x] `hydra-observatory/v1` is deterministic, content-addressed, privately
  cached, ETagged, and bounded to 32 initial samples. PostgreSQL computes final
  aggregates without transferring a multi-megabyte snapshot into the app.
- [x] `hydra-observatory-agent/v1` uses identifier validation and bound JSONB
  queries to select one agent across immutable snapshots.
- [x] Comparison validates Population Model, Script, mode, model route, and
  Budget Plan; seed and replay kind remain explicit controlled differences and
  incompatible governing inputs produce a caution state.
- [x] Locale switching preserves the selected primary/comparison Runs. Built-in
  metric, cohort, resource, event, action, and decision labels are localized in
  English and Russian.
- [x] Every visual has an immediate table or textual equivalent. ARIA tabs,
  keyboard semantic zoom and timeline controls, visible focus, reduced-motion
  rules, 44 px mobile controls, and contained table scrolling are present.
- [x] A real 5,000-agent automated acceptance Run stays below the 500 KB
  compressed initial-payload envelope and contains no full `agents` array.

Focused Observatory, Analysis, and Results coverage passes 11 tests with zero
failures, including the real 5,000-agent scale case. The live 5,000-agent
Balanced Run produced a 55,011-byte payload and a 7,242-byte compressed body,
with 32 bounded samples. Browser review at 1,280×900, 390×844, and an effective
320 px high-zoom viewport found no document overflow; tables retained contained
scrolling, mobile primary controls were at least 44 px, keyboard focus was
visible, and the final console had zero warnings or errors. Architecture and
operations are recorded in ADR 0007 and `docs/observatory.md`. The exact
implementation worktree passed `mix precommit` on 2026-07-18: warnings-as-errors
compilation, dependency lock hygiene and audit, formatting, Sobelow with only
the repository's reviewed low-confidence findings, and 681 ExUnit tests with
zero failures (seed 937221, 54.2 seconds). `mix assets.build` also passes.

### Epic 11 — Portable Simulation Pack and Run Pack

- [x] `.hydra-simpack` export is byte-deterministic and contains the exact
  Blueprint, Simulation, Context, Population, Script, Observation, route,
  budget, preview, compatibility, privacy, validation, and lineage contracts.
- [x] Simulation Pack import rejects hostile archives and validates every file
  hash, format/schema/compiler version, Blueprint and component lineage,
  Population and Script semantics, and source input contract before persistence.
- [x] Destination import resolves model capabilities without copying provider
  identifiers or credentials, reprices inside the preserved hard envelope,
  recompiles Population, and reruns the bounded preview before one atomic
  runnable-Simulation commit.
- [x] Raw notes, attachments, and URL inputs are excluded by default and require
  an explicit editor control. Structured redaction pseudonymizes identities and
  always overrides raw inclusion. Provider details are independently optional.
- [x] `.hydra-run` export uses the Run's historical immutable components and
  contains the exact Simulation Pack, Run/engine/seed/replay lineage, ordered
  events, decisions, resource transactions, Analysis, Report versions, usage,
  hashes, privacy declaration, and reproducibility README.
- [x] Run Pack interface defaults exclude raw sources, provider details, model
  rationales, and recovery snapshots while preserving the complete portable
  audit record required for Quick reproduction and Balanced exact replay.
- [x] Manual external-model request export includes exact instructions, JSON
  Schemas, preceding artifacts, source metadata, and Simulation/Blueprint/base
  artifact hashes without raw source text or credentials.
- [x] Manual upload preserves lineage, validates all Blueprint schemas,
  grounding, Population identity/count invariants, Script semantics, and a new
  preview, then appends all new immutable artifacts atomically. Stale or invalid
  output changes nothing.
- [x] English and Russian UI presents safe one-click defaults, progressive
  privacy controls, an explicit download/run/import manual flow, actionable
  compatibility states, 44 px primary controls, visible focus, and responsive
  reflow.
- [x] Reproducibility and operator behavior are recorded in ADR 0008 and
  `docs/portability.md`.

Focused domain and controller portability coverage passes 14 tests with zero
failures. It covers deterministic archives, traversal and executable rejection,
size and hash enforcement, cross-workspace transfer, default raw exclusion,
redacted and raw exports, provider omission, unsupported versions, component
tampering, undeclared-file rejection, privacy-policy contradictions, forged
preview and Analysis hashes, completed Run audit export, manual success and
stale-lineage atomicity, upload-boundary enforcement, download headers, both
locales, and the complete interface journey. Real Chromium review at 1,280×900
and 390×844 covered import, safe and advanced Simulation Pack export, the manual
external-model workflow, and Run Pack export in English and Russian. There was
no document overflow, primary controls met 44 px on mobile, keyboard focus was
visible, duplicate IDs were absent, and the final console had zero warnings or
errors. The exact Epic 11 worktree passed `mix precommit` on 2026-07-18:
warnings-as-errors compilation, dependency lock hygiene and audit, formatting,
Sobelow with only the repository's reviewed low-confidence findings, and 695
ExUnit tests with zero failures (seed 626548, 56.7 seconds). `mix assets.build`
also passes.

### Epic 12 — Pilot hardening

- [x] OpenAI-compatible chat, streaming, and embedding paths plus Anthropic and
  Ollama chat paths enforce bounded requests. Chat staging paths additionally
  enforce no retries/redirects/compression, strict content/usage contracts, and
  privacy-safe HTTP/transport failures.
- [x] One explicit low-cost live staging command validates a random structured
  nonce and normalized usage without returning prompts, content, endpoints, or
  credentials. Mock providers are rejected.
- [x] Workspace admins can download a scoped, no-store Run diagnostic with a
  support code, public routes, hard-budget state, reservation terminality,
  failure/fallback counts, recovery lineage, report failures, severity, and
  stable next actions. Prompts, rationales, sources, and secrets are excluded.
- [x] Settings → Privacy & data flow presents operator/support/security/privacy/
  retention disclosure, exact stage data flows, enabled route posture,
  safeguards, storage/deletion honesty, and the local Codex boundary in English
  and Russian. Missing operator values remain visibly incomplete.
- [x] The reusable Playwright audit checks desktop, 390 px mobile, and 320 px
  high-zoom layouts for semantic structure, naming, ARIA references, heading
  order, effective target size, overflow, keyboard focus, reduced motion,
  accessibility-tree presence, and console errors without recording tree text.
- [x] 69 English/Russian route/viewport checks passed with zero violations.
  Review corrected nested main landmarks, an Observatory heading jump, and
  several overly small quiet controls while preserving the visual hierarchy.
- [x] A repeatable temporary pilot fixture completes a no-data General Quick
  case and a strict-cutoff Decision Replay Balanced case, validates Reports,
  builds State/Flow/Explain, exports Run Packs, proves exact replay equality,
  and completes a fresh changed-model rerun. Its artifact states strengths and
  limitations and explicitly excludes real-provider claims.
- [x] The performance suite includes the complete 10k/20-round Quick benchmark
  and the bounded 5k/12-round Balanced benchmark; recorded artifacts preserve
  local/mock qualification limits.
- [x] Restore verification now proves the migration ledger and seven core
  application tables, reports safe record counts, and the off-host wrapper
  refuses a same-filesystem target or unconfirmed independent storage.
- [x] The operator kit covers ownership, deployment, disclosure, live provider
  staging, support diagnosis, incident recovery, accessibility, pilot cases,
  privacy/provider templates, and explicit go/no-go evidence.
- [x] Exact-revision production application, browser-worker, and backup images
  build successfully. Release and Compose smoke cover blank-database
  migrations, readiness, API boundaries, immutable assets, concurrent health,
  container isolation and limits, encrypted backup, and disposable restore.
- [ ] Run the live provider probe for every enabled production route and
  fallback. No non-mock provider or production credential exists locally.
- [ ] Complete a human VoiceOver/Safari review against the immutable staging
  candidate.
- [ ] Complete the encrypted restore rehearsal on storage that survives loss of
  the application host. The local repository and Downloads share one device.

Repeatable application-flow evidence is in
`docs/pilot-cases/2026-07-18-controlled-pilot-fixture.json`; automated
accessibility evidence is in
`docs/accessibility/2026-07-18-blueprint-studio-audit.json`. The release status
and external blockers are explicit in `docs/pilot-release-evidence.md`.

The exact Epic 12 worktree passed `mix precommit` on 2026-07-19: warning-free
compilation, dependency lock hygiene and audit with no known vulnerabilities,
formatting, Sobelow with only the repository's reviewed low-confidence
findings, and 710 ExUnit tests with zero failures (seed 598090, 57.5 seconds).
The same worktree passed the coverage floor at 76.78% with 710 tests and zero
failures. Browser-worker syntax and proxy-security tests passed with nine tests
and two environment-dependent real-Chromium cases skipped; the separate live
Chrome accessibility audit passed all 69 route/viewport checks.

Candidate commit `b8e25e7f29d0af99061ab3599b78d3d67f1cc160` passed a clean
`mix precommit` with 710 tests and zero failures, built all three `linux/arm64`
production images, passed all 11 browser-worker tests inside its Playwright
image, and passed both `ops/release-smoke` and `ops/compose-smoke`. The latter
includes an encrypted disposable restore and full container-boundary checks;
it remains intentionally distinct from the required independent-storage
rehearsal. All three exact-revision images also pass the Trivy 0.70.0 gate with
zero fixable HIGH/CRITICAL findings after Debian package upgrades and removal
of unused runtime npm/gosu tooling. Content-addressed evidence is in
`docs/release/2026-07-19-production-artifact-smoke.json`.

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

The exact Epic 4 worktree's focused 47-test suite passes with zero failures.
The provider-free 10k acceptance smoke builds and compiles exactly 10,000
agents, 20,000 small-world relationships, and 10 representatives with zero
model calls; a repeat compile produces the same agent-set hash. The current
worktree passed `mix precommit` on 2026-07-18: compilation with warnings as
errors, dependency lock hygiene and audit, formatting, Sobelow with no
high-confidence findings, and 630 ExUnit tests with zero failures (seed 975103,
24.5 seconds). The upload-boundary regression discovered during the gate is
included in both the focused and full totals.

The exact Epic 5 worktree's focused 54-test suite passes with zero failures.
It covers the Script validator and interpreter, Simulation lineage and
immutability, built-in package schema/example, audit privacy, controller
journeys, exports, both locales, and viewer restrictions. The current worktree
passed `mix precommit` on 2026-07-18: compilation with warnings as errors,
dependency lock hygiene and audit, formatting, Sobelow with no high-confidence
findings, and 641 ExUnit tests with zero failures (seed 591892, 20.9 seconds).
`mix assets.build` also passes.

The exact Epic 6 worktree's 32-test focused Script, Quick-engine, and Run UI
suite passes with zero failures. Its provider-free durable benchmark executes
the complete 10,000-agent Population for 20 atomic rounds, writes 163 ordered
events and 21 checksummed snapshots per run, and produces identical result and
final-state hashes across all three observations. The maximum 34.451-second
observation is recorded only as a local p95 proxy; hosted performance
qualification remains open. The exact worktree passed `mix precommit` on
2026-07-18: compilation with
warnings as errors, dependency lock hygiene and audit, formatting, Sobelow with
only the repository's reviewed low-confidence findings, and 654 ExUnit tests
with zero failures (seed 88332, 21.2 seconds).

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

Epic 4 Population browser QA is captured in:

- `docs/screenshots/simulation-studio-epic4-2026-07-18/population-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic4-2026-07-18/population-en-mobile-390.png`.

The captures and live interaction pass cover the exact Population/Context
lineage, deterministic status, structured types and representatives, partial
import feedback, on-demand prose, English/Russian copy, keyboard disclosure
focus, and collapsed advanced mapping. The desktop document measured 1280 px
at a 1280 px viewport; the narrow document measured exactly 390 px at a 390 px
viewport. Neither pass reported horizontal overflow or console warnings.

Epic 5 Script browser QA is captured in:

- `docs/screenshots/simulation-studio-epic5-2026-07-18/script-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic5-2026-07-18/script-en-mobile-390.png`;
- `docs/screenshots/simulation-studio-epic5-2026-07-18/script-ru-desktop.png`.

The live pass created a real provider-free Simulation, inspected the active
Script, verified the two-round/ten-representative result, checked exact Run-
checkpoint values, and archived the QA record afterward. The desktop document
measured 1,280 px at a 1,280 px viewport; the narrow document measured exactly
390 px at a 390 px viewport. The pass found and corrected English derived clock,
unit, policy, and metric labels in the Russian view. Final English/Russian DOM,
console, focusable controls, and both widths reported no overflow or browser
warnings.

Epic 6 Run browser QA exercised a real provider-free 5,000-agent, 12-round Run
from start through automatic progress refresh and completion, then repeated and
canceled a second Run before its first committed round. English and Russian
outcomes, progressive technical disclosure, keyboard focus, terminal actions,
and plain-language recovery copy were inspected. At 1280 px and at a 390 px
viewport, the document width matched the viewport exactly, no horizontal
overflow occurred, and the console remained free of warnings and errors. The
temporary QA Simulation was archived afterward.

Epic 7 Run-budget browser QA created and completed a real provider-free
5,000-agent, 12-round Run. It inspected honest unknown-price behavior,
estimated runtime, hard caps, the collapsed model-route editor, the active and
completed budget-progress strips, exact Quick `0 made · 0 left` simulation
decisions, and final usage persistence in English and Russian. At 1,280 px and
390 px, document width matched viewport width exactly. The model disclosure had
a visible 2 px keyboard-focus outline; the browser console reported no warnings
or errors. The pass raised fragile micro-text sizes while preserving the quiet
hierarchy, and archived its temporary QA Simulation afterward.

Epic 8 Balanced browser QA created a real 5,000-agent, 12-round Simulation,
configured a local structured mock route, observed durable progress from 0 to
7 to 12 rounds, and completed an exact recorded-decision replay. The original
Run recorded 80 new model decisions, 93 signature reuses, 485 covered agents,
and zero fallbacks; the exact replay recorded zero new model decisions and 173
recorded-decision reuses. English and Russian lineage, budget, replay, and
fresh-run copy were inspected. At 1,280 px and 390 px, document width matched
viewport width exactly, the console remained free of warnings and errors, and
keyboard focus was visible. Browser review also corrected singular agent copy
and raised mobile navigation, locale, back, and replay targets to 44 px. The QA
Simulation was archived and the temporary provider removed. Evidence is in:

- `docs/screenshots/simulation-studio-epic8-2026-07-18/balanced-complete-desktop.png`;
- `docs/screenshots/simulation-studio-epic8-2026-07-18/balanced-exact-replay-mobile.png`;
- `docs/screenshots/simulation-studio-epic8-2026-07-18/balanced-exact-replay-mobile-trace.png`;
- `docs/screenshots/simulation-studio-epic8-2026-07-18/balanced-exact-replay-mobile-actions.png`.

Epic 9 Results browser QA reused the real completed 5,000-agent Balanced Run
and its exact replay, generated validated English and Russian Report versions
through the actual interface, and inspected deterministic Analysis, exact
lineage, report history, regeneration, evidence references, validation copy,
and exports. The desktop viewport was 1,280×900; the narrow viewport was
390×844. Document width matched viewport width, all mobile report controls
measured 44 px, keyboard focus had a visible 2 px outline, reduced-motion rules
were present, and the final console had zero warnings or errors. The pass also
localized global flash titles and corrected English and Russian evidence-count
grammar. The QA Simulation was archived and its temporary provider disabled.
Evidence is in:

- `docs/screenshots/simulation-studio-epic9-2026-07-18/analysis-report-en-desktop-top.png`;
- `docs/screenshots/simulation-studio-epic9-2026-07-18/analysis-report-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic9-2026-07-18/analysis-report-ru-mobile-top.png`;
- `docs/screenshots/simulation-studio-epic9-2026-07-18/analysis-report-ru-mobile.png`.

Epic 10 Observatory browser QA reused that same completed 5,000-agent,
12-round Balanced Run and its exact replay. It exercised all three lenses,
semantic zoom, the on-demand Agent inspector, keyboard tab and timeline
controls, direct comparison, preserved Run selection across locale changes,
English/Russian derived labels, visible focus, 390 px reflow, and an effective
320 px high-zoom layout. The final console reported no warnings or errors.
Evidence is in:

- `docs/screenshots/simulation-studio-epic10-2026-07-18/observatory-state-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic10-2026-07-18/observatory-flow-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic10-2026-07-18/observatory-compare-ru-mobile.png`;
- `docs/screenshots/simulation-studio-epic10-2026-07-18/observatory-explain-ru-mobile.png`.

Epic 11 portability browser QA created a real provider-free 48-agent,
three-round completed Run and reviewed Simulation Pack import, Simulation Pack
export, the manual external-model handoff, and Run Pack export in English and
Russian. At 1,280×900 and 390×844, document width matched viewport width. All
new primary controls measured exactly 44 px high, keyboard disclosure focus had
a visible 2 px outline, duplicate IDs were absent, and the final browser console
reported no warnings or errors. The review also raised new explanatory and
option text above the inherited micro-copy scale and kept raw-source inclusion
behind deliberate progressive disclosure. Development-only live reload remains
compatible with the secure frame policy while production/test builds retain
`frame-src 'none'`. Evidence is in:

- `docs/screenshots/simulation-studio-epic11-2026-07-18/import-simpack-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic11-2026-07-18/import-simpack-ru-mobile.png`;
- `docs/screenshots/simulation-studio-epic11-2026-07-18/portability-build-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic11-2026-07-18/portability-build-ru-mobile.png`;
- `docs/screenshots/simulation-studio-epic11-2026-07-18/run-pack-en-desktop.png`;
- `docs/screenshots/simulation-studio-epic11-2026-07-18/run-pack-en-mobile.png`.

The exact-worktree aggregate Quick-engine baseline is recorded in
`docs/benchmarks/2026-07-18-quick-engine-10k.json`. On the recorded arm64
environment, ten measured 10k-population runs after two warmups produced a
0.236 ms p50 and 0.362 ms p95, conserved all 10,000 agents, made zero provider
calls, and recorded 40,000 deterministic pattern decisions over four rounds.
This measures the compact existing cohort engine; the future general Script
engine must earn its own 10k result.

## Known incompatibilities and open decisions

- Context, Population, Script, model routes, budgets, deterministic Quick
  execution, and Balanced replay lineage are durable and portable. Simulation
  Packs are deterministic transport artifacts rather than duplicate persisted
  rows.
- Normal Blueprint navigation is limited to Simulations, Blueprints, and
  Settings. Operations is role-gated to system administrators and workspace
  owners/administrators.
- Current SimLab lifecycle and terminology are Decision Replay-oriented.
- Legacy scenarios remain Decision Replay compatibility inputs; Blueprint
  Studio execution uses the general declarative Script and neutral Run profile.
- Balanced has bounded selective execution, immutable decision provenance, and
  exact recorded-decision replay. Deep remains experimental and disabled.
- Analysis, claim-validated Report regeneration, `.hydra-run`, and redacted
  export policy are complete. A custom Report Blueprint editor remains a later
  governance extension rather than a controlled-pilot requirement.
- English/Russian copy and locale persistence are established across Blueprint,
  Simulation, Context, Population, Script, Run, Analysis, Report, and
  Observatory surfaces. Arbitrary provider prose remains recorded evidence and
  is not silently translated.
- Full snapshots intentionally favor exact recovery over compact storage;
  hosted retention, compression, and codec evolution need qualification before
  public launch.

## Remaining release gates

Internal alpha, controlled pilot, hosted beta, and enterprise-private gates are
tracked in sections 26 and 27 of the governing specification. No Blueprint-
first gate is claimed complete until its exact current-worktree evidence is
recorded here.
