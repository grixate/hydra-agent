# ADR 0008: Fail-closed portable Simulation artifacts

- Status: Accepted
- Date: 2026-07-18
- Governing specification: `Hydra_Simulations_Blueprint_First_Development_Spec_2026-07-18.md`

## Context

A Simulation must move between compatible Hydra deployments without copying
database identifiers, provider credentials, or hidden in-memory state. A
completed Run also needs a durable audit export that preserves the exact model,
seed, engine, decisions, events, transactions, analysis, usage, and reports.
Both files cross a hostile upload boundary and may contain private inputs.

The destination deployment can have different Blueprint identifiers, provider
records, prices, and capabilities. Treating those deployment-specific values as
portable would either leak configuration or create a Pack that appears runnable
but fails unpredictably. Trusting a source preview without rerunning it would
have the same problem.

## Decision

Hydra defines two declarative, deterministic ZIP formats:

- `hydra-simpack` format v1, exposed as `.hydra-simpack`;
- `hydra-run` format v1, exposed as `.hydra-run`.

Every entry lives under a format-specific root. The archive boundary rejects
absolute and traversing paths, duplicate paths, links and special files,
executable modes, executable extensions and magic bytes, encryption,
unsupported compression, ZIP64, excessive entry counts, and compressed,
uncompressed, or per-file size violations. It verifies an exact file allowlist
against `manifest.json`, every SHA-256 file digest, and a canonical manifest
content hash before any domain import occurs. Package text is data and is never
evaluated as code, a template, or a shell command.

A Simulation Pack embeds the exact Blueprint package and declarative Context,
Population, Script, Observation, route-requirement, budget, and preview
contracts. Import validates archive safety, format and minimum Hydra versions,
component schemas and hashes, Blueprint lineage, Population and Script
semantics, and declared compatibility. Hydra then resolves destination model
routes by provider/model match or required capability, reprices the immutable
budget envelope for the destination, recompiles the Population, and reruns the
bounded Script preview. Only after all checks pass does one database transaction
create and activate a runnable Simulation. Credentials and source deployment
identifiers are never imported.

Raw notes, attachment text, and URL input are excluded by default. An editor
may explicitly include them. Structured identity redaction is deterministic and
always overrides raw-source inclusion because free-form text cannot be promised
anonymous. Provider/model details are independently optional. These controls
and their result are recorded in the manifest and README.

A Run Pack embeds the exact historical Simulation Pack associated with one
completed Run rather than exporting whichever build is active today. It also
contains ordered events, decisions, resource transactions, the immutable
Analysis Pack, all Report versions, usage, Run/result/decision hashes, seed,
engine version, replay kind, and a reproducibility README. Recovery snapshots
are intentionally excluded: the append-only record and hashes form the portable
audit artifact without duplicating large operational recovery state. Model
rationales, provider details, raw sources, and identities have independent
controls; safe interface defaults omit the first three.

The manual external-model workflow exports the exact Simulation and Blueprint
lineage, module instructions, output schemas, source metadata, and preceding
artifacts as bounded JSON. An uploaded result must preserve every lineage hash,
pass all three Blueprint schemas, retain supplied Population identifiers and
counts, pass grounding rules and semantic validation, compile, and pass a new
preview. A successful upload appends immutable Context, Population, Script, and
Preview versions atomically. Stale or partial output changes nothing.

## Consequences

### Positive

- Compatible deployments can exchange a validated Simulation without sharing
  database identities or secrets.
- Import failure is atomic and occurs before a Run can be started.
- Exact hashes, compiler versions, seeds, routes, budgets, decisions, and result
  lineage are visible and portable.
- Safe defaults minimize accidental disclosure while keeping deliberate raw
  export possible for authorized editors.
- Disconnected and restricted environments can use any external model without
  making a provider credential part of Hydra.
- Deterministic ZIP timestamps, entry ordering, JSON encoding, and manifests
  make equal exports byte-for-byte equal.

### Costs and constraints

- Route resolution and pricing are destination facts, so imported Pack hashes
  gain explicit portable-origin lineage instead of pretending to be source
  database records.
- A source preview is evidence, not authorization; import spends local compute
  to recompile and preview again.
- Structured redaction cannot sanitize arbitrary free-form Blueprint
  instructions. Users must review custom Blueprints and any explicitly included
  raw sources before sharing.
- Run Packs are audit and replay inputs, not operational backups. Snapshot-based
  crash recovery stays deployment-local.
- Format and compiler evolution requires explicit compatibility handling rather
  than permissive best-effort import.

## Rejected alternatives

- **Database dump as portability:** leaks deployment identities and couples
  transfer to schema internals.
- **Copy provider configuration or credentials:** violates tenant and secret
  boundaries and cannot work predictably on the destination.
- **Trust the source preview:** hides destination compiler, capability, or route
  incompatibility until execution.
- **Include raw inputs by default:** makes the most convenient action the least
  private one.
- **Best-effort unknown-version import:** may create an apparently valid but
  semantically different model.
- **Put every recovery snapshot in a Run Pack:** inflates audit files with
  operational state that the ordered immutable record already explains.

