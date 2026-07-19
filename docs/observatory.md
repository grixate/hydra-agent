# Observatory operations and interface contract

The Results Observatory answers three different questions without exposing the
raw event store:

1. **State** — where the synthetic population ended and how states, resources,
   types, and archetypes are distributed.
2. **Flow** — how recorded metrics and resources changed in Run order and which
   events changed the modeled trajectory.
3. **Explain** — which rules, actions, events, decisions, assumptions, and
   sources were prominent modeled drivers.

The concise main result, aggregate Run facts, and synthetic-evidence caveat
precede the lenses. The governed Report and exact lineage follow them.

## Protocols

`GET /simulations/:id/results/observatory.json`

Required query context:

- `workspace_id`
- `run_id` for an explicit completed primary Run; the latest completed Run is
  used only when it is omitted
- optional `compare_run_id`
- `locale`

The response protocol is `hydra-observatory/v1`. Its top-level fields are:

- `run` and `main_result`
- `state`
- `flow`
- `explain`
- `comparison`
- `content_hash`, `payload_bytes`, and `compressed_bytes`

The endpoint is viewer-scoped, returns only completed Runs in the owning
Simulation and workspace, and sends `Cache-Control: private, max-age=60` with a
stable ETag. Observatory JSON reads are limited to 240 per authenticated browser
identity per hour.

`GET /simulations/:id/results/observatory/agents/:agent_id/detail.json`

The response protocol is `hydra-observatory-agent/v1`. It contains a bounded
structured profile, recorded history, relationships, mapped model decisions,
optional representative persona, grounding, a synthetic-data marker, and a
content hash. It sends `Cache-Control: private, max-age=300`.

Both paths return the normal not-found response for an inaccessible Simulation,
foreign workspace, incomplete Run, invalid comparison, malformed identifier,
or absent agent. They do not reveal which authorization check failed.

## Hard bounds

| Data | Maximum |
|---|---:|
| Metrics | 8 |
| Timeline points | 48 |
| Resource flows | 48 |
| Pivotal events | 20 |
| Modeled drivers | 16 |
| Initial representative samples | 32 |
| Agent history snapshots | 64 |
| Agent relationships | 24 |
| Agent decisions | 32 |
| Agent grounding items | 24 |

The initial payload contains no `agents` collection. Final snapshot aggregation
runs in PostgreSQL. Agent history also uses bound JSONB selection so only the
chosen agent is transferred to Elixir from each snapshot.

## Comparison rules

A direct comparison requires matching:

- Population Model identity;
- Simulation Script identity;
- execution mode;
- Model Route Plan identity;
- Budget Plan identity.

Seed and replay kind are explicit controlled differences. A mismatch in a
governing identity produces a caution state; Hydra does not hide the delta or
pretend the Runs are directly comparable. Locale switches preserve both Run
identifiers.

## Progressive enhancement and failure behavior

The server response contains all headings, facts, tables, timelines, modeled-
driver text, uncertainty, and comparison warnings. JavaScript adds:

- ARIA tab behavior with arrow, Home, and End navigation;
- aggregate State canvas rendering;
- density/cohort/sample semantic zoom;
- keyboard selection of bounded samples;
- Flow timeline rendering and round scrubbing;
- on-demand agent-detail loading;
- responsive canvas redraws.

If the compact payload cannot be loaded or canvas is unavailable, a plain-
language status points to the complete tables. The Run, Analysis, and Report
remain available and unchanged.

## Accessibility and responsive behavior

- Every canvas has an immediate table or textual equivalent.
- State samples are also ordinary buttons; selecting one moves focus to the
  inspector heading after detail loads.
- Lens tabs, semantic zoom, timeline controls, tables, disclosures, and agent
  buttons work with a keyboard and have a visible 2 px focus indicator.
- Mobile controls are at least 44 px high; semantic-zoom buttons are 44 by 44 px.
- Tables scroll inside their own labeled container. The document does not gain
  horizontal overflow at 390 px or an effective 320 px high-zoom viewport.
- Reduced-motion media rules remove non-essential animation and transitions.
- English and Russian UI labels include derived built-in metric, type, resource,
  event, action, and decision metadata. Recorded arbitrary provider prose is
  not silently rewritten.

## Verification

Domain and controller tests cover deterministic payloads, exact aggregate
counts, size bounds, absence of a full agent array, bounded detail, malformed
identifiers, missing agents, workspace isolation, exact-replay comparison,
locale-preserving URLs, and the complete Results journey.

The scale acceptance test executes a real 5,000-agent Quick Run and verifies
that its encoded Observatory remains below 500 KB compressed. Live review also
uses a completed 5,000-agent, 12-round Balanced Run and exact replay at
1,280×900, 390×844, and an effective 320 px high-zoom viewport.
