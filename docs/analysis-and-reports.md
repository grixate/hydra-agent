# Analysis and governed Reports

Hydra presents completed Simulation results in three layers:

1. the **Run** is the authoritative execution record;
2. the **Analysis** is a deterministic, bounded view derived from that Run;
3. a **Report** is a validated model interpretation of the Analysis.

An Analysis or Report failure never changes a completed Run.

## Lifecycle

`HydraAgent.Simulations.AnalysisBuilder.ensure_for_run/1` creates the one
Analysis Pack for a completed Simulation Run. It verifies snapshot checksums and
exact lineage before publishing. Calling it again returns the same immutable
record. `build/1` can be used to recompute and compare the deterministic content
hash without inserting another row.

`HydraAgent.Simulations.ReportGenerator.queue/3` validates workspace authority,
the selected structured-generation route, language support, the bounded input
and output envelope, the price snapshot, and the optional regeneration source.
It then atomically inserts a queued Report and its Oban job. Each Analysis Pack
allows eight Report attempts.

The worker claims one attempt before calling the provider. Duplicate delivery
does not issue another request. If the worker is known to be retrying a Report
left in `running`, Hydra records `interrupted_provider_request` and stops. This
is intentionally conservative: the operator or user can create a new version,
while an automatic duplicate call cannot be taken back.

## Validation boundary

The model output must contain exactly:

- `title`;
- `summary`;
- nine `sections`, each with `heading`, `body`, and `references`;
- `limitations`;
- `recommended_next_steps`.

Hydra rejects unknown or missing fields, unknown references, values that do not
match the referenced Analysis numeric variants, invented URLs, unsupported
quotations, and unreferenced numeric claims. Ready Reports have
`validation_status=validated`; failed attempts have
`validation_status=rejected`, a public-safe failure code, and bounded structured
errors.

## Configuration

Report routes use enabled provider configurations advertising
`structured_generation`. Language capability metadata is enforced when present.
The selected route, model, route version, price, currency, Blueprint hash,
instruction hash, Analysis hash, token caps, and maximum reserved cost are
copied into the immutable Report attempt.

Local mock routes are suitable for tests and offline demonstrations. An
interactive Codex CLI login is not a production provider route today. Supporting
it requires an explicit adapter with stable request/response contracts, bounded
timeouts and cancellation, health checks, usage and price reporting, durable
provenance, and fail-closed policy behavior.

## Operator checks

Investigate Reports remaining in `queued` according to normal Oban queue health.
A `running` Report should exist only during one provider request. On worker
retry, it will become a terminal failure instead of being redispatched.

Common safe failure codes include:

- `provider_error` — the configured route failed;
- `invalid_report_json` — the route returned non-JSON content;
- `report_validation_failed` — references or claims did not pass validation;
- `invalid_report_usage` — provider usage was missing, malformed, or outside the
  reserved envelope;
- `interrupted_provider_request` — completion was ambiguous and no automatic
  duplicate was attempted.

Operators should fix route health or capability metadata, then ask the user to
create another Report version. Do not mutate or delete the failed attempt.

## Exports

The Results page offers:

- Analysis JSON;
- metrics CSV;
- ordered event CSV;
- resource-transaction CSV;
- Report Markdown;
- escaped printable HTML.

Analysis and Report exports carry content hashes and exact lineage. The event
and transaction CSV files preserve authoritative ordered records. Treat any
Report prose as model interpretation even when validation passes; it remains
directional simulation output, not observed evidence.

## Verification

Run the focused contract suite with:

```sh
mix test test/hydra_agent/simulations/analysis_report_test.exs \
  test/hydra_agent_web/controllers/simulation_controller_test.exs
```

Run `mix precommit` before release. Migration qualification should apply the
Analysis/Report migration, roll it back, and apply it again on a disposable
database before production deployment.
