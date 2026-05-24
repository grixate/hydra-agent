# Hydra Agent Implementation Roadmap

This is the continuation plan after the first public `hydra-agent` snapshot.
The repo already contains a solid Phoenix/LiveView + OTP runtime foundation:
workspace-scoped agents, tools, policies, providers, run steps, approvals,
knowledge graph, memory, usage, budgets, evals, webhooks, audit export, starter
packs, and a LiveView control plane.

The remaining work is not about rebuilding Hydra again. It is about turning the
foundation into a competitive agent runtime that can credibly stand next to
Hermes-style systems while using Elixir/OTP for durability, concurrency,
observability, and safety.

## Product Direction

Hydra Agent should be a general agent runtime, not a product-management app.
Any task, risk, decision, or artifact concepts that remain are runtime-neutral
knowledge graph types, not PM workflow assumptions.

The core promise:

- Fast, durable orchestration through OTP and database leases.
- Secure-by-default tools with explicit capability grants and policy gates.
- Transparent execution through run events, safety events, usage records, and
  audit export.
- Easy specialization through agent packs, skills, model routes, memory scopes,
  and tool policies.
- Measurable quality through first-class eval suites and benchmark reports.
- A simple LiveView control plane first; no React dependency for V1.

## Current Baseline

Already implemented:

- Phoenix app with LiveView/Tailwind control plane at `/control`.
- Runtime schemas and context for workspaces, agents, providers, conversations,
  turns, runs, steps, run events, and tool policies.
- Supervised run workers, leases, stale lease recovery, pause/resume/cancel, and
  approval queues.
- Provider adapters for mock, OpenAI-compatible, Anthropic, and Ollama.
- Provider routing, fallback, normalized usage, basic streaming callback path.
- Built-in tools: knowledge search/read/write, relationship creation, source
  ingest, artifact record, HTTP fetch, shell command, file list/read/write, noop.
- Least-privilege authorizer with side-effect classes and allowlists for
  network, shell, and filesystem access.
- Neutral knowledge graph seed types:
  `source`, `artifact`, `claim`, `observation`, `entity`, `event`, `decision`,
  `task`, `risk`, `memory`.
- Neutral relationships:
  `references`, `supports`, `contradicts`, `derived_from`, `produced_by`,
  `depends_on`, `relates_to`, `resolves`.
- Provenance guardrails for source/artifact nodes and evidence-oriented
  relationship validation.
- Skills lifecycle, starter agent packs, pack import/export.
- Automations, webhook gateways, audit export, doctor checks, usage ledger,
  budgets, safety events, eval suites/cases/runs/results.
- Tests currently pass through `mix precommit`.

## Definition Of A Solid V1

V1 is ready when a user can clone the repo, configure providers, create or
import specialized agents, run agent work safely, inspect everything that
happened, and compare quality over time.

Required acceptance criteria:

- `mix precommit` passes from a clean checkout with documented database setup.
- All API surfaces used by the LiveView control plane have DB-backed tests.
- OpenAI-compatible streaming uses true provider transport, not only a simulated
  callback path.
- Run workers have status-aware tests for success, approval wait, policy block,
  failure, pause, cancel, and stale recovery.
- The control plane shows a useful run timeline and graph drill-down without
  needing a separate frontend.
- Agent packs can be imported, validated, edited through APIs, and exported
  without losing skills, scopes, or policy intent.
- Tool execution is auditable, timeout-bounded, and policy-gated for every
  side-effect class.
- Evals include benchmark reports for orchestration quality, safety behavior,
  recovery, cost, and latency.
- Documentation explains setup, provider config, policies, packs, orchestration,
  graph semantics, and security posture.

## Phase 1: Hardening The Runtime Core

Goal: make orchestration boringly reliable.

Tasks:

- Add DB-backed runner fixtures that create realistic workspaces, agents,
  policies, runs, and steps.
- Test worker behavior for:
  - completes all planned steps;
  - stops on `awaiting_approval`;
  - stops on policy block;
  - stops on tool failure;
  - respects paused runs;
  - respects canceled runs;
  - does not double-execute leased steps;
  - recovers stale leases after timeout.
- Add explicit worker status introspection:
  - active PID;
  - current step id;
  - last heartbeat;
  - stop reason;
  - run state summary.
- Make worker stop semantics status-aware:
  - user stop should not mark the run failed;
  - cancel should terminate the worker and persist cancel state;
  - crash should write a safety event and leave recoverable state.
- Add run event coverage for every state transition.
- Add transaction boundaries around multi-step state changes where double writes
  would confuse the audit trail.

Acceptance:

- Runner and worker integration tests fail if any state transition skips event
  logging.
- Stale lease recovery is deterministic in tests.
- Canceling a run cannot leave an actively executing worker around.

