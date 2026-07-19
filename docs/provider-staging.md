# Provider staging and failure qualification

Hydra treats provider qualification as an explicit release action. A configured
route is not production-ready merely because a credential exists or a health
endpoint answers.

## What the probe proves

`HydraAgent.Release.probe_provider/2` sends one bounded, low-temperature request
through the same provider facade used by runtime work. It requires:

- an enabled `openai_compatible`, `anthropic`, or `ollama` provider owned by the
  selected workspace;
- successful authentication and transport;
- an exact two-field JSON response containing a random nonce;
- non-negative input, output, and total token usage;
- a response inside the adapter's strict contract.

The returned report contains provider/model names, elapsed time, request ID when
available, normalized usage, and pass/fail classifications. It never contains
the prompt, returned content, credential, endpoint, or raw provider body.

## Run the one-request live probe

1. Configure the provider in Operations and enable it for the pilot workspace.
2. Inject the environment variable named by that provider's credential
   reference into the running release.
3. Confirm that the chosen model is low-cost and allowed for staging.
4. Run:

```sh
bin/hydra_agent eval 'HydraAgent.Release.probe_provider("workspace-slug", "Provider name")'
```

This makes one potentially billable request. Store the safe result with the
release evidence. A successful example has `status: "passed"` and all checks
set to `"passed"`. Any error result blocks that route from pilot use.

## Failure classifications

| Classification | Meaning | Operator response |
|---|---|---|
| `authentication` | Provider returned HTTP 401 | Replace or rebind the credential reference, then probe again. |
| `authorization` | Provider returned HTTP 403 | Confirm project/model access and organization policy. |
| `rate_limit` | Provider returned HTTP 429 | Wait for the provider window or select a qualified fallback. Do not loosen Hydra budgets. |
| `credential` | The referenced environment variable is absent | Inject the named secret into the release process; never store its value in Hydra. |
| `transport` | DNS, TLS, timeout, connection, or adapter transport failed | Check egress, TLS, endpoint, and provider availability. |
| `response_contract` | Content or usage was missing or malformed | Disable the route or use a supported model/configuration. |
| `request_envelope` | The request exceeded Hydra's size limit | Reduce the input; do not bypass the adapter boundary. |
| `unsupported` | The route is mock or another unqualified kind | Select a supported production adapter. |

The automated fault suite covers 401, 403-class handling, 429, malformed
successes, missing/invalid usage, oversized input, transport exceptions, raw
body suppression, and exact structured responses. Run it with:

```sh
mix test \
  test/hydra_agent/provider_staging_test.exs \
  test/hydra_agent/providers/openai_compatible_failure_injection_test.exs \
  test/hydra_agent/providers/anthropic_ollama_failure_injection_test.exs
```

## Codex CLI boundary

A local interactive Codex login is valid user/session state for local workflows,
but it is not a workspace-scoped server credential. Hydra therefore does not
silently inherit an ambient Codex CLI login. For automation, use an explicitly
injected `CODEX_API_KEY` or trusted `CODEX_ACCESS_TOKEN` in a separately reviewed
adapter; for provider-backed Hydra runs, use the provider configuration and
staging path above. Mock and ambient CLI routes must never be recorded as a
passed production-provider gate.

## Release evidence

Record, without secrets:

- release image digest and commit;
- workspace slug and provider display name;
- adapter kind and model;
- safe probe result and UTC time;
- injected-failure suite commit and result;
- owner who accepted cost, region, retention, and provider terms;
- fallback route and its independent probe result, if enabled.
