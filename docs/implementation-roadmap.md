# Hydra Agent Implementation Roadmap

This is the continuation plan after the first public `hydra-agent` snapshot.
Hydra Agent is now a Phoenix/LiveView + OTP runtime foundation with
workspace-scoped agents, providers, tools, policies, runs, approvals, memory,
knowledge graph state, governed loops, usage, budgets, evals, webhooks, audit
export, starter packs, supervised run workers, and a first LiveView control
plane.

The next stage is not to rebuild the old Hydra-X product. It is to make Hydra a
mission-first, evidence-first agent runtime: long-lived agents, durable
orchestration, explicit policy gates, inspectable memory, provenance-backed
knowledge, repeatable evals, and an operational UI that exposes the Elixir/OTP
advantage without becoming an Erlang debugger.

## Direction Locked

- Use `Mission` as the user-level work object and `Run` as the durable execution
  attempt. Mission context, success criteria, team, permissions, budget, and
  start mode are persisted on the mission and copied into each run plan for
  traceability.
- Keep V1 LiveView/Tailwind first. JavaScript graph islands are allowed for
  focused visualizations after table/list views and data contracts are stable.
- Pursue selective Hermes parity. Match features that strengthen Hydra's runtime
  thesis: skills, memory, session search, cron/automations, tool bundles,
  protocol endpoints, model/provider visibility, sandboxing, and gateway health.
  Do not clone Hermes' full CLI/platform/plugin sprawl into V1.
- Treat persisted events as the source of truth. PubSub is for live updates, not
  for state that disappears on refresh.
- Keep the core runtime neutral. Domain-specific workflows belong in agent packs,
  skills, templates, or workspace graph types.
- Treat Loop as the reusable operating program, Mission as the operator-facing
  objective, and Run as the durable execution attempt.

Reference plans:

- [`docs/management-interface.md`](management-interface.md)
- [`docs/hermes-gap-review.md`](hermes-gap-review.md)
- [`docs/post-v1-gap-audit.md`](post-v1-gap-audit.md)
- [`docs/runtime-v1.md`](runtime-v1.md)

## Current Baseline

Already implemented:

- Phoenix app with LiveView/Tailwind control plane at `/control`.
- Runtime schemas and contexts for workspaces, agents, providers,
  conversations, turns, runs, run steps, run events, and tool policies.
- Supervised run workers, leases, stale lease recovery, pause/resume/cancel, and
  approval queues.
- Provider adapters for mock, OpenAI-compatible, Anthropic, and Ollama.
- Provider routing, fallback, normalized usage, true OpenAI-compatible SSE
  streaming, and a provider-independent delta callback path.
- Built-in tools: knowledge search/read/write, relationship creation, source
  ingest, artifact record, HTTP fetch, shell command, file list/read/write, noop.
- Least-privilege authorizer with side-effect classes and allowlists for
  network, shell, and filesystem access.
- Neutral knowledge graph seed types and evidence-oriented relationships.
- Skills lifecycle, starter agent packs, pack import/export, automations,
  webhooks, audit export, doctor checks, usage ledger, budgets, safety events,
  eval suites/cases/runs/results.
- `/control` now keeps orchestration/state handling in the LiveView and renders
  its dashboard panels through focused function components, preserving current
  operator actions while making the management shell easier to split.
- Agent Directory and Agent Detail now exist under `/control/agents`, backed by
  real workspace data for agent profiles, model routes, scopes, skills, tool
  policies, supervised runs, and assigned steps.
- Memory Studio now exists under `/control/memory` with workspace-scoped search
  and status filters, pending proposal editing/review, durable memory
  inspection, durable status/confidence/importance controls, archive actions,
  conflict signals from contradictory graph relationships, review/edit/archive
  history, dry-run curation signals, and configurable-threshold bulk
  low-confidence archival with operator provenance. It can also resolve
  duplicate active/verified memory titles by keeping the strongest canonical
  memory and archiving lower-ranked duplicates with provenance.
- Graph Workbench now exists under `/control/graph` with workspace-scoped node
  type/status filters, relationship type filters, provenance text filtering,
  relationship labels backed by graph edges, inline node relationship in/out
  lists, source-run provenance links, node status/confidence/importance edit
  controls, relationship confidence/provenance controls with JSON validation,
  and bulk verification of filtered draft/active graph nodes with review
  metadata. Filtered relationships can also be bulk reviewed with confidence and
  provenance audit metadata.