## Phase 2: True Streaming Providers

Goal: provider streaming should feel native and be testable end to end.

Tasks:

- Implement true SSE parsing for `openai_compatible`.
- Normalize stream events into a provider-independent shape:
  - `delta`;
  - `tool_call_delta`;
  - `usage`;
  - `finish`;
  - `error`.
- Decide whether Anthropic streaming lands in V1 or V1.1. If included, use its
  native event names but map them to the same normalized stream contract.
- Add provider stream tests with local fake HTTP responses.
- Expose stream progress through the existing PubSub conversation topics.
- Add API tests for `/api/v1/conversations/:id/stream`.
- Add LiveView progressive rendering for active conversation streams only after
  the transport is stable.

Acceptance:

- Streamed responses persist exactly one final assistant turn.
- Usage is recorded once when provider usage is available.
- Stream failure writes a safety event and does not create a misleading final
  assistant turn.

## Phase 3: LiveView Control Plane Polish

Goal: keep the first UI standard Phoenix/LiveView, but make it genuinely useful
for operating agents.

Tasks:

- Add a run detail panel:
  - timeline from run events;
  - step list with state, assigned agent, tool, attempts, approval status;
  - active worker status;
  - run metadata and output summary.
- Add graph drill-down:
  - node detail;
  - relationships in/out;
  - provenance;
  - linked run/step when available;
  - confidence and status controls.
- Add provider panel improvements:
  - health state;
  - model list;
  - last failure;
  - configured fallback route.
- Add budget and usage panel improvements:
  - daily/monthly token usage;
  - budget remaining;
  - route-level cost placeholders.
- Add approval inbox improvements:
  - diff-like payload preview for write tools;
  - policy reason;
  - approve/reject with note.
- Add LiveView tests using stable DOM ids only.

Acceptance:

- Operator can answer “what is running, why, under which policy, and what did it
  change?” from `/control`.
- UI remains LiveView/Tailwind only.
- No inline scripts; any hook code lives under `assets/js`.

## Phase 4: Agent Packs And Skills As A Real Interface

Goal: make specialized agents easy to create, share, audit, and evolve.

Tasks:

- Add pack schema versioning and migration helpers.
- Add JSON Schema generation for agent packs.
- Add pack validation errors with stable machine-readable codes.
- Add pack import modes:
  - dry run;
  - create;
  - update existing;
  - clone as new agent.
- Add pack export with optional redaction of internal ids.
- Add skill testing flow:
  - attach eval suite;
  - run examples;
  - activate only after passing threshold.
- Add control-plane screens or API endpoints for pack and skill lifecycle.
- Add docs for building agent packs from scratch.

Acceptance:

- A user can define planner/researcher/builder/reviewer-style agents without
  changing Elixir code.
- Dangerous tools in a pack cannot bypass approval policy.
- Pack round trips preserve model route, skills, memory scopes, knowledge
  scopes, autonomy, permissions, and approval intent.

## Phase 5: Knowledge Graph And Memory Quality

Goal: keep the flexible graph, but make it useful enough for agent reasoning.

Tasks:

- Keep the current neutral starter types, but treat them as workspace-extensible.
- Add type definition APIs for custom node and relationship types.
- Add relationship cardinality/semantic validation through type metadata.
- Add graph search filters:
  - type;
  - status;
  - confidence;
  - source;
  - created by run/step;
  - updated since.
- Add memory recall ranking:
  - text similarity placeholder now;
  - embedding route later;
  - recency and confidence weighting.
- Add memory write policy:
  - agents can propose memories;
  - trusted agents or operators can activate them;
  - low-confidence memories stay reviewable.
- Add source/artifact previews in control plane.
- Add graph eval cases for recall precision and provenance correctness.

Acceptance:

- Agents can use graph memory without confusing execution tasks with knowledge
  `task` nodes.
- Source and artifact records remain provenance-backed.
- Claims can be traced to evidence or marked unsupported.

## Phase 6: Tooling And MCP Integration

Goal: add more power without turning tools into an unsafe escape hatch.

Tasks:

- Define a narrow MCP tool wrapper contract:
  - named server;
  - named tool;
  - input schema;
  - side-effect class;
  - timeout;
  - approval sensitivity;
  - network/filesystem/shell constraints if applicable.
- Store MCP server definitions through environment references, not raw secrets.
- Add MCP allowlists to tool policy.
- Add MCP execution audit events with input/output redaction.
- Add tests for denied, approved, timeout, and successful MCP calls.
- Add built-in safe MCP examples only after the wrapper is policy-complete.
- Improve file tools:
  - size limits;
  - binary detection;
  - write conflict behavior;
  - optional patch-style writes.
- Improve shell tool:
  - stronger argv validation;
  - max output truncation metadata;
  - environment allowlist.

