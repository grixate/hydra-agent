# Hydra Agent V1 Backlog

## Current Objective

Continue the Hydra-X separation until `hydra-agent` is a polished, competitive
agent runtime: secure by default, transparent as an orchestrator, fast under
OTP, easy to specialize through agent packs, inspectable through a mission-first
management interface, and measurable through evals.

## Definition Of Done For V1

- Runtime core is independent of the product-management app.
- Workspaces, agents, providers, tools, conversations, runs, steps, approvals,
  budgets, usage, safety, evals, skills, automations, webhooks, and audit export
  have coherent schemas and APIs.
- Built-in tools are least-privilege, allowlisted, timeout-bounded, and audited.
- Planner-worker orchestration is durable, inspectable, steerable, recoverable,
  and safe under pause/cancel/approval.
- Provider routing supports fallback, usage tracking, budget preflight checks,
  and a streaming/progress path for the control plane.
- The LiveView management interface shows mission control, run timelines,
  attention queues, agent state, memory proposals, graph provenance, tool
  policies, and runtime health.
- Starter packs validate and represent useful specialized agents.
- Operator-facing documentation matches the implemented runtime.
- `mix precommit` passes against a real local database.

## Completed Evidence

- `mix precommit` passes locally after starting repo-local PostgreSQL.
- Starter packs validate through `HydraAgent.AgentPack`.
- Runtime docs describe current schemas, APIs, policies, and next build order.
- Pure and DB-backed ExUnit tests run through the normal Phoenix test alias.
- Stream-capable chat broadcasts provider deltas through runtime PubSub and
  persists final assistant turns with normal usage accounting.
- OpenAI-compatible providers use true SSE transport with chunk-boundary parser
  coverage, usage events, finish events, and provider error handling.
- Run Detail has a first LiveView route at `/control/runs/:id` with ordered
  steps, runtime events, run-scoped safety events, approvals, and worker state.
- Memory proposals create draft `memory` nodes with `memory_proposal`
  provenance, can be promoted or rejected through API and `/control` with review
  rationale, and stay out of recall until promoted.
- `/control` surfaces recent graph relationships and provenance labels instead
  of only showing graph counts.
- Tool bundles exist as policy templates over registered tools, expand to
  explicit grants, are supported by agent packs and APIs, and are visible in
  `/control`.
- MCP server records exist as validated protocol registry entries with env refs,
  include/exclude filters, trust level, health state, audit export, and
  `/control` visibility. HTTP and bounded stdio MCP `tools/call` execution are
  available through `mcp_call` with approval gating, declared env refs, cwd
  fencing for stdio, and redacted `mcp.call.*` run events. HTTP and stdio MCP
  discovery can refresh `tools/list`, optional resources/prompts, health status,
  checked time, and redacted error metadata from Tools And Protocols. SSE
  transport can execute JSON-RPC tool calls from event-stream responses with
  redacted audit events. Stdio MCP servers can opt into supervised persistent
  sessions through `config.persistent`, reusing the same subprocess across
  calls with idle expiry, explicit stop lifecycle support, and operator-visible
  session status in Tools And Protocols.
- File and shell tools now include binary-read refusal, bounded reads,
  create-new write conflicts, SHA preconditions, and shell output truncation
  metadata. Shell commands now fail closed for environment variables unless a
  tool policy explicitly grants their names through `shell_env_allowlist`.
- `/control` rendering has been split into focused LiveView function components
  while preserving the existing run, worker, approval, memory, graph, tool, and
  MCP operator actions.
- Agent Directory and Agent Detail are available at `/control/agents`, showing
  agent profiles, model routes, autonomy, scopes, declared/durable skills,
  matching tool policies, supervised runs, and assigned steps.
- Memory Studio is available at `/control/memory`, showing pending proposals,
  editable proposal title/body/confidence/importance fields, durable memory
  search/status filters, durable status/confidence/importance controls,
  conflict signals from contradictory graph relationships, promote/reject
  review forms, archive actions, review/edit/archive history, and dry-run
  curation signals with configurable-threshold bulk low-confidence archival and
  audit metadata. Duplicate active/verified memory titles can be resolved in
  bulk by keeping the strongest canonical memory and archiving lower-ranked
  duplicates with provenance.
- Graph Workbench is available at `/control/graph`, showing node type/status
  filters, relationship type filters, provenance text filtering, and labeled
  relationship evidence with inline node relationship in/out lists and
  source-run provenance links. Operators can update graph node status,
  confidence, and importance, and tune relationship confidence/provenance from
  the workbench with JSON validation. Filtered draft/active graph nodes can be
  bulk verified with operator review metadata. Filtered relationships can be
  bulk reviewed with confidence and provenance audit metadata.