- Runtime Operations now exists under `/control/runtime` with queue pressure,
  worker summaries, stale lease detection, provider route visibility, runtime
  incidents, node status, and supervisor topology.
- Tools And Protocols now exists under `/control/tools` with built-in tools,
  bundles, a policy editor with dangerous-posture warnings, tool policies, MCP
  servers, webhook gateways, env refs, allowlists, health/error status, and
  protocol status summaries.
- First-class Mission records now back Mission Control. The composer captures
  success criteria, context, team, permissions, budget, deadline, priority, and
  start mode. Mission starts create lineage-linked runs, and mission status
  rolls up from run state.
- Credential pools now have per-key items with request/failure counters,
  cooldowns, and health-aware provider routing before provider fallback.
- File and shell side effects now create DB-backed checkpoint records when run
  context is available. Checkpoints support run-scoped listing, diff preview,
  restore, Run Detail controls, and workspace-scoped API routes.
- Agent Studio now provides a real workspace surface for sandbox prompts,
  draft memory-proposal mode, live provider calls, raw request/response
  inspection, and eval-suite execution without creating durable chat turns in
  sandbox mode.
- Agent Studio now includes Web Agent Rooms: shared multi-agent transcripts,
  coordinator fallback routing, `@mention` routing, pending multi-agent
  response proposals with explicit approval controls, room member management,
  transcript export, Telegram delivery error/retry controls, and a guided agent
  builder that previews and creates agent profiles plus matching tool policies
  from presets.
- Telegram room bindings now provide the first messaging gateway MVP. Incoming
  Telegram updates are deduplicated by external message id, mapped into a room
  transcript, routed through the same `AgentChat` path as web messages, and
  optionally delivered back through env-backed bot token refs with persisted
  delivery cursors and visible retryable errors.
- Run trace export now includes mission/lineage, steps, events, safety events,
  usage, checkpoints, run-provenance knowledge nodes, memory nodes, artifact
  nodes, and graph relationships.
- Workspace-scoped API routes now verify resource ownership for missions, runs,
  providers, credential pools, tool policies, checkpoints, and knowledge graph
  detail/mutation paths. Production config disables capability-only policy
  fallback by default.
- The `/control/*` management pages now share a reusable LiveView shell header
  with workspace switching and stable navigation across Mission, Agents,
  Memory, Graph, Skills, Runtime, and Tools surfaces.
- Skills Registry and Skill Detail now exist under `/control/skills`, with
  workspace/status filtering, lifecycle controls, owning agent/source run
  visibility, required tools, scopes, eval metadata, owner-agent usage, attached
  eval run reports with failure drill-downs, proposal editing, activation
  readiness cues, validated raw JSON/map editing for advanced metadata, version
  history with changed-field diffs, eval run comparisons, activation override
  reporting, and provenance inspection. The registry summarizes thresholded,
  passing, blocked, and overridden skills across the workspace. Skills with
  declared eval thresholds are activation-gated until the latest attached eval
  run meets the threshold unless an operator records an explicit activation
  override with provenance.
- V4 skill learning records now track usage events and improvement proposals.
  Completed multi-tool runs can create governed skill proposals, safe read-only
  skills can auto-activate when confidence/eval policy passes, dangerous skills
  remain draft for operator review, and the Skill Registry surfaces draft
  improvement proposals plus observed usage counts. The loop now also supports
  explicit refine/prune proposals, generated per-skill eval suites, and an
  idempotent standard skill pack for common run triage, repository review,
  research synthesis, memory curation, and handoff workflows.
- The learning worker now scans successful conversation and room transcripts,
  not only runs. Hydra can draft governed skills from arbitrary chats,
  generate real-example regression eval cases from source turns/messages, and
  run safe read-only skill experiments that compare variants and draft a
  winning refinement.
- Project-local code skills now use a Hermes-compatible `SKILL.md` directory
  shape under `.hydra/skills/<slug>` with optional `references/`, `templates/`,
  `scripts/`, and `assets/` files. Existing Hermes-style skill directories can
  be imported through the same durable skill/provenance path. Execution goes
  through the approval-sensitive `project_skill_run` tool rather than bypassing
  Hydra's policy system.
- Skill import/export now supports an Agentskills-style Markdown path backed by
  durable skill records and version history.
- V4 tool coverage now includes policy-gated browser intents, vision input
  validation, artifact-backed image/TTS generation requests, bounded local code
  execution, and multi-model consensus. These tools are exposed through named
  bundles and the same authorization path as existing tools.
