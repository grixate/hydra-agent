# Automatic Context Pack

Epic 3 turns every saved Simulation question into a durable, inspectable
Context Pack before later build stages attempt to design a population or write
simulation rules. The Pack is usable without network access or provider
credentials, but it does not disguise missing evidence: model priors,
assumptions, pending retrieval, and gaps remain visibly distinct.

## Product contract

Creating a Simulation is one database transaction that persists:

1. the workspace-scoped Simulation identity;
2. immutable Simulation Version v1;
3. deterministic Context Pack v1 for that exact Version;
4. the six durable Build stages; and
5. the active Version and Pack references.

The transaction never waits for external retrieval. A no-data question still
produces a partial but usable Pack with a bounded interpretation, two explicitly
labeled model priors, visible conservative assumptions, a four-lane Quick
research plan, and gaps explaining what has not been established. Queue or
provider failure after commit cannot erase that work.

`simulation_context_packs` is append-only. Each row belongs to one workspace,
Simulation, and immutable Simulation Version, carries a monotonically
increasing version plus a SHA-256 semantic content hash, and can be activated
only by its owning Simulation. PostgreSQL triggers enforce immutability and
scope in addition to Ecto validation.

The general Context Pack deliberately does not reuse a legacy SimLab Context
Pack row as if the concepts were identical. It adapts the proven retrieval and
evidence boundaries while retaining explicit lineage and avoiding a destructive
conversion of existing Study data.

## Interpretation and grounding

The provider-free interpreter derives a bounded initial contract from the
question and normalized Simulation inputs:

- primary question and world statement;
- candidate agent types, resources, and actions;
- geography, horizon, and missing inputs;
- four concise retrieval purposes for Quick research.

It is deterministic and schema-validated. A later model-assisted interpreter
may improve semantic range, but it must return the same validated contract and
must not become required for saving work.

Every claim has exactly one grounding class:

| Class | Meaning |
|---|---|
| `user_data` | Inert text entered directly by the user. |
| `user_document` | Claim derived from an accepted uploaded document. |
| `external_source` | Claim linked to an attributed external source. |
| `analogue` | External evidence used as a comparison, not direct proof. |
| `model_prior` | A disclosed modeling prior with no claim of external evidence. |
| `assumption` | A visible hypothesis or conservative default. |

Sources retain canonical HTTPS URI, title, excerpt, content hash, publication
date when available, review status, and injection flags. Claims link to their
source IDs. Priors never receive a source ID, and assumptions live in their own
collection. The interface describes confidence as Low, Moderate, or High; the
internal bounded score supports deterministic logic but is not presented as
empirical precision.

## Retrieval lifecycle

Research is a durable `simulation_context_research_runs` record executed by an
idempotent Oban worker for one exact Simulation Version. Quick research plans
four bounded lanes. The current provider-neutral runner supplies safe queries,
parallel retrieval, normalization, and candidate evidence; the Context Builder
then applies the Pack contract.

Successful results are merged with the active Pack and persisted as a new
immutable version. Late results accumulate rather than replace prior context.
The contract caps retained state at 60 sources, 120 claims, 40 assumptions, and
40 gaps and deduplicates stable identities before hashing. Re-running a build
with identical content returns the existing Pack instead of manufacturing a
new version.

A failed lane or supplied source becomes a visible gap. Other lanes and the
provider-free Pack remain usable. The research run records queued, running,
completed, failed, or cancelled state and bounded lane counts so recovery and
support do not depend on hidden process memory.

## Supplied URLs without search credentials

URLs explicitly supplied in the composer use a separate `direct_sources`
route. This route needs no search API credential and is automatically queued
when URLs exist but no broader web-search provider is configured. It uses
`Req`, accepts only public HTTPS on port 443, rejects userinfo, IP literals,
localhost/internal hostnames, and private or reserved resolved addresses,
strips fragments, pins the request to a validated public address while
retaining the original TLS hostname, disables redirects, accepts text content
only, and bounds connection time, receive time, concurrency, bytes, and
extracted text.

The DNS and destination checks run again at fetch time; composer validation is
not treated as an SSRF defense because DNS can change after entry. Failed or
unsafe sources are not silently promoted to evidence.

