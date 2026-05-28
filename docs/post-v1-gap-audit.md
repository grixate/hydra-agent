# Post-V1 Gap Audit

Research pass date: 2026-05-25

Hermes comparison target: `NousResearch/hermes-agent` main at
`4117fc3645b59c5c0f9d623e0991fc9bc864c0e2` (verified 2026-05-25).

This audit compares the current Hydra implementation against:

- `/Users/grixate/Downloads/hydra_agent_management_interface_spec.md`
- `docs/management-interface.md`
- `docs/implementation-roadmap.md`
- `docs/hermes-gap-review.md`
- the current Hermes Agent repository and docs

## Current Position

Hydra has crossed the original V1 continuation line: durable missions/runs,
workers, approvals, memory/graph review, skill lifecycle, automations,
tools/policies, MCP execution/discovery, runtime operations, eval benchmarks,
checkpoint rollback, credential pools, Agent Studio, and the first LiveView
control plane are implemented and test-backed.

The remaining work is now product completion and competitive polish, not
foundational runtime rescue.

## Design-Spec Gaps

These are still called for by the management-interface concept but are not yet
first-class implementation surfaces.

1. Mission creation and mission list
   - Current state: first-class `Mission` records now exist with composer fields
     for success criteria, context, team, permissions, budget, deadline,
     priority, and start mode. Starts create lineage-linked runs and status
     rollups.
   - Remaining: richer team assignment UX, reusable permission presets, and
     mission acceptance loops that judge success criteria automatically.

2. Agent Studio
   - Current state: Agent Studio now supports sandbox/live/memory-proposal
     modes, raw request/response payloads, draft memory proposals, eval-suite
     execution, shared multi-agent rooms, room member management, Telegram
     binding management, proposal approval, transcript export, delivery retry
     controls, and guided agent creation from presets with policy previews.
   - Remaining: simulated event triggers, visible context-window budgeting,
     tool-call dry runs, proposed skill updates, room search, and richer builder
     eval readiness checks.

3. Autonomous skill loop
   - Current state: V4 adds skill usage events, improvement proposals, learning
     from completed multi-tool runs, safe auto-activation for read-only skills
     with confidence/eval evidence, Markdown import/export, and Skill Registry
     visibility for draft improvement proposals.
   - Remaining: richer pattern mining across conversations/rooms, generated
     eval cases from source runs, pruning workflows, and skill marketplace
     curation.

4. Policies and settings pages
   - Current state: policies are visible in Tools And Protocols with a policy
     editor, workspace-scoped API checks, production fail-closed policy fallback,
     and dangerous-posture warnings.
   - Remaining: a fuller dedicated settings page for provider/env/runtime
     defaults and plain-language policy templates.

5. Trace export, replay, and lineage
   - Current state: Run Detail renders persisted steps/events/safety records,
     checkpoints, and lineage. Trace JSON includes mission/lineage, steps,
     events, safety events, usage, checkpoints, memory nodes, artifact nodes,
     knowledge nodes, and graph relationships.
   - Remaining: downloadable bundle button, richer LLM/tool span schemas,
     replay/time-travel inspection, and delegation-specific rollups.

6. Memory and graph detail routes
   - Current state: Memory Studio and Graph Workbench support curation in list
     surfaces.
   - Missing: `/memory/:id`, `/graph/entities/:id`, validity windows,
     supersession chains, and one-hop visual neighborhoods.

## Fresh Hermes Gaps

Hermes main has grown beyond the older gap review. These current features are
worth selectively considering:

1. ACP editor integration
   - Hermes runs as an ACP server for editor-native chat, tool activity, file
     diffs, terminal commands, approvals, and streamed response chunks.
   - Hydra opportunity: add an ACP-compatible gateway only after its run/event
     contract is stable, mapping editor sessions to workspace-scoped runs.

2. OpenAI-compatible API server and local model proxy
   - Hermes exposes Chat Completions, Responses, streaming tool progress, stored
     response chains, capabilities, and a separate subscription proxy.
   - Hydra opportunity: add an OpenAI-compatible agent endpoint around
     conversations/runs, but preserve Hydra auth, policies, audit, and run
     events instead of serving a raw local proxy first.

3. Credential pools
   - Hermes rotates API keys/OAuth tokens by provider, handles 429/402/401
     recovery, shares pools with subagents, and falls back across providers.
   - Hydra state: provider credential pool records now have per-key items,
     cooldowns, usage/failure counters, env refs, and health-aware provider
     routing.

4. Checkpoints and rollback
   - Hermes can snapshot files before destructive file/terminal operations and
     restore them with `/rollback`.
   - Hydra state: workspace checkpoint records now wrap file writes and inferred
     shell targets, with diff/restore APIs and Run Detail restore controls.

5. Persistent goals and subgoals
   - Hermes has `/goal` and `/subgoal` loops with judge-model continuation.
   - Hydra opportunity: make this a first-class Mission acceptance loop using
     run success criteria and eval/rubric checks rather than chat slash-command
     state.

6. Delegation overlay
   - Hermes has subagent fan-out with nested depth limits, per-branch
     token/cost/file rollups, pause/kill controls, and post-hoc review.
   - Hydra opportunity: model delegation as parent/child runs and show it in
     Mission/Run Detail rather than opaque child sessions.

7. Plugin ecosystem
   - Hermes supports opt-in tools/hooks/commands/platforms/backends/plugins.
   - Hydra state: V4 adds governed browser, vision, image, TTS, code execution,
     and multi-model consensus MVP tools as registered policy-gated tools.
   - Hydra opportunity: still defer arbitrary code plugins until packaging,
     sandbox, and review boundaries are explicit.

8. Dashboard breadth
   - Hermes dashboard includes local config/env editing, sessions, logs,
     analytics, cron, skills, and embedded TUI chat.
   - Hydra opportunity: avoid becoming config-first. Add settings/logs/analytics
     only where they strengthen the mission cockpit.

## Recommended Next Slice

Build **Mission Acceptance + Delegation Rollups** next, while hardening rooms as
the main operator/chat surface.

Why this first:

- Mission, trace, checkpoint, credential, and Agent Studio primitives now exist.
- Rooms and the builder now make agent team creation usable, but success still
  needs to roll up into mission-level evidence and acceptance decisions.
- Hermes-style persistent goals and subgoals map cleanly onto Hydra missions,
  child runs, success criteria, evals, and trace evidence.
- This strengthens Hydra's OTP/runtime advantage without jumping into broad
  plugin or platform sprawl.

Concrete scope:

1. Add acceptance checks that evaluate mission success criteria with eval/rubric
   runs and record pass/fail evidence.
2. Add delegation rollups for child runs: token/cost, file changes,
   checkpoints, approvals, failures, and reviewer notes.
3. Add trace bundle download and replay-style timeline inspection.
4. Add richer Agent Studio dry runs for tool calls, context-window preview, and
   proposed skill updates.
5. Add room search, transcript filtering, and per-message delivery receipts for
   future multi-gateway delivery.
6. Expand the settings surface for provider/env/runtime defaults and reusable
   permission presets.
7. Keep ACP gateway as the next protocol candidate once the trace and mission
   acceptance contracts are stable.

## Intentional Deferrals

- Broad messaging platform parity with Hermes.
- Dashboard plugin marketplace.
- Full terminal backend matrix.
- Local subscription proxy for raw model inference.
- Arbitrary project-local code plugins.
- Media-generation ecosystem parity.

These are useful, but they are not the best next use of Hydra's OTP/runtime
advantage.