- Run Detail can draft an idempotent proposed skill from a run, preserving
  source run, owner agent, observed tools, generated review instructions, and
  provenance for operator review in Skill Detail.
- Run Detail can draft an idempotent memory proposal from a run, preserving
  source run, supervisor agent, observed steps, evidence, and provenance for
  operator review in Memory Studio.
- Workspace benchmark reports aggregate eval suites by benchmark category and
  expose latest suite quality plus category pass-rate summaries through API.
  Standard V1 benchmark suites can be seeded idempotently for orchestration,
  safety, recovery, memory recall, cost, and latency.
- Automations now exist under `/control/automations`, with workspace/status
  filtering, agent routing visibility, cron/next/last run metadata, last error
  inspection, structured failure detail, last output references, attention
  filtering, clear-error triage, pause/resume/archive controls, trigger-now
  execution, inline create/edit forms, validation errors, schedule previews,
  matching safety policy summaries, recent run history with conversation
  metadata, run-linked execution history with Run Detail links, five-run
  schedule previews with UTC cross-checks, recurring execution analytics, and
  fail-closed timezone validation plus setup documentation for unsupported
  timezone databases.
- Governed Loops now exist as workspace-scoped operating programs with manual
  or cron triggers, DB leases, loop-linked runs, strict JSON decisions,
  optional verifier agents, state patches, no-progress detection, budget and
  runtime guardrails, neutral recipes, API routes, `/control/loops`, run-index
  loop filtering, run-detail lineage badges, audit export, and trace export.
- Agent packs now expose a generated JSON Schema through API and structured
  validation details with stable field/code/message metadata while preserving
  existing human-readable error strings.
- Agent pack import now supports explicit `create`, `dry_run`,
  `update_existing`, and `clone` modes so operators can validate, preview,
  update, or fork agents without accidental overwrites.
- JSON APIs now support optional env-backed Bearer authentication for
  deployments. Local development remains open by default, while enabled auth
  fails closed on missing token refs or invalid credentials.
- Tests currently pass through `mix precommit` with local database setup.

## Definition Of A Solid V1

V1 is ready when a user can clone the repo, configure providers, create or
import specialized agents, run mission-style and loop-style work safely,
inspect what happened, review what Hydra learned, and compare quality over time.

Required acceptance criteria:

- `mix precommit` passes from a clean checkout with documented database setup.
- Run workers have DB-backed tests for success, approval wait, policy block,
  failure, pause, cancel, and stale recovery.
- Streaming provider paths persist exactly one assistant turn, record usage once,
  and surface provider failures without creating misleading final turns.
- Mission Control and Run Detail answer: what is running, why, under which
  policy, what changed, what needs human attention, and what evidence backs it.
- Memory and graph writes are visible, scoped, provenance-backed, and reviewable.
- Agent packs and skills can be imported, tested, activated, exported, and
  audited without losing policy intent.
- Tools and protocol endpoints are least-privilege, auditable, timeout-bounded,
  and policy-gated.
- Evals include workspace benchmark report aggregation and seeded standard V1
  benchmark content for orchestration, safety, recovery, memory recall, cost,
  and latency. Scoring now covers contains, exact tool decisions, JSON-path
  assertions, graph assertions, policy assertions, latency thresholds,
  token-cost thresholds, and model-graded rubric-style cases.

## Phase 1: Runtime Spine

Goal: make orchestration boringly reliable before expanding surface area.

Tasks:

- Add DB-backed fixtures that create realistic workspaces, agents, policies,
  runs, and steps.
- Test worker behavior for completion, approval wait, policy block, tool
  failure, paused runs, canceled runs, stale lease recovery, and duplicate lease
  prevention.
- Add worker status introspection for active PID, current step id, last
  heartbeat, stop reason, and run state summary.
- Make stop semantics status-aware: user stop does not mark a run failed, cancel
  terminates the worker and persists cancel state, and crashes write safety
  events while leaving recoverable state.
- Ensure critical state changes are persisted and evented in one transaction
  before broadcast.

Acceptance:

- Runner and worker integration tests fail if state transitions skip event
  logging.
- Stale lease recovery is deterministic in tests.
- Canceling a run cannot leave an active worker executing that run.

## Phase 2: Streaming And Trace Contract

Goal: make provider streaming native, resumable from persisted state, and useful
to the control plane.

