# Hydra Agent Management Interface Plan

Hydra Agent should feel like a living operations cockpit for intelligent
workers, not a blank chat app or a decorative graph canvas. The UI should answer
four questions at all times:

1. What is Hydra doing right now?
2. Why is it doing that?
3. What does it know, and where did that knowledge come from?
4. Where does the human need to intervene?

For V1, "mission" is a product/UI term for a user-level unit of work backed by
the existing `runs` table. A separate missions schema can be added later if
multi-run mission history, forks, or retries become awkward to represent through
run metadata.

## Product Model

Core UI objects:

- **Mission**: user-level work item backed by `Run`. It has a goal, context,
  team, permissions, success criteria, budget, and status.
- **Run**: one durable execution attempt. It contains steps, events, approvals,
  artifacts, metrics, errors, and final outcome.
- **Agent**: long-lived worker with identity, role, model route, memory scopes,
  skills, tool permissions, collaboration history, and runtime status.
- **Memory**: scoped, typed, auditable knowledge that can be proposed, approved,
  rejected, archived, superseded, or marked conflicted.
- **Skill**: procedural memory with trigger conditions, required tools, steps,
  examples, tests, versions, usage stats, and permission requirements.

The UI should be mission-first and evidence-first. Chat belongs inside a
mission/run, inside Agent Studio, or in a command palette. Do not add a permanent
global chat pane by default.

## Information Architecture

Recommended browser routes:

```text
/dashboard                    Mission Control
/runs                         Run list / mission list
/runs/:id                     Run detail
/agents                       Agent directory
/agents/:id                   Agent detail
/agents/:id/studio            Agent Studio
/memory                       Memory Studio
/memory/:id                   Memory item detail
/graph                        Knowledge Graph Explorer
/skills                       Skill registry
/skills/:id                   Skill detail
/tools                        Tools and protocol endpoints
/policies                     Policies and permissions
/runtime                      Runtime and supervision
/settings                     Instance settings
```

Keep `/control` as a compatibility redirect or alias until the new shell fully
replaces it.

Global shell:

- Left sidebar: Mission Control, Runs, Agents, Memory, Knowledge Graph, Skills,
  Tools, Policies, Runtime, Settings.
- Top bar: workspace selector, command palette placeholder, create mission
  action, system health, attention count, user/profile menu.
- Content area: page-specific layout with one primary scroll container.
- Right drawer: contextual inspector, closed by default unless the current page
  requires it.

## Page Build Order

### 1. Mission Control

Purpose: answer what is active, what needs attention, and what changed recently.

Build from real workspace state:

- System cards: active missions/runs, running agents, waiting approvals, runtime
  health.
- Active missions grouped by waiting approval, running, blocked, and recently
  completed.
- Attention queue for approvals, failed tool calls, stalled runs, budget
  warnings, memory proposals, graph conflicts, agent crashes, and protocol
  endpoint failures.
- Recent learning panel for approved memories, memory proposals, skill
  proposals, graph facts, and conflicts.
- Runtime heartbeat for provider/tool/worker health.

### 2. Run Detail

Purpose: show what happened, what is happening, and what can be done now.

Layout:

- Header: mission title, run status, agents, elapsed time, budget, pause/resume,
  stop/cancel, retry, fork placeholder, export trace.
- Left: step list and topology placeholder. Use a stable list/table first; graph
  view can come later.
- Center: event timeline from persisted run events.
- Right: inspector tabs for overview, context, agents, memory, graph, artifacts,
  approvals, metrics, and raw developer data.

Timeline item types:

- Planning and step lifecycle.
- Agent message and LLM call summaries.
- Tool authorization, approval, execution, output, and failure.
- Memory read/write/proposal.
- Graph mutation/proposal/conflict.
- Artifact creation.
- Runtime worker lifecycle and crash/recovery events.

Do not expose hidden chain-of-thought. Show observable decision summaries, tool
rationale, selected constraints, cited evidence, and raw JSON only in developer
mode.

### 3. Agent Directory And Agent Detail

Directory:

- Search and filter by status, role, model, skills, tool permissions, memory
  scope, active state, recent failure, and learning proposals.
- Card/table views showing identity, role, status, current run, top skills,
  memory health, last active, and risk flags.

Detail:

- Identity/config panel: role, purpose, system prompt, model route,
  collaboration preferences, memory scopes, permissions, safety policy.
- Activity panel: current activity, timeline, conversations, test chat, evals.
- State panel: memory, skills, tools, runtime, learning.
- Config edits should be versioned once agent versioning exists; until then, UI
  should label edits as future work.

### 4. Agent Studio

Purpose: prototype and debug one agent safely.

Modes:

