# Blueprint packages

Hydra Blueprints are portable, declarative `.hydra-blueprint` ZIP archives.
They contain instructions, JSON Schemas, examples, and a human-readable README;
they never contain or execute application code.

## Product contract

- A Blueprint is either a system built-in or belongs to one workspace.
- A Blueprint Version is immutable after insertion.
- A simulation keeps the exact Blueprint Version it was built with.
- The first release provisions exactly `general-agent-simulation` and
  `decision-replay` as read-only built-ins.
- Editing a workspace Blueprint creates a higher semantic version. It never
  rewrites previous content.
- Export is deterministic: equal semantic content produces equal package bytes
  and the same SHA-256 content hash.

## Archive structure

Every package uses a single `blueprint/` root with:

- `blueprint.yaml`;
- four Markdown modules under `instructions/`;
- five JSON Schemas under `schemas/`;
- optional inert examples under `examples/`;
- `README.md` with provider-independent usage instructions.

The manifest declares localized names and descriptions, input variables,
module-to-schema references, required capabilities, defaults, compatibility,
and optional file hashes.

## Import boundary

Import is fail-closed and happens in memory only after the central directory is
inspected. Hydra rejects:

- archives over 2 MB compressed or 10 MB uncompressed;
- more than 80 entries or any file over 2 MB;
- absolute paths, traversal, duplicate paths, invalid UTF-8 names, symlinks,
  special files, encryption, ZIP64, and unsupported compression;
- executable extensions, executable file modes, and executable content;
- YAML aliases, anchors, and explicit tags;
- missing files, undeclared references, invalid or unsafe JSON Schemas,
  mismatched declared hashes, invalid semantic versions, duplicate variables,
  and unsupported required capabilities.

Unknown optional files are ignored and are not imported into active content.
External schema references are rejected; local references remain inside the
validated package boundary.

## Operator lifecycle

Built-ins are provisioned idempotently during seeds and release migrations.
Ordinary workspace viewers may inspect and export Blueprints. Researchers and
workspace administrators may duplicate, import, test, and version workspace
Blueprints. Only system administrators or workspace owners/administrators see
Operations navigation.

`Test Blueprint` is provider-free and does not publish. It validates the
package, generates deterministic mock artifacts for three agents and two
rounds, executes the miniature, and displays validation failures, warnings,
provider calls, and cost.

## Configuration

`HYDRA_PRODUCT_SURFACE=blueprint_studio` sends signed-in users to the Blueprint
library. The safe default remains `legacy_simlab` during the staged migration.
`HYDRA_BLUEPRINT_IMPORT=false` can disable package import independently without
changing stored Blueprints.

Legacy SimLab routes and records remain available while
`HYDRA_LEGACY_SIMLAB=true`.
