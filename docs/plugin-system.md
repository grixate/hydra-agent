# Plugin System

Hydra plugins are workspace-scoped runtime capability bundles. The runtime
records the manifest, approvals, capabilities, events, and readiness findings in
Postgres; execution remains policy-gated through the existing tool, MCP,
connector, room, skill, and agent-pack surfaces.

The primary web management UI is not a runtime plugin. It should be a separate
first-party client app that talks to Hydra through the same API as the CLI.
Plugins can still declare optional launchable `client_surfaces` for companion
apps such as design studios or coding consoles, but Hydra does not mount
arbitrary plugin UI code.

## Manifest

Plugins declare a `.hydra-plugin/plugin.json` file. The current manifest version
is exposed by:

```sh
bin/hydra plugins schema
```

Required top-level fields are:

- `plugin_version`
- `slug`
- `name`
- `version`
- `trust_level`
- `permissions`
- `capabilities`

Recommended top-level fields are:

- `package_type`, one of `runtime_plugin`, `client_app`, or `hybrid`
- `config_schema` for non-secret workspace configuration
- `compatibility.hydra_version`
- `dependencies`

Supported capability fields are `tools`, `tool_bundles`, `agent_packs`,
`skills`, `mcp_servers`, `connectors`, `room_channels`, `cli_commands`,
`client_surfaces`, and `migrations`. Legacy manifests may still use `web_routes`;
Hydra maps them to `client_surface` capabilities.

Plugin permissions can include `api_scopes`, which allow client apps to render
consent, setup, and capability screens without hard-coded plugin knowledge:

```json
{
  "permissions": {
    "side_effect_classes": ["read_only"],
    "requires_approval": true,
    "env_refs": ["MY_PLUGIN_URL"],
    "api_scopes": ["workspaces:read", "plugins:read"]
  }
}
```

Non-secret configuration belongs in `config_schema`; raw secrets still belong in
environment variables referenced by name.

## Lifecycle

Local plugins can be scanned and installed with:

```sh
bin/hydra plugins scan --workspace WORKSPACE_ID --path plugins/examples/design-studio
bin/hydra plugins install --workspace WORKSPACE_ID --path plugins/examples/design-studio --approved-by operator
bin/hydra plugins enable --workspace WORKSPACE_ID --id PLUGIN_ID --approved-by operator
bin/hydra plugins doctor --workspace WORKSPACE_ID --id PLUGIN_ID
```

Git plugins must come from an allowlisted URL prefix and a full 40-character
commit SHA:

```sh
bin/hydra plugins install \
  --workspace WORKSPACE_ID \
  --source-url https://github.com/example/hydra-plugin \
  --source-ref 0123456789abcdef0123456789abcdef01234567 \
  --approved-by operator
```

Plugins can be upgraded, disabled, or uninstalled through the matching CLI/API
commands. State transitions record plugin events for auditability.

Non-secret plugin configuration is stored in Hydra and validated against the
plugin manifest's `config_schema`:

```sh
bin/hydra plugins config --workspace WORKSPACE_ID --id PLUGIN_ID
bin/hydra plugins configure \
  --workspace WORKSPACE_ID \
  --id PLUGIN_ID \
  --config-json '{"team_id":"eng"}' \
  --configured-by operator
```

Secrets must not be placed in this config. Use `env_refs` for secrets and set
the referenced environment variables outside Hydra.

## Security Defaults

- Plugins are inactive until explicitly enabled.
- Installing, enabling, upgrading, uninstalling, and applying migrations require
  an approving actor.
- Enabling fails closed when doctor reports errors: missing env refs, invalid
  config, missing dependencies, incompatible runtime version, or unavailable
  trusted callbacks.
- Raw secrets are rejected from manifests; use environment variable references
  such as `MY_PLUGIN_TOKEN`.
- Raw secrets are rejected from stored plugin config as well.
- Dangerous side effects must keep `requires_approval: true`.
- Name conflicts with core tools and bundles are rejected by default.
- `compatibility.hydra_version` is enforced during scan/install.
- `dependencies` are checked before enable, including simple version ranges such
  as `>=1.0.0 <2.0.0`.
- Trusted in-process execution and migrations require `trust_level: "trusted"`.
- Client surfaces are discovered as authenticated launch specs; external plugin
  UI code is not mounted by the core runtime.
- Webhook and trusted-module tool adapters currently fail closed unless the
  runtime explicitly supports them.

## Client Apps

Hydra's native operator surface is the CLI. Web management, design, mobile, and
ops interfaces should be API clients. A client app can discover plugin-aware
state through:

```sh
bin/hydra plugins client-contract --workspace WORKSPACE_ID
bin/hydra plugins client-surfaces --workspace WORKSPACE_ID
```

The client contract includes installed plugins, capability summaries, manifest
schema, requested API scopes, config schemas, dependencies, and enabled client
surfaces. This lets a management UI work independently of which runtime plugins
are installed while still reflecting plugin-provided capabilities.

## Runtime Surfaces

Enabled plugin capabilities participate in:

- tool discovery and tool policy authorization
- tool bundles
- starter agent packs
- durable workspace skills
- MCP server templates
- connector provider specs
- Telegram and room channel specs
- slash-command expansion in rooms
- optional client-surface discovery

Example manifests live under `plugins/examples/` for design-studio and
coding-agent plugin shells. A complete management UI should live as a separate
client app, not as a runtime plugin.
