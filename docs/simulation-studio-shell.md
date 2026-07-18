# Simulation Studio shell

The Blueprint-first Simulation Studio is an additive product surface for
creating durable simulation drafts before any build or provider work begins.
Epic 2 established the lifecycle, persistence, input boundary, permissions, and
honest empty states. Epic 3 now creates a usable immutable Context Pack for
every new Simulation, but a runnable Simulation Pack still does not exist.

## Runtime surface

Set `HYDRA_PRODUCT_SURFACE=blueprint_studio` to make the authenticated product
entry point `/simulations`. The default remains `legacy_simlab`, and the legacy
`/lab/*` routes and records are not rewritten. The runtime value is parsed from
a closed allowlist during startup; an unknown value fails fast.

The Studio routes are:

| Route | Purpose |
|---|---|
| `GET /simulations` | Workspace-scoped Simulation list and legacy-study links. |
| `GET /simulations/new` | One-question composer. |
| `POST /simulations` | Atomically create a Simulation, immutable Version, Context Pack v1, and six Build stages. |
| `GET /simulations/:id` | Redirect to the durable current lifecycle stage. |
| `GET /simulations/:id/build` | Build progress, Blueprint instructions, and readiness summary. |
| `GET /simulations/:id/context` | Inspect sources, claims, priors, assumptions, gaps, and retrieval state. |
| `GET /simulations/:id/run` | Run checkpoint; disabled until a valid Pack exists. |
| `GET /simulations/:id/results` | Results checkpoint with honest empty states. |
| `GET /simulations/:id/compare` | Comparison checkpoint. |
| `POST /simulations/:id/duplicate` | Create an independent v1 snapshot with provenance. |
| `POST /simulations/:id/archive` | Archive without deleting history. |
| `POST /simulations/:id/context/build` | Revalidate current context; identical content is a no-op. |
| `POST /simulations/:id/context/research` | Queue bounded durable research when a route is configured. |
| `POST /simulations/:id/context/sources/:source_id/exclude` | Create a new Pack version without the source or dependent claims. |

Workspace viewers may inspect. Researchers, administrators, owners, and system
administrators may create, duplicate, or archive. Operator-only navigation is
kept out of the ordinary viewer experience.

## Durable contract

Creation is one database transaction:

1. create the workspace-scoped `simulations` identity;
2. create immutable `simulation_versions` v1 with the exact active Blueprint
   Version and a deterministic content hash;
3. create deterministic immutable Context Pack v1;
4. create the six product-language `simulation_build_stages` rows;
5. activate Version v1 and Pack v1 only after all rows exist.

PostgreSQL constraints and triggers enforce the tenant and identity boundary,
not only Ecto changesets. A Simulation Version cannot be updated. The active
Version must belong to the same Simulation, workspace, and selected Blueprint.
Build-stage identity is immutable, Blueprint availability is workspace-safe,
duplicate provenance and legacy-study links cannot cross workspaces, and any
recorded owner or author must be active and authorized.

The six durable stages are:

1. understanding the question;
2. finding context;
3. designing the population;
4. writing the rules;
5. checking the model;
6. preparing the run.

They are persisted as domain state. The interface never exposes queue, worker,
or provider implementation details.

## Composer input boundary

All optional input is normalized before persistence and revalidated at the
domain boundary. This prevents controller-only validation from becoming a
security assumption.

| Input | Limit and behavior |
|---|---|
| Question | Required by the Version changeset; used to derive a title when omitted. |
| Notes/data | UTF-8 inert text, at most 20 KB. |
| URLs | At most 10 public HTTPS URLs; credentials, fragments, IP literals, and localhost names are rejected. |
| Files | At most 5 files, 1 MB each and 2 MB total. Only `.txt`, `.md`, `.markdown`, `.csv`, and `.json`. |
| JSON | Must parse before it can be stored. |
| File provenance | Basename, extension, media type, byte count, SHA-256, and inert text are recorded; temporary paths are never stored. |
| Population | 10–100,000; default derives from the selected Blueprint. |
| Locale | English or Russian. |
| Mode | Quick always available; Balanced and Deep require their runtime flags. |

Creation performs no retrieval and waits on zero provider calls. URLs are first
stored as pending references. After commit, bounded retrieval is queued through
the configured web route or through the credential-free direct-source route.
Network-safety policy is enforced again by the retrieval worker because DNS can
change between entry and use. Research failure cannot roll back the already
durable Simulation, Version, or usable Context Pack.

## Privacy and audit

The workspace audit export includes Simulation identities, immutable Version
metadata, Blueprint fingerprints, normalized source counts, URL safety state,
file metadata and hashes, and Build-stage state. It intentionally excludes raw
notes, file contents, and Blueprint instruction text. Records from another
workspace cannot enter the export.

The current UI reports what exists rather than forecasting missing values:
draft saved, Context Pack version and state, qualitative confidence, visible
gaps, and no invented cost. Run is disabled until later epics produce a
validated immutable Simulation Pack.

## Verification

Epic 2 is covered by domain, controller, authorization, database-trigger,
input-tampering, audit-privacy, refresh, duplicate, archive, locale, and route
tests. Visual evidence is stored in
`docs/screenshots/simulation-studio-epic2-2026-07-18/`.

The implementation ledger in
`docs/hydra-blueprint-studio-implementation-status.md` is authoritative for
which acceptance criteria have evidence and which remain open.

Epic 3 architecture, retrieval safety, local Codex adapter boundaries, and
release evidence are documented in `docs/automatic-context-pack.md`.
