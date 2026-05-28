# Hermes Gap Review

This review compares Hydra Agent against Nous Research's Hermes Agent as of the
research pass on 2026-05-25. Hermes is useful as a reference because it has a
long-lived agent loop, memory, skills, gateways, cron, MCP, multiple execution
environments, and a local web dashboard. Hydra should not copy it wholesale.
Hydra's advantage should be durable OTP orchestration, strict policy, provenance,
operator visibility, and eval-backed improvement.

References:

- Hermes README: https://github.com/NousResearch/hermes-agent/blob/main/README.md
- Hermes toolsets reference: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/toolsets-reference.md
- Hermes MCP config reference: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/mcp-config-reference.md
- Hermes web dashboard docs: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/web-dashboard.md
- Hermes v0.14.0 release notes: https://github.com/NousResearch/hermes-agent/blob/main/RELEASE_v0.14.0.md

## Parity Strategy

Use selective parity:

- **Match** capabilities that strengthen Hydra's mission-control runtime:
  skills, memory, session search, cron/automations, tool bundles, MCP registry,
  model/provider visibility, approval UX, sandbox/trust indicators, and
  dashboard operations.
- **Exceed** Hermes where Hydra's architecture is stronger: durable runs,
  leases, OTP supervision, event timelines, graph provenance, strict policy,
  audit export, evals, and operator control.
- **Defer** broad platform sprawl: many chat adapters, dashboard plugin
  marketplace, local OpenAI proxy, full terminal backend matrix, bundled media
  generation ecosystem, skins/themes, and achievement-style dashboard plugins.

## Feature Comparison

### Agent Loop And Sessions

Hermes has chat sessions, session search, live handoff between models/profiles,
subagent sessions linked to parents, and cross-platform conversation continuity.

Hydra has durable conversations and runs, but the run is the stronger control
object. Hydra should add:

- Run/conversation search with summaries and filters.
- Run-to-run fork/retry lineage in metadata before adding a missions table.
- Agent handoff events that preserve run context and are visible in the
  timeline.
- Parent/child run linkage for delegated work and subagents.

### Skills And Learning

Hermes has a large bundled skill library, optional skills, skill bundles, skill
usage analytics, skill config injection, autonomous skill creation, and curator
flows.

Hydra has durable skill records, starter agent packs, versions, activation
gates, and V4 learning records. Hydra should continue to deepen:

- Skill proposal review from completed runs. V4 now supports run-derived
  proposals, conversation/room-derived proposals, explicit refine/prune review,
  and standard skill-pack seeding.
- Skill tests/evals before activation. Threshold gates and safe auto-activation
  now exist, with generated per-skill eval cases and real transcript-derived
  regression examples available from the registry and API.
- Skill versioning and usage analytics. Versioning exists, and V4 usage events
  now back registry analytics.
- Skill bundles as pack-level or workspace-level install sets. The first
  standard workspace seed pack exists; marketplace-style discovery remains
  future work.
- Hermes ecosystem borrowing is now feasible through local `SKILL.md` directory
  imports. Hydra preserves Hermes' directory shape for project-local code
  skills while keeping durable DB lifecycle, eval gates, provenance, and
  policy-gated execution through `project_skill_run`.
- Safe autonomous skill experiments now compare read-only variants and draft the
  winning refinement instead of silently rewriting active skills.
- Curator-like review as an eval-backed operator workflow. V4 keeps dangerous
  skill changes in draft while allowing safe, read-only, eval-backed
  auto-activation.

### Memory

Hermes has persistent memory, background memory review, memory providers,
session search, user modeling, and profile-aware memory operations.

Hydra has a workspace knowledge graph and memory recall. Hydra should add:

- Dedicated memory proposal lifecycle with scope, source, confidence, conflict
  state, and rejected-memory feedback.
- Search and filters over memory/graph facts.
- Memory-source provenance chains from output to memory/fact to run event to
  source artifact.
- Optional provider-backed memory plugins only after local provenance semantics
  are stable.

### Tools And Toolsets

Hermes uses toolsets: named bundles such as file, terminal, web, browser,
memory, skills, delegation, code execution, cronjob, session search, and
platform-specific toolsets.

Hydra has registered tools and explicit policies. Hydra should add:

- Named tool bundles as policy templates, not as a bypass around policy. Initial
  built-in bundles now expand to explicit policy grants.
- Bundle visibility in agent profiles, packs, and Tools/Policies UI. Packs, API,
  and `/control` now expose the first bundle layer.
- Tool usage analytics and last-failure health.
- Clear distinction between registered tool, bundle, policy grant, and runtime
  authorization decision.
- V4 breadth tools now cover browser intents, vision input validation,
  artifact-backed image/TTS generation requests, bounded code execution, and
  multi-model consensus through normal tool policy.

### MCP And Protocols

Hermes supports configured MCP servers, generated MCP toolsets, include/exclude
filters, utility wrappers for resources/prompts, OAuth 2.1 PKCE, token
persistence, and package security checks.