Tasks:

- Extend SSE coverage beyond `openai_compatible` when other providers need it.
- Normalize stream events into provider-independent `delta`,
  `tool_call_delta`, `usage`, `finish`, and `error` shapes.
- Persist exactly one final assistant turn per streamed response and record
  usage once.
- Extend run events into a trace-oriented contract for LLM calls, tool calls,
  approvals, memory operations, graph operations, artifacts, worker lifecycle,
  failures, and recovery.
- Add API tests for `/api/v1/conversations/:id/stream` and LiveView tests for
  reconnecting from persisted timeline state.

Acceptance:

- Stream failures write safety events and do not create misleading final turns.
- Critical events survive refresh and can rebuild the visible timeline.
- Hidden chain-of-thought is never exposed; UI shows observable summaries,
  selected constraints, tool rationale, and cited evidence.

## Phase 3: Management Interface MVP

Goal: build the cockpit: Mission Control, Run Detail, Agent Directory, and
approval-first operations.

Tasks:

- Replace the single `/control` surface with a LiveView app shell and routes for
  dashboard, runs, agents, memory, graph, skills, tools, policies, runtime, and
  settings. The first reusable shell now covers the implemented `/control/*`
  pages, while skills, policies, settings, and deeper run indexes remain future
  routes.
- Build Mission Control from real workspace data: active missions/runs, waiting
  approvals, blocked work, recent learning, recent artifacts, budget pressure,
  provider/tool health, and runtime heartbeat.
- Build Run Detail with header controls, step list, event timeline, approval
  cards, artifacts, metrics, worker status, and developer raw JSON.
- Build Agent Directory and basic Agent Detail using existing agent profiles,
  model routes, skills, memory scopes, tool policies, and runtime state. Initial
  LiveView routes now cover the directory and detail views.
- Continue extracting shared UI components for status pills, agent avatar
  stacks, event timeline items, approval cards, budget bars, context chips, and
  inspector drawers. The first `/control` panel split and reusable page shell
  are complete.

Acceptance:

- An operator can find every pending approval from the dashboard.
- A failed run can be debugged without reading raw logs.
- The UI remains LiveView/Tailwind only except for optional focused graph hooks.

## Phase 4: Agent Rooms And Guided Creation

Goal: make Hydra feel like agentic team software, not a list of isolated bots.

Completed:

- Add workspace-scoped rooms, members, messages, and channel bindings.
- Route room messages by `@mention`, coordinator fallback, and priority fallback.
- Keep each responding agent on its own hidden durable room conversation so
  provider routing, usage, memory recall, and safety records still work.
- Add Agent Studio room UI for room creation, member management, shared chat,
  Telegram binding creation, and guided agent creation.
- Add API routes for rooms, room messages, members, channel bindings, agent
  builder preview/create, and Telegram webhook ingress.
- Add explicit approval controls for pending multi-agent response proposals,
  transcript export, Telegram delivery error visibility, gateway retry controls,
  idempotent Telegram update handling, and policy-template previews before
  guided agent creation.

Next acceptance hardening:

- Add room search and transcript filtering.
- Add richer builder presets with skill attachment and eval readiness checks.
- Add per-message delivery receipts if multiple external gateways are enabled.

## Phase 4: Learning Loop

Goal: make memory, graph facts, and skills visible before they become trusted.

Tasks:

- Add Memory Studio with search/filter shell, memory detail, proposal queue,
  conflict cards, provenance links, and approve/edit/reject/archive actions. The
  first Memory Studio route now covers search/status filtering, proposal
  editing/promote/reject, durable memory status/confidence/importance controls,
  contradiction conflict cards, review/edit/archive history, archive, and
  curation signals with configurable-threshold bulk low-confidence archival and
  duplicate-title resolution.
- Add memory proposal flow for agent-generated durable memory. Approved memory
  becomes searchable; rejected memory is retained as feedback to reduce repeats.
- Add graph explorer MVP with search-first table/detail views, fact cards,
  provenance, relationship in/out lists, confidence/status controls, and a
  small neighborhood graph only after query contracts stabilize. The first Graph
  Workbench route now covers node, relationship, and provenance filtering plus
  node status/confidence/importance and relationship confidence/provenance
  controls.
- Add Skills Registry and Skill Detail for lifecycle, tests, usage, versions,
  required tools, permissions, and proposal review. The first Skills route now
  covers workspace/status filtering, lifecycle transitions, owner/source
  visibility, required tools, scopes, eval metadata, owner-agent usage,
  attached eval run reports, version history, and provenance.