Acceptance:

- MCP calls are less privileged than local shell, not more privileged.
- Every external action has an authorization decision and audit trail.
- Unsafe tool inputs fail closed.

## Phase 7: Evals And Benchmarks

Goal: prove quality and performance with repeatable measurements.

Tasks:

- Add eval case types:
  - contains;
  - JSON path;
  - exact tool decision;
  - graph assertion;
  - policy assertion;
  - latency threshold;
  - cost threshold;
  - model-graded rubric later.
- Add benchmark suites:
  - simple chat quality;
  - tool-use correctness;
  - approval safety;
  - memory recall;
  - planner decomposition;
  - worker recovery;
  - provider fallback;
  - parallel read execution.
- Add comparison reports:
  - agent pack vs agent pack;
  - provider route vs provider route;
  - commit vs commit;
  - prompt/skill version vs previous version.
- Add CLI or mix task for running a suite locally.
- Persist eval environment metadata:
  - commit sha;
  - provider route;
  - pack version;
  - runtime config summary.

Acceptance:

- “Is Hydra better than before?” can be answered with a report, not a vibe.
- Hermes comparisons can be performed by reproducing tasks through Hydra evals
  and recording measured deltas.

## Phase 8: Security And Operational Readiness

Goal: make security a central runtime feature, not a checklist at the end.

Tasks:

- Write a threat model for:
  - tool execution;
  - provider secrets;
  - webhooks;
  - agent memory poisoning;
  - prompt injection through sources;
  - shell/filesystem/network/MCP side effects.
- Add redaction helpers for logs, safety events, and audit export.
- Add request authentication strategy for APIs beyond local development.
- Add rate limits for webhooks and high-cost endpoints.
- Add config validation at boot:
  - provider env refs;
  - webhook token env refs;
  - dangerous defaults;
  - database URL.
- Add deployment docs:
  - local dev;
  - Docker Compose;
  - production env vars;
  - backups and migrations.
- Add telemetry events for:
  - provider calls;
  - tool calls;
  - run transitions;
  - approval decisions;
  - budget blocks;
  - safety events.

Acceptance:

- A dangerous default is harder to enable accidentally than to leave disabled.
- Operators can audit who/what caused an external side effect.
- Production setup does not require reading source code to discover env vars.

## Phase 9: Performance Work

Goal: use Elixir's unfair advantage where it actually matters.

Tasks:

- Benchmark runner throughput with:
  - single-step execution;
  - parallel read batches;
  - many concurrent runs;
  - many waiting approvals;
  - provider mock latency.
- Tune DB indexes around:
  - planned runnable steps;
  - active runs;
  - approval queue;
  - run events;
  - graph search;
  - usage summaries.
- Add bounded concurrency knobs per workspace/agent.
- Add back-pressure behavior:
  - max active runs;
  - max provider calls;
  - max tool calls;
  - max shell/network calls.
- Add queue visibility in the control plane.
- Add load tests for PubSub/control plane event volume.

Acceptance:

- Hydra can run many lightweight agents concurrently without losing
  transparency or double-executing work.
- Operators can see bottlenecks instead of guessing.

## Phase 10: Hermes-Class Feature Gap Review

Goal: explicitly compare against Hermes-style agent expectations and decide
where Hydra should match, exceed, or intentionally differ.

Review areas:

- Agent definition ergonomics.
- Tool declaration and execution model.
- Planning loop quality.
- Memory model and retrieval.
- Multi-provider support.
- Streaming behavior.
- Observability and debuggability.
- Security and approval controls.
- Benchmarkability.
- Local-first operation.
- Extensibility through packs/skills/MCP.

Likely Hydra advantages to lean into:

- OTP supervision and crash recovery.
- Durable leases and transparent run state.
- Strict tool policy and approval model.
- Workspace-scoped knowledge graph with provenance.
- LiveView control plane with real-time updates.
- First-class eval and budget ledgers.

Likely Hermes gaps to study and potentially copy:

- Agent authoring ergonomics.
- Prompt/tool loop simplicity.
- Library-style composability.
- Fast iteration for developers.
- Any battle-tested conventions around tool schemas and memory APIs.

Acceptance:

- Maintain a `docs/hermes-gap-review.md` with concrete feature comparisons,
  not marketing language.
- Convert gaps into tracked roadmap items with tests or acceptance criteria.

## Recommended Next Batch

Start with Phase 1 and Phase 2 because they de-risk everything else:

1. Add DB-backed runner/worker integration fixtures.
2. Test pause/cancel/approval/failure/recovery semantics.
3. Implement true OpenAI-compatible SSE streaming.
4. Add streaming endpoint tests.
5. Then expand `/control` with run timeline and graph drill-down.

That sequence gives Hydra a stronger spine before adding more surface area.

