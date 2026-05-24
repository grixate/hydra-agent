# Hydra Agent

Hydra Agent is a clean runtime extraction from Hydra-X.

The goal is not to preserve the old product-management workspace. The goal is a
competitive, self-hosted agent runtime for teams: durable agents, transparent
orchestration, least-privilege tools, per-agent model routing, and a flexible
workspace knowledge graph.

## V1 Direction

- **Runtime first**: workspaces, agents, conversations, runs, steps, providers, and policies are core.
- **Secure by default**: agent packs start read-only; dangerous side effects need explicit grants and approvals.
- **Transparent orchestration**: supervisor/planner agents decompose work and delegate to specialized workers through durable run state.
- **Flexible knowledge graph**: the useful parts of the Hydra-X product graph become a generic workspace graph for evidence, memories, artifacts, risks, tasks, and decisions.
- **Declarative agents**: specialized agents are defined by versioned packs that describe prompts, tools, skills, model routes, memory scopes, knowledge scopes, permissions, and evals.

## Current State

The v1 runtime now includes:

- Phoenix/OTP application scaffold
- Runtime schemas for workspaces, agents, providers, policies, conversations, turns, runs, run steps, and run events
- Workspace knowledge graph schemas for node/relationship type definitions, nodes, and relationships
- Neutral knowledge type-definition seeding for sources, artifacts, claims, decisions, tasks, risks, and memories
- Declarative agent pack validation with registered tool checks
- Agent pack import/export APIs with round-trip preservation of declared skills
- Built-in starter packs for planner, researcher, builder, reviewer, memory curator, and security reviewer agents
- Durable skill records with proposal, testing, activation, deprecation, and archive states
- Provider-backed agent chat with durable conversation turns and knowledge recall
- Stream-capable agent chat path that broadcasts conversation deltas and persists final turns
- Provider-backed run planning that turns supervisor output into durable, validated steps
- Cron-backed scheduled automations that run through the normal agent chat path
- Eval suites, cases, runs, and results for measuring quality and regressions
- Benchmark-style eval reports with pass rate, average score, duration, and failures
- Env-backed webhook gateways for external triggers without raw DB secrets
- Workspace audit export for runs, events, policies, providers, tools, automations, webhooks, and evals
- Runtime PubSub topics for live control planes and conversation/run updates
- LiveView/Tailwind operator control plane at `/control` for runtime visibility and safe run/approval controls
- Memory curation for low-confidence nodes and duplicate-title reporting
- Usage ledger for provider calls across chat, planning, and eval execution
- Workspace and agent budget records with live token-usage status
- Workspace approval queue for operator review of blocked-sensitive steps
- Runtime doctor checks for database, tools, packs, OTP processes, and provider health
- Agent pack export for moving specialized agents between workspaces/repos
- A least-privilege tool contract with built-in knowledge graph, allowlisted filesystem, allowlisted HTTP, and allowlisted shell tools
- Provider adapters for mock, OpenAI-compatible APIs, Anthropic, and Ollama
- A conservative run runner, supervised OTP run worker, and background recovery worker that lease steps, execute one at a time, pause for approval, block unsafe tools, recover stale leases, and write audit events
- Explicit run worker stop controls; canceling a run also attempts to stop its active worker
- Bounded parallel execution for read-only tools that declare `parallel_safe`
- Safety event ledger for policy blocks, approvals, runtime incidents, and security signals
- JSON APIs for workspaces, agents, providers, tools, runs, run controls, knowledge graph data, and safety events

## Development

```bash
mix deps.get
docker compose up -d postgres
mix ecto.create
mix ecto.migrate
mix test
```

Use `mix precommit` before shipping changes.

If Docker is unavailable, `mix compile --warnings-as-errors` and the agent pack
smoke command below still verify most non-database code paths:

```bash
MIX_ENV=test mix run --no-start -e 'for path <- Path.wildcard("agent_packs/*.json"), do: IO.inspect({path, HydraAgent.AgentPack.load_json(path)})'
```
