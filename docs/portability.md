# Portable Simulation and Run Packs

Hydra exports portable, declarative files for moving a validated Simulation,
auditing a completed Run, or using an external model without connecting it as a
provider. Portable files never contain provider credentials or executable code.

## Simulation Pack

A `.hydra-simpack` contains:

- a reproducibility `README.md`;
- the exact `.hydra-blueprint` package;
- the Simulation Version and input metadata;
- Context Pack, Population Model, Simulation Script, and Observation Plan;
- model capability requirements and route metadata;
- the hard Budget Plan and price snapshot;
- passed preview evidence;
- `manifest.json` with compatibility, privacy, lineage, validation, and every
  file hash;
- raw source input only when an authorized editor explicitly includes it.

The default interface export excludes raw sources and provider details. It can
also pseudonymize structured identities. Redaction always excludes raw source
text, even when both controls are selected.

### Import sequence

Hydra saves nothing until all of these checks pass:

1. ZIP structure, path, link, executable, encryption, compression, count, and
   size checks;
2. exact manifest file set, SHA-256 file hashes, and manifest content hash;
3. Pack format, minimum Hydra version, schema, and compiler compatibility;
4. embedded Blueprint safety, schema, capability, and lineage checks;
5. Simulation, Context, Population, Script, Observation, and preview validation;
6. destination route resolution by compatible capability, never credentials or
   source database identifiers;
7. destination price resolution inside the preserved hard budget limits;
8. Population recompilation and a fresh bounded Script preview;
9. one atomic transaction creating and activating the runnable Simulation.

If the raw source file is absent, the imported Simulation records empty raw
inputs and a warning. If provider or pricing facts differ, Hydra records the
destination binding and portable origin. A missing Balanced simulation
capability blocks import with a configuration instruction.

## Run Pack

A `.hydra-run` is available only for a completed Run. It contains:

- the exact historical `.hydra-simpack` used by that Run;
- the Run record, seed, engine, Pack, decision-manifest, state, result, and
  Analysis hashes;
- ordered `events.jsonl`, `decisions.json`, and `transactions.jsonl`;
- the immutable Analysis Pack;
- every Report version and its validation/usage lineage;
- aggregate usage and a reproducibility README;
- a manifest describing compatibility, lineage, validation, and privacy.

Recovery snapshots are excluded. They are deployment-local crash-recovery
state, while the Run Pack is a portable audit and replay artifact. Interface
defaults also exclude raw sources, provider details, and recorded model
rationales. Identities may be pseudonymized.

Quick Runs reproduce from the exact Simulation Pack, seed, and compatible
engine. Balanced exact replay additionally consumes the recorded decisions. A
fresh rerun may call a model again and is always a new Run with explicit
lineage.

## Manual external-model workflow

This workflow supports local CLIs, hosted chat products, restricted corporate
models, and any other model that can return JSON:

1. Open the Simulation Build page and download the external-model request.
2. Run its `research`, `agents`, and `simulation` modules in that order.
3. Pass each validated module output to the next module as the preceding
   artifact.
4. Assemble the three results in the request's `expected_upload` object.
5. Upload that JSON on the same Build page.

The request contains exact instructions, JSON Schemas, Simulation and Blueprint
hashes, base artifact hashes, source metadata, and bounded preceding artifacts.
It excludes raw source text and credentials.

Hydra rejects stale lineage, invalid JSON, schema violations, changed questions,
unknown source claims, unverified grounding, changed Population identifiers or
counts, invalid Script operations, and failed previews. A successful import
appends new immutable Context, Population, Script, and Preview versions in one
transaction. External provider usage is recorded as external and unmetered; it
is never presented as Hydra-metered cost.

## Privacy controls

| Control | Default | Effect |
|---|---:|---|
| Raw sources | Excluded | Adds notes, attachment text, and URL inputs only after explicit editor action. |
| Structured identities | Original | Optional deterministic pseudonyms for identity fields, agent identifiers, email, phone, address, filenames, and URL credentials/query/fragment. |
| Provider details | Excluded in the interface | Optional provider/model names and price metadata; credentials are never included. |
| Model rationales | Excluded in Run Pack interface | Optional recorded prompts, outputs, scores, and short rationales. |
| Recovery snapshots | Always excluded | Operational recovery data is not part of the portable audit file. |

Structured redaction is not a promise that arbitrary free-form custom Blueprint
instructions are anonymous. Review custom instructions and every raw-source
export before sharing it outside the workspace.

## Archive limits

- 8 MB compressed;
- 64 MB total uncompressed;
- 32 MB per file;
- 64 entries;
- 5 MB for a manual external-model JSON upload;
- standard unencrypted ZIP using stored or deflate compression;
- no ZIP64, links, special files, executable paths, modes, or magic bytes.

The web endpoints are authenticated, workspace-scoped, CSRF-protected where
they mutate state, rate-limited, and serve downloads with `private, no-store`
and `nosniff` headers.

## Compatibility and troubleshooting

- **Upgrade or re-export:** the format, minimum Hydra version, schema, compiler,
  or engine is unsupported.
- **Configure a model capability:** a Balanced Pack needs a compatible
  structured simulation route in the destination workspace.
- **Download a new external request:** the Simulation, Blueprint, Context,
  Population, or Script changed before the manual upload returned.
- **Correct the external JSON:** one module does not match the exact Blueprint
  schema or semantic limits.
- **Review file size and extension:** use `.hydra-simpack`, `.hydra-run`, or the
  requested `.json` within the documented limits.

Do not rename an unrelated ZIP and expect it to import. Hydra validates the
declared inner format and exact file set independently from the filename.