- Runtime Operations is available at `/control/runtime`, showing queue pressure,
  worker summaries, stale running leases, provider routes, runtime incidents,
  process/node status, and supervisor topology.
- Tools And Protocols is available at `/control/tools`, showing built-in tools,
  bundles, policy grants, MCP servers, webhook gateways, env refs, allowlists,
  health/error status, and protocol status summaries.
- `/control/*` management pages now share a reusable LiveView shell header with
  workspace switching and stable navigation across Mission, Agents, Memory,
  Graph, Skills, Automations, Runtime, and Tools surfaces.
- Skills Registry and Skill Detail are available at `/control/skills`, showing
  workspace/status filters, lifecycle controls, owning agents, source runs,
  required tools, scopes, eval metadata, owner-agent usage, attached eval run
  reports with failure drill-downs, proposal editing, activation readiness cues,
  validated raw JSON/map editing for advanced metadata, version history, and
  changed-field version diffs, eval run comparisons, and activation override
  reporting. The registry also summarizes thresholded, passing, blocked, and
  overridden skills across the workspace. Skills with declared eval thresholds
  cannot activate until the latest attached eval run meets the threshold unless
  an operator records an explicit activation override with provenance.
- Run Detail can draft an idempotent proposed skill from a run, preserving the
  source run, owner agent, observed tools, instructions, and provenance for
  review in Skill Detail.
- Run Detail can draft an idempotent memory proposal from a run, preserving the
  source run, supervisor agent, observed steps, evidence, and provenance for
  review in Memory Studio.
- Workspace benchmark reports aggregate eval suites by benchmark category,
  expose latest suite quality and category pass-rate summaries, and are
  available through `/api/v1/workspaces/:workspace_id/evals/benchmark`.
- Standard V1 benchmark suites can be seeded idempotently for orchestration,
  safety, recovery, memory recall, cost, and latency through
  `/api/v1/workspaces/:workspace_id/evals/benchmarks/seed`.
- Eval scoring now supports text contains, exact tool decisions, JSON-path
  assertions, graph assertions, policy assertions, latency thresholds,
  token-cost thresholds, and model-graded rubric-style cases, with scoring
  context recorded on results.
- Automations are available at `/control/automations`, showing workspace/status
  filters, agent routing, cron expressions, next/last run metadata, last error
  state, structured failure detail, last output references, attention filtering,
  clear-error triage, pause/resume/archive controls, trigger-now execution,
  inline create/edit forms, validation errors, five-run schedule previews with
  UTC cross-checks, matching safety policy summaries, recent run history with
  conversation metadata, run-linked execution history with Run Detail links,
  recurring execution analytics, and fail-closed timezone validation plus setup
  documentation for unsupported timezone databases.
- Agent packs now provide a generated V1 JSON Schema and stable structured
  validation details for API/import clients while preserving existing string
  validation messages.
- Agent pack import now supports explicit `create`, `dry_run`,
  `update_existing`, and `clone` modes for safer authoring and migration flows.
- JSON APIs now support optional env-backed Bearer authentication for
  deployments, with fail-closed behavior when enabled but misconfigured.
- Run cancellation attempts to stop the active supervised worker, and operators
  have an explicit worker stop endpoint.
- Agent pack import/export APIs preserve declared skills for round trips.
- Workspaces can idempotently seed neutral knowledge graph type definitions.
- Neutral graph seeds now include observation/entity/event and evidence-oriented
  relationships; source/artifact writes require provenance guardrails.
- A standard Phoenix LiveView/Tailwind control plane exists at `/control` with
  run controls, worker controls, and approval/rejection actions.
- The V1 plan now includes a mission-first management interface and selective
  Hermes gap review:
  - `docs/management-interface.md`
  - `docs/hermes-gap-review.md`

## Remaining High-Value Work

The complete continuation plan lives in
[`docs/implementation-roadmap.md`](docs/implementation-roadmap.md).
The post-V1 design/Hermes audit lives in
[`docs/post-v1-gap-audit.md`](docs/post-v1-gap-audit.md).

Highest-value remaining work:

No blocking continuation item is currently known. Future hardening can deepen
product polish, add external grader-provider routing for eval rubrics, and
expand benchmark coverage, but the V1 continuation checklist above is
implemented and test-backed.

## Next Batch

Continue from the reusable management shell and hardened runtime:

1. Build Mission Studio and a searchable run/mission index.
2. Add mission success criteria, start modes, team, permission presets, priority,
   deadline, budget, and parent/child lineage in run metadata.
3. Add trace export from Run Detail as a persisted-state JSON bundle.
4. Then build Agent Studio with safe sandbox modes and eval-case execution.