## Could local Codex CLI access be a production provider?

It can be a developer or single-user adapter, but local CLI authentication is
not currently a Hydra production-provider route. The distinction is not
whether the CLI can generate an answer—it can—but whether Hydra has a supported,
machine-readable contract for identity, authorization, structured output,
timeouts, concurrency, cancellation, usage and cost accounting, retry safety,
versioned model selection, audit provenance, and deployment isolation.

A future local-Codex adapter could work if it is implemented as an explicit
provider adapter rather than by reading or copying CLI credentials. The safe
shape is:

1. an administrator opts in to a local execution route;
2. Hydra invokes a stable non-interactive interface in an isolated worker with
   a strict structured-output schema and bounded environment;
3. the adapter exposes model identity, request ID, usage, timeout,
   cancellation, and normalized error categories;
4. policy determines which workspace data may leave Hydra and which tool
   capabilities are disabled;
5. credential material remains owned by the local CLI/session and is never
   stored in Hydra's database or surfaced in logs; and
6. staging exercises timeout, rate limit, malformed output, cancellation,
   unavailable model, oversized context, locale, usage, and recovery behavior.

This can be a useful self-hosted option, especially when the Codex process and
Hydra share one trusted machine. It is not a substitute for a server-grade
provider configuration in a multi-user or distributed deployment: desktop
login state may expire, depend on an interactive user, have different limits,
and be unavailable inside containers or background services. Until the adapter
and staging matrix exist, Hydra should report local Codex as unsupported instead
of treating ambient CLI access as a credential.

The credential-free `direct_sources` route is unrelated: it retrieves user-
supplied public documents and makes no model call.

## Historical replay and source changes

A Pack with a historical cutoff rejects sources published after that date.
Decision Replay uses strict historical reconstruction and also rejects sources
whose publication date is unverified. Each rejection is counted and explained
as a gap; it is never quietly folded into the world state.

Researchers can exclude an active source. Exclusion creates Pack v2 or later,
removes dependent claims, records the excluded source ID, marks downstream
stages for rebuild, and leaves every earlier Pack intact. Later research honors
the exclusion so a delayed result cannot silently reintroduce the source.

## Untrusted content and privacy

Uploaded and retrieved text is data, never instruction. The sanitizer removes
active elements such as scripts, styles, iframes, objects, and embeds, detects
instruction-like patterns, and quarantines suspicious uploaded/retrieved
material before it can yield claims. Raw source text cannot change tools,
budgets, output schemas, credentials, or policy. Only bounded inert excerpts
enter the Pack.

Audit exports include Pack and research-run lineage, counts, states, hashes,
source metadata, and fingerprints. They do not export raw notes, document
contents, claim text, assumptions, safe queries, credentials, or hidden
instructions. Workspace and role checks apply at the domain boundary, and
ordinary viewers cannot exclude sources or queue research.

## Interface behavior

`GET /simulations/:id/context` is the human-readable inspector. It presents the
question interpretation, attributed sources, grounded claims, model priors,
assumptions, gaps, and retrieval plan in English or Russian. Internal provider,
queue, and worker names are deliberately omitted. Raw retrieval requests are
available only in a collapsed disclosure. Source exclusion is a quiet,
explicit mutation available to authorized researchers; it never edits history.

The Build screen links to Context as a first-class stage. Run remains disabled
until later epics produce and validate the remaining Population, Script,
Observation, Budget, Route, and Preview artifacts.

## Operating and release boundary

This epic proves deterministic construction, immutable lineage, direct-source
safety, mocked bounded provider behavior, failure recovery, authorization, and
responsive browser behavior. It does not prove a specific production model or
search provider, public latency percentile, provider cost, or production data-
flow claim.

Before public launch, every enabled production route must pass staging tests for
valid structured output, timeout, rate limit, malformed response, partial
usage, cancellation, cost recording, unavailable model, oversized context, and
both supported languages. Performance targets must be measured under normal
provider conditions before they appear in marketing copy.

Implementation progress and evidence are tracked in
`docs/hydra-blueprint-studio-implementation-status.md`.
