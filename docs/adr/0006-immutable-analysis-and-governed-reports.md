# ADR 0006: Immutable analysis and governed reports

- Status: Accepted
- Date: 2026-07-18
- Governing specification: `Hydra_Simulations_Blueprint_First_Development_Spec_2026-07-18.md`

## Context

A completed Simulation Run contains the authoritative execution record, but it
is too large and operationally shaped to send directly to a report model. A
model-generated summary is easier to read, but it cannot be allowed to become
the source of truth, invent values or references, change a Run, or issue
unbounded duplicate requests after a worker interruption.

Hydra therefore needs three explicit result layers: the durable Run, a compact
deterministic Analysis, and a separately governed model interpretation. Each
layer needs exact lineage, stable references, bounded size, predictable failure
semantics, and portable exports.

## Decision

Every completed Simulation Run receives at most one immutable, content-addressed
`AnalysisPack`. It is built only from verified initial and final snapshots,
ordered events, resource transactions, recorded decisions, exact component
lineage, and previously completed comparable Runs. Analysis creation never
changes Run completion. Failure to build Analysis is logged and can be retried
idempotently from the same completed Run.

The Analysis Pack contains bounded deterministic metrics, segments, timeline,
resource flows, pivotal events, representative traces, model decisions,
scenario deltas, seed robustness, uncertainty, grounding, usage, limitations,
and a stable reference index. Every displayed or reportable evidence item has a
reference such as `metric:*`, `event:*`, `trace:*`, `resource_flow:*`,
`decision:*`, `source:*`, or `assumption:*`. The content hash excludes database
identity and generation time so rebuilding the same Run produces the same
contract.

A `SimulationReport` is one durable generation attempt against exactly one
Analysis Pack. Its immutable identity records language, audience, length,
provider and model route, price snapshot, token envelope, Blueprint and
instruction hashes, Analysis hash, optional source Report, and reserved maximum
cost. The Analysis Pack permits at most eight attempts. Regeneration always
creates the next immutable version and never reruns the Simulation.

Report generation follows `queued -> running -> ready | failed`. A worker may
claim a queued attempt once. Duplicate first-attempt delivery observes the
already-running state and does not redispatch. A later retry of an interrupted
running attempt marks that attempt failed rather than risk a duplicate external
request. The user may explicitly create a new Report version afterward. Ready
and failed Reports are immutable and cannot be deleted independently from their
owning Run history.

The model receives only the bounded Analysis payload and the exact Report
instruction contract. It must return one JSON object with nine ordered sections.
Before a Report can become ready, Hydra verifies its exact shape, every
reference, every numeric claim against the referenced numeric variants, every
URL against recorded sources, and every quotation against recorded decisions
or traces. Unsupported output is stored only as a safe failure code and bounded
validation errors. It never invalidates the Run or Analysis.

Exports preserve the same authority boundary: Analysis JSON, deterministic
metrics CSV, events CSV, transactions CSV, Report Markdown, and escaped
printable HTML. Exported Reports include their content and Analysis hashes.

## Consequences

### Positive

- A readable Report cannot silently overwrite or redefine the recorded Run.
- Rebuilding Analysis is deterministic and auditable.
- Report failures, invalid claims, and provider interruptions are isolated.
- Explicit regeneration supports another language, audience, length, or model
  without consuming another Simulation Run.
- Stable references make every accepted Report section inspectable.
- Bounded attempts and token envelopes prevent open-ended report spend.
- Portable exports retain lineage without requiring the Hydra interface.

### Costs and constraints

- At-most-once dispatch prefers a visible failed attempt over an automatic
  duplicate request after an ambiguous provider interruption.
- A model can write fluent unsupported prose; strict validation may reject an
  otherwise readable Report.
- The deterministic Analysis deliberately selects representative traces and is
  not a full event-store replacement.
- Cross-seed robustness is only shown when compatible completed Runs exist.
- A separately packaged `.hydra-run` archive and redacted export belong to the
  portable-Pack work, not this artifact pair.

## Rejected alternatives

- **Send the event store directly to the model:** it is unbounded, expensive,
  and difficult to validate consistently.
- **Treat model prose as the result:** it makes unsupported interpretation more
  authoritative than recorded execution.
- **Retry an ambiguous provider request automatically:** it can create duplicate
  cost and conflicting immutable outputs.
- **Mutate the latest Report during regeneration:** it destroys comparison,
  audit, and reproducibility.
- **Permit unreferenced numeric prose:** stylistic fluency is not evidence that
  the number came from the Run.
- **Use interactive Codex CLI authentication as a server credential:** the CLI
  session does not currently provide Hydra's bounded request, health, usage,
  cancellation, pricing, and durable provenance contract. A future explicit
  local adapter may implement that contract without changing this boundary.
