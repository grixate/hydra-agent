# Hydra Agent V1 Backlog

## Current Objective

Continue the Hydra-X separation until `hydra-agent` is a polished, competitive
agent runtime: secure by default, transparent as an orchestrator, fast under
OTP, easy to specialize through agent packs, and measurable through evals.

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
- Run cancellation attempts to stop the active supervised worker, and operators
  have an explicit worker stop endpoint.
- Agent pack import/export APIs preserve declared skills for round trips.
- Workspaces can idempotently seed neutral knowledge graph type definitions.
- Neutral graph seeds now include observation/entity/event and evidence-oriented
  relationships; source/artifact writes require provenance guardrails.
- A standard Phoenix LiveView/Tailwind control plane exists at `/control` with
  run controls, worker controls, and approval/rejection actions.

## Remaining High-Value Work

1. True SSE transport for provider adapters that support it.
2. Status-aware worker loop tests with DB-backed run fixtures.
3. Expand the LiveView control plane with run timelines and graph drill-downs.
4. DB-backed integration tests for planner, approval, recovery, streaming, and pack import.
5. True SSE transport for provider adapters that support it.
6. MCP tool scaffolding behind explicit allowlists.
7. More integration tests that exercise full DB-backed planner, approval, and recovery flows.
8. Benchmark suites for orchestration, safety, recovery, cost, and latency.

## Next Batch

Expand the LiveView control plane with run timelines and graph drill-downs.