Hydra should add:

- MCP server records with env-backed config, transport, trust level,
  include/exclude filters, timeout, and health status. The first registry layer
  now exists through API, `/control`, and audit export.
- MCP allowlists in tool policy. The built-in `mcp_call` tool now enforces
  active server records plus include/exclude filters before HTTP JSON-RPC
  execution.
- OAuth/token strategy after the basic server registry and audit path exist.
- MCP execution events with redacted inputs/outputs and approval decisions.
  HTTP execution now writes redacted `mcp.call.*` run events.
- Tools/Protocols UI for MCP, webhooks, and future ACP/A2A endpoints.

### Gateways And Platforms

Hermes supports many messaging gateways and shared slash commands across CLI and
platforms.

Hydra already has webhook gateways. Hydra should add:

- Gateway health and delivery status in Tools/Protocols.
- External message audit events before adding many adapters.
- A small gateway interface that lets future adapters target conversations,
  runs, approvals, and artifacts consistently.
- The first narrow Telegram MVP now targets Agent Rooms: inbound updates map to
  shared room messages, use normal agent routing/memory/provider paths, and can
  deliver replies through env-backed bot token refs with idempotent inbound
  handling, delivery cursors, visible errors, and retry controls.

Do not prioritize broad Discord/Slack/WhatsApp parity unless a specific
deployment requires it.

### Cron And Automations

Hermes has cron jobs with skills, profiles, gateway delivery, pause/resume,
trigger-now, and dashboard management.

Hydra has scheduled automations that run through agent chat. Hydra should add:

- Automations UI with next run, last run, last error, pause/resume, trigger-now,
  agent/profile, and delivery target.
- Tests that cron-triggered work uses the same policy, memory, usage, and safety
  paths as interactive work.

### Web Dashboard

Hermes has a local web dashboard for sessions, skills, cron, models, profiles,
logs, analytics, plugins, config, env, and chat.

Hydra should build a different dashboard:

- Mission Control and Run Detail first, not chat first.
- Memory/Graph Workbench as a first-class learning loop.
- Runtime Console for OTP workers, queues, crashes, restarts, and recovery.
- Tools/Policies as the trust boundary.
- LiveView/Tailwind by default, with focused JS graph islands only when needed.

Dashboard plugin extensibility is deferred.

### Models And Providers

Hermes supports live model switching, many providers, aggregator-aware fallback,
prompt caching, and model dashboards.

Hydra has provider configs, routing, fallback, usage, and budgets. Hydra should
add:

- Provider health, model list, fallback route, last failure, and cost/latency
  summaries in the UI.
- Live model switching only as an explicit run/conversation event that preserves
  context and audit trail.
- Prompt caching awareness later, after true streaming and usage accounting are
  stable.

### Sandboxes And Execution Environments

Hermes supports local, Docker, SSH, Singularity, Modal, Daytona, and Vercel
Sandbox terminal backends, plus lazy installation of heavy dependencies.

Hydra should add:

- Sandbox profile records or metadata for local workspace, container, remote,
  and future serverless backends.
- UI trust labels and policy constraints per sandbox.
- Docker/local first. Defer the broader backend matrix until tool policy,
  audit, and recovery semantics are proven.

### Observability And Evals

Hermes has logs, analytics, dashboard metrics, observability plugins, and usage
pricing. Hydra has a stronger opportunity through durable run events, safety
events, usage, budgets, and eval tables.

Hydra should add:

- Benchmark eval suites for orchestration, safety, recovery, memory recall,
  provider fallback, cost, and latency.
- Timeline and trace export.
- Optional external observability adapters after the internal event model is
  stable.

## V1 Match List

These Hermes-inspired capabilities are in V1 scope:

- Session/run search.
- Skill proposal, testing, activation, usage, and bundles.
- Memory proposal queue with provenance.
- Tool bundles mapped to policy.
- MCP registry with allowlists and audit events.
- Automations dashboard.
- Provider/model health and switching visibility.
- Approval buttons/cards in the web UI.
- Sandbox/trust labels.
- Runtime analytics for tokens, cost placeholders, latency, failures, and
  worker health.

## V1 Defer List

These are explicitly out of V1 unless a user requirement changes:

- Broad messaging platform parity.
- Dashboard plugin marketplace/extensibility.
- Full terminal backend matrix.
- Local OpenAI-compatible proxy for external tools.
- Achievement or skin systems.
- Media generation ecosystem parity.
- Autonomous skill/memory mutation without review.
- Remote agent interoperability beyond placeholders for ACP/A2A.

## Review Cadence

Refresh this review when:

- A Hydra phase completes.
- A Hermes release adds a feature that overlaps Hydra's runtime thesis.
- A user asks for a platform/protocol feature currently in the defer list.

Every adopted gap should become a roadmap item with tests or acceptance
criteria. Every deferred gap should state why Hydra is intentionally different.
