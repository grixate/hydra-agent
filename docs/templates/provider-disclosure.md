# Hydra provider disclosure — operator template

> Create one row per enabled route and fallback. A route is not approved until
> its live staging probe and legal/privacy review pass.

| Stage/capability | Provider and model | Local/external | Data categories sent | Region | Provider retention/training terms | Credential owner | Live probe date/result | Fallback |
|---|---|---|---|---|---|---|---|---|
| Build/context | [name/model] | [local/external] | [bounded prompts/excerpts/metadata] | [region] | [link/summary] | [owner] | [UTC/pass] | [route/none] |
| Balanced simulation | [name/model] | [local/external] | [decision prompt and bounded synthetic state] | [region] | [link/summary] | [owner] | [UTC/pass] | [route/none] |
| Report | [name/model] | [local/external] | [Analysis Pack references and bounded metrics] | [region] | [link/summary] | [owner] | [UTC/pass] | [route/none] |
| Search/retrieval | [name] | [local/external] | [safe query/public URL] | [region] | [link/summary] | [owner] | [UTC/pass] | [route/none] |

For each route, also record:

- allowed workspace(s), use case, model version policy, and monthly ceiling;
- hard model-call/token/cost caps and how unknown pricing is handled;
- whether structured output and both supported interface languages were tested;
- timeout, 401/403, 429, malformed response, missing usage, cancellation,
  oversized input, and unavailable-model outcomes;
- provider incident and credential-rotation procedure;
- date the route must be requalified after model, endpoint, adapter, credential
  scope, region, or terms change.

Quick simulation execution makes zero simulation provider calls. This does not
mean the earlier Build or later Report stages are provider-free. A local Codex
CLI login is user/session state and must not be listed as a workspace production
credential unless a separately reviewed explicit adapter and auth boundary are
deployed.
