# ADR 0007: Compact and accessible Observatory

- Status: Accepted
- Date: 2026-07-18
- Governing specification: `Hydra_Simulations_Blueprint_First_Development_Spec_2026-07-18.md`

## Context

A completed Simulation may contain thousands of agents, relationships, events,
and full recovery snapshots. Sending that state directly to the browser would
make the Results surface slow, visually noisy, and difficult to use with a
keyboard or assistive technology. Rendering one DOM or canvas object per agent
would also suggest a level of individual observation that a synthetic
population does not provide.

The Observatory must explain the result through State, Flow, and Explain lenses
while preserving the authority boundary established by the immutable Run and
Analysis Pack. It must support comparison, selected-agent inspection, English
and Russian copy, narrow screens, high zoom, and a useful non-visual result when
client rendering or network enhancement fails.

## Decision

Hydra derives a deterministic, content-addressed `hydra-observatory/v1`
protocol from one immutable Analysis Pack and, optionally, one compatible
comparison Analysis Pack. It is a presentation protocol, not another source of
truth or persistence object. The payload contains cohort aggregates, state and
resource distributions, a compact metric timeline, bounded resource flows,
pivotal events, modeled-driver rankings, grounding and uncertainty, and at most
32 representative trace identifiers. It never contains the full population.

Final resource, state, and relationship aggregates are computed inside
PostgreSQL from the latest checksummed snapshot. This avoids transferring a
multi-megabyte snapshot into the application merely to build a small response.
The protocol has a stable content hash, reports its raw and compressed size, is
served with a private cache policy and ETag, and is scoped through the same
workspace viewer boundary as Results.

The server renders the complete three-lens hierarchy and every table or text
alternative immediately. A small client island progressively promotes the
lenses to ARIA tabs and draws aggregate State and Flow canvases. State semantic
zoom moves between density, cohorts, and no more than 32 representative
samples. Flow draws a bounded timeline and controlled comparison line. Canvas
is used instead of a new WebGL dependency because the protocol contains only
bounded aggregate primitives; it meets the current rendering envelope with a
smaller failure surface and keeps the server alternatives authoritative.

Agent detail uses a separate `hydra-observatory-agent/v1` endpoint. It validates
the identifier, requires a completed Run, and queries only the matching agent
from each immutable JSONB snapshot with bound parameters. History is capped at
64 snapshots, relationships at 24, decisions at 32, grounding at 24, and maps
and lists are bounded. It never returns memory seeds or a full snapshot. Dynamic
data is inserted into the interface with `textContent`, not HTML.

Comparison is allowed only between completed Runs in the same Simulation.
Population Model, Simulation Script, execution mode, model route, and Budget
Plan must match for a direct comparison. Seed and replay kind are shown as
controlled differences. The interface warns when governing configuration
differs and preserves the selected primary and comparison Run across locale
changes.

The language contract calls rankings **modeled drivers** and explicitly rejects
causal interpretation. Built-in domain labels and deterministic event summaries
are localized, while arbitrary provider rationale remains recorded source data.

## Consequences

### Positive

- Initial Results data is proportional to aggregates, not population size.
- A 5,000-agent acceptance run produces about 55 KB raw and 8 KB compressed,
  comfortably below the practical 500 KB initial-payload target.
- Full agent state is fetched only after an explicit selection.
- Tables and explanations are useful before JavaScript runs and remain present
  if the visualization request fails.
- Keyboard tabs, semantic zoom, timeline controls, visible focus, reduced
  motion, responsive reflow, and horizontally contained tables cover the main
  accessibility contract.
- Exact replay comparison exposes zero deltas without concealing replay
  lineage.
- The immutable Run and Analysis remain the only result authorities.

### Costs and constraints

- Canvas pixels are not semantic content; the adjacent tables and text are the
  accessible authority.
- PostgreSQL aggregate queries scan the latest JSONB snapshot. They are bounded
  to one snapshot but should be included in future snapshot-codec benchmarks.
- Arbitrary custom identifiers and provider rationale cannot be perfectly
  translated without changing recorded evidence.
- The current client draws a compact two-dimensional projection, not a full
  network editor or particle simulation.
- Payload metadata is recomputed on request rather than persisted; private
  caching and the stable ETag limit repeated work.

## Rejected alternatives

- **Send full snapshots to LiveView or the browser:** payload and privacy cost
  scale with every agent and relationship.
- **Render an element per agent:** this creates thousands of changing DOM nodes
  and implies unsupported individual precision.
- **Use the visualization as the only result:** a canvas-only answer excludes
  assistive technology and fails badly when enhancement is unavailable.
- **Persist a second analysis object for the Observatory:** it would duplicate
  the immutable Analysis Pack and create conflicting result authority.
- **Fetch an entire snapshot to inspect one agent:** it turns a deliberate
  on-demand action into an unbounded transfer.
- **Describe rankings as causes:** reach and prominence inside a synthetic model
  do not establish real-world causality.