- `Sandbox test - no durable writes` (default).
- `Sandbox test - memory proposals only`.
- `Live agent - durable writes enabled`.

Capabilities:

- Chat with agent, attach context, simulate an event trigger, run a skill,
  stream events, run an eval case, inspect context window, memory reads, tool
  calls, trace, proposed memories, proposed skill updates, and raw payloads.

### 5. Memory Studio

Purpose: manage what Hydra remembers.

Build:

- Search/filter by query, agent, scope, type, status, confidence, source, date,
  validation state, and conflict state.
- Memory list and detail with content, source, confidence, related graph nodes,
  history, and validation status.
- Dedicated proposal queue with approve, edit and approve, reject, keep
  temporary, change scope, and archive actions.
- Conflict cards that show existing memory, new conflicting claim, source A,
  source B, time relationship, recommended resolution, and action buttons.

### 6. Knowledge Graph Explorer

Purpose: explore and curate structured knowledge with provenance.

Default to search, not a giant graph.

Build:

- Search mode, table mode, entity detail, provenance mode, and conflict mode.
- Fact cards with subject, predicate, object, confidence, validity, source,
  creator, and status.
- Relationship in/out lists and one-hop expansion.
- Small neighborhood graph only after list/table interactions are stable.

### 7. Skills Registry

Purpose: manage procedural memory.

Build:

- Skill cards/table with name, description, category, version, installed agents,
  test status, permissions required, usage, and proposed updates.
- Detail tabs for overview, steps, schema, agents, tests, usage, versions, and
  permissions.
- Creation sources: manual, import file, generated from run, generated from
  repeated behavior, or future registry install.
- Generated skills start as `proposed` and require testing before activation
  unless an operator explicitly bypasses the gate.

### 8. Tools, Policies, Runtime

Tools and protocols:

- Built-in tools, MCP servers, webhooks, future ACP/A2A placeholders, secrets,
  and sandboxes.
- Trust labels: trusted local, trusted remote, limited, untrusted, disabled.
- Show exposed tools/resources/prompts, approval policy, health, allowlists,
  last use, and last failure.

Policies:

- Tool execution, shell/filesystem/network, memory writes, graph writes, skill
  creation, agent delegation, external communication, budget/runtime, redaction,
  and human approval.
- Plain-language cards first; structured JSON in developer mode.

Runtime:

- Node status, active workers, queues, restart counts, crash cards, worker
  recovery, provider health, tool health, and supervision tree.
- PIDs, mailbox length, reductions, memory usage, child specs, and raw logs only
  in developer mode.

## Reusable Components

Create shared LiveView components for:

- Status pills for run/mission, agent, memory, skill, tool, runtime.
- Agent avatar stack.
- Event timeline item.
- Trace span card or event detail card.
- Approval card.
- Memory proposal card.
- Graph fact card.
- Skill card.
- Budget bar.
- Context chip.
- Inspector drawer.
- Empty state.
- Command palette placeholder.

All components should include text plus icon; never rely on color alone.

## UI Data Contract

Use existing schemas first:

- Missions map to `Run`.
- Run timeline maps to `RunEvent`.
- Approval queue maps to `RunStep` with `status == "awaiting_approval"`.
- Agent state maps to `AgentProfile`, `RunStep.assigned_agent`, and
  `runtime_state`.
- Memory and graph views map to `Knowledge.Node`, `Knowledge.Relationship`, and
  memory curation APIs until a dedicated memory proposal schema exists.
- Skills map to `Skills.Skill`.
- Tools map to `Tools.Registry`, `Tools.Bundles`, and `ToolPolicy`.
- MCP protocol records map to `MCP.Server`.

When existing payloads are insufficient, prefer adding small, explicit fields to
event payloads or metadata before creating new tables. Add tables only for
durable objects that need their own lifecycle, query model, or authorization.

## Realtime Rules

Critical status changes must be persisted before broadcast. LiveViews should
recover from database state after refresh without relying on ephemeral socket
events.

Recommended topics:

```text
workspace:<workspace_id>
run:<run_id>
conversation:<conversation_id>
approvals:pending
memory:proposals
graph:updates
tools:health
system:runtime
```

Add topic helpers only as pages need them; keep the existing workspace/run
topics as the default.

## Acceptance Criteria

- A user can understand current system activity from Mission Control within ten
  seconds.
- A user can inspect a run without reading raw logs.
- Pending approvals are visible from the dashboard and Run Detail.
- Every active agent's current work is visible.
- Pause, resume, stop/cancel, and approval actions are available near the
  relevant context.
- Memory proposals have a dedicated queue and one-click source provenance.
- Every durable graph fact has provenance and can be invalidated or superseded.
- Major pages have LiveView tests with stable DOM ids.
- Raw sensitive payloads are redacted by default.