- Add autonomous skill learning records for usage events and improvement
  proposals. The first V4 path now proposes skills from completed multi-tool
  runs, records usage evidence, auto-activates safe read-only skills when
  confidence/eval policy passes, keeps dangerous skills in draft, and exposes
  proposals through API plus the Skill Registry. Refinement, pruning, generated
  eval suites, and standard skill-pack seeding are now first-class review
  actions.
- Add skill Markdown import/export so workspace skills can seed and exchange a
  larger ecosystem without bypassing Hydra's lifecycle and activation gates.
- Add "create memory from run" and "create skill from run" as proposal flows,
  not silent durable writes. Create-skill-from-run now exists as a Run Detail
  proposal action, and create-memory-from-run now creates pending Memory Studio
  proposals.

Acceptance:

- Every durable fact and memory can trace back to source run, event, span, or
  artifact.
- Memory and graph writes can require approval by policy.
- Generated skills start as `proposed` and must be tested before activation
  unless an operator explicitly bypasses that gate or the safe auto-activation
  policy passes with eval evidence.

## Phase 5: Tools, Protocols, And Policy

Goal: add power without turning tools into an unsafe escape hatch.

Tasks:

- Add named tool bundles as policy templates over registered tools and
  side-effect classes, inspired by Hermes toolsets but enforced through Hydra
  policies. Initial built-in bundles now expand to explicit policy grants and
  are visible through API and `/control`.
- Add V4 breadth bundles for browser, vision, image generation, TTS, code
  execution, and multi-model consensus. MVP tools are intentionally
  artifact-backed, output-bounded, and policy-gated rather than open-ended
  plugin execution.
- Define MCP server records with env-backed config, trust level, transport,
  include/exclude filters, resource/prompt utility toggles, timeout, approval
  sensitivity, and health status. Initial validated records now exist through
  API, `/control`, and audit export.
- Add MCP execution audit events with redacted inputs/outputs. HTTP MCP
  `tools/call` execution now writes redacted `mcp.call.*` run events. Stdio
  MCP `tools/call` execution is now available as a bounded JSON-RPC line
  exchange with workspace-root cwd fencing, declared env refs, timeout handling,
  and the same redacted audit trail. HTTP and stdio MCP discovery can now
  refresh `tools/list`, optional `resources/list` and `prompts/list`, health
  status, checked time, and redacted error metadata from Tools And Protocols.
  SSE MCP transport can execute JSON-RPC tool calls from event-stream responses
  with the same audit path. Stdio MCP servers can opt into supervised
  persistent sessions with `config.persistent`, reusing a subprocess across
  calls, expiring idle sessions, and exposing operator-visible status plus an
  explicit stop lifecycle from Tools And Protocols.
- Add Tools/Protocols page covering built-ins, MCP servers, webhooks, future
  ACP/A2A placeholders, secrets/env refs, allowlists, health checks, and recent
  failures. The first Tools And Protocols route now covers built-ins, bundles,
  policies, MCP, webhooks, env refs, allowlists, health/error status, and
  protocol summaries, including persistent stdio session status and stop
  controls.
- Improve file and shell tools with size limits, binary detection, write
  conflict behavior, output truncation metadata, and environment allowlists.
  Initial hardening now covers binary read refusal, bounded reads, create-new
  write conflicts, SHA preconditions, shell output truncation metadata, and
  explicit shell environment variable allowlists enforced by policy and by the
  shell tool itself.

Acceptance:

- MCP calls are less privileged than local shell, not more privileged.
- Every external action has an authorization decision and audit trail.
- Untrusted tools cannot silently gain broad filesystem, shell, network, or
  memory-write access.

## Phase 6: Runtime Console And Operations

Goal: surface OTP reliability as product value.

Tasks:

- Add Runtime page for node status, active workers, queues, recovery incidents,
  restart counts, recent crashes, process health, and supervisor topology. The
  first Runtime Operations route now covers node/process status, workers,
  queues, stale leases, runtime incidents, providers, and supervisor topology.
- Add provider/model panels for health state, model list, last failure, fallback
  route, live model switching hooks, and token/cost summaries.
