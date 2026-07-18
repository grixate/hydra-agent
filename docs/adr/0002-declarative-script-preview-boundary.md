# ADR 0002: Declarative Script and preview boundary

- Status: Accepted
- Date: 2026-07-18
- Governing specification: `Hydra_Simulations_Blueprint_First_Development_Spec_2026-07-18.md`

## Context

The legacy SimLab contains scenario records and deterministic execution code,
but its script shape is tied to the earlier Decision Replay product. The
Blueprint-first product needs a general, portable contract with explicit time,
actions, resources, events, perception, policies, transitions, measurements,
and stopping behavior. It must catch invalid references and unsafe or
impossible behavior before a production run.

Storing a Script without its preflight outcome would make readiness ambiguous.
Storing preview state inside the Script would either make an otherwise immutable
contract mutable or conflate a model definition with evidence that a particular
compiler checked it.

## Decision

Hydra adds two immutable, workspace-scoped artifacts:

- `simulation_scripts` stores the exact declarative contract, lineage,
  validation, generation metadata, status, and semantic content hash;
- `simulation_script_previews` stores one exact Script/Population miniature-run
  outcome, bounds, seed, safe summary, safe errors, and result hash.

The active Script must match the Simulation's active Version, Context Pack, and
Population Model. Context and Population changes atomically compile and
activate a new Script and preview. Identical manual rebuilds are idempotent.

V1 is interpreted from a typed, bounded AST and closed operator allowlists. It
cannot contain or invoke arbitrary code, tools, providers, or external side
effects. Hybrid decisions require an explicit model budget and deterministic
fallback. A generated contract can receive no more than one repair attempt.

The preview is deterministic, provider-free, limited to two rounds and 12
representatives, and uses the exact Population seed. A failed preview produces
an inspectable blocked artifact and prevents later execution. It never falls
through to a full run.

Legacy scenarios remain compatibility inputs. They are not rewritten and do
not become the general contract.

## Consequences

### Positive

- Readiness has durable evidence rather than an in-memory boolean.
- Definitions and validation outcomes can be versioned and audited separately.
- Provider credentials are unnecessary for the safe baseline.
- JSON and YAML exports are portable without carrying executable code.
- Every upstream change has exact, database-enforced downstream lineage.

### Costs and constraints

- The general execution adapter must translate this contract into the reused
  run/event/snapshot infrastructure instead of directly executing legacy
  scenario records.
- Preview support and full-engine support must evolve together; unsupported
  valid operators must fail safely until implemented.
- A passed preview is necessary but not sufficient for execution. Pack, budget,
  route, and engine release gates remain separate.

## Rejected alternatives

- **Execute generated Elixir or JavaScript:** violates portability, reviewability,
  and the fail-closed security boundary.
- **Reuse the legacy scenario schema unchanged:** cannot represent the required
  general clock, perception, policy, observation, and resource semantics.
- **Store preview fields on the Script row:** conflates immutable definition and
  validation evidence, and prevents multiple compiler-era checks.
- **Treat preview failure as a transient warning:** makes execution outcomes
  unpredictable and violates the required failed-preview block.
- **Require production-provider credentials:** makes a safe deterministic
  contract unnecessarily dependent on external configuration.