- Add automation/cron UI for scheduled prompts, profiles/agents, next run, last
  run, last error, pause/resume, and trigger-now. The first Automations route
  now covers these operator controls, trigger-now execution, inline create/edit,
  validation errors, five-run schedule previews with UTC cross-checks,
  structured failure detail, last output references, matching safety policy
  summaries, recent run history with conversation metadata, and run-linked
  execution history with Run Detail links and recurring execution analytics.
  Cron next-run computation uses the selected timezone when the configured
  timezone database supports it and rejects unsupported zones instead of
  silently treating them as UTC; runtime docs explain how to configure a full
  timezone database.
- Add deployment docs for local dev, Docker Compose, production env vars,
  backups, migrations, dashboard binding, and dangerous defaults.
- Add telemetry events for provider calls, tool calls, run transitions, approval
  decisions, budget blocks, safety events, and worker lifecycle.

Acceptance:

- Operators can see bottlenecks instead of guessing.
- Dangerous defaults are harder to enable accidentally than to leave disabled.
- Production setup does not require reading source code to discover env vars.

## Phase 7: Agent Packs, Skills, And Authoring

Goal: make specialized agents easy to create, share, audit, and evolve.

Tasks:

- Add pack schema versioning, migration helpers, JSON Schema generation, and
  stable machine-readable validation errors. Pack V1 now has generated JSON
  Schema and structured validation details for authoring/API clients.
- Add pack import modes: dry run, create, update existing, clone as new agent.
  API import now supports all four modes.
- Add pack export with optional redaction of internal ids.
- Add Agent Studio sandbox modes: no durable writes, memory proposals only, and
  live durable writes. Default to no durable writes.
- Add skill testing flow with attached eval suite, examples, thresholds, usage
  stats, and activation controls.

Acceptance:

- Users can define planner/researcher/builder/reviewer-style agents without
  changing Elixir code.
- Pack round trips preserve model route, skills, memory scopes, knowledge
  scopes, autonomy, permissions, and approval intent.
- Agent Studio never hides whether a test can write durable state.

## Phase 8: Evals And Benchmarks

Goal: answer "is Hydra better than before?" with reports, not vibes.

Tasks:

- Add eval case types for contains, JSON path, exact tool decision, graph
  assertion, policy assertion, latency threshold, cost threshold, and
  model-graded rubrics. V1 now supports contains, exact tool decisions,
  JSON-path assertions, graph assertions, policy assertions, latency thresholds,
  token-cost thresholds, and rubric-style model-graded cases.
- Add benchmark suites for chat quality, tool-use correctness, approval safety,
  memory recall, planner decomposition, worker recovery, provider fallback, and
  parallel read execution. The first standard V1 benchmark seed pack now covers
  orchestration, safety, recovery, memory, cost, and latency suites with a mix
  of text, JSON-path, rubric, policy, graph, latency, and token-cost scoring.
- Add comparison reports for agent pack vs pack, provider route vs route, commit
  vs commit, and prompt/skill version vs previous version.
- Persist eval environment metadata: commit sha, provider route, pack version,
  runtime config summary, cost, and latency.

Acceptance:

- Hermes comparisons can be reproduced as Hydra evals where the behavior is in
  selective-parity scope.
- Benchmark reports are visible in the control plane and available through APIs.

## Phase 9: Security And Threat Model

Goal: make security a central runtime feature, not a checklist at the end.

Tasks:

- Write threat models for tool execution, provider secrets, webhooks, agent
  memory poisoning, prompt injection through sources, shell/filesystem/network
  actions, and MCP.
- Add redaction helpers for logs, safety events, trace payloads, and audit
  export.
- Add request authentication for APIs beyond local development. Optional
  env-backed Bearer API auth is now available and test-backed.
- Add rate limits for webhooks and high-cost endpoints.
- Add config validation at boot for provider env refs, webhook token env refs,
  database URL, dashboard binding, and dangerous defaults.

Acceptance:

- Operators can audit who or what caused every external side effect.
- Raw sensitive payloads are redacted by default.
- Security posture is documented and test-backed.

## Recommended Next Batch

Build on the now-running runtime spine and first management shell:

1. Build Mission Studio and a searchable run/mission index.
2. Add mission success criteria, start modes, team, permission presets, priority,
   deadline, budget, and parent/child lineage in run metadata.
3. Add trace export from Run Detail as a persisted-state JSON bundle.
4. Then build Agent Studio with safe sandbox modes and eval-case execution.

This sequence keeps filling Hermes-parity gaps while preserving Hydra's
evidence-first runtime shape.
